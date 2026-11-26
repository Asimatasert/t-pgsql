# ==============================================================================
# CLONE
# ==============================================================================
# Identity of the database a parsed connection (FROM or TO globals) points at, normalised so
# that spellings of the same endpoint compare equal: loopback names/addresses/socket paths
# collapse to one host, empty or zero-padded ports become the default, host case is
# ignored. An ssh connection is identified by (ssh host, ssh port, db host, db port,
# database); the ssh port matters because different machines are often reached through one
# ssh host name on different ports (tunnels, containers). An ssh connection is only equal
# to a direct connection when that is certain: the ssh host is a loopback name AND the ssh
# port is 22 (it is this machine). Any other ssh connection never equals a direct one. The
# database user is not part of the key. Names that merely resolve to the same address
# (DNS aliases, ssh config aliases) cannot be detected without network access.
_clone_endpoint_key() {
    local p="$1" t v dbh port sshh sshp db
    t="${p}_TYPE"; t="${!t}"
    v="${p}_DB_HOST"; dbh="$(_clone_norm_host "${!v}")"
    port="${p}_DB_PORT"; port="${!port}"
    [[ "$port" =~ ^[0-9]+$ ]] && port=$((10#$port)) || port=5432
    v="${p}_DATABASE"; db="${!v}"
    if [ "$t" = "ssh" ]; then
        v="${p}_SSH_HOST"; sshh="$(_clone_norm_host "${!v}")"
        v="${p}_SSH_PORT"; sshp="${!v}"
        [[ "$sshp" =~ ^[0-9]+$ ]] && sshp=$((10#$sshp)) || sshp=22
        if [ "$sshh" != "loopback" ] || [ "$sshp" != 22 ]; then
            v="${p}_SSH_HOST"; sshh="${!v}"
            printf 'ssh|%s|%s|%s:%s/%s' "${sshh,,}" "$sshp" "$dbh" "$port" "$db"
            return
        fi
    fi
    printf 'direct|%s:%s/%s' "$dbh" "$port" "$db"
}
_clone_norm_host() {
    local h="${1,,}"
    if [ -z "$h" ] || [[ "$h" == /* ]] || [[ "$h" == localhost || "$h" == localhost.* ]] \
       || [[ "$h" == "::1" || "$h" == "::" || "$h" == "0:0:0:0:0:0:0:1" || "$h" == "0.0.0.0" ]] \
       || [[ "$h" =~ ^127\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        h="loopback"
    fi
    printf '%s' "$h"
}

cmd_clone() {
    log_info "Starting clone..."

    # Validate connections first
    if [ -z "$FROM_CONNECTION" ]; then
        log_error "--from required"
        return 1
    fi

    if [ ${#TO_CONNECTIONS[@]} -eq 0 ]; then
        log_error "--to required"
        return 1
    fi

    # Parse connections for health check
    parse_connection "$FROM_CONNECTION" "FROM" || { log_error "Invalid source connection: $FROM_CONNECTION"; return 1; }
    get_password "FROM"

    # Refuse a source==target clone for ANY target (not just the first): clone_stream/restore
    # iterate every --to and, with --force, drop each before pg_dump finishes reading the
    # source, permanently destroying it. Capture the source identity, then check every target.
    local _f_key; _f_key="$(_clone_endpoint_key FROM)"
    local _i
    for _i in "${!TO_CONNECTIONS[@]}"; do
        parse_connection "${TO_CONNECTIONS[$_i]}" "TO" || { log_error "Invalid target connection: ${TO_CONNECTIONS[$_i]}"; return 1; }
        if [ "$_f_key" = "$(_clone_endpoint_key TO)" ]; then
            log_error "Source and target #$((_i+1)) are the same database — refusing (this would destroy it)"
            return 1
        fi
    done

    # Re-parse the first target for the health check and downstream code (the loop left the
    # TO_* globals pointing at the last target).
    parse_connection "${TO_CONNECTIONS[0]}" "TO" || { log_error "Invalid target connection: ${TO_CONNECTIONS[0]}"; return 1; }
    get_password "TO" 0

    # Run health check before operation
    run_health_checks true true

    # Check if recent dump exists (skip_if_recent)
    if check_skip_recent; then
        return 0
    fi

    # Dry-run mode
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would dump from: $FROM_CONNECTION"
        for conn in "${TO_CONNECTIONS[@]}"; do
            log_info "[DRY-RUN] Would restore to: $conn"
        done
        return 0
    fi

    # Migrate cluster globals (roles/tablespaces) to the target before restoring,
    # so ownership and grants have something to resolve against.
    if [ "$GLOBALS" = true ]; then
        migrate_globals || log_warn "Continuing despite globals migration issues"
    fi

    # Streaming mode: direct pipe without temp files
    if [ "$STREAM" = true ]; then
        if [ "$MASK" = true ]; then
            log_error "--mask is not supported with --stream (masking runs after a restore); omit --stream to mask"
            return 1
        fi
        clone_stream
        return $?
    fi

    cmd_dump
    [ $? -ne 0 ] && return 1

    # Find latest archive (normalize path first)
    local norm_output_dir=$(cd "$OUTPUT_DIR" && pwd)
    local dump_base_name="${DUMP_NAME:-$FROM_DATABASE}"
    local latest=$(list_dumps_for_base "$norm_output_dir" "$dump_base_name" | head -1)
    [ -z "$latest" ] && { log_error "Dump not found"; return 1; }

    FILE="$latest"
    local restore_start=$(date +%s)
    cmd_restore
    local r=$?
    local restore_elapsed=$(($(date +%s) - restore_start))

    # Update metadata with target info
    # shellcheck disable=SC2046  # unquoted on purpose: empty elapsed must expand to nothing
    meta_update_target "$latest" $([ $r -eq 0 ] && echo "success" || echo "failed") $restore_elapsed

    # Cleanup
    [ "$KEEP" -eq 0 ] && rm -f "$latest"

    # Send notification
    local total_elapsed=$(format_elapsed $(($(date +%s) - META_START_EPOCH)))
    if [ $r -eq 0 ]; then
        log_success "Clone complete"
        local details=$(build_notify_details "CLONE" "Success" "$total_elapsed")
        send_notification "success" "Clone completed: ${dump_base_name} → ${TO_DATABASE}" "$details"
    else
        local details=$(build_notify_details "CLONE" "Failed" "$total_elapsed")
        send_notification "failed" "Clone failed: ${dump_base_name} → ${TO_DATABASE}" "$details"
        return 1
    fi
}

