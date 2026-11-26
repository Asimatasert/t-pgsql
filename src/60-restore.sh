# ==============================================================================
# RESTORE
# ==============================================================================
# Populate the _DBOPTS array with createdb options that reproduce the dump's database
# encoding and locale. Without this, a non-UTF8 (e.g. LATIN1) or non-default-locale
# source is silently restored with the cluster defaults, corrupting text. Best-effort:
# parsed from the CREATE DATABASE statement pg_restore emits for the (local) archive;
# callers fall back to a plain createdb if these options aren't available or are rejected
# (e.g. the source locale isn't installed on the target host).
_DBOPTS=()
build_db_opts_from_dump() {
    _DBOPTS=()
    local dump="$1" line
    # -Fd directory dumps and plain files both work; only custom/dir archives yield a line.
    line=$(pg_restore --create --schema-only -f - "$dump" 2>/dev/null | grep -m1 -i '^CREATE DATABASE ')
    [ -z "$line" ] && return 0
    local enc collate ctype locale
    enc=$(printf '%s' "$line"     | sed -n "s/.*ENCODING = '\([^']*\)'.*/\1/p")
    collate=$(printf '%s' "$line" | sed -n "s/.*LC_COLLATE = '\([^']*\)'.*/\1/p")
    ctype=$(printf '%s' "$line"   | sed -n "s/.*LC_CTYPE = '\([^']*\)'.*/\1/p")
    locale=$(printf '%s' "$line"  | sed -n "s/.*[^_]LOCALE = '\([^']*\)'.*/\1/p")
    [ -z "$enc" ] && return 0
    _DBOPTS+=(--template=template0 -E "$enc")
    if [ -n "$collate" ] || [ -n "$ctype" ]; then
        [ -n "$collate" ] && _DBOPTS+=(--lc-collate="$collate")
        [ -n "$ctype" ]   && _DBOPTS+=(--lc-ctype="$ctype")
    elif [ -n "$locale" ]; then
        _DBOPTS+=(--locale="$locale")
    fi
}

# Emit the _DBOPTS as a shq-escaped string for embedding in a remote /bin/sh command.
# shq (POSIX single-quoting) is used rather than pq (printf %q, which emits bash-only
# $'...' for control chars) because ssh_exec runs the command under the remote /bin/sh.
dbopts_remote() { local o out=""; for o in "${_DBOPTS[@]}"; do out+=" $(shq "$o")"; done; printf '%s' "$out"; }

# Grep pattern matching pg_restore output that indicates a FATAL archive/read failure
# DEFAULT-SAFE swap decision. A nonzero pg_restore exit is only safe to accept (and swap
# the restored temp DB over the original) when EVERY reported error is a cosmetic ownership
# error — the canonical case being "COMMENT ON EXTENSION plpgsql" -> "must be owner of
# extension" on managed / non-superuser PostgreSQL, which does not affect table data. ANY
# other error (disk full, decompression/corruption, lost connection, timeout, a failed
# CREATE that drops data, or anything unrecognized) makes this FALSE, so the swap is aborted
# and the intact original is kept. This is an allowlist, NOT a blocklist: unknown failures
# must never be treated as benign, or a partial restore could silently replace good data.
_PGRESTORE_BENIGN_RE='must be owner of'
restore_only_benign_errors() {
    local log="$1" errs
    [ -z "$log" ] || [ ! -s "$log" ] && return 1
    errs=$(grep -E 'pg_restore: error:' "$log" 2>/dev/null)
    [ -z "$errs" ] && return 1                                   # nonzero but no error lines -> unknown -> unsafe
    printf '%s\n' "$errs" | grep -qvE "$_PGRESTORE_BENIGN_RE" && return 1  # a non-benign error -> unsafe
    return 0
}

