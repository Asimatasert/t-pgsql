# ==============================================================================
# NOTIFICATIONS
# ==============================================================================

# Escape a string for safe embedding inside a JSON double-quoted value (prevents
# JSON/payload injection through a database/job/host/error name).
json_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\n'/\\n}"
    v="${v//$'\r'/\\r}"
    v="${v//$'\t'/\\t}"
    printf '%s' "$v"
}

# Call the Telegram Bot API without exposing the bot token in the local process argv.
# The token lives only in the request URL, which is passed to curl via a config on stdin
# (-K -) instead of on the command line — otherwise a local `ps` reveals the token (and
# for the long-running bot's getUpdates poll, continuously). Non-secret data (-d/
# --data-urlencode args) stays on argv. Extra curl args are forwarded; stdout passes through.
# Usage: tg_api <token> <method> [curl args...]
tg_api() {
    local token="$1" method="$2"; shift 2
    printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$token" "$method" \
        | curl -s -K - "$@"
}

send_notification() {
    local status="$1"      # success, failed, error
    local message="$2"     # Main message
    local details="$3"     # Additional details (optional)

    [ ${#NOTIFY[@]} -eq 0 ] && return 0
    [ "$QUIET" = true ] && return 0

    # Only notify on error if --notify-on-error is set
    if [ "$NOTIFY_ON_ERROR" = true ] && [ "$status" = "success" ]; then
        return 0
    fi

    local emoji="✅"
    [ "$status" = "failed" ] || [ "$status" = "error" ] && emoji="❌"
    [ "$status" = "warning" ] && emoji="⚠️"

    local hostname=$(hostname)
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    for channel in "${NOTIFY[@]}"; do
        case "$channel" in
            telegram:*) notify_telegram "$channel" "$emoji" "$message" "$details" "$timestamp" "$hostname" ;;
            telegram)
                # Bare "telegram": resolve config from env or jobs.yaml defaults.
                local resolved; resolved="$(resolve_bare_telegram)"
                if [ -n "$resolved" ]; then
                    notify_telegram "$resolved" "$emoji" "$message" "$details" "$timestamp" "$hostname"
                else
                    log_warn "Notification channel 'telegram' requested but no config found (set TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID or defaults.notify.telegram in $JOBS_FILE)"
                fi
                ;;
            webhook:*)  notify_webhook "$channel" "$status" "$message" "$details" "$timestamp" ;;
            slack:*)    notify_slack "$channel" "$emoji" "$message" "$details" "$timestamp" "$hostname" ;;
            email:*)    notify_email "$channel" "$status" "$message" "$details" ;;
            *)          log_warn "Unknown notification channel: $channel" ;;
        esac
    done
}

# Resolve the "telegram:TOKEN:CHAT[:THREAD]" string for a bare "telegram"
# channel from environment variables first, then jobs.yaml defaults.
resolve_bare_telegram() {
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local cfg="telegram:${TELEGRAM_BOT_TOKEN}:${TELEGRAM_CHAT_ID}"
        [ -n "$TELEGRAM_THREAD_ID" ] && cfg="${cfg}:${TELEGRAM_THREAD_ID}"
        printf '%s' "$cfg"
        return 0
    fi
    [ -f "$JOBS_FILE" ] && get_default_telegram_config
}

notify_telegram() {
    local channel="$1"
    local emoji="$2"
    local message="$3"
    local details="$4"
    local timestamp="$5"
    local hostname="$6"

    # Parse telegram:BOT_ID:BOT_SECRET:CHAT_ID or telegram:BOT_ID:BOT_SECRET:CHAT_ID:THREAD_ID
    # Token format: BOT_ID:BOT_SECRET (contains colon)
    local token=$(echo "$channel" | cut -d: -f2-3)
    local chat_id=$(echo "$channel" | cut -d: -f4)
    local thread_id=$(echo "$channel" | cut -d: -f5)

    if [ -z "$token" ] || [ -z "$chat_id" ]; then
        log_warn "Invalid Telegram config. Use: telegram:TOKEN:CHAT_ID[:THREAD_ID]"
        return 1
    fi

    local text="${emoji} ${message}

${details}
🕐 ${timestamp}"

    # On a failure notification, attach an inline "re-run backup" button whose
    # callback_data the running bot (t-pgsql bot) understands: backup:<yaml>:<job>.
    local callback_data=""
    if [ -n "$JOBS_FILE" ] && [ -n "$CURRENT_JOB_NAME" ]; then
        callback_data="backup:$(basename "$JOBS_FILE"):${CURRENT_JOB_NAME}"
    elif [ -n "$JOBS_FILE" ]; then
        callback_data="backup:$(basename "$JOBS_FILE"):all"
    fi

    local reply_markup=""
    if [[ "$emoji" == "❌" ]] && [ -n "$callback_data" ]; then
        reply_markup='{"inline_keyboard":[[{"text":"🔄 Re-run Backup","callback_data":"'"$(json_escape "${callback_data}")"'"}]]}'
    fi

    # Base args WITHOUT parse_mode; parse_mode is added only to the first (Markdown) attempt
    # so the plain-text retry can reuse the exact same base (no fragile array filtering).
    local base_args=(-X POST
        --data-urlencode "chat_id=${chat_id}"
        --data-urlencode "text=${text}"
        -d "disable_web_page_preview=true")
    [ -n "$thread_id" ] && base_args+=(-d "message_thread_id=${thread_id}")
    [ -n "$reply_markup" ] && base_args+=(-d "reply_markup=${reply_markup}")

    local response=$(tg_api "$token" sendMessage "${base_args[@]}" -d "parse_mode=Markdown" 2>&1)
    if echo "$response" | grep -q '"ok":true'; then
        log_debug "Telegram notification sent"
        return 0
    fi
    # Markdown parsing fails with HTTP 400 when an interpolated db/host/error name contains a
    # Markdown metacharacter, which would silently drop the whole alert. Retry as PLAIN TEXT.
    response=$(tg_api "$token" sendMessage "${base_args[@]}" 2>&1)
    if echo "$response" | grep -q '"ok":true'; then
        log_debug "Telegram notification sent (plain-text fallback)"
    else
        log_warn "Telegram notification failed: $response"
    fi
}

