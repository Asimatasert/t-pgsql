# ==============================================================================
# ARGUMENT PARSER
# ==============================================================================
# Abort with a clear message when a value-taking option is missing its value.
# (Without this, "shift 2" fails atomically on a trailing valueless flag and,
# with errexit off, the while-loop would spin forever.)
_need_val() { log_error "Option requires a value: $1"; exit 1; }

parse_args() {
    [ $# -eq 0 ] && { show_help; exit 0; }

    # Check if first arg is option or command
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        --version) show_version; exit 0 ;;
        --batch) BATCH_JOB="$2"; shift 2 || _need_val "$1" ;;
        -*) log_error "Command required. Use --help for usage."; exit 1 ;;
        *) COMMAND="$1"; shift ;;
    esac

    # Handle jobs subcommand (jobs list|show|remove <name>)
    if [ "$COMMAND" = "jobs" ] && [ $# -gt 0 ]; then
        case "$1" in
            list|show|remove)
                JOBS_ACTION="$1"
                shift
                # Skip options and get target
                while [[ $# -gt 0 ]]; do
                    if [[ "$1" == -* ]]; then
                        # It's an option, will be parsed in main loop
                        break
                    else
                        JOBS_TARGET="$1"
                        shift
                        break
                    fi
                done
                ;;
            -*)
                # It's an option, not a subcommand
                ;;
            *)
                # Assume it's a job name for 'show' as default action
                JOBS_ACTION="show"
                JOBS_TARGET="$1"
                shift
                ;;
        esac
    fi

    # Handle batch subcommand (batch <job|all>)
    if [ "$COMMAND" = "batch" ] && [ $# -gt 0 ] && [[ "$1" != -* ]]; then
        BATCH_JOB="$1"
        shift
    fi

    # Handle clean subcommand optional positional db/base name (clean <db>)
    if [ "$COMMAND" = "clean" ] && [ $# -gt 0 ] && [[ "$1" != -* ]]; then
        CLEAN_DB="$1"
        shift
    fi

    # Handle explain subcommand optional positional topic (explain <topic>)
    if [ "$COMMAND" = "explain" ] && [ $# -gt 0 ] && [[ "$1" != -* ]]; then
        EXPLAIN_TARGET="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --from) FROM_CONNECTION="$2"; shift 2 || _need_val "$1" ;;
            --to) TO_CONNECTIONS+=("$2"); shift 2 || _need_val "$1" ;;

            --password) PASSWORD="$2"; shift 2 || _need_val "$1" ;;
            --from-password) FROM_PASSWORD="$2"; shift 2 || _need_val "$1" ;;
            --to-password) TO_PASSWORD="$2"; shift 2 || _need_val "$1" ;;
            --password-file) PASSWORD_FILE="$2"; shift 2 || _need_val "$1" ;;
            --from-password-file) FROM_PASSWORD_FILE="$2"; shift 2 || _need_val "$1" ;;
            --to-password-file) TO_PASSWORD_FILES+=("$2"); shift 2 || _need_val "$1" ;;
            --config) CONFIG_FILE="$2"; shift 2 || _need_val "$1" ;;

            --exclude-table) EXCLUDE_TABLES="$2"; shift 2 || _need_val "$1" ;;
            --exclude-schema) EXCLUDE_SCHEMAS="$2"; shift 2 || _need_val "$1" ;;
            --exclude-data) EXCLUDE_DATA="$2"; shift 2 || _need_val "$1" ;;
            --only-table) ONLY_TABLES="$2"; shift 2 || _need_val "$1" ;;
            --only-schema) ONLY_SCHEMAS="$2"; shift 2 || _need_val "$1" ;;

            --compress) COMPRESS="$2"; COMPRESS_SET=true; shift 2 || _need_val "$1" ;;
            --compress-level) COMPRESS_LEVEL="$2"; shift 2 || _need_val "$1" ;;
            --pg-compress-level) PG_COMPRESS_LEVEL="$2"; PG_COMPRESS_LEVEL_SET=true; shift 2 || _need_val "$1" ;;

            --output) OUTPUT_DIR="$2"; OUTPUT_DIR_SET=true; shift 2 || _need_val "$1" ;;
            --keep) KEEP="$2"; KEEP_SET=true; shift 2 || _need_val "$1" ;;
            --from-keep) FROM_KEEP="$2"; FROM_KEEP_SET=true; shift 2 || _need_val "$1" ;;
            --dump-name) DUMP_NAME="$2"; shift 2 || _need_val "$1" ;;
            --skip-if-recent) SKIP_IF_RECENT="$2"; shift 2 || _need_val "$1" ;;
            --from-file)
                # Optional value: --from-file or --from-file <pattern>.
                # Reject any following token that starts with a dash (long OR
                # short flag) so e.g. "--from-file -v" does not swallow -v.
                if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                    FROM_FILE="$2"
                    shift 2
                else
                    FROM_FILE="latest"
                    shift
                fi
                ;;

            --retention) RETENTION=true; shift ;;
            --retention-daily) RETENTION_DAILY="$2"; shift 2 || _need_val "$1" ;;
            --retention-weekly) RETENTION_WEEKLY="$2"; shift 2 || _need_val "$1" ;;
            --retention-monthly) RETENTION_MONTHLY="$2"; shift 2 || _need_val "$1" ;;
            --retention-yearly) RETENTION_YEARLY="$2"; shift 2 || _need_val "$1" ;;

            --health-check) HEALTH_CHECK=true; shift ;;
            --health-check-after) HEALTH_CHECK_AFTER=true; shift ;;
            --no-health-check) HEALTH_CHECK=false; shift ;;
            --health-check-fail) HEALTH_CHECK_FAIL=true; shift ;;

            --notify) NOTIFY+=("$2"); shift 2 || _need_val "$1" ;;
            --notify-on-error) NOTIFY_ON_ERROR=true; shift ;;
            --token) BOT_TOKEN="$2"; shift 2 || _need_val "$1" ;;
            --cooldown) BOT_COOLDOWN="$2"; shift 2 || _need_val "$1" ;;

            --mask) MASK=true; shift ;;
            --mask-rules) MASK_RULES="$2"; shift 2 || _need_val "$1" ;;
            --mask-tables) MASK_TABLES="$2"; shift 2 || _need_val "$1" ;;

            --stream) STREAM=true; shift ;;
            --stream-buffer) STREAM_BUFFER="$2"; shift 2 || _need_val "$1" ;;

            --sudo) SUDO=true; shift ;;
            --globals) GLOBALS=true; shift ;;
            --pg-bindir) PG_BINDIR="$2"; shift 2 || _need_val "$1" ;;
            --bwlimit) BWLIMIT="$2"; shift 2 || _need_val "$1" ;;
            --retries) RETRIES="$2"; shift 2 || _need_val "$1" ;;

            --parallel) PARALLEL="$2"; PARALLEL_SET=true; shift 2 || _need_val "$1" ;;
            --continue-on-error) CONTINUE_ON_ERROR=true; CONTINUE_ON_ERROR_SET=true; shift ;;
            --only-jobs) ONLY_JOBS="$2"; shift 2 || _need_val "$1" ;;
            --exclude-jobs) EXCLUDE_JOBS="$2"; shift 2 || _need_val "$1" ;;
            --only) ONLY_JOBS="$2"; shift 2 || _need_val "$1" ;;        # deprecated alias for --only-jobs
            --exclude) EXCLUDE_JOBS="$2"; shift 2 || _need_val "$1" ;;  # deprecated alias for --exclude-jobs
            --notify-summary) NOTIFY_SUMMARY=true; shift ;;
            --save) SAVE_JOB="$2"; shift 2 || _need_val "$1" ;;
            --batch) BATCH_JOB="$2"; shift 2 || _need_val "$1" ;;
            --yaml)
                if [[ "$2" == *".yaml" ]]; then
                    # Already has .yaml extension
                    JOBS_FILE="$2"
                elif [[ "$2" == *"/"* ]]; then
                    # Contains path but no .yaml extension
                    JOBS_FILE="${2}.yaml"
                else
                    # Just a name, use SCRIPT_DIR
                    JOBS_FILE="${SCRIPT_DIR}/${2}.yaml"
                fi
                shift 2 || _need_val "$1" ;;

            --file) FILE="$2"; shift 2 || _need_val "$1" ;;

            --log) LOG_FILE="$2"; shift 2 || _need_val "$1" ;;
            --log-level) LOG_LEVEL="$2"; shift 2 || _need_val "$1" ;;
            -v|--verbose) VERBOSE=true; shift ;;
            -q|--quiet) QUIET=true; shift ;;
            -y|--yes) YES=true; shift ;;
            -f|--force) FORCE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --no-meta) META_ENABLED=false; shift ;;
            -h|--help) show_help; exit 0 ;;
            --version) show_version; exit 0 ;;

            *) log_error "Unknown: $1"; exit 1 ;;
        esac
    done
}

