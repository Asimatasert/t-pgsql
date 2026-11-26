# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Heartbeat ping (dead-man's switch)** for `dump`, `clone`, `restore`, `upgrade` and
  `fetch`: `--ping <url>` sends `<url>/start`, then `<url>` on success or `<url>/fail`
  on any failure; `--ping-start` / `--ping-fail` set explicit URLs (Uptime Kuma style).
  Also available as `ping`, `ping_start`, `ping_fail` in `--config` files, job YAML and
  `defaults:`. URLs are passed to curl on stdin and masked in logs and `jobs show`;
  a failed ping only warns. `T_PGSQL_PING_DISABLE=1` turns pings off.
- **Run history and `status` command**: every `dump`, `clone`, `restore`, `upgrade` and
  `fetch` run appends a line to `history.tsv` in the state directory
  (`T_PGSQL_STATE_DIR`, default `${XDG_STATE_HOME:-$HOME/.local/state}/t-pgsql`).
  `t-pgsql status [--yaml FILE] [--output DIR] [--name NAME] [--limit N] [--json]` shows
  the last run per job; `status --max-age DURATION` exits 3 when a listed job has no
  fresh successful run, for cron monitoring.
- **Run lock**: `dump`, `fetch`, `restore`, `clone` and `upgrade` take a lock per output
  directory + dump name / per target database, so overlapping runs cannot collide.
  `--lock-wait <seconds>` waits for a held lock, `--no-lock` disables it (`lock_wait`,
  `no_lock` in config and job YAML); stale locks are taken over (`T_PGSQL_LOCK_MAX_AGE`).
- `explain status`, `explain ping`, `explain lock`; man page, completions, README and
  `jobs.yaml.example` cover the new commands and options.

### Changed
- A run skipped because another run holds the lock exits **75** (EX_TEMPFAIL) instead of
  failing; it sends no failure notification and no ping, and is recorded in the history as
  `locked`. In `batch` such a job is `Skipped (locked)` and does not count as failed.
- A batch where every job was skipped by the lock reports "All N of M jobs were skipped
  (locked); nothing ran" and sends a warning notification, never a success notification.
- `batch --lock-wait N` and `batch --no-lock` are forwarded to every job the batch starts.
- `batch` rejects `--ping`, `--ping-start` and `--ping-fail` (exit 1); put `ping:` on the
  job in the jobs file instead.
- `status --max-age` accepts a bare number (seconds) and upper-case units (`1D`); only
  `ok` and `--skip-if-recent` skipped runs count as fresh, `failed`, `suspect` and
  `locked` runs do not. An unknown `status` option exits 2.
- `jobs show` also masks `--notify` values in legacy `args:`.

### Fixed
- With `--ping` the run history line is now written (the ping setup no longer replaces
  the exit handler).
- History messages no longer contain passwords, URLs or `user@host` words; messages are
  cut by bytes, so the file stays valid UTF-8.
- `status` on bash older than 4 prints `status needs bash 4 or newer` and exits 2 instead
  of reporting "No runs recorded yet."; `status --yaml` lists job names with dots or quotes.
- Ping URLs: `/start` and `/fail` go before a `#fragment`; `HTTPS://` is accepted; a bad
  URL is not an error under `--dry-run` or `T_PGSQL_PING_DISABLE=1`; a dump without
  `--from` no longer sends a start ping; legacy `args:` jobs no longer expose the ping URL
  on the child command line.
- Run lock: a lost take-over race no longer runs unlocked, pid reuse and host identity
  checks are stricter, and the take-over mutex is only stolen from a dead owner.

## [3.13.0] - 2026-11-26

### Added
- **Shrink guard `--min-size-ratio <percent>`** (also `min_size_ratio`
  in job YAML and `--config`): a new dump smaller than this percent (0-100, default 50,
  0 disables) of the previous dump of the same name no longer rotates anything. The new
  file is kept as `<name>.suspect`, keep-N, retention, archive and source-side cleanup are
  skipped, the job fails and a failure notification with both sizes is sent. Also applies
  to `clone`. Run once with `--min-size-ratio 0` if the shrink is expected.
