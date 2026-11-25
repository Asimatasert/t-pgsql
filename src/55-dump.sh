# ==============================================================================
# DUMP
# ==============================================================================
# Create the remote staging directory and verify it is safe to use: a real
# directory (not a symlink), owned by the connecting user, with no group/other
# permissions. The remote script only needs POSIX sh, id, ls and awk, so it
# behaves the same on Linux and BSD/macOS hosts. A directory pre-created by
# another account fails this check and the operation is aborted.
# Usage: remote_stage_prepare PORT USER@HOST DIR
remote_stage_prepare() {
    local port="$1" dest="$2" dir="$3" script
    local body='umask 077
bad() { echo "remote staging directory $d is unsafe: $1" >&2; exit 1; }
perms() { ls -ldn "$d" 2>/dev/null | awk '"'"'{print substr($1,1,1), substr($1,5,6), $3}'"'"'; }
[ -L "$d" ] && bad "it is a symlink"
mkdir -p "$d" 2>/dev/null
[ -L "$d" ] && bad "it is a symlink"
[ -d "$d" ] || bad "it cannot be created"
set -- $(perms)
[ "$1" = d ] || bad "it is not a directory"
[ "$3" = "$(id -u)" ] || bad "it is not owned by the connecting user"
chmod 700 "$d" 2>/dev/null
set -- $(perms)
[ "$1" = d ] && [ "$2" = "------" ] || bad "it grants group/other permissions"
exit 0'
    script="d=$(shq "$dir")
$body"
    if ! ssh_exec "$port" "$dest" "$script"; then
        log_error "Remote staging directory $dir failed the safety check on ${dest#*@}; aborting"
        return 1
    fi
    return 0
}

# Extended regex matching exactly one base name's staged dumps on a remote
# host: base + _YYYYMMDD_HHMMSS (+ optional _N) + .dump (+ compression ext).
# Mirrors list_dumps_for_base so "prod" never matches "prod_v2_...".
# The result has no ^ or / anchor; callers add their own.
remote_dump_match_re() {
    # Escape each ERE metacharacter with a bracket expression instead of a
    # backslash, so GNU grep 3.8+ never reports a "stray \" warning. "/" is an
    # ordinary character and is left alone.
    local s="$1" esc="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            '.'|'*'|'+'|'?'|'('|')'|'{'|'}'|'|'|'$'|'[') esc+="[$c]" ;;
            ']')  esc+='[]]' ;;
            '^')  esc+='\^' ;;
            '\')  esc+='[\]' ;;
            *)    esc+="$c" ;;
        esac
    done
    printf '%s%s' "$esc" '_[0-9]{8}_[0-9]{6}(_[0-9]+)?\.dump(\.zst|\.xz|\.bz2)?$'
}

# Confirm a freshly created dump is usable before any rotation removes older
# dumps. Invalid means: empty, missing the PGDMP magic bytes, or failing the
# compression stream test. A plain .dump that the LOCAL pg_restore cannot list
# is still valid: an older client cannot read archives written by a newer
# pg_dump, which is normal for dumps taken on a remote host. A missing tool only
# produces a warning.
verify_dump_integrity() {
    local f="$1" name; name=$(basename "$f")
    if [ ! -s "$f" ]; then
        log_error "Integrity check failed: $name is missing or empty"
        return 1
    fi
    local dec="" tool=""
    case "$f" in
        *.tar.gz)
            if command -v tar >/dev/null 2>&1 && ! tar -tzf "$f" >/dev/null 2>&1; then
                log_error "Integrity check failed: $name is not a readable tar.gz archive"
                return 1
            fi
            return 0 ;;
        *.dump.zst) tool=zstd;  dec="zstd -dc" ;;
        *.dump.xz)  tool=xz;    dec="xz -dc" ;;
        *.dump.bz2) tool=bzip2; dec="bzip2 -dc" ;;
        *.dump)     tool="" ;;
        *) return 0 ;;
    esac

    local magic
    if [ -n "$tool" ]; then
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_warn "Cannot verify $name: '$tool' not found; skipping readability check"
            return 0
        fi
        if ! "$tool" -t "$f" >/dev/null 2>&1; then
            log_error "Integrity check failed: $name failed the $tool stream test"
            return 1
        fi
        # First 5 bytes through the decompressor only (cheap, stops early).
        magic=$($dec "$f" 2>/dev/null | head -c 5)
    else
        magic=$(head -c 5 "$f" 2>/dev/null)
    fi
    if [ "$magic" != "PGDMP" ]; then
        log_error "Integrity check failed: $name does not look like a PostgreSQL custom-format archive (missing PGDMP header)"
        return 1
    fi

    if [ -z "$tool" ] && command -v pg_restore >/dev/null 2>&1 && ! pg_restore -l "$f" >/dev/null 2>&1; then
        log_warn "$name could not be listed by the local pg_restore (probably a newer server version); treating it as valid"
    fi
    return 0
}

