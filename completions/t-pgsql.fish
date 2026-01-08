# Fish completion for t-pgsql

# Commands
set -l commands dump restore clone fetch batch jobs list meta clean version help

# Disable file completion by default
complete -c t-pgsql -f

# Commands
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "dump" -d "Create database backup"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "restore" -d "Restore backup to database"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "clone" -d "Dump + Restore (full sync)"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "fetch" -d "Fetch existing dump from remote"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "batch" -d "Run multiple jobs"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "jobs" -d "Manage saved jobs"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "list" -d "List dump files"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "meta" -d "Show metadata"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "clean" -d "Clean old dumps"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "version" -d "Show version"
complete -c t-pgsql -n "not __fish_seen_subcommand_from $commands" -a "help" -d "Show help"

# Jobs subcommands
complete -c t-pgsql -n "__fish_seen_subcommand_from jobs" -a "list" -d "List all jobs"
complete -c t-pgsql -n "__fish_seen_subcommand_from jobs" -a "show" -d "Show job details"
complete -c t-pgsql -n "__fish_seen_subcommand_from jobs" -a "delete" -d "Delete a job"

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

# Storage options
complete -c t-pgsql -l output -d "Output directory" -ra "(__fish_complete_directories)"
complete -c t-pgsql -l dump-name -d "Custom dump filename"
complete -c t-pgsql -l keep -d "Keep N local dumps"
complete -c t-pgsql -l from-keep -d "Keep N on source"
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

# Notification options
complete -c t-pgsql -l notify -d "Notification channel"
complete -c t-pgsql -l notify-on-error -d "Only on error"

# Masking options
complete -c t-pgsql -l mask -d "Enable masking"
complete -c t-pgsql -l mask-rules -d "Masking rules" -r
complete -c t-pgsql -l mask-tables -d "Tables to mask"

# Other options
complete -c t-pgsql -l stream -d "Stream mode"
complete -c t-pgsql -l stream-buffer -d "Buffer size MB"
complete -c t-pgsql -l sudo -d "Use sudo"
complete -c t-pgsql -l parallel -d "Parallel jobs"
complete -c t-pgsql -l continue-on-error -d "Continue on error"
complete -c t-pgsql -l save -d "Save as job"
complete -c t-pgsql -l batch -d "Run batch job"
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
