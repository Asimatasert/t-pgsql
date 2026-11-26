# ==============================================================================
# MAJOR-VERSION LOGICAL MIGRATION (upgrade helper)
#
# This is the logical (dump + restore) path for moving a database to a newer
# PostgreSQL major version. It is NOT a replacement for pg_upgrade (fast in-place)
# or logical replication (near-zero downtime) — those remain the right tools for
# large clusters or minimal-downtime cutovers. What this adds over a plain clone:
# it also carries cluster-global objects (roles, tablespaces) and checks that the
# target major version is not older than the source.
# ==============================================================================

# Numeric server version (e.g. 160014) for a parsed prefix (FROM/TO).
# TCP/local only; prints nothing for SSH sources (preflight is then skipped).
server_version_num() {
    local prefix="$1"
    local tvar="${prefix}_TYPE" uvar="${prefix}_DB_USER" hvar="${prefix}_DB_HOST"
    local pvar="${prefix}_DB_PORT" wvar="${prefix}_DB_PASSWORD"
    local v
    if [ "${!tvar}" = "ssh" ]; then
        # Query over SSH too (password via remote PGPASSFILE, command via ssh_exec stdin)
        # so the upgrade version preflight is not silently skipped for SSH endpoints.
        local shvar="${prefix}_SSH_HOST" spvar="${prefix}_SSH_PORT" suvar="${prefix}_SSH_USER"
        local pre; pre="$(remote_pgpass_preamble "${!uvar}" "${!wvar}")"
        local rcmd="${pre}psql -U $(pq "${!uvar}") -h $(pq "${!hvar}") -p $(pq "${!pvar}") -d postgres -tAc $(pq "SHOW server_version_num") 2>/dev/null"
        v=$(ssh_exec "${!spvar}" "${!suvar}@${!shvar}" "$rcmd" | tr -d '[:space:]')
        printf '%s' "$v"
        return 0
    fi
    setup_local_pgpass "${!uvar}" "${!wvar}"
    v=$(psql -U "${!uvar}" -h "${!hvar}" -p "${!pvar}" -d postgres -tAc "SHOW server_version_num" 2>/dev/null | tr -d '[:space:]')
    cleanup_local_pgpass
    printf '%s' "$v"
}

# Dump the source cluster's globals (roles, tablespaces) into $1.
# Handles both local/TCP sources (pg_dumpall -h) and SSH sources (pg_dumpall run
# on the remote host, output streamed back over ssh).
dump_source_globals() {
    local out="$1"
    if [ "$FROM_TYPE" = "ssh" ]; then
        local rcmd
        if [ "$SUDO" = true ]; then
            rcmd="sudo -u $(pq "$FROM_DB_USER") pg_dumpall --globals-only -h $(pq "$FROM_DB_HOST") -p $(pq "$FROM_DB_PORT")"
        else
            rcmd="$(remote_pgpass_preamble "$FROM_DB_USER" "$FROM_DB_PASSWORD")pg_dumpall --globals-only -U $(pq "$FROM_DB_USER") -h $(pq "$FROM_DB_HOST") -p $(pq "$FROM_DB_PORT")"
        fi
        ssh_exec "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}" "$rcmd" > "$out" 2>/dev/null
        return $?
    fi
    setup_local_pgpass "$FROM_DB_USER" "$FROM_DB_PASSWORD"
    local rc=0
    pg_dumpall --globals-only -U "$FROM_DB_USER" -h "$FROM_DB_HOST" -p "$FROM_DB_PORT" > "$out" 2>/dev/null || rc=$?
    cleanup_local_pgpass
    return $rc
}

