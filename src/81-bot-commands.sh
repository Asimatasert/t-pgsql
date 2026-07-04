bot_cmd_help() {
    local bot_token="$1" chat_id="$2" thread_id="$3"

    local text="🤖 *t-pgsql Bot Commands*

/list — List all YAML files
/list <yaml> — List jobs in a YAML
/backup <yaml> <job> — Start a backup
/help — Show this message

📌 Cooldown: the same job cannot run again until ${BOT_COOLDOWN:-1h} has passed since its last backup.

💡 Examples:
\`/list mydb\`
\`/backup mydb nightly\`"

    bot_send_message "$bot_token" "$chat_id" "$thread_id" "$text"
}

# ---------------------------------------------------------------------------
# Bot command: /list (all YAMLs)
# ---------------------------------------------------------------------------
bot_cmd_list_yamls() {
    local bot_token="$1" chat_id="$2" thread_id="$3"

    local text="📁 *YAML Files*
"
    local count=0
    for f in "${SCRIPT_DIR}"/*.yaml; do
        [ -f "$f" ] || continue
        local name=$(basename "$f" .yaml)
        local job_count
        job_count=$(awk '/^jobs:/{found=1;next} found && /^  [a-zA-Z0-9_-]+:/{count++} found && /^[a-zA-Z]/ && !/^  /{exit} END{print count+0}' "$f") || true
        text="${text}
📄 \`${name}\` — ${job_count} job"
        count=$((count + 1))
    done

    if [ $count -eq 0 ]; then
        text="❌ No YAML files found."
    else
        text="${text}

📌 Job details: \`/list <yaml>\`"
    fi

    bot_send_message "$bot_token" "$chat_id" "$thread_id" "$text"
}

# ---------------------------------------------------------------------------
# Bot command: /list <yaml> (jobs in a YAML)
# ---------------------------------------------------------------------------
bot_cmd_list_jobs() {
    local bot_token="$1" chat_id="$2" thread_id="$3" yaml_name="$4"

    local yaml_path
    yaml_path=$(bot_resolve_yaml "$yaml_name")

    if [ ! -f "$yaml_path" ]; then
        bot_send_message "$bot_token" "$chat_id" "$thread_id" "❌ YAML not found: ${yaml_name}

Use /list to see available files."
        return 0
    fi

    local display_name=$(basename "$yaml_path" .yaml)
    local text="📄 *${display_name}* Jobs
"

    # Extract job names from YAML
    local jobs_list
    jobs_list=$(awk '/^jobs:/{found=1;next} found && /^  [a-zA-Z0-9_-]+:/{name=$1; gsub(/:$/,"",name); print name} found && /^[a-zA-Z]/ && !/^  /{exit}' "$yaml_path") || true

    if [ -z "$jobs_list" ]; then
        text="${text}
⚠️ No jobs found in this YAML."
    else
        while IFS= read -r job_name; do
            [ -z "$job_name" ] && continue
            local cmd
            cmd=$(JOBS_FILE="$yaml_path" get_job_field "$job_name" "command" 2>/dev/null) || true
            local db_from
            db_from=$(JOBS_FILE="$yaml_path" get_job_field "$job_name" "from" "database" 2>/dev/null) || true
            text="${text}
▫️ \`${job_name}\` �� ${cmd:-?} ${db_from:+($db_from)}"
        done <<< "$jobs_list"

        text="${text}

📌 Backup: \`/backup ${display_name} <job>\`"
    fi

    bot_send_message "$bot_token" "$chat_id" "$thread_id" "$text"
}

# ---------------------------------------------------------------------------
# Bot command: /backup <yaml> <job>
# ---------------------------------------------------------------------------
bot_cmd_backup() {
    local bot_token="$1" chat_id="$2" thread_id="$3"
    local yaml_name="$4" job_name="$5" bot_cooldown="$6"

    if [ -z "$yaml_name" ] || [ -z "$job_name" ]; then
        bot_send_message "$bot_token" "$chat_id" "$thread_id" "❌ Usage: /backup <yaml> <job>

Example: \`/backup mydb nightly\`
To see jobs: \`/list ${yaml_name:-<yaml>}\`"
        return 0
    fi

    local yaml_path
    yaml_path=$(bot_resolve_yaml "$yaml_name")

    if [ ! -f "$yaml_path" ]; then
        bot_send_message "$bot_token" "$chat_id" "$thread_id" "❌ YAML not found: ${yaml_name}"
        return 0
    fi

    # Verify job exists
    local job_cmd
    job_cmd=$(JOBS_FILE="$yaml_path" get_job_field "$job_name" "command" 2>/dev/null) || true
    if [ -z "$job_cmd" ]; then
        bot_send_message "$bot_token" "$chat_id" "$thread_id" "❌ Job not found: ${job_name}

\`/list ${yaml_name}\` to see available jobs."
        return 0
    fi

    # Check cooldown
    local skip_msg
    skip_msg=$(bot_check_cooldown "$yaml_path" "$job_name" "$bot_cooldown")

    if [ -n "$skip_msg" ]; then
        bot_send_message "$bot_token" "$chat_id" "$thread_id" "⏳ ${skip_msg}"
        log_info "Skipped: ${skip_msg}"
    else
        bot_send_message "$bot_token" "$chat_id" "$thread_id" "🚀 Starting backup: *${job_name}*
YAML: ${yaml_name}"
        log_info "Starting backup: yaml=${yaml_name} job=${job_name}"
        bot_run_backup "$yaml_path" "$job_name" "$bot_token" "$chat_id" "$thread_id"
    fi
}

# ---------------------------------------------------------------------------
# Bot helpers
# ---------------------------------------------------------------------------

# Resolve YAML name to full path