cmd_restore() {
    log_info "Starting restore..."

    # Auto-find latest dump if no file specified. Pick the genuinely newest file by
    # mtime across ALL formats — the old code tried *.tar.gz first, so a stale tar.gz
    # would shadow a newer .dump/.dump.zst and silently restore an OLDER backup.
    if [ -z "$FILE" ]; then
        local norm_dir=$(cd "$OUTPUT_DIR" 2>/dev/null && pwd)
        if [ -z "$norm_dir" ]; then
            log_error "Output directory not found: $OUTPUT_DIR"
            return 1
        fi
        FILE=$(ls -t "${norm_dir}/"*.tar.gz "${norm_dir}/"*.dump.zst "${norm_dir}/"*.dump.xz \
                     "${norm_dir}/"*.dump.bz2 "${norm_dir}/"*.dump 2>/dev/null | head -1)

        if [ -z "$FILE" ]; then
            log_error "No dump file found. Use --file <path>"
            return 1
        fi
        log_info "Using latest: $(basename "$FILE")"
    fi

    # Accept a regular file OR a directory (pg_dump -Fd directory-format dump).
    if [ ! -e "$FILE" ]; then
        log_error "File not found: $FILE"
        return 1
    fi

    if [ ${#TO_CONNECTIONS[@]} -eq 0 ]; then
        log_error "--to required"
        return 1
    fi

    local restore_file="$FILE"
    local _decompressed=""
    local temp_dir=""
    local cleanup_temp=false

    # Handle different archive types
    case "$restore_file" in
        *.tar.gz)
            # Extract dump from tar archive
            temp_dir=$(mktemp -d); reg_tmp "$temp_dir"
            [ -z "$temp_dir" ] && { log_error "mktemp failed, cannot extract archive"; return 1; }
            cleanup_temp=true
            log_info "Extracting from archive..."
            restore_file=$(extract_dump "$FILE" "$temp_dir")
            if [ -z "$restore_file" ] || [ ! -f "$restore_file" ]; then
                log_error "Failed to extract dump from archive"
                rm -rf "$temp_dir"
                return 1
            fi
            ;;
        *.gz|*.xz|*.bz2|*.zst)
            # Decompress to a UNIQUE temp dir (not next to the archive): avoids a
            # collision with a same-named sibling .dump and leaves no plaintext copy behind.
            local _dd; _dd=$(mktemp -d); reg_tmp "$_dd"
            local _out="$_dd/$(basename "${restore_file%.*}")"
            case "$restore_file" in
                *.gz)  gunzip  -c "$restore_file" > "$_out" ;;
                *.xz)  unxz    -c "$restore_file" > "$_out" ;;
                *.bz2) bunzip2 -c "$restore_file" > "$_out" ;;
                *.zst) zstd   -dc "$restore_file" > "$_out" ;;
            esac
            if [ $? -ne 0 ]; then log_error "Decompression failed: $restore_file"; return 1; fi
            restore_file="$_out"
            ;;
    esac

    local idx=0
    local restore_failed=0
    for conn in "${TO_CONNECTIONS[@]}"; do
        restore_to "$conn" "$restore_file" "$idx" || restore_failed=1
        idx=$((idx+1))
    done

    # Cleanup temp dir and any file we decompressed next to the source archive.
    [ "$cleanup_temp" = true ] && rm -rf "$temp_dir"
    [ -n "$_decompressed" ] && rm -f "$_decompressed"

    # Post-operation health check (--health-check-after)
    [ $restore_failed -eq 0 ] && run_post_health_check

    # Send notification (only for standalone restore, not when called from clone).
    # With multiple targets, TO_DATABASE holds only the LAST target, so name the count
    # rather than implying a single database succeeded/failed.
    if [ "$COMMAND" = "restore" ]; then
        local tgt_label="${TO_DATABASE}"
        [ "${#TO_CONNECTIONS[@]}" -gt 1 ] && tgt_label="${#TO_CONNECTIONS[@]} targets"
        if [ $restore_failed -eq 0 ]; then
            local details=$(build_notify_details "RESTORE" "Success" "")
            send_notification "success" "Restore completed: ${tgt_label}" "$details"
        else
            local details=$(build_notify_details "RESTORE" "Failed" "")
            send_notification "failed" "Restore failed: ${tgt_label}" "$details"
        fi
    fi

    return $restore_failed
}

restore_to() {
    local conn="$1"
    local dump="$2"
    local index="${3:-0}"

    parse_connection "$conn" "TO" || { log_error "Invalid target connection: $conn"; return 1; }
    # Fail this target if its password can't be resolved — do NOT silently reuse the
    # previous target's credential.
    get_password "TO" "$index" || return 1

    log_info "To: ${TO_DB_USER}@${TO_DB_HOST}:${TO_DB_PORT}/${TO_DATABASE}"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would restore to: $conn"
        return 0
    fi

    if [ "$TO_TYPE" = "ssh" ]; then
        restore_ssh "$dump"
    else
        restore_local "$dump"
    fi
}

