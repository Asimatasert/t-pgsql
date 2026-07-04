# ==============================================================================
# TELEGRAM BOT (commands + inline button listener)
# ==============================================================================
cmd_bot() {
    local bot_token=""
    local poll_interval=2
    local bot_cooldown="1h"
    local offset=0

    # Get token from --token arg or from YAML defaults
    if [ -n "$BOT_TOKEN" ]; then
        bot_token="$BOT_TOKEN"
    elif [ -f "$JOBS_FILE" ]; then
        local tg_config=$(get_default_telegram_config)
        if [ -n "$tg_config" ]; then
            bot_token=$(echo "$tg_config" | cut -d: -f2-3)
        fi
    fi

    if [ -z "$bot_token" ]; then
        log_error "Telegram bot token required. Use --token or configure in YAML"
        return 1
    fi

    [ -n "$BOT_COOLDOWN" ] && bot_cooldown="$BOT_COOLDOWN"

    # Detect chat_id and thread_id from YAML for sending messages
    local default_chat_id="" default_thread_id=""
    if [ -f "$JOBS_FILE" ]; then
        local tg_full=$(get_default_telegram_config)
        if [ -n "$tg_full" ]; then
            default_chat_id=$(echo "$tg_full" | cut -d: -f4)
            default_thread_id=$(echo "$tg_full" | cut -d: -f5)
        fi
    fi

    log_info "🤖 t-pgsql bot started (cooldown: ${bot_cooldown})"
    log_info "Listening for commands and callbacks..."
    log_info "Press Ctrl+C to stop"
    # Fail-closed: without a configured chat_id the bot ignores every command/callback.
    [ -z "$default_chat_id" ] && log_warn "No chat_id configured (telegram config in YAML) — the bot will IGNORE all commands until an allowed chat is set."

    # Per-user temp files, created 600 (the response holds Telegram message content,
    # so it must not be world-readable on a shared host).
    local offset_file="${TMPDIR:-/tmp}/.t-pgsql-bot-offset-$(id -u)"
    local tmp_resp="${TMPDIR:-/tmp}/.t-pgsql-bot-resp-$(id -u).json"
    (umask 077; : >> "$offset_file"; : >> "$tmp_resp") 2>/dev/null
    chmod 600 "$offset_file" "$tmp_resp" 2>/dev/null
    [ -f "$offset_file" ] && offset=$(cat "$offset_file" 2>/dev/null || echo 0)

    # Main polling loop (errexit already disabled globally)
    set +e

    while true; do
        local response
        response=$(tg_api "$bot_token" getUpdates --max-time 35 -X POST \
            -d "offset=${offset}" \
            -d "timeout=30" \
            -d "allowed_updates=[\"message\",\"callback_query\"]" 2>&1)

        # Validate response
        if ! echo "$response" | grep -q '"ok":true' 2>/dev/null; then
            log_warn "Telegram API error"
            sleep "$poll_interval"
            continue
        fi

        # Skip if empty result
        if echo "$response" | grep -q '"result":\[\]' 2>/dev/null; then
            continue
        fi

        # Save response
        echo "$response" > "$tmp_resp"

        # Use python3/jq to extract updates reliably, fallback to grep
        local update_ids=""
        if command -v python3 &>/dev/null; then
            update_ids=$(python3 -c "
import json,sys
data=json.load(open('$tmp_resp'))
def s(v):
    # CRITICAL: strip the field/record delimiters from EVERY user-controlled value so a
    # message text (or callback data / first_name) containing a newline or '|' cannot forge
    # an extra '|'-delimited update line and bypass the chat-id authorization (or poison the
    # poll offset). The bot only ever needs single-line '/command args' text, so collapsing
    # these characters to spaces is lossless for its purpose.
    return str(v).replace('\r',' ').replace('\n',' ').replace('|',' ')
for u in data.get('result',[]):
    uid=u['update_id']
    # Detect type
    if 'callback_query' in u:
        cb=u['callback_query']
        cb_chat=cb.get('message',{}).get('chat',{}).get('id','')
        print(f\"{uid}|callback|{s(cb.get('id',''))}|{s(cb.get('data',''))}|{cb_chat}|{s(cb.get('from',{}).get('first_name',''))}\")
    elif 'message' in u:
        m=u['message']
        chat_id=m['chat']['id']
        thread=m.get('message_thread_id','')
        print(f\"{uid}|message|{chat_id}|{s(m.get('text',''))}|{thread}\")
" 2>/dev/null)
        fi

        if [ -z "$update_ids" ]; then
            # Fallback: just advance offset past all updates
            local max_uid
            max_uid=$(grep -o '"update_id":[0-9]*' "$tmp_resp" 2>/dev/null | grep -o '[0-9]*' 2>/dev/null | sort -n | tail -1)
            if [ -n "$max_uid" ]; then
                offset=$((max_uid + 1))
                echo "$offset" > "$offset_file"
            fi
            sleep "$poll_interval"
            continue
        fi

        # Process each update line
        while IFS='|' read -r uid utype field1 field2 field3 field4; do
            [ -z "$uid" ] && continue

            # Advance offset
            offset=$((uid + 1))
            echo "$offset" > "$offset_file"

            if [ "$utype" = "callback" ]; then
                local cb_id="$field1"
                local cb_data="$field2"
                local cb_chat="$field3"
                local cb_user="$field4"

                # Authorize the callback the same way messages are: only act on button
                # presses coming from the configured chat. FAIL CLOSED — if no allowed chat
                # is configured, reject everything rather than accepting any chat.
                if [ -z "$default_chat_id" ] || [ "$cb_chat" != "$default_chat_id" ]; then
                    log_warn "Ignoring callback from unauthorized chat: ${cb_chat}"
                    bot_answer_callback "$bot_token" "$cb_id" "⛔ Not authorized"
                    continue
                fi

                log_info "Callback from ${cb_user}: ${cb_data}"

                local cb_action cb_yaml cb_job
                cb_action=$(echo "$cb_data" | cut -d: -f1)
                cb_yaml=$(echo "$cb_data" | cut -d: -f2)
                cb_job=$(echo "$cb_data" | cut -d: -f3)

                if [ "$cb_action" = "backup" ]; then
                    local yaml_path
                    yaml_path=$(bot_resolve_yaml "$cb_yaml")
                    if [ ! -f "$yaml_path" ]; then
                        bot_answer_callback "$bot_token" "$cb_id" "❌ YAML not found: ${cb_yaml}"
                    else
                        local skip_msg
                        skip_msg=$(bot_check_cooldown "$yaml_path" "$cb_job" "$bot_cooldown")
                        if [ -n "$skip_msg" ]; then
                            bot_answer_callback "$bot_token" "$cb_id" "⏳ ${skip_msg}"
                        else
                            bot_answer_callback "$bot_token" "$cb_id" "🚀 Starting backup: ${cb_job}"
                            bot_run_backup "$yaml_path" "$cb_job" "$bot_token" "$default_chat_id" "$default_thread_id"
                        fi
                    fi
                else
                    bot_answer_callback "$bot_token" "$cb_id" "❓ Unknown command"
                fi

            elif [ "$utype" = "message" ]; then
                local chat_id="$field1"
                local msg_text="$field2"
                local msg_thread="$field3"

                # Only respond in the configured group chat. FAIL CLOSED — with no allowed
                # chat configured, ignore all commands rather than answering any chat.
                if [ -z "$default_chat_id" ] || [ "$chat_id" != "$default_chat_id" ]; then
                    continue
                fi

                # Use default thread_id if not present in message
                [ -z "$msg_thread" ] && msg_thread="$default_thread_id"

                # Only process commands
                [[ "$msg_text" != /* ]] && continue

                log_info "Command: ${msg_text} (chat: ${chat_id})"

                case "$msg_text" in
                    /help|/help@*)
                        bot_cmd_help "$bot_token" "$chat_id" "$msg_thread"
                        ;;
                    /list\ *)
                        local yaml_name="${msg_text#/list }"
                        yaml_name="${yaml_name%%@*}"
                        yaml_name=$(echo "$yaml_name" | tr -d ' ')
                        bot_cmd_list_jobs "$bot_token" "$chat_id" "$msg_thread" "$yaml_name"
                        ;;
                    /list|/list@*)
                        bot_cmd_list_yamls "$bot_token" "$chat_id" "$msg_thread"
                        ;;
                    /backup\ *)
                        local args="${msg_text#/backup }"
                        args="${args%%@*}"
                        local b_yaml b_job
                        b_yaml=$(echo "$args" | awk '{print $1}')
                        b_job=$(echo "$args" | awk '{print $2}')
                        bot_cmd_backup "$bot_token" "$chat_id" "$msg_thread" "$b_yaml" "$b_job" "$bot_cooldown"
                        ;;
                    /backup|/backup@*)
                        bot_send_message "$bot_token" "$chat_id" "$msg_thread" "❌ Usage: /backup <yaml> <job>

Example: /backup mydb nightly"
                        ;;
                esac
            fi
        done <<< "$update_ids"

        sleep "$poll_interval"
    done
}

# ---------------------------------------------------------------------------
# Bot command: /help
# ---------------------------------------------------------------------------
