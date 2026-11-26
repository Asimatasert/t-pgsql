# ==============================================================================
# HEALTH CHECK
# ==============================================================================
health_check() {
    local prefix="$1"  # FROM or TO
    local label="${2:-$prefix}"

    local type="" host="" port="" user="" password="" database=""

    if [ "$prefix" = "FROM" ]; then
        type="$FROM_TYPE"
        host="${FROM_SSH_HOST:-$FROM_DB_HOST}"
        port="$FROM_DB_PORT"
        user="$FROM_DB_USER"
        password="$FROM_DB_PASSWORD"
        database="$FROM_DATABASE"
    else
        type="$TO_TYPE"
        host="${TO_SSH_HOST:-$TO_DB_HOST}"
        port="$TO_DB_PORT"
        user="$TO_DB_USER"
        password="$TO_DB_PASSWORD"
        database="$TO_DATABASE"
    fi

    log_info "Health check: $label ($host/$database)..."

    local result=0

    if [ "$type" = "ssh" ]; then
        local ssh_user ssh_host ssh_port db_host db_port
        if [ "$prefix" = "FROM" ]; then
            ssh_user="$FROM_SSH_USER"
            ssh_host="$FROM_SSH_HOST"
            ssh_port="$FROM_SSH_PORT"
            db_host="$FROM_DB_HOST"
            db_port="$FROM_DB_PORT"
        else
            ssh_user="$TO_SSH_USER"
            ssh_host="$TO_SSH_HOST"
            ssh_port="$TO_SSH_PORT"
            db_host="$TO_DB_HOST"
            db_port="$TO_DB_PORT"
        fi

        # Check SSH connection (honor the same SSH_OPTS as every other ssh call so the
        # probe uses the same key/keepalive settings as the operations it precedes).
        if ! ssh -p "$ssh_port" "${SSH_OPTS[@]}" -o ConnectTimeout=5 -o BatchMode=yes "${ssh_user}@${ssh_host}" "echo ok" >/dev/null 2>&1; then
            log_error "SSH connection failed: ${ssh_user}@${ssh_host}:${ssh_port}"
            return 1
        fi
        log_debug "SSH connection OK"

        # Check database connection via SSH (password via remote PGPASSFILE, not argv)
        local pgpass_pre; pgpass_pre="$(remote_pgpass_preamble "$user" "$password")"
        local check_cmd="${pgpass_pre}psql -U $(pq "$user") -h $(pq "$db_host") -p $(pq "$db_port") -d $(pq "$database") -c 'SELECT 1' >/dev/null 2>&1 && echo ok"
        if ! ssh_exec "$ssh_port" "${ssh_user}@${ssh_host}" "$check_cmd" -o ConnectTimeout=5 -o BatchMode=yes | grep -q "ok"; then
            # A SOURCE database MUST exist — do not fall back (that falsely passed the
            # check for a non-existent source). Only a TARGET may not exist yet.
            if [ "$prefix" = "FROM" ]; then
                log_error "Source database does not exist or is unreachable: $user@$db_host:$db_port/$database"
                return 1
            fi
            local fallback_cmd="${pgpass_pre}psql -U $(pq "$user") -h $(pq "$db_host") -p $(pq "$db_port") -d postgres -c 'SELECT 1' >/dev/null 2>&1 && echo ok"
            if ! ssh_exec "$ssh_port" "${ssh_user}@${ssh_host}" "$fallback_cmd" -o ConnectTimeout=5 -o BatchMode=yes | grep -q "ok"; then
                log_error "Database connection failed: $user@$db_host:$db_port/$database"
                return 1
            fi
            log_debug "Target database '$database' doesn't exist yet, but PostgreSQL server is accessible"
        fi
    else
        # Local database check (password via PGPASSFILE, not argv).
        # Use "$host" (set per-prefix above), NOT a hardcoded FROM_DB_HOST — otherwise
        # a TO-target check probes the source's host and spuriously fails.
        setup_local_pgpass "$user" "$password" || { log_error "Failed to prepare credentials"; return 1; }
        if ! psql -U "$user" -h "$host" -p "$port" -d "$database" -c 'SELECT 1' >/dev/null 2>&1; then
            # Source must exist; only a target may not exist yet (see above).
            if [ "$prefix" = "FROM" ]; then
                cleanup_local_pgpass
                log_error "Source database does not exist or is unreachable: $user@$host:$port/$database"
                return 1
            fi
            if ! psql -U "$user" -h "$host" -p "$port" -d postgres -c 'SELECT 1' >/dev/null 2>&1; then
                cleanup_local_pgpass
                log_error "Database connection failed: $user@$host:$port/$database"
                return 1
            fi
            log_debug "Target database '$database' doesn't exist yet, but PostgreSQL server is accessible"
        fi
        cleanup_local_pgpass
    fi

    log_success "Health check passed: $label"
    return 0
}

run_health_checks() {
    local check_from="${1:-true}"
    local check_to="${2:-false}"

    if [ "$HEALTH_CHECK" != true ]; then
        return 0
    fi

    local failed=0

    if [ "$check_from" = true ] && [ -n "$FROM_DATABASE" ]; then
        health_check "FROM" "Source" || failed=1
    fi

    if [ "$check_to" = true ] && [ -n "$TO_DATABASE" ]; then
        health_check "TO" "Target" || failed=1
    fi

    if [ $failed -eq 1 ] && [ "$HEALTH_CHECK_FAIL" = true ]; then
        log_error "Health check failed, aborting (--health-check-fail)"
        exit 1
    fi

    return $failed
}

# Post-operation health check (--health-check-after): verify connectivity with a
# "SELECT 1" against the operation's endpoint (target if set, otherwise source).
run_post_health_check() {
    [ "$HEALTH_CHECK_AFTER" != true ] && return 0
    [ "$DRY_RUN" = true ] && return 0

    log_info "Running post-operation health check..."
    local rc=0
    if [ -n "$TO_DATABASE" ]; then
        health_check "TO" "Target (post-op)" || rc=1
    elif [ -n "$FROM_DATABASE" ]; then
        health_check "FROM" "Source (post-op)" || rc=1
    else
        log_warn "Post-operation health check skipped: no database to check"
        return 0
    fi

    [ $rc -eq 0 ] && log_success "Post-operation health check passed" || log_warn "Post-operation health check failed"
    return $rc
}