restore_local() {
    local dump="$1"

    # Validate the dump is a readable custom-format archive BEFORE any destructive
    # step. Otherwise --force would drop the populated target DB and only then find
    # out the dump is corrupt — losing the existing data with nothing to restore.
    if ! pg_restore -l "$dump" >/dev/null 2>&1; then
        log_error "Not a valid dump archive (refusing to touch the target): $dump"
        return 1
    fi

    setup_local_pgpass "$TO_DB_USER" "$TO_DB_PASSWORD"

    local _pc=(-U "$TO_DB_USER" -h "$TO_DB_HOST" -p "$TO_DB_PORT")
    # Reproduce the source DB encoding/locale (best-effort; plain createdb is the fallback).
    build_db_opts_from_dump "$dump"

    # Check exists
    local exists=$(psql "${_pc[@]}" \
        -tAc "SELECT 1 FROM pg_database WHERE datname='$(sqllit "$TO_DATABASE")'" postgres 2>/dev/null)

    if [ "$exists" = "1" ] && [ "$FORCE" != true ]; then
        log_error "Database '$TO_DATABASE' already exists. Use --force to overwrite."
        cleanup_local_pgpass
        return 1
    fi

    local r=0

    if [ "$exists" != "1" ]; then
        # Target does not exist: nothing to lose, restore directly.
        log_info "Creating database..."
        if ! createdb "${_pc[@]}" "${_DBOPTS[@]}" -- "$TO_DATABASE" 2>/dev/null && \
           ! createdb "${_pc[@]}" -- "$TO_DATABASE"; then
            log_error "Failed to create database '$TO_DATABASE', aborting restore"
            cleanup_local_pgpass
            return 1
        fi
        log_info "Restoring..."
        pg_restore --verbose --no-owner --no-privileges --clean --if-exists \
            "${_pc[@]}" -d "$TO_DATABASE" "$dump" 2>&1
        r=$?
    else
        # Target EXISTS and --force: restore into a fresh temp database and only swap it
        # into place once the restore succeeds. A dump that passes the TOC check but fails
        # mid-data (e.g. a truncated transfer) then can no longer destroy the existing data.
        # Temp/old names use short fixed prefixes (not derived from the target name) so they
        # can never collide after PostgreSQL's 63-byte identifier truncation, nor inherit a
        # leading '-' from the target name.
        local tmpdb="tpgtmp_$$"
        local olddb="tpgold_$$"
        local q_tmp; q_tmp="$(sqlid "$tmpdb")"
        local q_old; q_old="$(sqlid "$olddb")"
        local q_tgt; q_tgt="$(sqlid "$TO_DATABASE")"

        dropdb "${_pc[@]}" --if-exists -- "$tmpdb" 2>/dev/null
        log_info "Restoring into temporary database (safe swap)..."
        if ! createdb "${_pc[@]}" "${_DBOPTS[@]}" -- "$tmpdb" 2>/dev/null && \
           ! createdb "${_pc[@]}" -- "$tmpdb"; then
            log_error "Failed to create temporary database, aborting (existing '$TO_DATABASE' left intact)"
            cleanup_local_pgpass
            return 1
        fi

        # Capture the restore log to make a DEFAULT-SAFE swap decision: swap only when the
        # restore is clean (exit 0) or its only errors are cosmetic ownership errors. Any
        # other failure (truncated/corrupt dump, disk full, lost connection, ...) keeps the
        # intact original and discards the partial temp DB.
        local _rlog; _rlog="$(mktemp "${TMPDIR:-/tmp}/t-pgsql-restore.XXXXXX")" && reg_tmp "$_rlog"
        pg_restore --verbose --no-owner --no-privileges \
            "${_pc[@]}" -d "$tmpdb" "$dump" >"${_rlog:-/dev/stdout}" 2>&1
        r=$?
        [ -n "$_rlog" ] && cat "$_rlog"

        # r>128 means pg_restore was killed by a signal (OOM-killer/SIGTERM) mid-restore —
        # never benign, even if only cosmetic errors were logged before it died.
        if [ $r -ne 0 ] && { [ "$r" -gt 128 ] || ! restore_only_benign_errors "$_rlog"; }; then
            log_error "Restore failed — existing '$TO_DATABASE' left intact (partial restore discarded)"
            dropdb "${_pc[@]}" --if-exists -- "$tmpdb" 2>/dev/null
            cleanup_local_pgpass
            return 1
        fi
        [ $r -ne 0 ] && log_warn "Restore reported only cosmetic ownership errors; swapping the restored copy into place"

        # Swap: rename existing -> old, temp -> target, then drop old. If the second
        # rename fails, roll the original back. The original is recoverable at every step.
        log_info "Swapping restored database into place..."
        psql "${_pc[@]}" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$(sqllit "$TO_DATABASE")' AND pid<>pg_backend_pid();" postgres >/dev/null 2>&1
        if ! psql "${_pc[@]}" -v ON_ERROR_STOP=1 -c "ALTER DATABASE $q_tgt RENAME TO $q_old;" postgres >/dev/null 2>&1; then
            log_error "Could not rename existing '$TO_DATABASE' (active connections?) — restored copy kept as '$tmpdb'"
            cleanup_local_pgpass
            return 1
        fi
        if ! psql "${_pc[@]}" -v ON_ERROR_STOP=1 -c "ALTER DATABASE $q_tmp RENAME TO $q_tgt;" postgres >/dev/null 2>&1; then
            log_error "Swap failed; rolling back original '$TO_DATABASE'"
            psql "${_pc[@]}" -c "ALTER DATABASE $q_old RENAME TO $q_tgt;" postgres >/dev/null 2>&1
            dropdb "${_pc[@]}" --if-exists -- "$tmpdb" 2>/dev/null
            cleanup_local_pgpass
            return 1
        fi
        dropdb "${_pc[@]}" --if-exists -- "$olddb" 2>/dev/null
    fi

    cleanup_local_pgpass

    # Apply data masking if enabled. If the restore succeeded but masking failed,
    # fail the whole operation — the target may hold unmasked data the user wanted masked.
    apply_masking "TO"; local mrc=$?
    if [ $r -eq 0 ] && [ "$MASK" = true ] && [ $mrc -ne 0 ]; then
        log_error "Restore succeeded but masking failed — target may contain UNMASKED data"
        r=1
    fi

    [ $r -eq 0 ] && log_success "Restore complete" || log_warn "Restore done with warnings"

    return $r
}

