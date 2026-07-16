# ==============================================================================
# CONFIG FILE PARSER
# ==============================================================================
load_config() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        log_error "Config file not found: $config_file"
        return 1
    fi

    log_debug "Loading config: $config_file"

    # Parse YAML-like config file
    while IFS=': ' read -r key value || [ -n "$key" ]; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue

        # Trim surrounding whitespace, then strip at most one matching pair of
        # surrounding quotes. Pure bash so it is portable (no GNU-only sed BRE
        # alternation) and safe on values containing apostrophes (no xargs).
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
        case "$value" in
            \"*) value="${value#\"}" ;;
            \'*) value="${value#\'}" ;;
        esac
        case "$value" in
            *\") value="${value%\"}" ;;
            *\') value="${value%\'}" ;;
        esac

        # Expand a leading ~ to $HOME ONLY for path-type keys — never for passwords
        # or connection strings (a password that happens to start with ~ was being
        # silently rewritten into a home-dir path).
        case "$key" in
            output|log|log_level|*_file|*-file) value="${value/#\~/$HOME}" ;;
        esac

        case "$key" in
            from) [ -z "$FROM_CONNECTION" ] && FROM_CONNECTION="$value" ;;
            to) [ ${#TO_CONNECTIONS[@]} -eq 0 ] && TO_CONNECTIONS+=("$value") ;;
            password) [ -z "$PASSWORD" ] && PASSWORD="$value" ;;
            from_password|from-password) [ -z "$FROM_PASSWORD" ] && FROM_PASSWORD="$value" ;;
            to_password|to-password) [ -z "$TO_PASSWORD" ] && TO_PASSWORD="$value" ;;
            password_file|password-file) [ -z "$PASSWORD_FILE" ] && PASSWORD_FILE="$value" ;;
            from_password_file|from-password-file) [ -z "$FROM_PASSWORD_FILE" ] && FROM_PASSWORD_FILE="$value" ;;
            to_password_file|to-password-file) [ ${#TO_PASSWORD_FILES[@]} -eq 0 ] && TO_PASSWORD_FILES+=("$value") ;;
            output) [ "$OUTPUT_DIR_SET" != true ] && OUTPUT_DIR="$value" ;;
            keep) [ "$KEEP_SET" != true ] && KEEP="$value" ;;
            from_keep|from-keep) [ "$FROM_KEEP_SET" != true ] && FROM_KEEP="$value" ;;
            from_stale|from-stale) [ "$FROM_STALE_SET" != true ] && FROM_STALE="$value" ;;
            compress) [ "$COMPRESS_SET" != true ] && COMPRESS="$value" ;;
            compress_where|compress-where) [ "$COMPRESS_WHERE_SET" != true ] && COMPRESS_WHERE="$value" ;;
            bwlimit) [ -z "$BWLIMIT" ] && BWLIMIT="$value" ;;
            retries) [ "$RETRIES" = 0 ] && RETRIES="$value" ;;
            exclude_table|exclude-table) [ -z "$EXCLUDE_TABLES" ] && EXCLUDE_TABLES="$value" ;;
            exclude_schema|exclude-schema) [ -z "$EXCLUDE_SCHEMAS" ] && EXCLUDE_SCHEMAS="$value" ;;
            exclude_data|exclude-data) [ -z "$EXCLUDE_DATA" ] && EXCLUDE_DATA="$value" ;;
            only_table|only-table) [ -z "$ONLY_TABLES" ] && ONLY_TABLES="$value" ;;
            only_schema|only-schema) [ -z "$ONLY_SCHEMAS" ] && ONLY_SCHEMAS="$value" ;;
            notify) NOTIFY+=("$value") ;;
            verbose) [ "$value" = "true" ] && VERBOSE=true ;;
            force) [ "$value" = "true" ] && FORCE=true ;;
            sudo) [ "$value" = "true" ] && SUDO=true ;;
        esac
    done < "$config_file"

    log_debug "Config loaded"
}

