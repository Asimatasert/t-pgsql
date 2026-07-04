cmd_batch() {
    local target="$1"

    # Load defaults from jobs.yaml (parallel, continue_on_error)
    load_batch_defaults

    if [ -z "$target" ]; then
        if [ ! -f "$JOBS_FILE" ]; then
            log_error "Jobs file not found: $JOBS_FILE"
            return 1
        fi

        # Interactive job selection cannot run under -y/--yes (no prompt).
        if [ "$YES" = true ]; then
            log_error "No job specified. With -y/--yes provide a job name (e.g. '$SCRIPT_NAME batch <job>' or 'batch all')"
            return 1
        fi

        # Get jobs list
        local jobs_array=()
        while IFS= read -r job; do
            jobs_array+=("$job")
        done < <(awk '
            /^jobs:/ { in_jobs=1; next }
            /^[a-zA-Z]/ { if ($0 !~ /^jobs:/) in_jobs=0 }
            in_jobs && /^  [a-zA-Z0-9_-]+:/ {
                gsub(/^ +/, "")
                gsub(/:.*/, "")
                print
            }
        ' "$JOBS_FILE")

        if [ ${#jobs_array[@]} -eq 0 ]; then
            log_warn "No jobs found"
            return 1
        fi

        echo ""
        echo "Available jobs:"
        echo "==============="
        local i=1
        for job in "${jobs_array[@]}"; do
            if [[ "$job" == *"-to-local"* ]]; then
                echo -e "  ${BOLD}$i)${NC} ${MAGENTA}${job}${NC}"
            elif [[ "$job" == *"-to-30"* ]]; then
                echo -e "  ${BOLD}$i)${NC} ${CYAN}${job}${NC}"
            else
                echo -e "  ${BOLD}$i)${NC} $job"
            fi
            i=$((i + 1))
        done
        echo ""

        # Ask for selection
        read -p "Select job (1-${#jobs_array[@]}): " selection

        # Validate selection
        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#jobs_array[@]} ]; then
            log_error "Invalid selection"
            return 1
        fi

        target="${jobs_array[$((selection - 1))]}"

        # Confirmation
        echo ""
        if [[ "$target" == *"-to-local"* ]]; then
            echo -e "Selected: ${MAGENTA}${target}${NC}"
        elif [[ "$target" == *"-to-30"* ]]; then
            echo -e "Selected: ${CYAN}${target}${NC}"
        else
            echo "Selected: $target"
        fi
        echo ""
        if [ "$YES" != true ]; then
            read -p "Are you sure? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                log_warn "Cancelled"
                return 0
            fi
        fi
        echo ""
    fi

    if [ "$target" = "all" ]; then
        if [ ! -f "$JOBS_FILE" ]; then
            log_error "Jobs file not found: $JOBS_FILE"
            return 1
        fi

        meta_start
        log_info "Running all jobs..."
        echo ""

        local all_jobs=$(awk '
            /^jobs:/ { in_jobs=1; next }
            /^[a-zA-Z]/ { if ($0 !~ /^jobs:/) in_jobs=0 }
            in_jobs && /^  [a-zA-Z0-9_-]+:/ {
                gsub(/^ +/, "")
                gsub(/:.*/, "")
                print
            }
        ' "$JOBS_FILE")

        # Filter jobs with --only and --exclude
        local jobs=""
        for job in $all_jobs; do
            local include=true

            # Check --only filter
            if [ -n "$ONLY_JOBS" ]; then
                include=false
                IFS=',' read -ra only_arr <<< "$ONLY_JOBS"
                for o in "${only_arr[@]}"; do
                    [[ "$job" == $(echo "$o" | xargs) ]] && include=true
                done
            fi

            # Check --exclude filter
            if [ -n "$EXCLUDE_JOBS" ] && [ "$include" = true ]; then
                IFS=',' read -ra excl_arr <<< "$EXCLUDE_JOBS"
                for e in "${excl_arr[@]}"; do
                    [[ "$job" == $(echo "$e" | xargs) ]] && include=false
                done
            fi

            [ "$include" = true ] && jobs="$jobs $job"
        done
        jobs=$(echo "$jobs" | xargs)

        if [ -z "$jobs" ]; then
            log_warn "No jobs to run (check --only/--exclude filters)"
            return 0
        fi

        local total=$(echo "$jobs" | wc -w | tr -d ' ')
        local current=0
        local failed=0

        if [ "$PARALLEL" -gt 1 ]; then
            # Parallel execution
            log_info "Running $total jobs with $PARALLEL parallel workers..."
            echo ""

            local pids=()
            local job_names=()
            local running=0
            local completed=0
            local stop_launching=false
            local temp_dir=$(mktemp -d)
            if [ -z "$temp_dir" ]; then
                log_error "mktemp failed, cannot run parallel batch"
                return 1
            fi

            for job in $jobs; do
                # Honor --continue-on-error: stop launching new jobs once one failed
                [ "$stop_launching" = true ] && break

                # Wait if we've reached max parallel jobs
                while [ $running -ge $PARALLEL ]; do
                    for i in "${!pids[@]}"; do
                        if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                            wait "${pids[$i]}" 2>/dev/null
                            # Read status from the .exit file, not from wait
                            local exit_code=$(cat "$temp_dir/${job_names[$i]}.exit" 2>/dev/null || echo "1")
                            completed=$((completed + 1))

                            if [ "$exit_code" -eq 0 ]; then
                                log_success "[${completed}/${total}] Completed: ${job_names[$i]}"
                            else
                                log_error "[${completed}/${total}] Failed: ${job_names[$i]}"
                                failed=$((failed + 1))
                                [ "$CONTINUE_ON_ERROR" != true ] && stop_launching=true
                            fi

                            unset pids[$i]
                            unset job_names[$i]
                            running=$((running - 1))
                        fi
                    done
                    sleep 0.5
                done

                # A job may have FAILED while we were waiting for a free slot, setting
                # stop_launching. The top-of-loop break only fires on the NEXT iteration, so
                # without re-checking here we would launch one extra job after the stop.
                [ "$stop_launching" = true ] && break

                # Start new job in background.
                # Always write the .exit file even when run_job fails: capture rc
                # first, then persist it (a bare "echo $?" could reflect the redirect).
                log_info "Starting: $job"
                (run_job "$job" > "$temp_dir/$job.log" 2>&1; rc=$?; echo "$rc" > "$temp_dir/$job.exit") &
                pids+=($!)
                job_names+=("$job")
                running=$((running + 1))
            done

            # Wait for remaining jobs
            for i in "${!pids[@]}"; do
                wait "${pids[$i]}" 2>/dev/null
                local exit_code=$(cat "$temp_dir/${job_names[$i]}.exit" 2>/dev/null || echo "1")
                completed=$((completed + 1))

                if [ "$exit_code" -eq 0 ]; then
                    log_success "[${completed}/${total}] Completed: ${job_names[$i]}"
                else
                    log_error "[${completed}/${total}] Failed: ${job_names[$i]}"
                    failed=$((failed + 1))
                fi
            done

            if [ "$stop_launching" = true ]; then
                log_warn "Some jobs were not started (a job failed; use --continue-on-error to run all)"
            fi

            rm -rf "$temp_dir"
        else
            # Sequential execution
            for job in $jobs; do
                current=$((current + 1))
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_info "[$current/$total] Job: $job"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                if run_job "$job"; then
                    log_success "[$current/$total] Completed: $job"
                else
                    log_error "[$current/$total] Failed: $job"
                    failed=$((failed + 1))
                    [ "$CONTINUE_ON_ERROR" != true ] && { log_error "Stopping (use --continue-on-error to continue)"; return 1; }
                fi
                echo ""
            done
        fi

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ $failed -eq 0 ]; then
            log_success "All $total jobs completed successfully"
        else
            log_warn "$failed of $total jobs failed"
        fi

        # Send summary notification
        if [ "$NOTIFY_SUMMARY" = true ] && [ ${#NOTIFY[@]} -gt 0 ]; then
            local status="success"
            [ $failed -gt 0 ] && status="failed"
            local elapsed=$(format_elapsed $(($(date +%s) - META_START_EPOCH)))
            local summary="Completed: $((total - failed))/$total\nFailed: $failed\nDuration: $elapsed"
            send_notification "$status" "Batch completed: $total jobs" "$summary"
        fi

        # Propagate failure so cron/CI sees a nonzero exit when any job failed.
        [ $failed -gt 0 ] && return 1
        return 0
    else
        run_job "$target"
    fi
}

