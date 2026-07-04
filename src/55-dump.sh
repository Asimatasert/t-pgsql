# ==============================================================================
# DUMP
# ==============================================================================
cmd_dump() {
    meta_start
    log_info "Starting dump..."

    if [ -z "$FROM_CONNECTION" ]; then
        log_error "--from required"
        return 1
    fi

    parse_connection "$FROM_CONNECTION" "FROM" || { log_error "Invalid source connection: $FROM_CONNECTION"; return 1; }
    get_password "FROM"

    # Check if recent dump exists (skip_if_recent)
    if check_skip_recent; then
        return 0
    fi

    # Run health check before operation
    run_health_checks true false

    mkdir -p "$OUTPUT_DIR"

    local ts=$(date '+%Y%m%d_%H%M%S')
    local dump_base_name="${DUMP_NAME:-$FROM_DATABASE}"
    # Atomically reserve a unique filename (O_EXCL via noclobber) so two concurrent
    # dumps with the same name in the same second can't clobber each other — the
    # loser gets a _N suffix instead of overwriting the winner's backup.
    local dump_file="${OUTPUT_DIR}/${dump_base_name}_${ts}.dump" _n=0
    if [ "$DRY_RUN" != true ]; then
        while ! (set -o noclobber; : > "$dump_file") 2>/dev/null; do
            # Only retry for a genuine name COLLISION (the file exists). Any other
            # failure — unwritable dir, name too long — leaves no file, so error out
            # instead of spinning forever.
            if [ ! -e "$dump_file" ]; then
                log_error "Cannot create dump file (output dir not writable or name too long): $dump_file"
                return 1
            fi
            _n=$((_n + 1))
            [ "$_n" -gt 10000 ] && { log_error "Too many colliding dumps for ${dump_base_name}_${ts}"; return 1; }
            dump_file="${OUTPUT_DIR}/${dump_base_name}_${ts}_${_n}.dump"
        done
    fi

    log_info "From: ${FROM_DB_USER}@${FROM_DB_HOST}:${FROM_DB_PORT}/${FROM_DATABASE}"
    log_info "To: ${dump_file}"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would dump to: $dump_file"
        return 0
    fi

    # Build exclude options. These strings are later eval'd, so every table/schema
    # value MUST be shell-escaped with pq (printf %q) — a naive '...' wrapper let an
    # identifier containing a quote break out and run arbitrary shell commands.
    local exclude_opts=""
    if [ -n "$EXCLUDE_TABLES" ]; then
        IFS=',' read -ra arr <<< "$EXCLUDE_TABLES"
        for t in "${arr[@]}"; do
            exclude_opts="$exclude_opts --exclude-table=$(pq "$(trim "$t")")"
        done
    fi
    if [ -n "$EXCLUDE_SCHEMAS" ]; then
        IFS=',' read -ra arr <<< "$EXCLUDE_SCHEMAS"
        for s in "${arr[@]}"; do
            exclude_opts="$exclude_opts --exclude-schema=$(pq "$(trim "$s")")"
        done
    fi
    if [ -n "$EXCLUDE_DATA" ]; then
        IFS=',' read -ra arr <<< "$EXCLUDE_DATA"
        for t in "${arr[@]}"; do
            t=$(trim "$t")
            # Check for wildcard pattern (e.g., "public.*" or "audit.*")
            if [[ "$t" == *".*" ]]; then
                local schema_name="${t%.*}"
                log_info "Expanding wildcard: $t"
                local tables=""
                local wc_sql="SELECT schemaname || '.' || tablename FROM pg_tables WHERE schemaname='$(sqllit "$schema_name")'"
                if [ "$FROM_TYPE" = "ssh" ]; then
                    local wc_pre; wc_pre="$(remote_pgpass_preamble "$FROM_DB_USER" "$FROM_DB_PASSWORD")"
                    tables=$(ssh_exec "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}" \
                        "${wc_pre}psql -U $(pq "$FROM_DB_USER") -h $(pq "$FROM_DB_HOST") -p $(pq "$FROM_DB_PORT") -d $(pq "$FROM_DATABASE") -tAc $(pq "$wc_sql")")
                else
                    setup_local_pgpass "$FROM_DB_USER" "$FROM_DB_PASSWORD"
                    tables=$(psql -U "$FROM_DB_USER" -h "$FROM_DB_HOST" -p "$FROM_DB_PORT" -d "$FROM_DATABASE" -tAc "$wc_sql")
                    cleanup_local_pgpass
                fi
                for tbl in $tables; do
                    exclude_opts="$exclude_opts --exclude-table-data=$(pq "$tbl")"
                done
            else
                exclude_opts="$exclude_opts --exclude-table-data=$(pq "$t")"
            fi
        done
    fi

    # Build include-only options (--only-table -> -t, --only-schema -> -n).
    # Comma-separated lists become one -t/-n per item. pq-escaped (see above).
    local only_opts=""
    if [ -n "$ONLY_TABLES" ]; then
        IFS=',' read -ra arr <<< "$ONLY_TABLES"
        for t in "${arr[@]}"; do
            only_opts="$only_opts -t $(pq "$(trim "$t")")"
        done
    fi
    if [ -n "$ONLY_SCHEMAS" ]; then
        IFS=',' read -ra arr <<< "$ONLY_SCHEMAS"
        for s in "${arr[@]}"; do
            only_opts="$only_opts -n $(pq "$(trim "$s")")"
        done
    fi

    # Determine pg_dump's built-in (-Z) compression level from the --compress type:
    #   none            -> 0 (no compression at all)
    #   gzip            -> pg_dump compresses; honor --compress-level (or the
    #                      advanced --pg-compress-level override)
    #   zstd/xz/bzip2   -> 0: let the external compressor do the work. Compressing
    #                      twice (pg_dump -Z then zstd/xz/bzip2) wastes CPU and
    #                      usually yields a WORSE ratio than a single pass.
    local pg_zlevel="$PG_COMPRESS_LEVEL"
    case "$COMPRESS" in
        none)              pg_zlevel=0 ;;
        gzip)              [ "$PG_COMPRESS_LEVEL_SET" = true ] && pg_zlevel="$PG_COMPRESS_LEVEL" || pg_zlevel="$COMPRESS_LEVEL" ;;
        zstd|xz|bzip2)     pg_zlevel=0 ;;
    esac

    local result=0

    if [ "$FROM_TYPE" = "ssh" ]; then
        log_info "Dumping via SSH..."
        local remote_dump_dir="/tmp/t-pgsql"
        ssh -p "$FROM_SSH_PORT" "${SSH_OPTS[@]}" "${FROM_SSH_USER}@${FROM_SSH_HOST}" "mkdir -p $(pq "$remote_dump_dir") && chmod 700 $(pq "$remote_dump_dir")"
        local dump_base_name="${DUMP_NAME:-$FROM_DATABASE}"
        local remote_file="${remote_dump_dir}/${dump_base_name}_${ts}.dump"

        local cmd=""
        if [ "$SUDO" = true ]; then
            # Use sudo -u postgres (peer auth)
            cmd="sudo -u $(pq "$FROM_DB_USER") pg_dump"
            cmd="$cmd -h $(pq "$FROM_DB_HOST") -p $(pq "$FROM_DB_PORT")"
        else
            # Use password auth via remote PGPASSFILE (not argv)
            cmd="$(remote_pgpass_preamble "$FROM_DB_USER" "$FROM_DB_PASSWORD")pg_dump"
            cmd="$cmd -U $(pq "$FROM_DB_USER") -h $(pq "$FROM_DB_HOST") -p $(pq "$FROM_DB_PORT")"
        fi
        cmd="$cmd -Fc -Z${pg_zlevel} -v $exclude_opts $only_opts"
        cmd="$cmd -f $(pq "$remote_file") $(pq "$FROM_DATABASE")"

        # stdin-free: feed the command (with embedded pgpass preamble) via stdin so the
        # password never lands in the local ssh process argv.
        ssh_exec "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}" "$cmd"
        result=$?

        if [ $result -eq 0 ]; then
            log_info "Transferring..."
            if ! scp_transfer "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}:${remote_file}" "$dump_file"; then
                log_error "Transfer failed; leaving the source dump in place"
                result=1
            fi

            # Cleanup based on FROM_KEEP — ONLY after a successful transfer, so a
            # failed copy never deletes the only remaining copy on the source.
            if [ $result -eq 0 ] && [ "$FROM_KEEP" -eq 0 ]; then
                log_info "Cleaning source dump..."
                ssh -p "$FROM_SSH_PORT" "${SSH_OPTS[@]}" "${FROM_SSH_USER}@${FROM_SSH_HOST}" "rm -f $(pq "$remote_file")"
            elif [ $result -eq 0 ] && [ "$FROM_KEEP" -gt 0 ]; then
                log_info "Keeping last $FROM_KEEP dump(s) on source..."
                local dump_base_name="${DUMP_NAME:-$FROM_DATABASE}"
                local cleanup_cmd="cd $(pq "$remote_dump_dir") && ls -t $(pq "$dump_base_name")_*.dump 2>/dev/null | tail -n +$((FROM_KEEP + 1)) | xargs -r rm -f"
                ssh -p "$FROM_SSH_PORT" "${SSH_OPTS[@]}" "${FROM_SSH_USER}@${FROM_SSH_HOST}" "$cleanup_cmd"
            elif [ $result -eq 0 ]; then
                log_info "Keeping source dump (--from-keep -1)"
            fi
        fi
    else
        log_info "Dumping locally..."
        setup_local_pgpass "$FROM_DB_USER" "$FROM_DB_PASSWORD"

        local cmd="pg_dump -U $(pq "$FROM_DB_USER") -h $(pq "$FROM_DB_HOST") -p $(pq "$FROM_DB_PORT")"
        cmd="$cmd -Fc -Z${pg_zlevel} -v $exclude_opts $only_opts"
        cmd="$cmd -f $(pq "$dump_file") $(pq "$FROM_DATABASE")"

        eval "$cmd"
        result=$?
        cleanup_local_pgpass
    fi

    if [ $result -eq 0 ]; then
        local elapsed=$(format_elapsed $(($(date +%s) - META_START_EPOCH)))

        # External compression must happen BEFORE metadata is written, and
        # dump_file must be advanced to the compressed artifact so meta_write
        # sees an existing file (and DUMP_FILE reflects what really exists).
        if [ "$COMPRESS" != "gzip" ] && [ "$COMPRESS" != "none" ]; then
            if compress_file "$dump_file"; then
                case "$COMPRESS" in
                    zstd)  dump_file="${dump_file}.zst" ;;
                    xz)    dump_file="${dump_file}.xz" ;;
                    bzip2) dump_file="${dump_file}.bz2" ;;
                esac
            fi
        fi

        # Size of the final artifact that actually exists on disk
        local size=$(ls -lh "$dump_file" 2>/dev/null | awk '{print $5}')
        log_success "Dump complete: $dump_file ($size)"

        # Write metadata (meta_write sets META_ARTIFACT to the resulting file)
        meta_write "$dump_file" "success" 0
        local final_file="${META_ARTIFACT:-$dump_file}"

        # Cleanup
        cleanup_old_dumps

        # Post-operation health check (--health-check-after)
        run_post_health_check

        # Send notification
        local details=$(build_notify_details "DUMP" "Success" "$elapsed" "$size")
        send_notification "success" "Dump completed: ${FROM_DATABASE}" "$details"

        echo "DUMP_FILE=$final_file"
        echo "DUMP_SIZE=$size"
    else
        log_error "Dump failed: $result"
        # pg_dump opens its output file before connecting, so a failed run leaves a
        # partial/0-byte .dump behind. Remove it (and any half-written artifact) so a
        # failure does not leave a misleading archive in the output directory.
        rm -f "$dump_file" "${dump_file}.zst" "${dump_file}.xz" "${dump_file}.bz2" 2>/dev/null

        # Send notification
        local elapsed=$(format_elapsed $(($(date +%s) - META_START_EPOCH)))
        local details=$(build_notify_details "DUMP" "Failed" "$elapsed")
        send_notification "failed" "Dump failed: ${FROM_DATABASE}" "$details"

        return 1
    fi
}

