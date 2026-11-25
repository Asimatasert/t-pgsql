# Read "telegram_allowed_users" from the defaults: section of the yaml. Understands an inline
# value (comma string or [a, b]) and a block list ("- 111" lines). Prints nothing when the key
# is absent; otherwise prints PRESENT: followed by the raw ids (possibly empty).
bot_yaml_allowed_raw() {
    awk '
    /^defaults:/ { d = 1; next }
    /^[A-Za-z]/ { d = 0; if (k) k = 2 }
    d && k != 1 && k != 2 && /^  telegram_allowed_users:/ {
        k = 1; v = $0
        sub(/^  telegram_allowed_users:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v)
        val = v; next
    }
    k == 1 && /^[ \t]*-([ \t]|$)/ {
        v = $0; sub(/^[ \t]*-[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v)
        val = val "," v; next
    }
    k == 1 && /^[ \t]*(#.*)?$/ { next }
    k == 1 { k = 2 }
    END { if (k) print "PRESENT:" val }
    ' "$1"
}

# Print the normalized sender allowlist as ",id1,id2,". Prints nothing when no allowlist is
# configured. A configured list without any valid numeric id prints "," (matches nobody).
# Source: TELEGRAM_ALLOWED_USERS (non-empty), else "telegram_allowed_users" under defaults:
# in the YAML (key present, even when empty or in an unreadable form, counts as configured).
bot_allowed_users() {
    local raw="${TELEGRAM_ALLOWED_USERS:-}" present=""
    [ -n "$raw" ] && present=1
    if [ -z "$present" ] && [ -f "$JOBS_FILE" ]; then
        raw=$(bot_yaml_allowed_raw "$JOBS_FILE" 2>/dev/null) || true
        if [ -n "$raw" ]; then present=1; raw="${raw#PRESENT:}"; fi
    fi
    [ -z "$present" ] && return 0
    raw=$(printf '%s' "$raw" | tr -d '[]"\047 \t')
    local out="," id ids=()
    IFS=, read -ra ids <<< "$raw"
    for id in "${ids[@]}"; do
        [[ "$id" =~ ^[0-9]+$ ]] && out+="${id},"
    done
    printf '%s\n' "$out"
}

# bot_user_allowed <allowlist> <user_id>: succeeds when no allowlist is set, or when the
# sender id is a number present in it. A missing or non-numeric id never matches.
bot_user_allowed() {
    [ -z "$1" ] && return 0
    [[ "$2" =~ ^[0-9]+$ ]] || return 1
    [[ "$1" == *",$2,"* ]]
}

# Printable sender id for logs (digits only, otherwise "unknown").
bot_user_label() {
    [[ "$1" =~ ^[0-9]+$ ]] && echo "$1" || echo unknown
}

# Owner uid of a path (GNU stat first, BSD stat as fallback).
bot_file_owner() {
    stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null
}

# True when the path is a regular file (not a symlink) owned by the current user.
bot_safe_file() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(bot_file_owner "$1")" = "$(id -u)" ]
}

# Print the per-user state directory (created 700); fail if it is a symlink,
# not a directory, or not owned by the current user.
bot_state_dir() {
    local base="${XDG_STATE_HOME:-}"
    [ -z "$base" ] && [ -n "$HOME" ] && base="$HOME/.local/state"
    [ -z "$base" ] && return 1
    local dir="$base/t-pgsql"
    [ -L "$dir" ] && return 1
    if [ ! -e "$dir" ]; then
        (umask 077; mkdir -p "$dir") 2>/dev/null || return 1
    fi
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(bot_file_owner "$dir")" = "$(id -u)" ] || return 1
    chmod 700 "$dir" 2>/dev/null
    echo "$dir"
}

# Print the integer stored in an offset file, or 0 if it is not a plain integer.
bot_read_offset() {
    local v=""
    read -r v < "$1" 2>/dev/null || true
    [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

# Persist the poll offset (no-op when no safe offset file is available).
bot_save_offset() {
    [ -n "$1" ] || return 0
    (umask 077; printf '%s\n' "$2" > "$1") 2>/dev/null || true
}

bot_valid_job_name() {
    # Job names from chat or button data: the safe set YAML job keys use, and never
    # a leading dash (the name is passed to --only).
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]]
}

bot_resolve_yaml() {
    local name="$1"

    # The yaml the bot was started with is always addressable: by its base name, by the
    # base name without ".yaml", or by the exact path it was started with.
    if [ -n "$JOBS_FILE" ]; then
        local own_base
        own_base=$(basename "$JOBS_FILE")
        if [ "$name" = "$JOBS_FILE" ] || [ "$name" = "$own_base" ] || [ "$name" = "${own_base%.yaml}" ]; then
            echo "$JOBS_FILE"
            return
        fi
    fi

    # Chat input: only a plain file name inside SCRIPT_DIR is accepted. Paths,
    # "..", leading dots/dashes and unusual characters resolve to nothing.
    if [[ ! "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || [[ "$name" == *..* ]]; then
        return 1
    fi

    # Add .yaml extension if missing
    [[ "$name" != *.yaml ]] && name="${name}.yaml"

    echo "${SCRIPT_DIR}/${name}"
}

# Check cooldown for a job, returns skip message or empty
bot_check_cooldown() {
    local yaml_path="$1" job_name="$2" cooldown="$3"

    # Use the same base name the dump code uses: ${DUMP_NAME:-$FROM_DATABASE}.
    # The job name is only a last resort (it is not part of the dump file name).
    local dump_name
    dump_name=$(JOBS_FILE="$yaml_path" get_job_value "$job_name" "dump_name" 2>/dev/null) || true
    if [ -z "$dump_name" ]; then
        local profile
        profile=$(JOBS_FILE="$yaml_path" get_job_field "$job_name" "from" "profile" 2>/dev/null) || true
        dump_name=$(JOBS_FILE="$yaml_path" get_job_field "$job_name" "from" "database" 2>/dev/null) || true
        if [ -z "$dump_name" ] && [ -n "$profile" ]; then
            dump_name=$(JOBS_FILE="$yaml_path" get_profile_value "$profile" "database" 2>/dev/null) || true
        fi
    fi
    [ -z "$dump_name" ] && dump_name="$job_name"
    # The name is used in a file glob: refuse anything that could widen or escape it.
    [[ "$dump_name" =~ ^[A-Za-z0-9._-]+$ ]] || return 0

    local output_dir
    output_dir=$(JOBS_FILE="$yaml_path" get_job_value "$job_name" "output" 2>/dev/null) || true
    [ -z "$output_dir" ] && output_dir="${SCRIPT_DIR}/../data/dumps"
    output_dir="${output_dir/#\~/$HOME}"

    [ ! -d "$output_dir" ] && return 0

    local latest
    latest=$(ls -t "$output_dir/${dump_name}"_*.tar.gz "$output_dir/${dump_name}"_*.dump.zst "$output_dir/${dump_name}"_*.dump "$output_dir/${dump_name}"_*.dump.xz "$output_dir/${dump_name}"_*.dump.bz2 2>/dev/null | head -1) || true

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
        local log_file; log_file=$(mktemp "${_BOT_SCRATCH:-${TMPDIR:-/tmp}}/run-XXXXXX" 2>/dev/null) || log_file=/dev/null

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
        [ "$log_file" != /dev/null ] && rm -f "$log_file"
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

