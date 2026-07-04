# ==============================================================================
# LOGGING
# ==============================================================================
log_info() {
    [ "$QUIET" != true ] && echo -e "${GREEN}[INFO]${NC} $1"
    log_to_file "INFO" "$1"
}

log_warn() {
    [ "$QUIET" != true ] && echo -e "${YELLOW}[WARN]${NC} $1"
    log_to_file "WARN" "$1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    log_to_file "ERROR" "$1"
}

log_success() {
    [ "$QUIET" != true ] && echo -e "${GREEN}[OK]${NC} $1"
    log_to_file "OK" "$1"
}

log_debug() {
    # Console debug is shown when --verbose is set or --log-level is debug.
    if [ "$VERBOSE" = true ] || [ "$(log_level_num "$LOG_LEVEL")" -le 0 ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
    log_to_file "DEBUG" "$1"
}

# Map a log level name (debug|info|warn|error and their INFO/OK aliases) to a
# numeric severity so --log-level can gate output.
log_level_num() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        debug)      echo 0 ;;
        info|ok)    echo 1 ;;
        warn)       echo 2 ;;
        error)      echo 3 ;;
        *)          echo 1 ;;
    esac
}

log_to_file() {
    if [ -n "$LOG_FILE" ]; then
        # Only write messages at or above the configured --log-level.
        [ "$(log_level_num "$1")" -lt "$(log_level_num "$LOG_LEVEL")" ] && return 0
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" >> "$LOG_FILE"
    fi
}

