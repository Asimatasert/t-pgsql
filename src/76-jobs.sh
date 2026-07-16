save_job() {
    local job_name="$1"
    shift
    local job_command="$1"

    [ -z "$job_name" ] && { log_error "Job name required"; return 1; }
    [ -z "$job_command" ] && { log_error "Command required"; return 1; }

    # Build args string from current settings (use single quotes for values with special chars)
    local args=""
    [ -n "$FROM_CONNECTION" ] && args="$args --from $(pq "$FROM_CONNECTION")"
    for to in "${TO_CONNECTIONS[@]}"; do
        args="$args --to $(pq "$to")"
    done
    [ -n "$FROM_PASSWORD_FILE" ] && args="$args --from-password-file $(pq "$FROM_PASSWORD_FILE")"
    for pf in "${TO_PASSWORD_FILES[@]}"; do
        args="$args --to-password-file $(pq "$pf")"
    done
    [ -n "$PASSWORD_FILE" ] && args="$args --password-file $(pq "$PASSWORD_FILE")"
    [ -n "$OUTPUT_DIR" ] && args="$args --output $(pq "$OUTPUT_DIR")"
    [ "$KEEP" -ge 0 ] && args="$args --keep $KEEP"
    [ "$FROM_KEEP" -gt 0 ] && args="$args --from-keep $FROM_KEEP"
    [ -n "$EXCLUDE_TABLES" ] && args="$args --exclude-table $(pq "$EXCLUDE_TABLES")"
    [ -n "$EXCLUDE_SCHEMAS" ] && args="$args --exclude-schema $(pq "$EXCLUDE_SCHEMAS")"
    [ -n "$EXCLUDE_DATA" ] && args="$args --exclude-data $(pq "$EXCLUDE_DATA")"
    [ -n "$ONLY_TABLES" ] && args="$args --only-table $(pq "$ONLY_TABLES")"
    [ -n "$ONLY_SCHEMAS" ] && args="$args --only-schema $(pq "$ONLY_SCHEMAS")"

    # Naming / skip
    [ -n "$DUMP_NAME" ] && args="$args --dump-name $(pq "$DUMP_NAME")"
    [ -n "$SKIP_IF_RECENT" ] && args="$args --skip-if-recent $(pq "$SKIP_IF_RECENT")"

    # Compression (only when changed from defaults)
    [ "$COMPRESS" != "gzip" ] && args="$args --compress $(pq "$COMPRESS")"
    [ "$COMPRESS_LEVEL" != 6 ] && args="$args --compress-level $COMPRESS_LEVEL"
    [ "$PG_COMPRESS_LEVEL_SET" = true ] && args="$args --pg-compress-level $PG_COMPRESS_LEVEL"
    [ "$COMPRESS_WHERE" != "target" ] && args="$args --compress-where $(pq "$COMPRESS_WHERE")"
    [ "$FROM_STALE" != "72h" ] && args="$args --from-stale $(pq "$FROM_STALE")"

    # Streaming
    [ "$STREAM" = true ] && args="$args --stream"
    [ "$STREAM_BUFFER" != 64 ] && args="$args --stream-buffer $STREAM_BUFFER"

    # Retention (GFS)
    if [ "$RETENTION" = true ]; then
        args="$args --retention"
        [ "$RETENTION_DAILY" != 7 ] && args="$args --retention-daily $RETENTION_DAILY"
        [ "$RETENTION_WEEKLY" != 4 ] && args="$args --retention-weekly $RETENTION_WEEKLY"
        [ "$RETENTION_MONTHLY" != 12 ] && args="$args --retention-monthly $RETENTION_MONTHLY"
        [ "$RETENTION_YEARLY" != 3 ] && args="$args --retention-yearly $RETENTION_YEARLY"
    fi

    # Masking
    [ "$MASK" = true ] && args="$args --mask"
    [ -n "$MASK_RULES" ] && args="$args --mask-rules $(pq "$MASK_RULES")"
    [ -n "$MASK_TABLES" ] && args="$args --mask-tables $(pq "$MASK_TABLES")"

    # Health checks
    [ "$HEALTH_CHECK_FAIL" = true ] && args="$args --health-check-fail"

    # Notifications
    for n in "${NOTIFY[@]}"; do
        args="$args --notify $(pq "$n")"
    done
    [ "$NOTIFY_ON_ERROR" = true ] && args="$args --notify-on-error"

    # Batch job filters
    [ -n "$ONLY_JOBS" ] && args="$args --only $(pq "$ONLY_JOBS")"
    [ -n "$EXCLUDE_JOBS" ] && args="$args --exclude $(pq "$EXCLUDE_JOBS")"

    [ "$SUDO" = true ] && args="$args --sudo"
    [ "$FORCE" = true ] && args="$args --force"
    [ "$VERBOSE" = true ] && args="$args --verbose"

    # Create jobs file if not exists
    [ ! -f "$JOBS_FILE" ] && echo "jobs:" > "$JOBS_FILE"

    # Check if job exists
    if grep -q "^  $job_name:" "$JOBS_FILE" 2>/dev/null; then
        # Update existing job
        # Pass args via ENVIRON (NOT awk -v, which interprets backslash escapes and would
        # mangle pq's \" / \\), and serialize it IDENTICALLY to the append path below
        # (bare "    args:" + raw value, no double-quote wrapping which clean_value would
        # truncate at the first embedded quote).
        local tmp_file=$(mktemp)
        JOBARGS="$args" awk -v name="$job_name" -v cmd="$job_command" '
        BEGIN { skip=0 }
        {
            if ($0 ~ /^  [a-zA-Z0-9_-]+:/ && $1 == name":") {
                print "  " name ":"
                print "    command: " cmd
                print "    args:" ENVIRON["JOBARGS"]
                skip=1
                next
            }
            if (skip==1) {
                # Skip only the old job body (indented deeper than the 2-space job
                # key). Stop at the next 2-space job key OR any top-level (0-indent)
                # line such as a "defaults:" section header — which the old code
                # deleted, reparenting its keys and corrupting the file.
                if ($0 ~ /^  [a-zA-Z0-9_-]+:/ || $0 ~ /^[^ ]/) { skip=0; print }
                next
            }
            print
        }
        ' "$JOBS_FILE" > "$tmp_file"
        mv "$tmp_file" "$JOBS_FILE"
        log_success "Updated job: $job_name"
    else
        # Add new job
        cat >> "$JOBS_FILE" << EOF
  $job_name:
    command: $job_command
    args:$args
EOF
        log_success "Saved job: $job_name"
    fi

    log_info "Jobs file: $JOBS_FILE"
}

