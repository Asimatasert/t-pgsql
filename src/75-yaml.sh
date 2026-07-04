# ==============================================================================
# BATCH SYSTEM
# ==============================================================================

# Shared awk helper prepended to every YAML value extractor. clean_value() strips
# a YAML inline comment and the surrounding quotes from a raw value. A '#' inside
# a quoted value is preserved; an unquoted ' #...' (or a leading '#') is treated
# as a comment and removed along with any trailing whitespace.
_YAML_AWK_LIB='
function clean_value(v,   q, rest, idx) {
    if (v ~ /^["'\'']/) {
        q = substr(v, 1, 1)
        rest = substr(v, 2)
        idx = index(rest, q)
        if (idx > 0) return substr(rest, 1, idx - 1)
        return rest
    }
    sub(/[ \t]+#.*$/, "", v)
    sub(/^#.*$/, "", v)
    sub(/[ \t]+$/, "", v)
    return v
}
'

# Get a value from YAML file using awk
# Usage: get_yaml_value "file" "section" "key"
get_yaml_value() {
    local file="$1"
    local section="$2"
    local key="$3"

    awk -v section="$section" -v key="$key" "$_YAML_AWK_LIB"'
    BEGIN { in_section=0; indent=0 }
    /^[a-zA-Z0-9_-]+:/ {
        if ($1 == section":") { in_section=1; indent=0 }
        else if (in_section && indent==0) { in_section=0 }
    }
    in_section && $1 == key":" {
        sub(/^[^:]+: */, "")
        print clean_value($0)
        exit
    }
    ' "$file"
}

# Get value from defaults section in jobs.yaml
# Usage: get_default_value "key"
get_default_value() {
    local key="$1"

    awk -v key="$key" "$_YAML_AWK_LIB"'
    BEGIN { in_defaults=0 }
    /^defaults:/ { in_defaults=1; next }
    /^[a-zA-Z]/ { if ($0 !~ /^defaults:/) in_defaults=0 }
    in_defaults && /^  [a-zA-Z0-9_-]+:/ {
        gsub(/^ +/, "")
        if ($1 == key":") {
            sub(/^[^:]+: */, "")
            print clean_value($0)
            exit
        }
    }
    ' "$JOBS_FILE"
}

# Get job field value, with fallback to defaults section
# Usage: get_job_value "job_name" "field"
get_job_value() {
    local job="$1"
    local field="$2"
    local val=$(get_job_field "$job" "$field")
    [ -z "$val" ] && val=$(get_default_value "$field")
    echo "$val"
}

# Load batch defaults from jobs.yaml (parallel, continue_on_error)
load_batch_defaults() {
    [ ! -f "$JOBS_FILE" ] && return 0

    # YAML defaults only apply when the user did NOT pass the matching CLI flag,
    # so explicit --parallel / --continue-on-error always win.
    local val
    if [ "$PARALLEL_SET" != true ]; then
        val=$(get_default_value "parallel")
        [ -n "$val" ] && PARALLEL="$val" || true
    fi

    if [ "$CONTINUE_ON_ERROR_SET" != true ]; then
        val=$(get_default_value "continue_on_error")
        [ "$val" = "true" ] && CONTINUE_ON_ERROR=true || true
    fi
}

# Get profile configuration from jobs.yaml
# Usage: get_profile "profile_name" "key"
get_profile_value() {
    local profile="$1"
    local key="$2"

    awk -v profile="$profile" -v key="$key" "$_YAML_AWK_LIB"'
    BEGIN { in_profiles=0; in_profile=0; base_indent=0 }
    /^profiles:/ { in_profiles=1; next }
    /^[a-zA-Z]/ { if ($0 !~ /^profiles:/) { in_profiles=0; in_profile=0 } }
    in_profiles && /^  [a-zA-Z0-9_-]+:/ {
        gsub(/:.*/, "", $1)
        if ($1 == profile) { in_profile=1 }
        else { in_profile=0 }
        next
    }
    in_profile && /^    [a-zA-Z0-9_-]+:/ {
        gsub(/^ +/, "")
        if ($1 == key":") {
            sub(/^[^:]+: */, "")
            print clean_value($0)
            exit
        }
    }
    ' "$JOBS_FILE"
}

# Get job field value (supports nested fields like from.database)
# Usage: get_job_field "job_name" "field" [subfield]
get_job_field() {
    local job="$1"
    local field="$2"
    local subfield="$3"

    if [ -n "$subfield" ]; then
        # Nested field (e.g., from.database)
        awk -v job="$job" -v field="$field" -v subfield="$subfield" "$_YAML_AWK_LIB"'
        BEGIN { in_job=0; in_field=0 }
        /^  [a-zA-Z0-9_-]+:/ {
            gsub(/:.*/, "", $1)
            if ($1 == job) { in_job=1 } else { in_job=0; in_field=0 }
            next
        }
        in_job && /^    [a-zA-Z0-9_-]+:/ {
            gsub(/^ +/, "")
            current_field=$1; gsub(/:.*/, "", current_field)
            if (current_field == field) {
                # Check if value is on same line (string format)
                val=$0; gsub(/^[^:]+: */, "", val)
                if (val != "" && val !~ /^$/) {
                    # Its a string value, not nested
                    if (subfield == "_value_") {
                        print clean_value(val)
                        exit
                    }
                }
                in_field=1
            } else { in_field=0 }
            next
        }
        in_job && in_field && /^      [a-zA-Z0-9_-]+:/ {
            gsub(/^ +/, "")
            if ($1 == subfield":") {
                sub(/^[^:]+: */, "")
                print clean_value($0)
                exit
            }
        }
        ' "$JOBS_FILE"
    else
        # Simple field
        awk -v job="$job" -v field="$field" "$_YAML_AWK_LIB"'
        BEGIN { in_job=0 }
        /^  [a-zA-Z0-9_-]+:/ {
            gsub(/:.*/, "", $1)
            if ($1 == job) { in_job=1 } else { in_job=0 }
            next
        }
        in_job && /^    [a-zA-Z0-9_-]+:/ {
            gsub(/^ +/, "")
            if ($1 == field":") {
                sub(/^[^:]+: */, "")
                print clean_value($0)
                exit
            }
        }
        ' "$JOBS_FILE"
    fi
}

# Build connection string from profile or inline config
# Usage: build_connection "job_name" "from|to"
build_connection() {
    local job="$1"
    local direction="$2"  # from or to

    # First check if it's a simple string value
    local conn_string=$(get_job_field "$job" "$direction" "_value_")
    if [ -n "$conn_string" ]; then
        echo "$conn_string"
        return
    fi

    # Check for profile reference
    local profile=$(get_job_field "$job" "$direction" "profile")

    local type="" ssh_user="" ssh_host="" ssh_port=""
    local db_user="" db_host="" db_port="" database=""

    if [ -n "$profile" ]; then
        # Load from profile (including database — it was omitted, so a job whose
        # connection came entirely from a profile produced an empty database).
        type=$(get_profile_value "$profile" "type")
        ssh_user=$(get_profile_value "$profile" "ssh_user")
        ssh_host=$(get_profile_value "$profile" "ssh_host")
        ssh_port=$(get_profile_value "$profile" "ssh_port")
        db_user=$(get_profile_value "$profile" "db_user")
        db_host=$(get_profile_value "$profile" "db_host")
        db_port=$(get_profile_value "$profile" "db_port")
        database=$(get_profile_value "$profile" "database")

        # A referenced-but-missing/empty profile must NOT silently fall back to
        # postgres@localhost — that could dump/restore the WRONG (local) server.
        if [ -z "${type}${ssh_host}${db_user}${db_host}${db_port}${database}" ]; then
            log_error "Profile not found or empty: '$profile' (referenced by job's $direction)"
            return 1
        fi
    fi

    # Override with job-specific values
    [ -n "$(get_job_field "$job" "$direction" "type")" ] && type=$(get_job_field "$job" "$direction" "type")
    [ -n "$(get_job_field "$job" "$direction" "ssh_user")" ] && ssh_user=$(get_job_field "$job" "$direction" "ssh_user")
    [ -n "$(get_job_field "$job" "$direction" "ssh_host")" ] && ssh_host=$(get_job_field "$job" "$direction" "ssh_host")
    [ -n "$(get_job_field "$job" "$direction" "ssh_port")" ] && ssh_port=$(get_job_field "$job" "$direction" "ssh_port")
    [ -n "$(get_job_field "$job" "$direction" "db_user")" ] && db_user=$(get_job_field "$job" "$direction" "db_user")
    [ -n "$(get_job_field "$job" "$direction" "db_host")" ] && db_host=$(get_job_field "$job" "$direction" "db_host")
    [ -n "$(get_job_field "$job" "$direction" "db_port")" ] && db_port=$(get_job_field "$job" "$direction" "db_port")
    [ -n "$(get_job_field "$job" "$direction" "database")" ] && database=$(get_job_field "$job" "$direction" "database")

    # Nothing was specified for this direction at all — return no connection instead
    # of synthesizing a spurious "postgres@localhost/" (which added a bogus --to to
    # every job and could aim an operation at the wrong local server).
    if [ -z "$profile" ] && [ -z "${type}${ssh_host}${db_user}${db_host}${db_port}${database}" ]; then
        return 0
    fi

    # Set defaults
    [ -z "$db_user" ] && db_user="postgres"
    [ -z "$db_host" ] && db_host="localhost"
    [ -z "$db_port" ] && db_port="5432"
    [ -z "$ssh_port" ] && ssh_port="22"

    # Build connection string
    if [ "$type" = "ssh" ]; then
        local conn="ssh://"
        conn+="${ssh_user}@${ssh_host}"
        [ "$ssh_port" != "22" ] && conn+=":${ssh_port}"
        conn+="/${db_user}@${db_host}"
        [ "$db_port" != "5432" ] && conn+=":${db_port}"
        conn+="/${database}"
        echo "$conn"
    else
        # Local connection
        local conn="${db_user}@${db_host}"
        [ "$db_port" != "5432" ] && conn+=":${db_port}"
        conn+="/${database}"
        echo "$conn"
    fi
}

# Get password file from profile or job config
get_password_file() {
    local job="$1"
    local direction="$2"

    # Check job-level password file first
    local pw_file=$(get_job_field "$job" "${direction}_password_file")
    if [ -n "$pw_file" ]; then
        # Expand ~ to home directory
        echo "${pw_file/#\~/$HOME}"
        return
    fi

    # Check inside direction block
    pw_file=$(get_job_field "$job" "$direction" "password_file")
    if [ -n "$pw_file" ]; then
        echo "${pw_file/#\~/$HOME}"
        return
    fi

    # Check profile
    local profile=$(get_job_field "$job" "$direction" "profile")
    if [ -n "$profile" ]; then
        pw_file=$(get_profile_value "$profile" "password_file")
        if [ -n "$pw_file" ]; then
            echo "${pw_file/#\~/$HOME}"
            return
        fi
    fi
}

# Get telegram notify config from defaults section
# Usage: get_default_telegram_config
get_default_telegram_config() {
    awk '
    BEGIN { in_defaults=0; in_notify=0; in_telegram=0; token=""; chat_id=""; thread_id="" }
    /^defaults:/ { in_defaults=1; next }
    /^[a-zA-Z]/ { if ($0 !~ /^defaults:/) { in_defaults=0; in_notify=0; in_telegram=0 } }
    in_defaults && /^  notify:/ { in_notify=1; next }
    in_defaults && /^  [a-zA-Z]/ { if ($0 !~ /^  notify:/) { in_notify=0; in_telegram=0 } }
    in_notify && /^    telegram:/ { in_telegram=1; next }
    in_notify && /^    [a-zA-Z]/ { if ($0 !~ /^    telegram:/) in_telegram=0 }
    in_telegram && /^      token:/ {
        val=$0; gsub(/^[^:]+: */, "", val); gsub(/^["'\''"]|["'\''"]$/, "", val)
        token=val
    }
    in_telegram && /^      chat_id:/ {
        val=$0; gsub(/^[^:]+: */, "", val); gsub(/^["'\''"]|["'\''"]$/, "", val)
        chat_id=val
    }
    in_telegram && /^      message_thread_id:/ {
        val=$0; gsub(/^[^:]+: */, "", val); gsub(/^["'\''"]|["'\''"]$/, "", val)
        thread_id=val
    }
    END {
        if (token != "" && chat_id != "") {
            printf "telegram:%s:%s", token, chat_id
            if (thread_id != "") printf ":%s", thread_id
            print ""
        }
    }
    ' "$JOBS_FILE"
}

# Get telegram notify config from job (3-level nested: notify.telegram.*)
# Falls back to defaults if job doesn't have notify config
# Usage: get_job_telegram_config "job_name"
get_job_telegram_config() {
    local job="$1"

    local config=$(awk -v job="$job" '
    BEGIN { in_job=0; in_notify=0; in_telegram=0; token=""; chat_id=""; thread_id="" }
    /^  [a-zA-Z0-9_-]+:/ {
        gsub(/:.*/, "", $1)
        if ($1 == job) { in_job=1 } else { in_job=0; in_notify=0; in_telegram=0 }
        next
    }
    in_job && /^    notify:/ { in_notify=1; next }
    in_job && /^    [a-zA-Z]/ { if ($0 !~ /^    notify:/) { in_notify=0; in_telegram=0 } }
    in_notify && /^      telegram:/ { in_telegram=1; next }
    in_notify && /^      [a-zA-Z]/ { if ($0 !~ /^      telegram:/) in_telegram=0 }
    in_telegram && /^        token:/ {
        val=$0; gsub(/^[^:]+: */, "", val); gsub(/^["'\''"]|["'\''"]$/, "", val)
        token=val
    }
    in_telegram && /^        chat_id:/ {
        val=$0; gsub(/^[^:]+: */, "", val); gsub(/^["'\''"]|["'\''"]$/, "", val)
        chat_id=val
    }
    in_telegram && /^        message_thread_id:/ {
        val=$0; gsub(/^[^:]+: */, "", val); gsub(/^["'\''"]|["'\''"]$/, "", val)
        thread_id=val
    }
    END {
        if (token != "" && chat_id != "") {
            printf "telegram:%s:%s", token, chat_id
            if (thread_id != "") printf ":%s", thread_id
            print ""
        }
    }
    ' "$JOBS_FILE")

    # Fallback to defaults if job doesn't have notify
    if [ -z "$config" ]; then
        config=$(get_default_telegram_config)
    fi

    echo "$config"
}

# Parse job and build command arguments
# Usage: parse_job_to_args "job_name"
parse_job_to_args() {
    local job="$1"
    local args=""

    # Check if job has old-style args
    local old_args=$(get_job_field "$job" "args")
    if [ -n "$old_args" ]; then
        echo "$old_args"
        return
    fi

    # Build from new format
    local from_conn=$(build_connection "$job" "from")
    local to_conn=$(build_connection "$job" "to")

    [ -n "$from_conn" ] && args+=" --from $(pq "$from_conn")"
    [ -n "$to_conn" ] && args+=" --to $(pq "$to_conn")"

    # Password files
    local from_pw=$(get_password_file "$job" "from")
    local to_pw=$(get_password_file "$job" "to")

    [ -n "$from_pw" ] && args+=" --from-password-file $(pq "$from_pw")"
    [ -n "$to_pw" ] && args+=" --to-password-file $(pq "$to_pw")"

    # Inline passwords are deliberately NOT emitted as argv flags here: run_job reads them
    # via job_inline_passwords() and exports them as T_PGSQL_*_PASSWORD env vars for the
    # re-exec'd child, so a plaintext password never lands on the child process argv (local
    # `ps`) or in the job-args preview/log. (password_file flags remain — a path is not secret.)

    # Options (with defaults fallback)
    # Boolean flags
    [ "$(get_job_value "$job" "force")" = "true" ] && args+=" --force"
    [ "$(get_job_value "$job" "verbose")" = "true" ] && args+=" --verbose"
    [ "$(get_job_value "$job" "quiet")" = "true" ] && args+=" --quiet"
    [ "$(get_job_value "$job" "dry_run")" = "true" ] && args+=" --dry-run"
    [ "$(get_job_value "$job" "no_meta")" = "true" ] && args+=" --no-meta"
    [ "$(get_job_value "$job" "sudo")" = "true" ] && args+=" --sudo"
    [ "$(get_job_value "$job" "stream")" = "true" ] && args+=" --stream"
    [ "$(get_job_value "$job" "notify_on_error")" = "true" ] && args+=" --notify-on-error"

    # Storage options
    [ -n "$(get_job_value "$job" "output")" ] && args+=" --output $(pq "$(get_job_value "$job" "output")")"
    [ -n "$(get_job_value "$job" "dump_name")" ] && args+=" --dump-name $(pq "$(get_job_value "$job" "dump_name")")"
    [ -n "$(get_job_value "$job" "keep")" ] && args+=" --keep $(pq "$(get_job_value "$job" "keep")")"
    [ -n "$(get_job_value "$job" "from_keep")" ] && args+=" --from-keep $(pq "$(get_job_value "$job" "from_keep")")"
    [ -n "$(get_job_value "$job" "skip_if_recent")" ] && args+=" --skip-if-recent $(pq "$(get_job_value "$job" "skip_if_recent")")"

    # Filtering options
    [ -n "$(get_job_value "$job" "exclude_table")" ] && args+=" --exclude-table $(pq "$(get_job_value "$job" "exclude_table")")"
    [ -n "$(get_job_value "$job" "exclude_data")" ] && args+=" --exclude-data $(pq "$(get_job_value "$job" "exclude_data")")"
    [ -n "$(get_job_value "$job" "exclude_schema")" ] && args+=" --exclude-schema $(pq "$(get_job_value "$job" "exclude_schema")")"
    [ -n "$(get_job_value "$job" "only_table")" ] && args+=" --only-table $(pq "$(get_job_value "$job" "only_table")")"
    [ -n "$(get_job_value "$job" "only_schema")" ] && args+=" --only-schema $(pq "$(get_job_value "$job" "only_schema")")"

    # Compression options
    [ -n "$(get_job_value "$job" "compress")" ] && args+=" --compress $(pq "$(get_job_value "$job" "compress")")"
    [ -n "$(get_job_value "$job" "compress_level")" ] && args+=" --compress-level $(pq "$(get_job_value "$job" "compress_level")")"
    [ -n "$(get_job_value "$job" "pg_compress_level")" ] && args+=" --pg-compress-level $(pq "$(get_job_value "$job" "pg_compress_level")")"

    # Streaming options
    [ -n "$(get_job_value "$job" "stream_buffer")" ] && args+=" --stream-buffer $(pq "$(get_job_value "$job" "stream_buffer")")"

    # Health check options
    [ "$(get_job_value "$job" "health_check")" = "true" ] && args+=" --health-check"
    [ "$(get_job_value "$job" "health_check_after")" = "true" ] && args+=" --health-check-after"
    [ "$(get_job_value "$job" "no_health_check")" = "true" ] && args+=" --no-health-check"
    [ "$(get_job_value "$job" "health_check_fail")" = "true" ] && args+=" --health-check-fail"

    # Retention (GFS) options
    [ "$(get_job_value "$job" "retention")" = "true" ] && args+=" --retention"
    [ -n "$(get_job_value "$job" "retention_daily")" ] && args+=" --retention-daily $(pq "$(get_job_value "$job" "retention_daily")")"
    [ -n "$(get_job_value "$job" "retention_weekly")" ] && args+=" --retention-weekly $(pq "$(get_job_value "$job" "retention_weekly")")"
    [ -n "$(get_job_value "$job" "retention_monthly")" ] && args+=" --retention-monthly $(pq "$(get_job_value "$job" "retention_monthly")")"
    [ -n "$(get_job_value "$job" "retention_yearly")" ] && args+=" --retention-yearly $(pq "$(get_job_value "$job" "retention_yearly")")"

    # Masking options
    [ "$(get_job_value "$job" "mask")" = "true" ] && args+=" --mask"
    [ -n "$(get_job_value "$job" "mask_rules")" ] && args+=" --mask-rules $(pq "$(get_job_value "$job" "mask_rules")")"
    [ -n "$(get_job_value "$job" "mask_tables")" ] && args+=" --mask-tables $(pq "$(get_job_value "$job" "mask_tables")")"

    # Logging options
    [ -n "$(get_job_value "$job" "log")" ] && args+=" --log $(pq "$(get_job_value "$job" "log")")"
    [ -n "$(get_job_value "$job" "log_level")" ] && args+=" --log-level $(pq "$(get_job_value "$job" "log_level")")"

    # Notify - telegram
    local telegram_config=$(get_job_telegram_config "$job")
    [ -n "$telegram_config" ] && args+=" --notify $(pq "$telegram_config")"

    echo "$args"
}