- `doctor` shows the active ratio, warns when a base's newest dump is below it and reports
  `.suspect` files; `explain dump` / `explain retention` describe the guard.

### Changed
- Files created by the tool (dumps, archives, logs, directories) are private by default
  (umask 077). Set `T_PGSQL_UMASK=027` (one to four octal digits) to share through a group.
- `-q/--quiet` no longer silences failure notifications; early failures (missing `--from`,
  bad connection string, `--health-check-fail`) now notify when a channel is configured.
- `--dry-run` sends no notifications and writes nothing (no summary, no `--save`, no
  `jobs remove`, no output directory).
- `restore` without `--file` picks the newest dump of the right database when the output
  directory holds several; it errors and lists the bases when none matches.
- `fetch` requires the connecting SSH user to own the remote staging directory.
- A stream target without any password source fails instead of reusing the previous target's.
- `install.sh` verifies `SHA256SUMS` and fails closed (`--allow-unverified` to opt out).
- Translated READMEs and the internal audit report were removed; the project is English only.
- Dump and clone notifications now use the job name instead of the raw database name
  in their titles, so alerts identify the job unambiguously when several jobs share a
  database name.

### Security
- `upgrade`: random verified here-doc terminator for the globals dump and a digits-only
  `server_version_num`, so a hostile source server cannot run code on the target host or locally.
- Telegram bot: optional sender allowlist (`TELEGRAM_ALLOWED_USERS`, `telegram_allowed_users`),
  validated yaml and job names, private scratch and offset files, no replay after a lost offset.
- Database passwords are kept off `ssh` argv in stream and masking runs; the bot token is not
  on the argv of re-executed jobs; notification secrets are masked in logs.
- The remote staging directory is verified before use; remote retention patterns are anchored
  on the dump timestamp; `fetch --from-file` is quoted and restricted to a staged file name.
- Connection strings reject option-like and unsafe values; the source==target guard handles
  loopback aliases and SSH ports; stream `--force` probes the source before dropping the target.
- `--exclude-data` fails closed; a new dump is verified before rotation (bad dumps are kept
  as `.invalid`); notification curl calls have timeouts and `--fail`.

### Fixed
- The Telegram "re-run" button no longer breaks failure alerts when `callback_data` is too long.
- Unknown job keys in jobs.yaml are reported; YAML quoting and trailing comments parse correctly.
- `NO_COLOR` and non-terminal output are honoured; failed parallel jobs show their output.

## [3.12.1] - 2026-07-31

### Fixed
- **`--dry-run` silently ignored under `batch`**: `run_job()` re-execs each job as a
  brand-new process built purely from the job's YAML args, so a `--dry-run` given on
  the `batch` command line (e.g. `t-pgsql batch all --yaml prod --dry-run`) never
  reached the child — it ran the dump for real. `--dry-run` is now forced into every
  re-exec'd job when the parent process was invoked with it, regardless of what the
  job's own YAML sets. Discovered via a live production test where a dry-run
  triggered a real dump/transfer.

## [3.12.0] - 2026-07-31

### Added
- **Two-tier retention**: `--archive-output <dir>` / `--archive-keep <N>` (also settable
  as `archive_output` / `archive_keep` in job YAML or a `--config` defaults file). When a
  dump ages out of `--keep`, it is now MOVED to `--archive-output` instead of being
  deleted, and a second `--archive-keep` cap prunes that archive dir once it's set
  (-1=keep all, 0=delete immediately; default -1). Lets recent backups live on a
  fast/redundant disk while older-but-still-wanted history moves to a second,
  cheaper/less redundant disk instead of being lost outright.

### Fixed
- **Orphaned `.meta` files on cleanup**: `--keep`/GFS cleanup now also removes the
  matching `.meta` sidecar when a dump is deleted (previously only the dump itself
  was removed, leaving the metadata file behind).

## [3.11.1] - 2026-07-16

### Fixed
- **`bwlimit` / `retries` ignored in YAML and config files**: both options existed only on
  the command line, so a `bwlimit` or `retries` key in a jobs YAML or `--config` file was
  silently ignored. They are now wired into the batch YAML runner, the config loader and
  the job serializer, and pass through the existing strict validation.

