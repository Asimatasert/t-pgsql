# ==============================================================================
# STREAMING CLONE (no temp files)
# ==============================================================================
clone_stream() {
    meta_start
    log_info "Starting streaming clone (no temp files)..."

    # Filter values are eval'd into the dump command, so pq-escape each (see 55-dump).
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

    # Build include-only options (--only-table -> -t, --only-schema -> -n).
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

    local result=0
    local idx=0

    for to_conn in "${TO_CONNECTIONS[@]}"; do
        parse_connection "$to_conn" "TO" || { log_error "Invalid target connection: $to_conn"; result=1; idx=$((idx + 1)); continue; }
        get_password "TO" "$idx"

        log_info "Streaming: ${FROM_SSH_HOST:-$FROM_DB_HOST}/${FROM_DATABASE} → ${TO_SSH_HOST:-$TO_DB_HOST}/${TO_DATABASE}"

        # Track temp .pgpass files created for local commands so we can clean up.
        local stream_from_pgpass="" stream_to_pgpass=""

        # Build pg_dump command
        local dump_cmd=""
        if [ "$FROM_TYPE" = "ssh" ]; then
            local from_rcmd=""
            if [ "$SUDO" = true ]; then
                from_rcmd="sudo -u $(pq "$FROM_DB_USER") pg_dump -h $(pq "$FROM_DB_HOST") -p $(pq "$FROM_DB_PORT") -Fc $exclude_opts $only_opts $(pq "$FROM_DATABASE")"
            else
                from_rcmd="$(remote_pgpass_preamble "$FROM_DB_USER" "$FROM_DB_PASSWORD")pg_dump -U $(pq "$FROM_DB_USER") -h $(pq "$FROM_DB_HOST") -p $(pq "$FROM_DB_PORT") -Fc $exclude_opts $only_opts $(pq "$FROM_DATABASE")"
            fi
            dump_cmd="ssh -p $(pq "$FROM_SSH_PORT") ${SSH_OPTS[*]} $(pq "${FROM_SSH_USER}@${FROM_SSH_HOST}") $(shq "$from_rcmd")"
        else
            stream_from_pgpass="$(make_pgpass_file "$FROM_DB_USER" "$FROM_DB_PASSWORD")"; reg_tmp "$stream_from_pgpass"
            dump_cmd="PGPASSFILE=$(pq "$stream_from_pgpass") pg_dump -U $(pq "$FROM_DB_USER") -h $(pq "$FROM_DB_HOST") -p $(pq "$FROM_DB_PORT") -Fc $exclude_opts $only_opts $(pq "$FROM_DATABASE")"
        fi

        # Build pg_restore command
        local restore_cmd=""
        if [ "$TO_TYPE" = "ssh" ]; then
            # Prepare target database (password via remote PGPASSFILE, not argv)
            local prep_pre; prep_pre="$(remote_pgpass_preamble "$TO_DB_USER" "$TO_DB_PASSWORD")"
            # Refuse to stream into an existing DB without --force: pg_restore would
            # append and DUPLICATE the existing rows.
            local _st_check="SELECT 1 FROM pg_database WHERE datname='$(sqllit "$TO_DATABASE")'"
            local _st_exists=$(ssh_exec "$TO_SSH_PORT" "${TO_SSH_USER}@${TO_SSH_HOST}" \
                "${prep_pre}psql -U $(pq "$TO_DB_USER") -h $(pq "$TO_DB_HOST") -p $(pq "$TO_DB_PORT") -tAc $(pq "$_st_check") postgres 2>/dev/null")
            if [ "$_st_exists" = "1" ] && [ "$FORCE" != true ]; then
                log_error "Target database '$TO_DATABASE' already exists. Use --force (stream clone would duplicate its data)."
                return 1
            fi
            local prep_cmd="$prep_pre"
            if [ "$FORCE" = true ]; then
                local prep_term_sql="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$(sqllit "$TO_DATABASE")' AND pid<>pg_backend_pid();"
                prep_cmd+="psql -U $(pq "$TO_DB_USER") -h $(pq "$TO_DB_HOST") -p $(pq "$TO_DB_PORT") -c $(pq "$prep_term_sql") postgres 2>/dev/null;"
                prep_cmd+="dropdb -U $(pq "$TO_DB_USER") -h $(pq "$TO_DB_HOST") -p $(pq "$TO_DB_PORT") --if-exists -- $(pq "$TO_DATABASE") 2>/dev/null;"
            fi
            prep_cmd+="createdb -U $(pq "$TO_DB_USER") -h $(pq "$TO_DB_HOST") -p $(pq "$TO_DB_PORT") -- $(pq "$TO_DATABASE") 2>/dev/null || true"

            # stdin-free prep step: command (with pgpass preamble) via stdin, not argv.
            ssh_exec "$TO_SSH_PORT" "${TO_SSH_USER}@${TO_SSH_HOST}" "$prep_cmd"

            # NOTE: the dump|restore data pipe below carries the DB stream on ssh stdin/stdout,
            # so the command (with its pgpass preamble) must ride in argv here — the password
            # is transiently visible to a local `ps` for the duration of the stream. All other
            # ssh calls use ssh_exec to keep it out of argv.
            local to_rcmd="$(remote_pgpass_preamble "$TO_DB_USER" "$TO_DB_PASSWORD")pg_restore --no-owner --no-privileges -U $(pq "$TO_DB_USER") -h $(pq "$TO_DB_HOST") -p $(pq "$TO_DB_PORT") -d $(pq "$TO_DATABASE")"
            restore_cmd="ssh -p $(pq "$TO_SSH_PORT") ${SSH_OPTS[*]} $(pq "${TO_SSH_USER}@${TO_SSH_HOST}") $(shq "$to_rcmd")"
        else
            # Prepare local target database (password via PGPASSFILE, not argv)
            setup_local_pgpass "$TO_DB_USER" "$TO_DB_PASSWORD"
            # Refuse to stream into an existing DB without --force (would duplicate data).
            local _st_exists=$(psql -U "$TO_DB_USER" -h "$TO_DB_HOST" -p "$TO_DB_PORT" -tAc \
                "SELECT 1 FROM pg_database WHERE datname='$(sqllit "$TO_DATABASE")'" postgres 2>/dev/null)
            if [ "$_st_exists" = "1" ] && [ "$FORCE" != true ]; then
                log_error "Target database '$TO_DATABASE' already exists. Use --force (stream clone would duplicate its data)."
                cleanup_local_pgpass
                return 1
            fi
            if [ "$FORCE" = true ]; then
                psql -U "$TO_DB_USER" -h "$TO_DB_HOST" -p "$TO_DB_PORT" \
                    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$(sqllit "$TO_DATABASE")' AND pid<>pg_backend_pid();" postgres >/dev/null 2>&1
                dropdb -U "$TO_DB_USER" -h "$TO_DB_HOST" -p "$TO_DB_PORT" --if-exists -- "$TO_DATABASE" 2>/dev/null
            fi
            createdb -U "$TO_DB_USER" -h "$TO_DB_HOST" -p "$TO_DB_PORT" -- "$TO_DATABASE" 2>/dev/null || true
            cleanup_local_pgpass

            stream_to_pgpass="$(make_pgpass_file "$TO_DB_USER" "$TO_DB_PASSWORD")"; reg_tmp "$stream_to_pgpass"
            restore_cmd="PGPASSFILE=$(pq "$stream_to_pgpass") pg_restore --no-owner --no-privileges -U $(pq "$TO_DB_USER") -h $(pq "$TO_DB_HOST") -p $(pq "$TO_DB_PORT") -d $(pq "$TO_DATABASE")"
        fi

        # Execute streaming pipe with buffer (redact secrets before logging)
        log_debug "Executing: $(redact_cmd "$dump_cmd") | pv -q -B ${STREAM_BUFFER}M | $(redact_cmd "$restore_cmd")"

        if command -v pv &>/dev/null; then
            # Use pv for buffering (and rate-limiting with --bwlimit) if available
            local pv_rate=""; [ -n "$PV_RATE" ] && pv_rate="-L $PV_RATE"
            eval "$dump_cmd" | pv -q -B "${STREAM_BUFFER}M" $pv_rate 2>/dev/null | eval "$restore_cmd"
        else
            [ -n "$PV_RATE" ] && log_warn "--bwlimit for streaming requires 'pv' (not installed); transfer will NOT be rate-limited"
            # Direct pipe without buffer
            eval "$dump_cmd" | eval "$restore_cmd"
        fi

        # Capture the full pipeline status: first element is pg_dump,
        # last element is pg_restore (pv, if present, sits in between).
        local pipe_status=("${PIPESTATUS[@]}")
        local dump_rc=${pipe_status[0]}
        local restore_rc=${pipe_status[$(( ${#pipe_status[@]} - 1 ))]}
        if [ "$dump_rc" -ne 0 ] || [ "$restore_rc" -ne 0 ]; then
            result=1
        fi

        # Remove any local temp .pgpass files created for this iteration.
        [ -n "$stream_from_pgpass" ] && rm -f "$stream_from_pgpass"
        [ -n "$stream_to_pgpass" ] && rm -f "$stream_to_pgpass"

        idx=$((idx + 1))
    done

    local elapsed=$(format_elapsed $(($(date +%s) - META_START_EPOCH)))

    if [ $result -eq 0 ]; then
        log_success "Streaming clone complete ($elapsed)"
        run_post_health_check
        local details=$(build_notify_details "STREAM-CLONE" "Success" "$elapsed")
        send_notification "success" "Streaming clone completed: ${FROM_DATABASE} → ${TO_DATABASE}" "$details"
    else
        log_error "Streaming clone failed"
        local details=$(build_notify_details "STREAM-CLONE" "Failed" "$elapsed")
        send_notification "failed" "Streaming clone failed: ${FROM_DATABASE} → ${TO_DATABASE}" "$details"
    fi

    return $result
}

