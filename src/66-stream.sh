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
        # Reset first: get_password leaves the variable untouched when it finds no password,
        # which would otherwise let this target inherit the previous target's credential.
        TO_DB_PASSWORD=""
        get_password "TO" "$idx" || { log_error "No password available for target #$((idx + 1)): $to_conn"; result=1; idx=$((idx + 1)); continue; }

        log_info "Streaming: ${FROM_SSH_HOST:-$FROM_DB_HOST}/${FROM_DATABASE} → ${TO_SSH_HOST:-$TO_DB_HOST}/${TO_DATABASE}"

        # Track temp .pgpass files created for local commands so we can clean up.
        local stream_from_pgpass="" stream_to_pgpass="" from_rpgpass="" to_rpgpass=""

        # Build pg_dump command
        local dump_cmd=""
        if [ "$FROM_TYPE" = "ssh" ]; then
            local from_rcmd=""
            if [ "$SUDO" = true ]; then
                from_rcmd="sudo -u $(pq "$FROM_DB_USER") pg_dump -h $(pq "$FROM_DB_HOST") -p $(pq "$FROM_DB_PORT") -Fc $exclude_opts $only_opts $(pq "$FROM_DATABASE")"
            else
                # The ssh command line carries the data stream on stdin/stdout, so it rides in
                # argv: keep the password out of it by creating the remote .pgpass first (stdin).
                if ! remote_pgpass_create "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}" "$FROM_DB_USER" "$FROM_DB_PASSWORD"; then
                    log_error "Could not create a credential file on the source host"
                    _stream_release; result=1; idx=$((idx + 1)); continue
                fi
                from_rpgpass="$_RPGPASS_PATH"
                from_rcmd="PGPASSFILE=$(pq "$from_rpgpass") pg_dump -U $(pq "$FROM_DB_USER") -h $(pq "$FROM_DB_HOST") -p $(pq "$FROM_DB_PORT") -Fc $exclude_opts $only_opts $(pq "$FROM_DATABASE")"
            fi
            dump_cmd="ssh -p $(pq "$FROM_SSH_PORT") ${SSH_OPTS[*]} $(pq "${FROM_SSH_USER}@${FROM_SSH_HOST}") $(shq "$from_rcmd")"
        else
            stream_from_pgpass="$(make_pgpass_file "$FROM_DB_USER" "$FROM_DB_PASSWORD")"; reg_tmp "$stream_from_pgpass"
            dump_cmd="PGPASSFILE=$(pq "$stream_from_pgpass") pg_dump -U $(pq "$FROM_DB_USER") -h $(pq "$FROM_DB_HOST") -p $(pq "$FROM_DB_PORT") -Fc $exclude_opts $only_opts $(pq "$FROM_DATABASE")"
        fi

        # --force drops the target before a single byte is read from the source (a stream has
        # no temp-database swap). Prove the source is reachable and the database exists first,
        # and abort with the target untouched when it is not.
        if [ "$FORCE" = true ]; then
            local _src_probe="SELECT 1" _src_ok=""
            if [ "$FROM_TYPE" = "ssh" ]; then
                local _src_pre _src_uopt
                _src_uopt="-U $(pq "$FROM_DB_USER") "
                if [ "$SUDO" = true ]; then
                    _src_pre="sudo -u $(pq "$FROM_DB_USER") "; _src_uopt=""
                else
                    _src_pre="$(remote_pgpass_preamble "$FROM_DB_USER" "$FROM_DB_PASSWORD")"
                fi
                _src_ok=$(ssh_exec "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}" \
                    "${_src_pre}psql ${_src_uopt}-h $(pq "$FROM_DB_HOST") -p $(pq "$FROM_DB_PORT") -tAc $(pq "$_src_probe") -d $(pq "$FROM_DATABASE")" 2>/dev/null)
            else
                _src_ok=$(PGPASSFILE="$stream_from_pgpass" psql -w -U "$FROM_DB_USER" -h "$FROM_DB_HOST" -p "$FROM_DB_PORT" -tAc "$_src_probe" -d "$FROM_DATABASE" 2>/dev/null)
            fi
            if [ "$_src_ok" != "1" ]; then
                log_error "Source database '$FROM_DATABASE' is not reachable; aborting before touching the target '$TO_DATABASE' (--force would have dropped it)"
                _stream_release
                result=1; idx=$((idx + 1)); continue
            fi
        fi

        # Build pg_restore command
        local restore_cmd=""
        if [ "$TO_TYPE" = "ssh" ]; then
            # Credential file for the restore command (created over stdin; see above).
            if ! remote_pgpass_create "$TO_SSH_PORT" "${TO_SSH_USER}@${TO_SSH_HOST}" "$TO_DB_USER" "$TO_DB_PASSWORD"; then
                log_error "Could not create a credential file on the target host"
                _stream_release; result=1; idx=$((idx + 1)); continue
            fi
            to_rpgpass="$_RPGPASS_PATH"
            # Prepare target database (password via remote PGPASSFILE, not argv)
            local prep_pre; prep_pre="$(remote_pgpass_preamble "$TO_DB_USER" "$TO_DB_PASSWORD")"
            # Refuse to stream into an existing DB without --force: pg_restore would
            # append and DUPLICATE the existing rows.
            local _st_check="SELECT 1 FROM pg_database WHERE datname='$(sqllit "$TO_DATABASE")'"
            local _st_exists=$(ssh_exec "$TO_SSH_PORT" "${TO_SSH_USER}@${TO_SSH_HOST}" \
                "${prep_pre}psql -U $(pq "$TO_DB_USER") -h $(pq "$TO_DB_HOST") -p $(pq "$TO_DB_PORT") -tAc $(pq "$_st_check") postgres 2>/dev/null")
            if [ "$_st_exists" = "1" ] && [ "$FORCE" != true ]; then
                log_error "Target database '$TO_DATABASE' already exists. Use --force (stream clone would duplicate its data)."
                _stream_release
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

            # The dump|restore pipe carries the DB stream on ssh stdin/stdout, so this command
            # rides in argv; it references only the pgpass file path, never the password.
            local to_rcmd="PGPASSFILE=$(pq "$to_rpgpass") pg_restore --no-owner --no-privileges -U $(pq "$TO_DB_USER") -h $(pq "$TO_DB_HOST") -p $(pq "$TO_DB_PORT") -d $(pq "$TO_DATABASE")"
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
                _stream_release
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

        # Remove the temp .pgpass files (local and remote) created for this iteration.
        _stream_release

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

# Remove the per-target credential files of the running clone_stream iteration (local temp
# files and remote .pgpass files). Reads clone_stream's locals through bash dynamic scope.
_stream_release() {
    [ -n "$stream_from_pgpass" ] && rm -f "$stream_from_pgpass"
    [ -n "$stream_to_pgpass" ] && rm -f "$stream_to_pgpass"
    [ -n "$from_rpgpass" ] && remote_pgpass_remove "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}" "$from_rpgpass"
    [ -n "$to_rpgpass" ] && remote_pgpass_remove "$TO_SSH_PORT" "${TO_SSH_USER}@${TO_SSH_HOST}" "$to_rpgpass"
    stream_from_pgpass=""; stream_to_pgpass=""; from_rpgpass=""; to_rpgpass=""
    return 0
}