restore_ssh() {
    local dump="$1"
    local remote_dump_dir="/tmp/t-pgsql"
    ssh -p "$TO_SSH_PORT" "${SSH_OPTS[@]}" "${TO_SSH_USER}@${TO_SSH_HOST}" "mkdir -p $(pq "$remote_dump_dir") && chmod 700 $(pq "$remote_dump_dir")"
    local remote="${remote_dump_dir}/$(basename "$dump")"

    # Check if DB exists on remote (password via remote PGPASSFILE, not argv)
    local pgpass_pre; pgpass_pre="$(remote_pgpass_preamble "$TO_DB_USER" "$TO_DB_PASSWORD")"
    local check_sql="SELECT 1 FROM pg_database WHERE datname='$(sqllit "$TO_DATABASE")'"
    local check_cmd="${pgpass_pre}psql -U $(pq "$TO_DB_USER") -h $(pq "$TO_DB_HOST") -p $(pq "$TO_DB_PORT") -tAc $(pq "$check_sql") postgres 2>/dev/null"
    local exists=$(ssh_exec "$TO_SSH_PORT" "${TO_SSH_USER}@${TO_SSH_HOST}" "$check_cmd")

    if [ "$exists" = "1" ]; then
        if [ "$FORCE" = true ]; then
            log_warn "Remote database '$TO_DATABASE' exists, will drop (--force)..."
        else
            log_error "Remote database '$TO_DATABASE' already exists. Use --force to overwrite."
            return 1
        fi
    fi

    log_info "Uploading dump..."
    if ! scp_transfer "$TO_SSH_PORT" "$dump" "${TO_SSH_USER}@${TO_SSH_HOST}:${remote}"; then
        log_error "Upload failed"
        return 1
    fi

    log_info "Restoring on remote..."
    # Reusable, pq-escaped connection flags for the remote psql/createdb/dropdb/pg_restore.
    local rcf="-U $(pq "$TO_DB_USER") -h $(pq "$TO_DB_HOST") -p $(pq "$TO_DB_PORT")"
    local q_remote; q_remote="$(pq "$remote")"
    # Reproduce the source DB encoding/locale on the remote createdb (parsed from the local
    # dump); remote createdb falls back to defaults if the options are rejected.
    build_db_opts_from_dump "$dump"
    local dbo; dbo="$(dbopts_remote)"
    local cmd="$pgpass_pre"

    if [ "$exists" = "1" ] && [ "$FORCE" = true ]; then
        # Same safe temp-swap as restore_local: restore into a fresh temp DB and only swap
        # it into place on success, so a mid-data failure can't destroy the existing remote
        # database. Short fixed temp/old names (never derived from the target) avoid 63-byte
        # truncation collisions and leading-'-' issues.
        local tmpdb="tpgtmp_$$" olddb="tpgold_$$"
        local q_tgt q_tmp q_old
        q_tgt="$(sqlid "$TO_DATABASE")"; q_tmp="$(sqlid "$tmpdb")"; q_old="$(sqlid "$olddb")"
        local term_sql="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$(sqllit "$TO_DATABASE")' AND pid<>pg_backend_pid();"
        cmd+="dropdb $rcf --if-exists -- $(pq "$tmpdb") 2>/dev/null;"
        cmd+="{ createdb $rcf$dbo -- $(pq "$tmpdb") 2>/dev/null || createdb $rcf -- $(pq "$tmpdb"); } || { rm -f $q_remote 2>/dev/null; exit 1; };"
        # DEFAULT-SAFE swap decision (mirrors restore_local): swap only if the restore is
        # clean or its ONLY errors are cosmetic ownership errors; any other failure keeps the
        # intact original and discards the partial temp DB. __benign=1 requires that error
        # lines exist AND none is outside the benign allowlist.
        # Fallback path lives inside the chmod-700 remote dir (created above), not a
        # world-writable /tmp, so a predictable name can't be pre-symlinked by another user.
        cmd+="__rlog=\$(mktemp 2>/dev/null || echo $(pq "$remote_dump_dir")/.tpgrestore.\$\$);"
        cmd+="pg_restore --verbose --no-owner --no-privileges $rcf -d $(pq "$tmpdb") $q_remote >\"\$__rlog\" 2>&1; __rc=\$?; cat \"\$__rlog\" >&2;"
        cmd+="__benign=0; if [ \$__rc -ne 0 ] && [ \$__rc -le 128 ] && [ -s \"\$__rlog\" ] && grep -qE 'pg_restore: error:' \"\$__rlog\" && ! grep -E 'pg_restore: error:' \"\$__rlog\" | grep -qvE $(pq "$_PGRESTORE_BENIGN_RE"); then __benign=1; fi;"
        cmd+="if [ \$__rc -ne 0 ] && [ \$__benign -ne 1 ]; then dropdb $rcf --if-exists -- $(pq "$tmpdb") 2>/dev/null; rm -f $q_remote \"\$__rlog\" 2>/dev/null; exit \$__rc; fi;"
        cmd+="rm -f \"\$__rlog\" 2>/dev/null;"
        cmd+="psql $rcf -c $(pq "$term_sql") postgres >/dev/null 2>&1;"
        cmd+="psql $rcf -v ON_ERROR_STOP=1 -c $(pq "ALTER DATABASE $q_tgt RENAME TO $q_old;") postgres >/dev/null 2>&1 || { rm -f $q_remote 2>/dev/null; exit 1; };"
        cmd+="psql $rcf -v ON_ERROR_STOP=1 -c $(pq "ALTER DATABASE $q_tmp RENAME TO $q_tgt;") postgres >/dev/null 2>&1 || { psql $rcf -c $(pq "ALTER DATABASE $q_old RENAME TO $q_tgt;") postgres >/dev/null 2>&1; dropdb $rcf --if-exists -- $(pq "$tmpdb") 2>/dev/null; rm -f $q_remote 2>/dev/null; exit 1; };"
        cmd+="dropdb $rcf --if-exists -- $(pq "$olddb") 2>/dev/null;"
        cmd+="rm -f $q_remote 2>/dev/null; exit \$__rc"
    else
        # Target does not exist: nothing to lose, restore directly.
        cmd+="{ createdb $rcf$dbo -- $(pq "$TO_DATABASE") 2>/dev/null || createdb $rcf -- $(pq "$TO_DATABASE"); } || { rm -f $q_remote 2>/dev/null; exit 1; };"
        cmd+="pg_restore --verbose --no-owner --no-privileges $rcf -d $(pq "$TO_DATABASE") $q_remote; __rc=\$?;"
        cmd+="rm -f $q_remote 2>/dev/null;"
        cmd+="exit \$__rc"
    fi

    # stdin-free: command (with pgpass preamble) via stdin, keeping the password out of argv.
    ssh_exec "$TO_SSH_PORT" "${TO_SSH_USER}@${TO_SSH_HOST}" "$cmd"
    local rc=$?

    # Apply data masking if enabled (must run after capturing restore status). Mirror
    # restore_local: if the restore succeeded but masking failed, fail the whole
    # operation — the remote target may hold unmasked data the user wanted masked.
    apply_masking "TO"; local mrc=$?
    if [ $rc -eq 0 ] && [ "$MASK" = true ] && [ $mrc -ne 0 ]; then
        log_error "Remote restore succeeded but masking failed — target may contain UNMASKED data"
        rc=1
    fi

    [ $rc -eq 0 ] && log_success "Remote restore complete" || log_warn "Remote restore done with warnings"

    return $rc
}

