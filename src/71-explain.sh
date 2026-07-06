# ==============================================================================
# EXPLAIN — teach what each command is for and when to use it
# ==============================================================================
# `t-pgsql explain`          lists the topics
# `t-pgsql explain <topic>`  prints a focused, example-driven explanation

_ex_title() { echo -e "${BOLD}t-pgsql $1${NC} — $2"; echo; }
_ex_sec()   { echo -e "${CYAN}$1${NC}"; }
_ex_see()   { echo; echo -e "${MAGENTA}See also:${NC} $1"; }

_explain_overview() {
    echo -e "${BOLD}t-pgsql — what each command is for${NC}"
    echo
    echo -e "  ${CYAN}dump${NC}      Back up one database to a compressed -Fc file"
    echo -e "  ${CYAN}restore${NC}   Load a dump back into a database (safe on --force)"
    echo -e "  ${CYAN}clone${NC}     Dump + restore in one step (full sync)"
    echo -e "  ${CYAN}upgrade${NC}   Logical major-version migration (e.g. 16 → 18) with globals"
    echo -e "  ${CYAN}fetch${NC}     Download an existing remote dump (no new dump)"
    echo -e "  ${CYAN}batch${NC}     Run saved jobs from a jobs.yaml"
    echo -e "  ${CYAN}bot${NC}       Telegram bot to trigger/monitor backups from a chat"
    echo -e "  ${CYAN}list${NC} / ${CYAN}meta${NC} / ${CYAN}clean${NC}   Inspect dumps, show metadata, prune old dumps"
    echo -e "  ${CYAN}doctor${NC}    Check the environment and backup health"
    echo
    echo -e "  Extra topics: ${CYAN}stream${NC}, ${CYAN}masking${NC}, ${CYAN}retention${NC}"
    echo
    echo -e "Run ${BOLD}t-pgsql explain <topic>${NC} for details, e.g. ${BOLD}t-pgsql explain clone${NC}."
}

_explain_dump() {
    _ex_title "dump" "point-in-time backup of one database"
    _ex_sec "What it does"
    echo "  Runs pg_dump in the custom format (-Fc) and writes a timestamped file"
    echo "  to the output directory. Works against a local/TCP database or, with an"
    echo "  ssh:// source, dumps on the remote host and transfers the file back."
    echo
    _ex_sec "When to use"
    echo "  • Scheduled backups (cron / batch jobs)"
    echo "  • A safety snapshot before a risky migration or deploy"
    echo "  • Archiving a database for later"
    echo
    _ex_sec "Key options"
    echo "  --from <conn>          source database"
    echo "  --output <dir>         where to write (default: <script>/../data/dumps)"
    echo "  --compress <type>      zstd | gzip | xz | bzip2 | none"
    echo "  --keep <N>             keep only the newest N dumps locally"
    echo "  --retention            GFS rotation (daily/weekly/monthly/yearly)"
    echo "  --exclude-table/-data  filter what is dumped"
    echo "  --skip-if-recent <t>   skip if a dump already exists within the window"
    echo
    _ex_sec "Examples"
    echo "  t-pgsql dump --from \"postgres@localhost/appdb\" --compress zstd --keep 7"
    echo "  t-pgsql dump --from \"ssh://user@host/postgres@localhost/db\" \\"
    echo "               --from-password-file .secrets/db.pass --retention"
    _ex_see "explain restore · explain retention · explain masking"
}

_explain_restore() {
    _ex_title "restore" "load a dump back into a database"
    _ex_sec "What it does"
    echo "  Runs pg_restore from a dump file (any of .tar.gz/.dump/.dump.zst/.xz/.bz2,"
    echo "  auto-picking the newest if --file is omitted) into one or more --to targets."
    echo
    _ex_sec "Why it is safe with --force"
    echo "  --force does NOT drop the target first. t-pgsql restores into a temporary"
    echo "  database and swaps it in only when the restore fully succeeds — a corrupt or"
    echo "  truncated dump can never destroy the existing data. It also preserves the"
    echo "  source encoding/locale."
    echo
    _ex_sec "When to use"
    echo "  • Recovering a database from a backup"
    echo "  • Spinning up a copy on another host"
    echo
    _ex_sec "Key options"
    echo "  --to <conn>            target (repeatable for multiple targets)"
    echo "  --file <path>          dump to restore (default: newest in --output)"
    echo "  --force               overwrite an existing target (safe temp-swap)"
    echo "  --mask                anonymize sensitive columns after restore"
    echo
    _ex_sec "Examples"
    echo "  t-pgsql restore --to \"postgres@localhost/appdb\" --force -y"
    echo "  t-pgsql restore --file dumps/appdb_20260706.tar.gz --to \"postgres@localhost/dev\""
    _ex_see "explain clone · explain masking"
}