notify_webhook() {
    local channel="$1"
    local status="$2"
    local message="$3"
    local details="$4"
    local timestamp="$5"

    local url="${channel#webhook:}"

    local payload=$(cat <<EOF
{
    "status": "$(json_escape "$status")",
    "message": "$(json_escape "$message")",
    "details": "$(json_escape "$details")",
    "timestamp": "$(json_escape "$timestamp")",
    "tool": "t-pgsql",
    "version": "$VERSION"
}
EOF
)

    local response=$(curl -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)

    log_debug "Webhook response: $response"
}

notify_slack() {
    local channel="$1"
    local emoji="$2"
    local message="$3"
    local details="$4"
    local timestamp="$5"
    local hostname="$6"

    local webhook_url="${channel#slack:}"

    local color="good"
    [[ "$emoji" == "❌" ]] && color="danger"
    [[ "$emoji" == "⚠️" ]] && color="warning"

    local payload=$(cat <<EOF
{
    "attachments": [{
        "color": "$color",
        "title": "$emoji t-pgsql: $(json_escape "$message")",
        "text": "$(json_escape "$details")",
        "footer": "Host: $(json_escape "$hostname") | $(json_escape "$timestamp")"
    }]
}
EOF
)

    curl -s -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$payload" >/dev/null 2>&1

    log_debug "Slack notification sent"
}

notify_email() {
    local channel="$1"
    local status="$2"
    local message="$3"
    local details="$4"

    local email="${channel#email:}"

    if command -v mail &>/dev/null; then
        echo -e "Status: $status\n\n$message\n\nDetails:\n$details" | \
            mail -s "[t-pgsql] $status: $message" "$email"
        log_debug "Email notification sent to $email"
    else
        log_warn "mail command not found, skipping email notification"
    fi
}

# Build notification details for operations
build_notify_details() {
    local operation="$1"
    local status="$2"
    local elapsed="$3"
    local size="${4:-}"

    local details=""

    # Source info
    if [ -n "$FROM_DATABASE" ]; then
        local src_host="${FROM_SSH_HOST:-${FROM_DB_HOST}}"
        details+="📤 \`${src_host}\`/\`${FROM_DATABASE}\`\n"
    fi

    # Target info
    if [ -n "$TO_DATABASE" ]; then
        local tgt_host="${TO_SSH_HOST:-${TO_DB_HOST}}"
        details+="📥 \`${tgt_host}\`/\`${TO_DATABASE}\`\n"
    fi

    # Size and duration on same line if both exist
    local metrics=""
    [ -n "$size" ] && metrics+="📦 ${size}"
    [ -n "$elapsed" ] && [ -n "$metrics" ] && metrics+="  •  "
    [ -n "$elapsed" ] && metrics+="⏱ ${elapsed}"
    [ -n "$metrics" ] && details+="${metrics}\n"

    # Exclusions
    local exclusions=""
    [ -n "$EXCLUDE_TABLES" ] && exclusions+="tables: ${EXCLUDE_TABLES}, "
    [ -n "$EXCLUDE_DATA" ] && exclusions+="data: ${EXCLUDE_DATA}, "
    [ -n "$EXCLUDE_SCHEMAS" ] && exclusions+="schemas: ${EXCLUDE_SCHEMAS}, "
    if [ -n "$exclusions" ]; then
        exclusions="${exclusions%, }"  # Remove trailing comma
        details+="🚫 ${exclusions}\n"
    fi

    # Retention info
    local retention=""
    [ "$FROM_KEEP" -eq 0 ] && retention+="source: none, "
    [ "$FROM_KEEP" -gt 0 ] && retention+="source: ${FROM_KEEP}, "
    [ "$KEEP" -eq 0 ] && retention+="local: none"
    [ "$KEEP" -gt 0 ] && retention+="local: ${KEEP}"
    if [ -n "$retention" ] && [ "$retention" != "source: 1, local: -1" ]; then
        retention="${retention%, }"  # Remove trailing comma
        details+="💾 keep: ${retention}\n"
    fi

    echo -e "$details"
}