list_jobs() {
    if [ ! -f "$JOBS_FILE" ]; then
        log_warn "No jobs file found: $JOBS_FILE"
        return 1
    fi

    echo ""
    echo "Available jobs:"
    echo "==============="
    # Only list jobs under the 'jobs:' section
    awk '
    /^jobs:/ { in_jobs=1; next }
    /^[a-zA-Z]/ { if ($0 !~ /^jobs:/) in_jobs=0 }
    in_jobs && /^  [a-zA-Z0-9_-]+:/ {
        gsub(/^ +/, "")
        gsub(/:.*/, "")
        print
    }
    ' "$JOBS_FILE" | while read -r job; do
        if [[ "$job" == *"-to-local"* ]]; then
            echo -e "  • ${MAGENTA}${job}${NC}"
        elif [[ "$job" == *"-to-30"* ]]; then
            echo -e "  • ${CYAN}${job}${NC}"
        else
            echo "  • $job"
        fi
    done
    echo ""
    echo "Usage: t-pgsql jobs [list|show|remove] <name>"
    echo ""
}

show_job() {
    local job_name="$1"

    if [ -z "$job_name" ]; then
        log_error "Job name required. Usage: t-pgsql jobs show <name>"
        return 1
    fi

    if [ ! -f "$JOBS_FILE" ]; then
        log_error "Jobs file not found: $JOBS_FILE"
        return 1
    fi

    # Check if job exists
    local job_cmd=$(get_job_field "$job_name" "command")
    if [ -z "$job_cmd" ]; then
        log_error "Job not found: $job_name"
        return 1
    fi

    # Parse job args (supports both old and new format)
    local job_args=$(parse_job_to_args "$job_name")

    echo ""
    echo -e "Job: ${BOLD}$job_name${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${CYAN}Command:${NC} $job_cmd"
    echo -e "${CYAN}Arguments:${NC}"

    # Parse and display args nicely (handle quoted values)
    echo "$job_args" | sed "s/' --/'\n--/g" | while read -r arg; do
        [ -n "$arg" ] && echo -e "  ${GREEN}${arg}${NC}"
    done
    echo ""
}