_explain_clone() {
    _ex_title "clone" "dump + restore in one step"
    _ex_sec "What it does"
    echo "  A full sync: dumps --from and restores it into --to. With --globals it also"
    echo "  migrates cluster roles/tablespaces first. Refuses source == target."
    echo
    _ex_sec "When to use"
    echo "  • Refreshing dev/staging from production"
    echo "  • One-shot copy of a database between hosts"
    echo
    _ex_sec "Key options"
    echo "  --from / --to <conn>   source and target (--to repeatable)"
    echo "  --stream               pipe directly, no temp files (see: explain stream)"
    echo "  --mask                 anonymize data after restore (not with --stream)"
    echo "  --force                overwrite the target (safe temp-swap)"
    echo
    _ex_sec "Example"
    echo "  t-pgsql clone --from \"ssh://user@prod/postgres@localhost/appdb\" \\"
    echo "                --to \"postgres@localhost/appdb_dev\" \\"
    echo "                --from-password-file .secrets/prod.pass --force -y"
    _ex_see "explain stream · explain dump · explain restore"
}

_explain_stream() {
    _ex_title "clone --stream" "pipe dump→restore with no temp files"
    _ex_sec "What it does"
    echo "  Streams pg_dump directly into pg_restore over a pipe — nothing is staged to"
    echo "  disk. Use --stream-buffer <MB> and --bwlimit to shape the flow (needs 'pv')."
    echo
    _ex_sec "When to use"
    echo "  • Very large databases"
    echo "  • Hosts that don't have room for a temporary dump file"
    echo
    _ex_sec "Trade-offs"
    echo "  • --mask is NOT supported (masking runs after a full restore)"
    echo "  • The remote command rides briefly in the ssh argv during the stream"
    echo
    _ex_sec "Example"
    echo "  t-pgsql clone --stream --from \"...\" --to \"...\" --bwlimit 50m --force -y"
    _ex_see "explain clone"
}

_explain_upgrade() {
    _ex_title "upgrade" "logical major-version migration"
    _ex_sec "What it does"
    echo "  A clone that also migrates cluster globals and refuses to restore into an"
    echo "  OLDER major version. It is a logical dump+restore — NOT a pg_upgrade or"
    echo "  logical-replication replacement for large, low-downtime migrations."
    echo
    _ex_sec "Important"
    echo "  Run it where pg_dump matches the TARGET major version (e.g. PG18), or point"
    echo "  --pg-bindir at that version's client tools."
    echo
    _ex_sec "Example"
    echo "  t-pgsql upgrade --from \"postgres@old-16:5432/appdb\" \\"
    echo "                  --to \"postgres@new-18:5432/appdb\" \\"
    echo "                  --pg-bindir /usr/lib/postgresql/18/bin -y"
    _ex_see "explain clone"
}

_explain_fetch() {
    _ex_title "fetch" "download an existing remote dump"
    _ex_sec "What it does"
    echo "  Downloads a dump that already exists on an ssh:// source (from its"
    echo "  /tmp/t-pgsql dir) without creating a new one."
    echo
    _ex_sec "Example"
    echo "  t-pgsql fetch --from \"ssh://user@host/postgres@localhost/appdb\" --from-file latest"
    _ex_see "explain dump"
}

_explain_batch() {
    _ex_title "batch / jobs" "run saved jobs from a jobs.yaml"
    _ex_sec "What it does"
    echo "  Saved jobs live in a YAML file. 'batch <job>' runs one; 'batch all' runs all"
    echo "  (with --only-jobs/--exclude-jobs filters, optional --parallel N). Save the"
    echo "  current command as a job with --save <name>."
    echo
    _ex_sec "Key options"
    echo "  --yaml <name>          jobs file (bare name → <script>/<name>.yaml)"
    echo "  --parallel <N>         run N jobs concurrently"
    echo "  --continue-on-error    keep going if a job fails"
    echo "  --notify-summary       send one summary after the batch"
    echo
    _ex_sec "Examples"
    echo "  t-pgsql clone --from ... --to ... --save nightly     # save it"
    echo "  t-pgsql batch nightly --yaml jobs.yaml -y            # run it"
    echo "  t-pgsql jobs list                                   # see saved jobs"
    _ex_see "explain doctor · README (jobs.yaml format)"
}

