bot_resolve_yaml() {
    local name="$1"

    # Already a full path
    if [[ "$name" == *"/"* ]]; then
        echo "$name"
        return
    fi

    # Add .yaml extension if missing
    [[ "$name" != *.yaml ]] && name="${name}.yaml"

    echo "${SCRIPT_DIR}/${name}"
}

# Check cooldown for a job, returns skip message or empty
bot_check_cooldown() {
    local yaml_path="$1" job_name="$2" cooldown="$3"

    local dump_name
    dump_name=$(JOBS_FILE="$yaml_path" get_job_value "$job_name" "dump_name" 2>/dev/null) || true
    [ -z "$dump_name" ] && dump_name="$job_name"

    local output_dir
    output_dir=$(JOBS_FILE="$yaml_path" get_job_value "$job_name" "output" 2>/dev/null) || true
    [ -z "$output_dir" ] && output_dir="${SCRIPT_DIR}/../data/dumps"
    output_dir="${output_dir/#\~/$HOME}"

    [ ! -d "$output_dir" ] && return 0

    local latest
    latest=$(ls -t "$output_dir"/${dump_name}_*.tar.gz "$output_dir"/${dump_name}_*.dump.zst "$output_dir"/${dump_name}_*.dump "$output_dir"/${dump_name}_*.dump.xz "$output_dir"/${dump_name}_*.dump.bz2 2>/dev/null | head -1) || true

    [ -z "$latest" ] && return 0

    local file_epoch now_epoch diff_sec cooldown_sec
    file_epoch=$(stat -c %Y "$latest" 2>/dev/null) || file_epoch=$(stat -f %m "$latest" 2>/dev/null) || true
    [[ ! "$file_epoch" =~ ^[0-9]+$ ]] && return 0

    now_epoch=$(date +%s)
    diff_sec=$((now_epoch - file_epoch))
    cooldown_sec=$(parse_time_to_seconds "$cooldown")

    if [ $diff_sec -lt $cooldown_sec ]; then
        local age_min=$((diff_sec / 60))
        local remain_min=$(( (cooldown_sec - diff_sec) / 60 ))
        echo "Last backup was ${age_min} min ago. Try again in ${remain_min} min. (cooldown: ${cooldown})"
    fi
}

# Run backup job in background with notification
bot_run_backup() {
    local yaml_path="$1" job_name="$2"
    local notify_token="$3" notify_chat="$4" notify_thread="$5"

    (
        local start_time=$(date +%s)
        # Unique per-run temp log (a fixed /tmp path was symlink-clobberable: a
        # pre-placed symlink would redirect this truncating write to an arbitrary file).
        local log_file; log_file=$(mktemp "${TMPDIR:-/tmp}/.t-pgsql-bot-$(id -u)-XXXXXX" 2>/dev/null) || log_file="${TMPDIR:-/tmp}/.t-pgsql-bot-$(id -u)-$$.log"

        # Run with --skip-if-recent 0 to bypass YAML's skip_if_recent
        "$0" batch all --yaml "$yaml_path" --only "$job_name" --skip-if-recent 0 -y > "$log_file" 2>&1
        local exit_code=$?

        local end_time=$(date +%s)
        local elapsed=$(( end_time - start_time ))
        local mins=$(( elapsed / 60 ))
        local secs=$(( elapsed % 60 ))
        local duration="${mins}m ${secs}s"

        # Send result notification
        local result_text
        if [ $exit_code -eq 0 ]; then
            result_text="✅ *Backup complete*
📄 Job: \`${job_name}\`
⏱ Duration: ${duration}
🕐 $(date '+%Y-%m-%d %H:%M:%S')"
        else
            # Get last error from log
            local last_error
            last_error=$(grep -i 'error\|fail' "$log_file" 2>/dev/null | tail -1 | sed 's/\x1b\[[0-9;]*m//g')
            result_text="❌ *Backup failed*
📄 Job: \`${job_name}\`
⏱ Duration: ${duration}
💬 ${last_error:-Unknown error}
🕐 $(date '+%Y-%m-%d %H:%M:%S')"
        fi

        # Send to Telegram (token via tg_api stdin config, not argv). The failure text embeds
        # raw log output, which routinely contains Markdown metacharacters -> parse_mode would
        # 400 and drop the alert; bot_send_message falls back to plain text.
        bot_send_message "$notify_token" "$notify_chat" "$notify_thread" "$result_text"
    ) &
    log_info "Backup started in background (PID: $!)"
}

# Send message to Telegram. Tries Markdown, then falls back to PLAIN TEXT if the API rejects
# it (an interpolated name / raw error text with a Markdown metacharacter yields HTTP 400,
# which would otherwise silently drop the message).
bot_send_message() {
    local token="$1" chat_id="$2" thread_id="$3" text="$4"

    local base_args=(-X POST
        -d "chat_id=${chat_id}"
        --data-urlencode "text=${text}"
        -d "disable_web_page_preview=true")
    [ -n "$thread_id" ] && base_args+=(-d "message_thread_id=${thread_id}")

    local resp
    resp=$(tg_api "$token" sendMessage "${base_args[@]}" -d "parse_mode=Markdown" 2>&1)
    echo "$resp" | grep -q '"ok":true' && return 0
    # Plain-text retry so the message still gets delivered.
    tg_api "$token" sendMessage "${base_args[@]}" > /dev/null 2>&1
}

# Answer callback query (inline button popup)
bot_answer_callback() {
    local token="$1"
    local callback_id="$2"
    local text="$3"

    tg_api "$token" answerCallbackQuery -X POST \
        -d "callback_query_id=${callback_id}" \
        -d "text=${text}" \
        -d "show_alert=true" > /dev/null 2>&1
}

# Helper: parse time string to seconds (1h, 30m, 2d)
parse_time_to_seconds() {
    local time_str="$1"
    case "$time_str" in
        *h) echo $(( ${time_str%h} * 3600 )) ;;
        *m) echo $(( ${time_str%m} * 60 )) ;;
        *d) echo $(( ${time_str%d} * 86400 )) ;;
        *)  echo $(( time_str * 3600 )) ;;  # Default: hours
    esac
}