## [3.11.0] - 2026-07-16

### Added
- **`doctor` command**: local, read-only environment and backup health checks (required
  and optional tools, output directory and free disk space, freshness of each database's
  newest dump, readability of the newest archives, the jobs file, and optional
  connectivity with `--from`/`--to`). Exits non-zero when it finds a problem.
- **`explain` command**: built-in, offline reference for what each command is for and when
  to use it, with key options and examples.
- Completions for the `bot` command (bash, zsh, fish).

## [3.10.0] - 2026-07-16

### Added
- **`--compress-where source|target`**: for SSH dumps with `zstd`/`xz`/`bzip2`, compress on
  the source host before the transfer. Falls back to target-side compression with a
  warning if the tool is missing on the source. Default `target` (previous behaviour).
- **`--from-stale <time>`**: with `--from-keep 0`, purge this job's leftover staging dumps
  from failed runs on the source before dumping (default `72h`, `0` disables).

### Fixed
- Retention and fetch globs for source staging dumps now also match compressed artifacts.
- `compress_where` and `from_stale` keys in a jobs YAML were not passed to batch jobs.

## [3.9.0] - 2026-07-02

Audit remediation release. Hardening and correctness fixes across the tool plus documentation and packaging version sync.

### Fixed
- **Error handling**: Corrected `set -e` interactions that could cause silent exits or mask failures during dump/restore/clone and batch runs
- **Restore exit codes**: Restore now reports accurate exit codes so failures propagate instead of being swallowed
- **Password leak hardening**: Passwords are no longer exposed via process arguments or logs
- **Injection hardening**: Sanitized values interpolated into remote/SSH and shell commands
- **YAML parsing**: Inline comments are now stripped from job/profile values
- **Retention glob anchoring**: GFS retention globs are anchored to the correct database/output so unrelated files are never matched
- **save_job completeness**: `--save` now persists the full set of job options

### Added
- **Transfer resilience & throttling** (for big jobs over shared/VPN links):
  `--bwlimit <rate>` caps bandwidth (10m / 500k / bare KByte/s) on scp copies (scp -l)
  and the streaming pipe (pv -L; needs `pv`); `--retries <N>` retries a failed scp with
  backoff; all SSH transfers now use ConnectTimeout + ServerAlive keepalive so a stalled
  link fails within ~60s instead of hanging. A failed SSH dump transfer no longer deletes
  the source copy (data-safety).
