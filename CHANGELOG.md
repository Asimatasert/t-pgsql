# Changelog

All notable changes to this project will be documented in this file.

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

## [3.3.0] - 2025-01-05

### Added
- **Profile-based job configuration**: Define reusable connection profiles in `jobs.yaml` to reduce repetition
- **Wildcard support for `--exclude-data`**: Use `schema.*` pattern to exclude all tables in a schema (e.g., `--exclude-data "audit.*"`)
- **New jobs.yaml formats**: Support for profile-based, connection string, and legacy args formats

### Changed
- Remote dump files are now stored in `/tmp/t-pgsql/` instead of `/tmp/` for better organization
- Updated all README documentation (EN, DE, ES, RU) with new jobs.yaml format examples

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
