# ==============================================================================
# MAIN
# ==============================================================================
main() {
    # Dumps, archives, logs and job files hold database contents and credentials, so
    # everything this tool creates is private (0600/0700) by default. Setups that share
    # dumps through group permissions can relax it with T_PGSQL_UMASK (e.g. 027 or 007).
    local _umask="${T_PGSQL_UMASK:-077}" _umask_warn=""
    if [[ "$_umask" =~ ^[0-7]{1,4}$ ]]; then
        umask "$_umask"
        # "other" read bit (4) clear in the mask means new files are world-readable
        if [ $(( 8#$_umask & 4 )) -eq 0 ]; then
            _umask_warn="T_PGSQL_UMASK=$_umask leaves new files (dumps, logs) readable by every local user"
        fi
    else
        umask 077
        _umask_warn="Ignoring invalid T_PGSQL_UMASK '$_umask' (expected one to four octal digits such as 077, 027 or 22); using 077"
    fi

    install_cleanup_trap
    parse_args "$@"
    [ -n "$_umask_warn" ] && log_warn "$_umask_warn"

    # Notification specs handed over by a parent job run (run_job sets T_PGSQL_NOTIFY_SPECS
    # for its re-exec'd child). This is an INTERNAL variable, not a user option: it holds
    # the bot token, so it travels in the environment rather than on argv. Consume and drop
    # it so nothing we spawn (pg_dump, ssh, ...) inherits it.
    if [ -n "${T_PGSQL_NOTIFY_SPECS:-}" ]; then
        local _spec
        while IFS= read -r _spec; do
            [ -n "$_spec" ] && NOTIFY+=("$_spec")
        done <<< "$T_PGSQL_NOTIFY_SPECS"
    fi
    unset T_PGSQL_NOTIFY_SPECS

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

    # --min-size-ratio is a percentage: 0 (off) to 100.
    if ! [[ "$MIN_SIZE_RATIO" =~ ^(0|[1-9][0-9]{0,2})$ ]] || [ "$MIN_SIZE_RATIO" -gt 100 ]; then
        log_error "Invalid --min-size-ratio '${MIN_SIZE_RATIO}': expected an integer from 0 to 100 (0 disables the check)"
        exit 1
    fi

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

    case "$COMPRESS_WHERE" in
        source|target) ;;
        *) log_error "Invalid --compress-where '$COMPRESS_WHERE' (use source|target)"; exit 1 ;;
    esac

    # --from-stale is a time string that feeds $(( )) arithmetic and a remote
    # find(1) argument; validate the format so nothing else can reach either.
    if ! [[ "$FROM_STALE" =~ ^[0-9]+[hmd]?$ ]]; then
        log_error "Invalid --from-stale '$FROM_STALE' (use e.g. 72h, 2d, or 0 to disable)"
        exit 1
    fi

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

    history_begin   # arms the run-history line (work commands only; see 74-status.sh)

    case "$COMMAND" in
        dump)    cmd_dump;    notify_unreported_failure $? dump ;;
        restore) cmd_restore; notify_unreported_failure $? restore ;;
        clone)   cmd_clone;   notify_unreported_failure $? clone ;;
        upgrade) cmd_upgrade; notify_unreported_failure $? upgrade ;;
        fetch)   cmd_fetch;   notify_unreported_failure $? fetch ;;
        batch)   cmd_batch "$BATCH_JOB" ;;
        bot)     cmd_bot ;;
        list)    cmd_list ;;
        meta)    cmd_meta ;;
        clean)   cmd_clean ;;
        doctor)  cmd_doctor ;;
        status)  cmd_status ;;
        explain) cmd_explain ;;
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