- **`upgrade` command + `--globals` / `--pg-bindir`**: logical major-version migration
  (e.g. PG16 → PG18). `upgrade` clones a database and also migrates cluster globals
  (roles, tablespaces via `pg_dumpall --globals-only`), with a version preflight that
  refuses to restore into an older major version. `--globals` adds the same to `clone`;
  `--pg-bindir` selects which PostgreSQL client tools local operations use (so an old
  server can be dumped with the target version's tools). This is the logical
  (dump/restore) path — not a replacement for `pg_upgrade` or logical replication on
  large clusters. Globals migration supports local/TCP and SSH sources and is applied
  to every --to target.
- **Docker support**: `Dockerfile` (non-root, PostgreSQL client major version as a
  `PG_MAJOR` build arg so cross-version dumps use the right tools), `.dockerignore`,
  and a `docker-compose.yml` example for running the bot as a service.
- **`bot` command**: Telegram bot that listens for commands and inline-button
  callbacks to trigger backups (`/list`, `/backup <yaml> <job>`), with per-job
  cooldown (`--cooldown`) and token via `--token` or YAML. Group-chat access control;
  backups run in the background with a result notification.
- **--only-table** and **--only-schema**: Include-only filtering for tables and schemas is now implemented
- **--health-check-after**: Post-operation health check is now implemented
- **--log-level**: Log verbosity levels (debug, info, warn, error) are now honored

### Changed
- Compression: with `zstd`/`xz`/`bzip2`, pg_dump's built-in `-Z` compression is now
  disabled so the data is compressed once by the external tool instead of twice
  (previously pg_dump compressed at level 6 and the external tool recompressed it —
  wasted CPU and a worse ratio).
- Batch job filters renamed for clarity: **--only-jobs** / **--exclude-jobs**
  (the old `--only` / `--exclude` still work as aliases). This removes the confusion
  with the content filters `--only-table` / `--exclude-table`.
- Help text clarified: `--compress-level` vs the advanced `--pg-compress-level`,
  `--config` (a per-run credentials/defaults file, not the jobs file), and `--from-keep`
  (remote `/tmp` staging retention for SSH sources).
- Documentation corrected to match actual behavior (default output directory, jobs `remove` subcommand, notification channels, `--yaml`, environment variables)
- Packaging and version metadata synchronized to 3.9.0 (man page, jobs.yaml.example, metadata script_version)

## [3.7.1] - 2026-01-08

### Fixed
- Fixed compressed dump file detection (`.dump.zst`, `.dump.xz`, `.dump.bz2`)
- Fixed Linux/macOS `stat` command compatibility
- Fixed `--skip-if-recent`, restore, clone, list, meta commands for compressed files
- Fixed retention cleanup for all dump formats

## [3.7.0] - 2026-01-08

### Added
- **Skip if recent dump exists**: New `--skip-if-recent` parameter

### Changed
- Added `--skip-if-recent` documentation to README and help text

## [3.6.0] - 2026-01-08

### Added
- **Custom YAML file support for jobs command**: Use `--yaml` parameter with jobs list/show/remove commands
- **Custom dump naming**: New `--dump-name` parameter and `dump_name` job option for custom dump file names
- **Notification support for fetch command**: Added missing notification functionality to fetch operations

### Fixed
- **Fish shell compatibility**: Changed PGPASSWORD syntax to `env PGPASSWORD=` for cross-shell compatibility
- **Health check fallback**: Added fallback to 'postgres' database when target database doesn't exist yet
- **Jobs command argument parsing**: Fixed --yaml parameter parsing for jobs subcommand
- **Clone command**: Fixed undefined `get_dump_name` function call in clone operation

### Changed
- Updated help text with --yaml parameter for jobs command
- Enhanced README documentation with jobs command examples and custom dump naming

## [3.5.0] - 2026-01-07

### Fixed
- Fixed macOS `awk` compatibility (regex negation syntax)
- Fixed batch command silent exit with `set -e`
- Fixed defaults not being applied to jobs (force, output, exclude_data)

### Added
- Added `get_job_value()` for defaults fallback in job config
- Jobs now properly inherit `defaults` section values
- Added buffer/compression defaults support in YAML config

## [3.4.0] - 2026-01-06

### Added
- **Streaming mode** (`--stream`): Direct pipe clone without temp files
- **Parallel batch execution** (`--parallel N`)
- **Job filtering** (`--only`, `--exclude`)
- **Batch summary notifications** (`--notify-summary`)
- **Config file support** (`--config`)
- **Health checks** before operations (`--health-check`)
- **GFS retention policy** (`--retention`)
- **Data masking** after restore (`--mask`)
- Fish shell completion
- man page

## [3.3.0] - 2026-01-05

### Added
- **Profile-based job configuration**: Define reusable connection profiles in `jobs.yaml` to reduce repetition
- **Wildcard support for `--exclude-data`**: Use `schema.*` pattern to exclude all tables in a schema (e.g., `--exclude-data "audit.*"`)
- **New jobs.yaml formats**: Support for profile-based, connection string, and legacy args formats

### Changed
- Remote dump files are now stored in `/tmp/t-pgsql/` instead of `/tmp/` for better organization
- Updated all README documentation with new jobs.yaml format examples

### Fixed
- Jobs list now correctly shows only jobs, not profiles or defaults sections

## [3.2.0] - 2024-12-30

### Added
- Colored job list output
- Interactive batch mode with job selection
- Zsh autocompletion support
- `jobs show` and `jobs remove` commands

## [3.1.0] - 2024-12-28

### Added
- Notification system (Telegram, Slack, Webhook, Email)
- `--notify` parameter for all commands
- `--notify-on-error` and `--notify-summary` options

## [3.0.0] - 2024-12-25

### Added
- Initial public release
- Dump, restore, clone, fetch commands
- SSH tunnel support
- Batch job system
- Metadata tracking
- Password file support
