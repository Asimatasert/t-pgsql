# Fish completion for t-pgsql

# Commands
set -l commands dump restore clone upgrade fetch batch bot jobs list meta clean doctor status explain version help

# Disable file completion by default
complete -c t-pgsql -f

# Commands
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "dump" -d "Create database backup"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "restore" -d "Restore backup to database"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "clone" -d "Dump + Restore (full sync)"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "upgrade" -d "Logical major-version migration"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "fetch" -d "Fetch existing dump from remote"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "batch" -d "Run multiple jobs"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "bot" -d "Telegram bot (listen for commands)"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "jobs" -d "Manage saved jobs"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "list" -d "List dump files"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "meta" -d "Show metadata"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "clean" -d "Clean old dumps"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "doctor" -d "Check environment and backup health"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "status" -d "Show last run of each job (--max-age checks freshness)"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "explain" -d "Explain what a command is for"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "version" -d "Show version"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "help" -d "Show help"

# Jobs subcommands
complete -c t-pgsql -n "__fish_seen_subcommand_from jobs" -a "list" -d "List all jobs"
complete -c t-pgsql -n "__fish_seen_subcommand_from jobs" -a "show" -d "Show job details"
complete -c t-pgsql -n "__fish_seen_subcommand_from jobs" -a "remove" -d "Remove a job"

# Explain topics
complete -c t-pgsql -n "__fish_seen_subcommand_from explain" -a "dump restore clone stream upgrade fetch batch jobs bot list meta clean doctor status ping lock masking retention" -d "Topic"

# Connection options
complete -c t-pgsql -l from -d "Source connection"
complete -c t-pgsql -l to -d "Target connection"
complete -c t-pgsql -l password -d "Password"
complete -c t-pgsql -l from-password -d "Source password"
complete -c t-pgsql -l to-password -d "Target password"
complete -c t-pgsql -l password-file -d "Password file" -r
complete -c t-pgsql -l from-password-file -d "Source password file" -r
complete -c t-pgsql -l to-password-file -d "Target password file" -r
complete -c t-pgsql -l config -d "Config file" -r

# Filtering options
complete -c t-pgsql -l exclude-table -d "Exclude tables"
complete -c t-pgsql -l exclude-schema -d "Exclude schemas"
complete -c t-pgsql -l exclude-data -d "Exclude data only"
complete -c t-pgsql -l only-table -d "Only these tables"
complete -c t-pgsql -l only-schema -d "Only these schemas"

# Compression options
complete -c t-pgsql -l compress -d "Compression type" -xa "gzip zstd xz bzip2 none"
complete -c t-pgsql -l compress-level -d "Compression level 1-9"
complete -c t-pgsql -l pg-compress-level -d "pg_dump compression 0-9"
complete -c t-pgsql -l compress-where -d "Where to compress SSH dumps" -xa "source target"

# Storage options
complete -c t-pgsql -l output -d "Output directory" -ra "(__fish_complete_directories)"
complete -c t-pgsql -l dump-name -d "Custom dump filename"
complete -c t-pgsql -l keep -d "Keep N local dumps"
complete -c t-pgsql -l from-keep -d "Keep N on source"
complete -c t-pgsql -l min-size-ratio -d "Fail if new dump is smaller than this percent of the previous" -xa "0 25 50 75 100"
complete -c t-pgsql -l from-stale -d "Purge stale remote dumps older than"
complete -c t-pgsql -l archive-output -d "Move aged-out dumps here" -ra "(__fish_complete_directories)"
complete -c t-pgsql -l archive-keep -d "Keep N dumps in archive"
complete -c t-pgsql -l skip-if-recent -d "Skip if recent dump exists" -xa "today 24h 12h 6h 1d"
complete -c t-pgsql -l from-file -d "Fetch existing dump" -r
complete -c t-pgsql -l file -d "Dump file" -r
complete -c t-pgsql -l yaml -d "Custom YAML file" -ra "(__fish_complete_suffix .yaml)"