_explain_bot() {
    _ex_title "bot" "control backups from a Telegram chat"
    _ex_sec "What it does"
    echo "  A long-running poller that only obeys the configured chat (fail-closed)."
    echo "  Chat commands: /help, /list, /list <yaml>, /backup <yaml> <job>, plus a"
    echo "  'Re-run Backup' button on failure notifications."
    echo
    _ex_sec "Key options"
    echo "  --token <token>        bot token (or TELEGRAM_BOT_TOKEN / YAML defaults)"
    echo "  --cooldown <t>         throttle re-triggered runs (default 1h)"
    echo
    _ex_sec "Example"
    echo "  t-pgsql bot --yaml jobs.yaml --token \"123:ABC...\" --cooldown 30m"
    _ex_see "explain batch"
}

_explain_maint() {
    _ex_title "list / meta / clean" "inspect and prune dumps"
    _ex_sec "list"
    echo "  Show dump files in --output, newest first, with size and date."
    echo
    _ex_sec "meta"
    echo "  Show the metadata sidecar for a dump (timing, source, target)."
    echo
    _ex_sec "clean"
    echo "  Delete old dumps for a base name per --keep or --retention (GFS). The single"
    echo "  newest dump is always kept. Supports --dry-run."
    echo
    _ex_sec "Examples"
    echo "  t-pgsql list"
    echo "  t-pgsql clean appdb --retention --dry-run"
    _ex_see "explain retention · explain doctor"
}

_explain_doctor() {
    _ex_title "doctor" "check the environment and backup health"
    _ex_sec "What it does"
    echo "  Runs local checks and prints ✓/!/✗ findings: required and optional tools,"
    echo "  the output directory and free disk space, how fresh each database's newest"
    echo "  dump is, whether the newest archives are readable, and the jobs file. Add"
    echo "  --from/--to to also test connectivity. Exits non-zero if it finds a problem."
    echo
    _ex_sec "Example"
    echo "  t-pgsql doctor"
    echo "  t-pgsql doctor --from \"ssh://user@host/postgres@localhost/appdb\""
    _ex_see "explain list"
}

_explain_mask() {
    _ex_title "masking" "anonymize sensitive data after restore"
    _ex_sec "What it does"
    echo "  With --mask, after a restore/clone t-pgsql overwrites sensitive columns."
    echo "  --mask-tables auto-masks known columns (email, phone, password, ssn, ...)"
    echo "  that actually exist; --mask-rules applies your own SQL from a JSON file."
    echo "  Fail-safe: if nothing was masked, or a statement errors, the op FAILS rather"
    echo "  than reporting an unmasked copy as success. Not supported with --stream."
    echo
    _ex_sec "Example"
    echo "  t-pgsql clone --from ... --to ... --mask --mask-tables \"users,customers\" --force"
    _ex_see "explain clone · explain restore"
}

_explain_retention() {
    _ex_title "retention" "Grandfather-Father-Son dump rotation"
    _ex_sec "What it does"
    echo "  With --retention, t-pgsql keeps the newest dump per day/week/month/year up"
    echo "  to the configured counts and prunes the rest. The single newest dump is"
    echo "  always kept, so retention can never leave a base with nothing."
    echo
    _ex_sec "Key options"
    echo "  --retention                 enable GFS"
    echo "  --retention-daily <N>       (default 7)"
    echo "  --retention-weekly <N>      (default 4)"
    echo "  --retention-monthly <N>     (default 12)"
    echo "  --retention-yearly <N>      (default 3)"
    echo
    _ex_sec "Example"
    echo "  t-pgsql dump --from ... --retention --retention-daily 14 --retention-monthly 24"
    _ex_see "explain dump · explain clean"
}

cmd_explain() {
    local topic
    topic=$(printf '%s' "${EXPLAIN_TARGET:-}" | tr '[:upper:]' '[:lower:]')
    case "$topic" in
        "")                     _explain_overview ;;
        dump)                   _explain_dump ;;
        restore)                _explain_restore ;;
        clone)                  _explain_clone ;;
        stream|streaming)       _explain_stream ;;
        upgrade)                _explain_upgrade ;;
        fetch)                  _explain_fetch ;;
        batch|jobs|job)         _explain_batch ;;
        bot|telegram)           _explain_bot ;;
        list|meta|clean)        _explain_maint ;;
        doctor)                 _explain_doctor ;;
        mask|masking)           _explain_mask ;;
        retention|gfs)          _explain_retention ;;
        *)
            log_error "No explanation for '$topic'. Run 't-pgsql explain' to see the topics."
            return 1
            ;;
    esac
}
