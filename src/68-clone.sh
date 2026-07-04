# ==============================================================================
# CLONE
# ==============================================================================
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
    local _f_type="$FROM_TYPE" _f_ssh="$FROM_SSH_HOST" _f_db="${FROM_DB_HOST}:${FROM_DB_PORT}/${FROM_DATABASE}"
    local _i
    for _i in "${!TO_CONNECTIONS[@]}"; do
        parse_connection "${TO_CONNECTIONS[$_i]}" "TO" || { log_error "Invalid target connection: ${TO_CONNECTIONS[$_i]}"; return 1; }
        if [ "$_f_type" = "$TO_TYPE" ] \
           && [ "${_f_ssh}" = "${TO_SSH_HOST}" ] \
           && [ "${_f_db}" = "${TO_DB_HOST}:${TO_DB_PORT}/${TO_DATABASE}" ]; then
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
    meta_update_target "$latest" $([ $r -eq 0 ] && echo "success" || echo "failed") $restore_elapsed

    # Cleanup
    [ "$KEEP" -eq 0 ] && rm -f "$latest"

    # Send notification
    local total_elapsed=$(format_elapsed $(($(date +%s) - META_START_EPOCH)))
    if [ $r -eq 0 ]; then
        log_success "Clone complete"
        local details=$(build_notify_details "CLONE" "Success" "$total_elapsed")
        send_notification "success" "Clone completed: ${FROM_DATABASE} → ${TO_DATABASE}" "$details"
    else
        local details=$(build_notify_details "CLONE" "Failed" "$total_elapsed")
        send_notification "failed" "Clone failed: ${FROM_DATABASE} → ${TO_DATABASE}" "$details"
        return 1
    fi
}