# Retention options
complete -c t-pgsql -l retention -d "Enable GFS retention"
complete -c t-pgsql -l retention-daily -d "Daily backups"
complete -c t-pgsql -l retention-weekly -d "Weekly backups"
complete -c t-pgsql -l retention-monthly -d "Monthly backups"
complete -c t-pgsql -l retention-yearly -d "Yearly backups"

# Health check options
complete -c t-pgsql -l health-check -d "Check before"
complete -c t-pgsql -l health-check-after -d "Check after"
complete -c t-pgsql -l no-health-check -d "Disable checks"
complete -c t-pgsql -l health-check-fail -d "Fail on health check error"

# Notification options
complete -c t-pgsql -l notify -d "Notification channel"
complete -c t-pgsql -l notify-on-error -d "Only on error"
complete -c t-pgsql -l notify-summary -d "Send batch summary notification"

# Masking options
complete -c t-pgsql -l mask -d "Enable masking"
complete -c t-pgsql -l mask-rules -d "Masking rules" -r
complete -c t-pgsql -l mask-tables -d "Tables to mask"

# Other options
complete -c t-pgsql -l stream -d "Stream mode"
complete -c t-pgsql -l stream-buffer -d "Buffer size MB"
complete -c t-pgsql -l sudo -d "Use sudo"
complete -c t-pgsql -l globals -d "Also migrate roles/tablespaces"
complete -c t-pgsql -l pg-bindir -d "PostgreSQL client bin dir" -ra "(__fish_complete_directories)"
complete -c t-pgsql -l bwlimit -d "Cap transfer bandwidth (e.g. 10m, 500k)"
complete -c t-pgsql -l retries -d "Retry failed scp transfers"
complete -c t-pgsql -l token -d "Telegram bot token"
complete -c t-pgsql -l cooldown -d "Bot cooldown between backups"
complete -c t-pgsql -l parallel -d "Parallel jobs"
complete -c t-pgsql -l continue-on-error -d "Continue on error"
complete -c t-pgsql -l only-jobs -d "Only run these batch jobs"
complete -c t-pgsql -l exclude-jobs -d "Exclude these batch jobs"
complete -c t-pgsql -l only -d "Alias for --only-jobs"
complete -c t-pgsql -l exclude -d "Alias for --exclude-jobs"
complete -c t-pgsql -l save -d "Save as job"
complete -c t-pgsql -l batch -d "Run batch job"
complete -c t-pgsql -l ping -d "Heartbeat monitor URL (start, success, fail)"
complete -c t-pgsql -l ping-start -d "Explicit heartbeat start URL"
complete -c t-pgsql -l ping-fail -d "Explicit heartbeat failure URL"
complete -c t-pgsql -l lock-wait -d "Wait N seconds for a held run lock" -xa "0 30 60 300"
complete -c t-pgsql -l no-lock -d "Do not take the run lock"
complete -c t-pgsql -l name -d "status: only this name"
complete -c t-pgsql -l limit -d "status: last N runs of --name"
complete -c t-pgsql -l max-age -d "status: fail (exit 3) if no fresh success within this time" -xa "1h 6h 12h 26h 1d 2d"
complete -c t-pgsql -l json -d "status: JSON output"
complete -c t-pgsql -l log -d "Log file" -r
complete -c t-pgsql -l log-level -d "Log level" -xa "debug info warn error"
complete -c t-pgsql -s v -l verbose -d "Verbose output"
complete -c t-pgsql -s q -l quiet -d "Quiet output"
complete -c t-pgsql -s y -l yes -d "Skip confirmations"
complete -c t-pgsql -s f -l force -d "Force overwrite"
complete -c t-pgsql -l dry-run -d "Dry run"
complete -c t-pgsql -l no-meta -d "No meta files"
complete -c t-pgsql -s h -l help -d "Show help"
complete -c t-pgsql -l version -d "Show version"
