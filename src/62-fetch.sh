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

    remote_stage_prepare "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}" "/tmp/t-pgsql" || return 1

    # Determine which file to fetch
    local remote_file=""

    if [ -n "$FROM_FILE" ] && [ "$FROM_FILE" != "latest" ]; then
        # Only a file name (or glob) inside the staging directory is valid.
        case "$FROM_FILE" in
            */*|-*)
                log_error "--from-file must be a file name inside /tmp/t-pgsql on the source (no '/', not starting with '-'): $FROM_FILE"
                return 1
                ;;
        esac
        # User specified file/pattern
        if [[ "$FROM_FILE" == *"*"* || "$FROM_FILE" == *"?"* ]]; then
            # Glob pattern - find latest matching. Quote the value, leaving only
            # * and ? active as wildcards.
            log_info "Finding latest match for: $FROM_FILE"
            local from_glob sq="'"; from_glob=$(shq "$FROM_FILE")
            from_glob="${from_glob//\*/${sq}*${sq}}"
            from_glob="${from_glob//\?/${sq}?${sq}}"
            local glob_name
            glob_name=$(ssh_exec "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}" \
                "cd /tmp/t-pgsql && ls -t -- $from_glob 2>/dev/null | head -1")
            [ -n "$glob_name" ] && remote_file="/tmp/t-pgsql/$glob_name"
        else
            remote_file="/tmp/t-pgsql/$FROM_FILE"
        fi
    else
        # Auto-find latest dump for database (--from-file or --from-file latest)
        log_info "Finding latest dump for: $FROM_DATABASE"
        local latest_re latest_name
        latest_re="^$(remote_dump_match_re "$FROM_DATABASE")"
        latest_name=$(ssh_exec "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}" \
            "cd /tmp/t-pgsql && ls -t -- $(shq "$FROM_DATABASE")_*.dump* 2>/dev/null | grep -E $(shq "$latest_re") | head -1")
        [ -n "$latest_name" ] && remote_file="/tmp/t-pgsql/$latest_name"
    fi

    if [ -z "$remote_file" ]; then
        log_error "No dump file found on source"
        return 1
    fi

    # Check file exists
    local exists=$(ssh_exec "$FROM_SSH_PORT" "${FROM_SSH_USER}@${FROM_SSH_HOST}" \
        "[ -f $(shq "$remote_file") ] && echo yes || echo no")

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

