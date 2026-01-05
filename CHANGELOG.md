# Changelog

All notable changes to this project will be documented in this file.

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