remove_job() {
    local job_name="$1"

    if [ -z "$job_name" ]; then
        log_error "Job name required. Usage: t-pgsql jobs remove <name>"
        return 1
    fi

    if [ ! -f "$JOBS_FILE" ]; then
        log_error "Jobs file not found: $JOBS_FILE"
        return 1
    fi

    # Check if job exists
    if ! grep -q "^  $job_name:" "$JOBS_FILE" 2>/dev/null; then
        log_error "Job not found: $job_name"
        return 1
    fi

    # Remove job using awk
    local tmp_file=$(mktemp)
    awk -v name="$job_name" '
    BEGIN { skip=0 }
    {
        if ($0 ~ /^  [a-zA-Z0-9_-]+:/ && $1 == name":") { skip=1; next }
        if (skip==1) {
            # Skip only the removed job body; stop at the next 2-space job key OR any
            # top-level (0-indent) line (e.g. a "defaults:" header) — preserving it.
            if ($0 ~ /^  [a-zA-Z0-9_-]+:/ || $0 ~ /^[^ ]/) { skip=0; print }
            next
        }
        print
    }
    ' "$JOBS_FILE" > "$tmp_file"

    mv "$tmp_file" "$JOBS_FILE"
    log_success "Removed job: $job_name"
}

run_job() {
    local job_name="$1"

    if [ ! -f "$JOBS_FILE" ]; then
        log_error "Jobs file not found: $JOBS_FILE"
        return 1
    fi

    # Extract command
    local job_cmd=$(get_job_field "$job_name" "command")

    if [ -z "$job_cmd" ]; then
        log_error "Job $(pq "$job_name") not found or missing a 'command:' field"
        return 1
    fi

    # The command word is re-exec'd via bash -c, so it MUST be one of the known
    # subcommands — never an arbitrary string like "dump; rm -rf ...".
    case "$job_cmd" in
        dump|restore|clone|upgrade|fetch|batch|list|meta|clean) ;;
        *) log_error "Job $(pq "$job_name") has an invalid command: $(pq "$job_cmd")"; return 1 ;;
    esac

    # Parse job args (supports both old and new format). Inline passwords are NOT in here
    # (parse_job_to_args deliberately omits them); they travel via the environment below.
    local job_args=$(parse_job_to_args "$job_name")

    # Read inline passwords to hand to the child via the ENVIRONMENT (not argv, so they stay
    # off the child's process argv / ps). Empty values are treated as unset by get_password.
    local _pw_both _pw_from _pw_to
    _pw_both=$(get_job_value "$job_name" "password")
    _pw_from=$(get_job_field "$job_name" "from" "password"); [ -z "$_pw_from" ] && _pw_from=$(get_job_value "$job_name" "from_password")
    _pw_to=$(get_job_field "$job_name" "to" "password");     [ -z "$_pw_to" ]   && _pw_to=$(get_job_value "$job_name" "to_password")

    log_info "Running job: $job_name"
    log_debug "Command: $job_cmd $(redact_args "$job_args")"

    # Export so the re-exec'd child (which runs the dump and sends notifications)
    # can attach a job-specific "re-run" button to a failure notification.
    export CURRENT_JOB_NAME="$job_name"
    export JOBS_FILE

    # Execute via bash -c. Job passwords are passed as scoped env assignments (not argv).
    # Fall back to any INHERITED T_PGSQL_*_PASSWORD when the job has none, so a passwordless
    # job does not get an empty assignment that would shadow the documented ambient env var.
    T_PGSQL_PASSWORD="${_pw_both:-$T_PGSQL_PASSWORD}" \
    T_PGSQL_FROM_PASSWORD="${_pw_from:-$T_PGSQL_FROM_PASSWORD}" \
    T_PGSQL_TO_PASSWORD="${_pw_to:-$T_PGSQL_TO_PASSWORD}" \
        bash -c "'$0' $job_cmd $job_args"
}

