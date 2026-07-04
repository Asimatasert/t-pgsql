# ==============================================================================
# FETCH (existing dump from source)
# ==============================================================================
cmd_fetch() {
    meta_start
    log_info "Fetching existing dump..."

    if [ -z "$FROM_CONNECTION" ]; then
        log_error "--from required"
        return 1
    fi

    parse_connection "$FROM_CONNECTION" "FROM" || { log_error "Invalid source connection: $FROM_CONNECTION"; return 1; }

    if [ "$FROM_TYPE" != "ssh" ]; then
        log_error "fetch command requires SSH connection (ssh://...)"
        return 1
    fi

    mkdir -p "$OUTPUT_DIR"

    # Determine which file to fetch
    local remote_file=""

    if [ -n "$FROM_FILE" ] && [ "$FROM_FILE" != "latest" ]; then
        # User specified file/pattern
        if [[ "$FROM_FILE" == *"*"* ]]; then
            # Glob pattern - find latest matching
            log_info "Finding latest match for: $FROM_FILE"
            remote_file=$(ssh -p "$FROM_SSH_PORT" "${SSH_OPTS[@]}" "${FROM_SSH_USER}@${FROM_SSH_HOST}" \
                "ls -t /tmp/t-pgsql/$FROM_FILE 2>/dev/null | head -1")
        else
            # Exact filename - check if it has path
            if [[ "$FROM_FILE" == /* ]]; then
                remote_file="$FROM_FILE"
            else
                remote_file="/tmp/t-pgsql/$FROM_FILE"
            fi
        fi
    else
        # Auto-find latest dump for database (--from-file or --from-file latest)
        log_info "Finding latest dump for: $FROM_DATABASE"
        remote_file=$(ssh -p "$FROM_SSH_PORT" "${SSH_OPTS[@]}" "${FROM_SSH_USER}@${FROM_SSH_HOST}" \
            "ls -t /tmp/t-pgsql/$(pq "$FROM_DATABASE")_*.dump 2>/dev/null | head -1")
    fi

    if [ -z "$remote_file" ]; then
        log_error "No dump file found on source"
        return 1
    fi

    # Check file exists
    local exists=$(ssh -p "$FROM_SSH_PORT" "${SSH_OPTS[@]}" "${FROM_SSH_USER}@${FROM_SSH_HOST}" \
        "[ -f '$remote_file' ] && echo 'yes' || echo 'no'")

    if [ "$exists" != "yes" ]; then
        log_error "File not found: $remote_file"
        return 1
    fi

    log_info "Found: $remote_file"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would fetch: $remote_file"
        return 0
    fi

    local local_file="${OUTPUT_DIR}/$(basename $remote_file)"

    log_info "Downloading..."
    scp_transfer "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}:${remote_file}" "$local_file"

    if [ $? -eq 0 ]; then
        local size=$(ls -lh "$local_file" | awk '{print $5}')
        log_success "Fetched: $local_file ($size)"
        meta_write "$local_file" "success" 0
        
        # Send notification
        local details=$(build_notify_details "FETCH" "Success" "File: $(basename $local_file)\nSize: $size\nSource: ${FROM_SSH_HOST}")
        send_notification "success" "Fetch completed: ${FROM_DATABASE}" "$details"
        
        echo "DUMP_FILE=$local_file"
        echo "DUMP_SIZE=$size"
    else
        log_error "Fetch failed"
        meta_write "$local_file" "failed" 1
        
        # Send notification
        local details=$(build_notify_details "FETCH" "Failed" "Source: ${FROM_SSH_HOST}")
        send_notification "failed" "Fetch failed: ${FROM_DATABASE}" "$details"
        
        return 1
    fi
}