# Set the new dump aside so no dump pattern (keep-N, retention, restore, fetch,
# list) matches it any more. It is not deleted. Usage: quarantine_dump FILE
quarantine_dump() {
    local f="$1"
    if [ -e "$f" ] && mv -f "$f" "${f}.invalid" 2>/dev/null; then
        log_error "The unusable dump was kept as ${f}.invalid; older dumps were not rotated"
    else
        log_error "Older dumps were not rotated"
    fi
}

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
                local tables="" wc_rc=0
                # format(%I) quotes upper-case/dotted names so pg_dump's pattern
                # parser sees each schema.table exactly.
                local wc_sql="SELECT format('%I.%I', schemaname, tablename) FROM pg_tables WHERE schemaname='$(sqllit "$schema_name")'"
                if [ "$FROM_TYPE" = "ssh" ]; then
                    local wc_pre; wc_pre="$(remote_pgpass_preamble "$FROM_DB_USER" "$FROM_DB_PASSWORD")"
                    tables=$(ssh_exec "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}" \
                        "${wc_pre}psql -U $(pq "$FROM_DB_USER") -h $(pq "$FROM_DB_HOST") -p $(pq "$FROM_DB_PORT") -d $(pq "$FROM_DATABASE") -tAc $(pq "$wc_sql")") || wc_rc=$?
                else
                    setup_local_pgpass "$FROM_DB_USER" "$FROM_DB_PASSWORD"
                    tables=$(psql -U "$FROM_DB_USER" -h "$FROM_DB_HOST" -p "$FROM_DB_PORT" -d "$FROM_DATABASE" -tAc "$wc_sql") || wc_rc=$?
                    cleanup_local_pgpass
                fi
                if [ "$wc_rc" -ne 0 ]; then
                    # Fail closed: dumping without the exclusion would leak data the
                    # user asked to keep out of the dump.
                    log_error "Could not expand --exclude-data pattern '$t' (table lookup failed); aborting dump"
                    rm -f "$dump_file"
                    return 1
                fi
                local tbl
                while IFS= read -r tbl; do
                    [ -z "$tbl" ] && continue
                    exclude_opts="$exclude_opts --exclude-table-data=$(pq "$tbl")"
                done <<< "$tables"
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
    local integrity_checked=""
    local remote_compressed=false comp_ext=""

    if [ "$FROM_TYPE" = "ssh" ]; then
        log_info "Dumping via SSH..."
        local remote_dump_dir="/tmp/t-pgsql"
        if ! remote_stage_prepare "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}" "$remote_dump_dir"; then
            rm -f "$dump_file"
            local _elapsed; _elapsed=$(format_elapsed $(($(date +%s) - META_START_EPOCH)))
            send_notification "failed" "Dump failed: ${DUMP_NAME:-$FROM_DATABASE}" "$(build_notify_details "DUMP" "Failed" "$_elapsed")"
            return 1
        fi
        local dump_base_name="${DUMP_NAME:-$FROM_DATABASE}"
        local remote_file="${remote_dump_dir}/${dump_base_name}_${ts}.dump"

        # Purge leftovers from failed/interrupted runs (--from-stale). Post-transfer
        # cleanup never runs when a run dies mid-way, so its dump would sit in the
        # source temp dir forever. Only with --from-keep 0: a positive keep policy
        # manages its own retention, and -1 means keep everything on the source.
        local stale_min=$(( $(parse_time_to_seconds "$FROM_STALE") / 60 ))
        if [ "$FROM_KEEP" -eq 0 ] && [ "$stale_min" -gt 0 ]; then
            local stale_out stale_re
            stale_re="/$(remote_dump_match_re "$dump_base_name")"
            stale_out=$(ssh_exec "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}" \
                "find $(shq "$remote_dump_dir") -maxdepth 1 -type f -mmin +${stale_min} -print 2>/dev/null | grep -E $(shq "$stale_re") | while IFS= read -r f; do rm -f -- \"\$f\" && printf '%s\\n' \"\$f\"; done")
            if [ -n "$stale_out" ]; then
                log_info "Purged $(echo "$stale_out" | wc -l | tr -d ' ') stale source dump(s) older than ${FROM_STALE}"
            fi
        fi

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

        # Source-side compression (--compress-where source): shrink the dump on
        # the source host BEFORE the copy, so a slow uplink moves the compressed
        # artifact instead of the raw dump. Falls back to the old transfer-then-
        # compress path if the tool is missing or compression fails — never
        # blocks the backup. gzip needs nothing here: pg_dump -Z already
        # compressed it in-format on the source.
        if [ $result -eq 0 ] && [ "$COMPRESS_WHERE" = "source" ]; then
            case "$COMPRESS" in
                zstd|xz|bzip2)
                    local clvl="$COMPRESS_LEVEL" ccmd=""
                    [ "$clvl" -lt 1 ] && clvl=1
                    case "$COMPRESS" in
                        zstd)  [ "$clvl" -gt 19 ] && clvl=19; comp_ext="zst"; ccmd="zstd -q -${clvl} --rm -f $(pq "$remote_file")" ;;
                        xz)    [ "$clvl" -gt 9 ]  && clvl=9;  comp_ext="xz";  ccmd="xz -${clvl} -f $(pq "$remote_file")" ;;
                        bzip2) [ "$clvl" -gt 9 ]  && clvl=9;  comp_ext="bz2"; ccmd="bzip2 -${clvl} -f $(pq "$remote_file")" ;;
                    esac
                    if ssh -p "$FROM_SSH_PORT" "${SSH_OPTS[@]}" "${FROM_SSH_USER}@${FROM_SSH_HOST}" "command -v $(pq "$COMPRESS") >/dev/null 2>&1"; then
                        log_info "Compressing on source ($COMPRESS)..."
                        if ssh -p "$FROM_SSH_PORT" "${SSH_OPTS[@]}" "${FROM_SSH_USER}@${FROM_SSH_HOST}" "$ccmd"; then
                            remote_file="${remote_file}.${comp_ext}"
                            remote_compressed=true
                        else
                            log_warn "Source-side compression failed; transferring raw and compressing on target"
                        fi
                    else
                        log_warn "'$COMPRESS' not found on source host; transferring raw and compressing on target"
                    fi
                    ;;
            esac
        fi

        if [ $result -eq 0 ]; then
            log_info "Transferring..."
            if ! scp_transfer "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}:${remote_file}" "$dump_file"; then
                log_error "Transfer failed; leaving the source dump in place"
                result=1
            fi

            # The local name was reserved as a plain .dump path; when the bytes
            # arrived already compressed, rename to the real extension so
            # metadata, retention and restore see what the file actually is.
            if [ $result -eq 0 ] && [ "$remote_compressed" = true ]; then
                local final_file="${dump_file}.${comp_ext}" _m=0
                while [ -e "$final_file" ]; do
                    _m=$((_m + 1))
                    [ "$_m" -gt 10000 ] && { log_error "Too many colliding dumps for ${dump_file}.${comp_ext}"; result=1; break; }
                    final_file="${dump_file}.${_m}.${comp_ext}"
                done
                if [ $result -eq 0 ]; then
                    if mv "$dump_file" "$final_file"; then
                        dump_file="$final_file"
                    else
                        log_error "Could not rename transferred dump to $final_file"
                        result=1
                    fi
                fi
            fi

            # Never delete older source dumps (or the source copy) unless the
            # copy we just received is readable.
            if [ $result -eq 0 ] && [ "$FROM_KEEP" -ge 0 ]; then
                if verify_dump_integrity "$dump_file"; then
                    integrity_checked="$dump_file"
                else
                    quarantine_dump "$dump_file"
                    log_error "Keeping existing dumps on the source"
                    result=1
                fi
            fi

            # Cleanup based on FROM_KEEP — ONLY after a successful transfer, so a
            # failed copy never deletes the only remaining copy on the source.
            if [ $result -eq 0 ] && [ "$FROM_KEEP" -eq 0 ]; then
                log_info "Cleaning source dump..."
                ssh -p "$FROM_SSH_PORT" "${SSH_OPTS[@]}" "${FROM_SSH_USER}@${FROM_SSH_HOST}" "rm -f $(pq "$remote_file")"
            elif [ $result -eq 0 ] && [ "$FROM_KEEP" -gt 0 ]; then
                log_info "Keeping last $FROM_KEEP dump(s) on source..."
                local dump_base_name="${DUMP_NAME:-$FROM_DATABASE}"
                local keep_re; keep_re="^$(remote_dump_match_re "$dump_base_name")"
                local cleanup_cmd="cd $(shq "$remote_dump_dir") && ls -t -- $(shq "$dump_base_name")_*.dump* 2>/dev/null | grep -E $(shq "$keep_re") | tail -n +$((FROM_KEEP + 1)) | while IFS= read -r f; do rm -f -- \"\$f\"; done"
                ssh_exec "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}" "$cleanup_cmd"
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
        # Skipped when the file already arrived compressed from the source.
        if [ "$remote_compressed" != true ] && [ "$COMPRESS" != "gzip" ] && [ "$COMPRESS" != "none" ]; then
            if compress_file "$dump_file"; then
                case "$COMPRESS" in
                    zstd)  dump_file="${dump_file}.zst" ;;
                    xz)    dump_file="${dump_file}.xz" ;;
                    bzip2) dump_file="${dump_file}.bz2" ;;
                esac
            fi
        fi

        # Make sure the new dump is usable BEFORE it is wrapped in metadata or
        # any rotation removes older dumps. Skipped when this very file was
        # already verified before source-side rotation (once per run).
        if [ "$integrity_checked" != "$dump_file" ] && ! verify_dump_integrity "$dump_file"; then
            quarantine_dump "$dump_file"
            local _ve; _ve=$(format_elapsed $(($(date +%s) - META_START_EPOCH)))
            send_notification "failed" "Dump failed: ${dump_base_name}" "$(build_notify_details "DUMP" "Failed" "$_ve")"
            return 1
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
        send_notification "success" "Dump completed: ${dump_base_name}" "$details"

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
        send_notification "failed" "Dump failed: ${dump_base_name}" "$details"

        return 1
    fi
}