# Apply a globals SQL file ($1) to the CURRENTLY-PARSED target (TO_* vars).
# Handles both local/TCP and SSH targets. Roles/tablespaces are cluster-wide, so
# they are applied on the target's 'postgres' database. Pre-existing roles produce
# harmless "already exists" notices, which are tolerated (nonzero return).
apply_globals_to_target() {
    local gfile="$1" errout=""
    # psql doesn't stop on statement errors, so capture stderr and decide from it:
    # "already exists" notices (pre-existing roles) are benign; any OTHER error is real
    # and must NOT be reported as a clean success.
    if [ "$TO_TYPE" = "ssh" ]; then
        local rcmd
        if [ "$SUDO" = true ]; then
            rcmd="sudo -u $(pq "$TO_DB_USER") psql -h $(pq "$TO_DB_HOST") -p $(pq "$TO_DB_PORT") -d postgres"
        else
            rcmd="$(remote_pgpass_preamble "$TO_DB_USER" "$TO_DB_PASSWORD")psql -U $(pq "$TO_DB_USER") -h $(pq "$TO_DB_HOST") -p $(pq "$TO_DB_PORT") -d postgres"
        fi
        # Feed the globals as a quoted here-doc appended to the command (which itself,
        # with the pgpass preamble, travels on ssh's stdin via ssh_exec — never argv).
        # The delimiter is unquoted content: psql reads the here-doc, not ssh stdin.
        rcmd+=" <<'__TPG_GLOBALS_EOF__'
$(cat "$gfile")
__TPG_GLOBALS_EOF__"
        errout=$(ssh_exec "$TO_SSH_PORT" "${TO_SSH_USER}@${TO_SSH_HOST}" "$rcmd" 2>&1 >/dev/null)
    else
        setup_local_pgpass "$TO_DB_USER" "$TO_DB_PASSWORD"
        errout=$(psql -U "$TO_DB_USER" -h "$TO_DB_HOST" -p "$TO_DB_PORT" -d postgres -f "$gfile" 2>&1 >/dev/null)
        cleanup_local_pgpass
    fi
    if printf '%s\n' "$errout" | grep -i 'ERROR:' | grep -qiv 'already exists'; then
        return 1
    fi
    return 0
}

# Migrate cluster globals from the source to EVERY target. The source globals are
# dumped once; then applied to each --to target (local/TCP or SSH). Re-parses each
# target into TO_* (cmd_restore re-parses again afterwards, so this is safe).
migrate_globals() {
    log_info "Migrating cluster globals (roles, tablespaces)..."
    local gfile
    # XXXXXX must be the TRAILING component: BSD/macOS mktemp does not substitute X's
    # followed by a suffix (it would create a predictable, colliding literal filename for
    # this sensitive globals file, which can contain role password hashes).
    gfile="$(umask 077; mktemp "${TMPDIR:-/tmp}/t-pgsql-globals.XXXXXX")" || { log_error "mktemp failed"; return 1; }

    if ! dump_source_globals "$gfile"; then
        rm -f "$gfile"
        log_error "Failed to dump globals from source"
        return 1
    fi

    local idx=0 conn
    for conn in "${TO_CONNECTIONS[@]}"; do
        if ! parse_connection "$conn" "TO"; then
            log_warn "Skipping globals for invalid target: $conn"
            idx=$((idx+1)); continue
        fi
        get_password "TO" "$idx"
        if apply_globals_to_target "$gfile"; then
            log_success "Globals applied to ${TO_DATABASE}@${TO_DB_HOST}"
        else
            log_warn "Globals for ${TO_DATABASE}@${TO_DB_HOST} completed WITH ERRORS (beyond pre-existing roles) — review before relying on the migration"
        fi
        idx=$((idx+1))
    done

    rm -f "$gfile"
    return 0
}

cmd_upgrade() {
    log_info "Logical major-version migration (dump + globals + restore)."
    log_warn "For large clusters or minimal downtime, pg_upgrade or logical replication are better-established methods."

    [ -z "$FROM_CONNECTION" ] && { log_error "--from required"; return 1; }
    [ ${#TO_CONNECTIONS[@]} -eq 0 ] && { log_error "--to required"; return 1; }

    parse_connection "$FROM_CONNECTION" "FROM" || { log_error "Invalid source connection: $FROM_CONNECTION"; return 1; }
    get_password "FROM"
    parse_connection "${TO_CONNECTIONS[0]}" "TO" || { log_error "Invalid target connection: ${TO_CONNECTIONS[0]}"; return 1; }
    get_password "TO" 0

    # Version preflight (best effort; TCP/local only)
    local sv tv
    sv=$(server_version_num "FROM"); tv=$(server_version_num "TO")
    if [ -n "$sv" ] && [ -n "$tv" ]; then
        log_info "Source server_version_num=$sv  ->  target=$tv"
        if [ "$(( tv / 10000 ))" -lt "$(( sv / 10000 ))" ]; then
            log_error "Target major ($(( tv / 10000 ))) is OLDER than source major ($(( sv / 10000 ))); logical restore into an older major version is not supported."
            return 1
        fi
    fi

    # A migration always carries globals, then clones the database.
    GLOBALS=true
    cmd_clone
}

