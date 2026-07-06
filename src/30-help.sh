# ==============================================================================
# HELP
# ==============================================================================
show_help() {
    cat << 'EOF'
t-pgsql - PostgreSQL Database Sync & Clone Tool

USAGE:
    t-pgsql <command> [options]

COMMANDS:
    dump        Create database backup
    restore     Restore backup to database
    clone       Dump + Restore (full sync)
    upgrade     Logical major-version migration (clone + cluster globals)
    fetch       Fetch existing dump from remote (no new dump)
    batch       Run multiple jobs from config
    bot         Telegram bot (listen for commands + inline button callbacks)
                  bot [--yaml <file>] [--token <token>] [--cooldown <time>]
    jobs        Manage saved jobs
                  jobs [list] [--yaml <file>]  List all jobs
                  jobs show <name> [--yaml <file>]  Show job details
                  jobs remove <name> [--yaml <file>] Remove a job
    list        List dump files
    meta        Show metadata from archive
    clean       Clean old dumps (requires a target + retention)
                  clean <db> --keep <N>        Clean by database name
                  clean --from <conn> --keep <N>
                  clean --dump-name <name> --retention
    doctor      Check the environment and backup health (add --from/--to to test connectivity)
    explain     Explain what a command is for: explain [dump|restore|clone|upgrade|...]
    version     Show version

CONNECTION:
    --from <connection>           Source connection
    --to <connection>             Target connection (repeatable)

    Format:
      Local:  [user@]host[:port]/database
      Remote: ssh://[ssh_user@]host[:port]/[db_user@]host[:port]/database

    Examples:
      localhost/mydb
      postgres@localhost:5432/mydb
      ssh://ubuntu@192.0.2.20/mydb
      ssh://ubuntu@192.0.2.20:22/postgres@localhost:5432/mydb

PASSWORD:
    --password <pass>             Password for both connections
    --from-password <pass>        Source password
    --to-password <pass>          Target password
    --password-file <file>        Read password from file
    --from-password-file <file>   Source password file
    --to-password-file <file>     Target password file (repeatable for multiple targets)
    --config <file>               Defaults file (connections/credentials) for a single run.
                                  This is NOT the batch jobs file — use --yaml for jobs.

    Env vars: T_PGSQL_PASSWORD, T_PGSQL_FROM_PASSWORD, T_PGSQL_TO_PASSWORD
    Tip: prefer password files or env vars over --password (CLI args are visible in `ps`).

FILTER (dump content — which tables/schemas go into the dump):
    --exclude-table <t1,t2>       Exclude tables
    --exclude-schema <s1,s2>      Exclude schemas
    --exclude-data <t1,t2>        Exclude data only (keep structure, supports schema.* wildcard)
    --only-table <t1,t2>          Include only these tables
    --only-schema <s1,s2>         Include only these schemas
    (For selecting which batch JOBS run, see --only-jobs/--exclude-jobs under BATCH.)

COMPRESSION:
    --compress <type>             gzip|zstd|xz|bzip2|none (default: gzip)
    --compress-level <N>          Level for the active compressor (default: 6).
                                  Valid range depends on the type: gzip/xz/bzip2 1-9,
                                  zstd 1-19. With zstd/xz/bzip2, pg_dump's built-in
                                  compression is disabled so data is compressed once.
    --pg-compress-level <0-9>     Advanced: override pg_dump's built-in -Z level
                                  (only affects the gzip type; default: 6)

STORAGE:
    --output <dir>                Output directory (default: env T_PGSQL_OUTPUT_DIR,
                                  else <script dir>/../data/dumps)
    --dump-name <name>            Custom dump filename (without timestamp)
    --keep <N>                    Keep last N local dumps (-1=all, 0=none)
    --from-keep <N>               For SSH sources: how many dumps to keep in the remote
                                  /tmp staging dir (default: 1, -1=all, 0=delete)
    --skip-if-recent <time>       Skip if dump exists within timeframe
                                  Examples: 24h, 12h, 1d, today
    --from-file [pattern]         Fetch existing dump (for fetch command)
                                  No value = latest dump for database
                                  Pattern: filename or glob (e.g., mydb_*.dump)

RETENTION (GFS):
    --retention                   Enable GFS retention
    --retention-daily <N>         Daily backups (default: 7)
    --retention-weekly <N>        Weekly backups (default: 4)
    --retention-monthly <N>       Monthly backups (default: 12)
    --retention-yearly <N>        Yearly backups (default: 3)

HEALTH CHECK:
    --health-check                Check before operation (default)
    --health-check-after          Check after operation
    --no-health-check             Disable checks
    --health-check-fail           Abort on check failure

NOTIFY:
    --notify <channel>            Notification channel (repeatable)
                                  telegram|telegram:TOKEN:CHAT
                                  webhook:URL|email:ADDR|slack:URL
    --notify-on-error             Only notify on error
    --quiet                       No notifications

MASKING:
    --mask                        Enable data masking
    --mask-rules <file>           Masking rules JSON
    --mask-tables <t1,t2>         Tables to mask

STREAMING:
    --stream                      Stream without temp files
    --stream-buffer <MB>          Buffer size (default: 64)

BATCH:
    --yaml <name>                 Use <name>.yaml instead of jobs.yaml
                                  Example: --yaml prod (uses prod.yaml)
    --parallel <N>                Parallel jobs (default: 1)
    --continue-on-error           Don't stop on error
    --only-jobs <j1,j2>           Run only these jobs   (alias: --only)
    --exclude-jobs <j1,j2>        Skip these jobs       (alias: --exclude)
    --notify-summary              Summary notification

MIGRATION / UPGRADE:
    --globals                     Also migrate cluster globals (roles, tablespaces)
                                  from source to every target (local/TCP or SSH)
    --pg-bindir <dir>             Use PostgreSQL client tools from <dir> for local
                                  operations (e.g. dump an old server with the target
                                  major version's pg_dump). Does not affect SSH sources.

    The 'upgrade' command = clone + --globals + a version preflight (it refuses to
    restore into an OLDER major version). This is the logical (dump/restore) path;
    for large clusters or minimal downtime prefer pg_upgrade or logical replication.

TRANSFER (SSH scp + streaming clone):
    --bwlimit <rate>              Cap transfer bandwidth. Accepts 10m (MByte/s),
                                  500k (KByte/s) or a bare number (KByte/s).
                                  Applies to scp copies and the streaming pipe (pv).
    --retries <N>                 Retry a failed scp transfer N extra times (backoff).
    (SSH transfers also use ConnectTimeout + ServerAlive keepalive so a stalled
     link fails within ~60s instead of hanging.)

BOT:
    --token <token>               Telegram bot token (or auto-detect from YAML)
    --cooldown <time>             Min interval between button-triggered backups (default: 1h)

RESTORE:
    --file <path>                 Dump file to restore

GENERAL:
    --log <file>                  Log file
    --log-level <level>           debug|info|warn|error
    -v, --verbose                 Verbose output
    -q, --quiet                   Minimal output
    -y, --yes                     Skip confirmations
    --dry-run                     Show actions without executing
    --no-meta                     Don't write .meta files
    -h, --help                    Show help
    --version                     Show version

EXAMPLES:
    # Remote to local
    t-pgsql clone \
      --from ssh://ubuntu@192.0.2.20/prod_db \
      --to localhost/dev_db \
      --from-password-file ~/.secrets/prod.pass \
      --to-password-file ~/.secrets/local.pass

    # Local to remote (push)
    t-pgsql clone \
      --from localhost/mydb \
      --to ssh://ubuntu@192.0.2.20/backup_db \
      --password-file ~/.secrets/db.pass

    # Dump with retention
    t-pgsql dump \
      --from ssh://ubuntu@192.0.2.20/prod \
      --from-password-file ~/.secrets/prod.pass \
      --compress zstd \
      --retention

    # Restore
    t-pgsql restore \
      --file ./dumps/prod_20250130.dump \
      --to localhost/test_db \
      --to-password-file ~/.secrets/local.pass

    # Batch
    t-pgsql batch all --yaml prod --parallel 2

    # Major-version logical migration (e.g. PG16 -> PG18), with roles/tablespaces.
    # Run from a host/container whose pg_dump matches the TARGET version.
    t-pgsql upgrade \
      --from "postgres@old-16-host:5432/appdb" \
      --to   "postgres@new-18-host:5432/appdb" -y

    # Telegram bot (token from YAML), custom cooldown
    t-pgsql bot --yaml prod --cooldown 30m
    #   /list              - list all YAML files
    #   /list prod         - list jobs in prod.yaml
    #   /backup prod nightly - run the "nightly" job (respects cooldown)

    # Fetch latest dump for database (auto-find)
    t-pgsql fetch --from ssh://ubuntu@192.0.2.20/prod --from-file

    # Fetch with specific pattern
    t-pgsql fetch \
      --from ssh://ubuntu@192.0.2.20/prod \
      --from-file "prod_20250130*.dump"

More info: https://github.com/Asimatasert/t-pgsql
EOF
}

show_version() {
    echo "${SCRIPT_NAME} v${VERSION}"
}

