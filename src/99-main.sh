# ==============================================================================
# MAIN
# ==============================================================================
main() {
    install_cleanup_trap
    parse_args "$@"

    # Use a specific PostgreSQL client version if requested (affects all LOCAL
    # pg_dump/pg_restore/psql/createdb/pg_dumpall calls; not SSH-remote ones).
    [ -n "$PG_BINDIR" ] && export PATH="$PG_BINDIR:$PATH"

    # Bound how long libpq waits to establish a connection, so an unreachable host
    # fails fast instead of hanging a backup/cron run. Override via the env var.
    export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"

    [ -n "$LOG_FILE" ] && mkdir -p "$(dirname "$LOG_FILE")"

    # Load config file if specified
    if [ -n "$CONFIG_FILE" ]; then
        load_config "$CONFIG_FILE" || exit 1
    fi

    # Validate numeric options BEFORE any are used. Several land unquoted in
    # eval'd/arithmetic contexts (pg_dump -Z<level>, $(( bwlimit )), retention
    # counts), so a non-integer value is both a correctness and an injection risk.
    local _n _v
    # Count-type options must be NON-negative — a negative count is nonsensical and, for
    # RETENTION_*, would make cleanup_gfs delete every dump. (Rejects '+', leading zeros/octal.)
    for _n in PARALLEL COMPRESS_LEVEL PG_COMPRESS_LEVEL STREAM_BUFFER RETRIES \
              RETENTION_DAILY RETENTION_WEEKLY RETENTION_MONTHLY RETENTION_YEARLY; do
        _v="${!_n}"
        if ! [[ "$_v" =~ ^(0|[1-9][0-9]*)$ ]]; then
            log_error "Invalid value for a numeric option (${_n}='${_v}'): expected a non-negative integer"
            exit 1
        fi
    done
    # KEEP / FROM_KEEP keep the signed form (-1 = keep all).
    for _n in KEEP FROM_KEEP; do
        _v="${!_n}"
        if ! [[ "$_v" =~ ^-?(0|[1-9][0-9]*)$ ]]; then
            log_error "Invalid value for a numeric option (${_n}='${_v}'): expected an integer"
            exit 1
        fi
    done

    # --cooldown (bot) is a time string; validate its format so it can't reach the
    # bot's $(( )) arithmetic as an injection payload.
    if ! [[ "$BOT_COOLDOWN" =~ ^[0-9]+[hmd]?$ ]]; then
        log_error "Invalid --cooldown '$BOT_COOLDOWN' (use e.g. 1h, 30m, 2d)"
        exit 1
    fi

    # Validate --compress type (an unknown type used to be silently accepted and
    # falsely reported as "Compressed", shipping an uncompressed dump).
    case "$COMPRESS" in
        gzip|zstd|xz|bzip2|none) ;;
        *) log_error "Invalid --compress '$COMPRESS' (use gzip|zstd|xz|bzip2|none)"; exit 1 ;;
    esac

    # Resolve --bwlimit (human units) to scp's Kbit/s. Strict pattern so the value
    # can never reach the arithmetic below as an injection payload. 10m=MByte/s,
    # 500k=KByte/s, bare number = KByte/s.
    if [ -n "$BWLIMIT" ]; then
        if [[ "$BWLIMIT" =~ ^[0-9]+[mMkK]?$ ]]; then
            case "$BWLIMIT" in
                *m|*M) BWLIMIT_KBIT=$(( ${BWLIMIT%[mM]} * 1024 * 8 )); PV_RATE="$BWLIMIT" ;;
                *k|*K) BWLIMIT_KBIT=$(( ${BWLIMIT%[kK]} * 8 )); PV_RATE="$BWLIMIT" ;;
                *)     BWLIMIT_KBIT=$(( BWLIMIT * 8 )); PV_RATE="${BWLIMIT}k" ;;
            esac
        else
            log_error "Invalid --bwlimit '$BWLIMIT' (use e.g. 10m, 500k)"
            exit 1
        fi
    fi

    # Handle --save: save current command as a job
    if [ -n "$SAVE_JOB" ]; then
        save_job "$SAVE_JOB" "$COMMAND"
        return 0
    fi

    # Handle batch with --batch argument (alternative to 'batch' command).
    # Only treat --batch as the action when no positional command was given
    # (or the command IS 'batch'); otherwise --batch conflicts with the command.
    if [ -n "$BATCH_JOB" ]; then
        if [ -z "$COMMAND" ] || [ "$COMMAND" = "batch" ]; then
            cmd_batch "$BATCH_JOB"
            return $?
        else
            log_error "--batch cannot be combined with the '$COMMAND' command"
            exit 1
        fi
    fi

    case "$COMMAND" in
        dump)    cmd_dump ;;
        restore) cmd_restore ;;
        clone)   cmd_clone ;;
        upgrade) cmd_upgrade ;;
        fetch)   cmd_fetch ;;
        batch)   cmd_batch "$BATCH_JOB" ;;
        bot)     cmd_bot ;;
        list)    cmd_list ;;
        meta)    cmd_meta ;;
        clean)   cmd_clean ;;
        jobs)
            case "$JOBS_ACTION" in
                show)   show_job "$JOBS_TARGET" ;;
                remove) remove_job "$JOBS_TARGET" ;;
                *)      list_jobs ;;
            esac
            ;;
        version) show_version ;;
        help)    show_help ;;
        *)       log_error "Unknown command: $COMMAND"; exit 1 ;;
    esac
}

main "$@"
