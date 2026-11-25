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
    # Errors go to stderr: only colour them when stderr itself is a terminal.
    local _red="$RED" _nc="$NC"
    [ -t 2 ] || { _red=""; _nc=""; }
    echo -e "${_red}[ERROR]${_nc} $1" >&2
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
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $(strip_ansi "$2")" >> "$LOG_FILE"
    fi
}

# Remove ANSI colour sequences (a real ESC or the literal \033 text) from a string, so log
# files and notifications never carry escape codes.
strip_ansi() {
    case "$1" in
        *$'\033'*|*'\033['*) ;;
        *) printf '%s' "$1"; return 0 ;;
    esac
    printf '%s' "$1" | sed -E "s/($(printf '\033')|\\\\033)\[[0-9;]*m//g"
}

