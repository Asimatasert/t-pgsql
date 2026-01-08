# t-pgsql

Advanced CLI tool for backing up, restoring, and synchronizing PostgreSQL databases.

**Documentation:** [Türkçe](README_TR.md) | [Español](README_ES.md) | [Русский](README_RU.md) | [Deutsch](README_DE.md)

## Features

### Core Operations
- **Dump**: Backup from local or remote database
- **Restore**: Restore backup to local or remote database
- **Clone**: Single command dump + restore (full sync)
- **Fetch**: Download existing dump from remote server
- **Streaming**: Direct pipe clone without temp files (`--stream`)

### Batch & Automation
- **Batch Jobs**: Run multiple jobs from `jobs.yaml`
- **Parallel Execution**: Run jobs concurrently (`--parallel N`)
- **Job Filtering**: Run specific jobs (`--only`) or skip jobs (`--exclude`)
- **Notifications**: Telegram, Slack, Webhook, Email with summary support

### Data Management
- **Data Masking**: Anonymize sensitive data after restore (`--mask`)
- **Table Filtering**: Include/exclude tables or schemas
- **GFS Retention**: Grandfather-Father-Son backup rotation policy

### Security & Reliability
- **Health Checks**: Verify connections before operations
- **SSH Tunnel**: Secure access to remote databases
- **Password Security**: Read from files or environment variables
- **Metadata**: Track timing, source, and operation details

## Installation

### Quick Install (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/Asimatasert/t-pgsql/master/install.sh | bash
```

### Homebrew (macOS/Linux)

```bash
brew tap Asimatasert/t-pgsql
brew install t-pgsql
```

### Debian/Ubuntu

```bash
# Download latest .deb package
curl -LO https://github.com/Asimatasert/t-pgsql/releases/latest/download/t-pgsql_latest_all.deb
sudo dpkg -i t-pgsql_latest_all.deb
```

### Arch Linux (AUR)

```bash
# Using yay
yay -S t-pgsql

# Or manually
git clone https://github.com/Asimatasert/t-pgsql.git
cd t-pgsql/arch
makepkg -si
```

### Manual Installation

```bash
# Clone the repository
git clone https://github.com/Asimatasert/t-pgsql
cd t-pgsql

# Install with make
sudo make install

# Or manual install
chmod +x t-pgsql
sudo ln -s $(pwd)/t-pgsql /usr/local/bin/t-pgsql
```

### Shell Completions

Completions are installed automatically with package managers. For manual setup:

```bash
# Zsh
cp completions/_t-pgsql ~/.zsh/completions/

# Bash
cp completions/t-pgsql.bash /etc/bash_completion.d/t-pgsql

# Fish
cp completions/t-pgsql.fish ~/.config/fish/completions/
```

### Man Page

```bash
man t-pgsql
```

### Requirements

- PostgreSQL client (`pg_dump`, `pg_restore`, `psql`)
- SSH client (for remote operations)
- Bash 4.0+
- Optional: `pv` (for streaming buffer)

## Quick Start

```bash
# Dump from local database
./t-pgsql dump --from "postgres@localhost/mydb" --password-file .secrets/db.pass

# Dump from remote server
./t-pgsql dump --from "ssh://user@192.168.1.100/postgres@localhost/mydb" --from-password-file .secrets/remote.pass

# Restore a dump
./t-pgsql restore --file ./dumps/mydb_20250101.tar.gz --to "postgres@localhost/mydb_copy" --to-password-file .secrets/local.pass

# Clone with single command (dump + restore)
./t-pgsql clone --from "ssh://user@server/postgres@localhost/prod" --to "postgres@localhost/dev" --from-password-file .secrets/prod.pass --to-password-file .secrets/local.pass --force
```

---

## Connection Formats

### Local Connection

```
[db_user@]host[:port]/database
```

| Example | Description |
|---------|-------------|
| `localhost/mydb` | Default user with localhost |
| `postgres@localhost/mydb` | With postgres user |
| `postgres@localhost:5432/mydb` | With explicit port |
| `asimatasert@localhost/test123` | Custom user |

### SSH (Remote) Connection

```
ssh://[ssh_user@]ssh_host[:ssh_port]/[db_user@]db_host[:db_port]/database
```

| Example | Description |
|---------|-------------|
| `ssh://awsm3@192.168.1.100/mydb` | Simple format (db: localhost, user: postgres) |
| `ssh://awsm3@192.168.1.100/postgres@localhost/mydb` | With DB user specified |
| `ssh://awesome@192.168.1.31/postgres@localhost/rftt-template` | Full format |
| `ssh://asimatasert@server:2222/postgres@localhost:5433/prod` | Custom ports |

### Connection Structure

```
ssh://awesome@192.168.1.31/postgres@localhost/workarea
       |        |            |        |       |
       |        |            |        |       +-- Database name
       |        |            |        +---------- DB host (inside SSH)
       |        |            +------------------- DB user
       |        +-------------------------------- SSH server IP
       +----------------------------------------- SSH user
```

---

## Commands

### dump

Creates a database backup.

```bash
./t-pgsql dump --from <connection> [options]
```

**Examples:**

```bash
# Simple dump
./t-pgsql dump --from "postgres@localhost/mydb" --password-file .secrets/db.pass

# Dump from remote server
./t-pgsql dump \
  --from "ssh://awesome@192.168.1.31/postgres@localhost/rftt-template" \
  --from-password-file .secrets/from.pass \
  --output ./dumps

# Exclude specific tables
./t-pgsql dump \
  --from "postgres@localhost/mydb" \
  --password-file .secrets/db.pass \
  --exclude-table "logs,sessions,temp_data"

# Include only specific tables
./t-pgsql dump \
  --from "postgres@localhost/mydb" \
  --password-file .secrets/db.pass \
  --only-table "users,orders,products"

# Exclude data only (keep structure)
./t-pgsql dump \
  --from "postgres@localhost/mydb" \
  --password-file .secrets/db.pass \
  --exclude-data "logs,audit_trail"

# Clean old dumps on source
./t-pgsql dump \
  --from "ssh://user@server/postgres@localhost/prod" \
  --from-password-file .secrets/prod.pass \
  --from-keep 3  # Keep last 3 dumps

# Custom dump name
./t-pgsql dump \
  --from "postgres@localhost/mydb" \
  --password-file .secrets/db.pass \
  --dump-name myapp-backup  # Creates: myapp-backup_YYYYMMDD_HHMMSS.dump
```

**Output:** `./dumps/database_YYYYMMDD_HHMMSS.tar.gz`

The tar archive contains:
- `database_YYYYMMDD_HHMMSS.dump` - PostgreSQL dump file (or custom name)
- `metadata.yaml` - Operation information

---

### restore

Restores a dump file to a database.

```bash
./t-pgsql restore --to <connection> [--file <file>] [options]
```

**Examples:**

```bash
# Restore latest dump (auto-find)
./t-pgsql restore --to "postgres@localhost/mydb" --to-password-file .secrets/local.pass

# Restore specific file
./t-pgsql restore \
  --file ./dumps/mydb_20250130.tar.gz \
  --to "postgres@localhost/mydb_copy" \
  --to-password-file .secrets/local.pass

# Drop and recreate existing DB
./t-pgsql restore \
  --file ./dumps/prod_backup.tar.gz \
  --to "postgres@localhost/test_db" \
  --to-password-file .secrets/local.pass \
  --force
```

> **Note:** If `--file` is not specified, automatically finds the latest `.tar.gz` file in the `--output` directory.

---

### clone

Performs dump + restore in a single command.

```bash
./t-pgsql clone --from <source> --to <target> [options]
```

**Examples:**

```bash
# Clone from remote to local
./t-pgsql clone \
  --from "ssh://awesome@192.168.1.31/postgres@localhost/rftt-template" \
  --to "asimatasert@localhost/test123" \
  --from-password-file .secrets/from.pass \
  --to-password-file .secrets/to.pass \
  --force

# Push from local to remote
./t-pgsql clone \
  --from "postgres@localhost/dev" \
  --to "ssh://user@server/postgres@localhost/staging" \
  --from-password-file .secrets/local.pass \
  --to-password-file .secrets/remote.pass

# Clone to multiple targets
./t-pgsql clone \
  --from "ssh://user@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev1" \
  --to "postgres@localhost/dev2" \
  --to "postgres@localhost/test" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --force

# Streaming clone (no temp files, direct pipe)
./t-pgsql clone \
  --from "ssh://user@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --stream \
  --force

# Streaming with custom buffer size
./t-pgsql clone \
  --from "postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --stream \
  --stream-buffer 128 \
  --force
```

---

### fetch

Downloads an existing dump file from remote (without creating a new dump).

```bash
./t-pgsql fetch --from <connection> --from-file [pattern] [options]
```

**Examples:**

```bash
# Download latest dump
./t-pgsql fetch \
  --from "ssh://user@server/postgres@localhost/mydb" \
  --from-file \
  --output ./dumps

# Download with specific pattern
./t-pgsql fetch \
  --from "ssh://user@server/postgres@localhost/mydb" \
  --from-file "mydb_20250130*.dump" \
  --output ./dumps
```

---

### list

Lists dump files.

```bash
./t-pgsql list [--output <directory>]
```

**Example output:**

```
Dumps in: /Users/user/t-pgsql/dumps

FILE                                      SIZE DATE
---------------------------------------------------------------------------
rftt-template_20251230_225325.tar.gz     39MiB 2025-12-30 22:54
mydb_20251229_143022.tar.gz              15MiB 2025-12-29 14:30
```

---

### meta

Displays metadata information from a dump archive.

```bash
./t-pgsql meta --file <archive.tar.gz>
```

**Example output:**

```yaml
timing:
  started_at: "2025-12-30 22:53:25"
  finished_at: "2025-12-30 22:54:39"
  elapsed: "1m 14s"
  elapsed_seconds: 74

source:
  type: ssh
  host: 192.168.1.31
  port: 5432
  database: rftt-template
  user: postgres

file:
  name: rftt-template_20251230_225325.dump
  size: "41M"
  compression: gzip
  compress_level: 6

operation:
  command: dump
  status: success
  exit_code: 0

environment:
  script_version: "3.0.0"
  executed_by: asimatasert
  executed_on: macbookair
  working_dir: /Users/asimatasert/t-pgsql/t-pgsql
```

---

### clean

Cleans old dump files.

```bash
./t-pgsql clean [--output <directory>] [--keep <N>]
```

---

### jobs

Lists saved batch jobs.

```bash
./t-pgsql jobs
```

---

## Batch System

Save repetitive operations and run them with a single command.

### Saving a Job

Save any command with `--save <name>`:

```bash
./t-pgsql clone \
  --from "ssh://awesome@192.168.1.31/postgres@localhost/rftt-template" \
  --to "asimatasert@localhost/test123" \
  --from-password-file .secrets/from.pass \
  --to-password-file .secrets/to.pass \
  --force \
  --save rftt_sync
```

### Running Jobs

```bash
# Run a single job
./t-pgsql batch rftt_sync

# Run all jobs sequentially
./t-pgsql batch all

# Use different YAML file
./t-pgsql batch all --yaml sync-30     # Uses ~/bin/sync-30.yaml
./t-pgsql batch all --yaml /path/to/custom.yaml

# Run jobs in parallel (3 concurrent jobs)
./t-pgsql batch all --parallel 3

# Parallel with error handling
./t-pgsql batch all --parallel 4 --continue-on-error

# Run only specific jobs
./t-pgsql batch all --only "job1,job2,job3"

# Exclude specific jobs
./t-pgsql batch all --exclude "slow_job,optional_job"

# Send summary notification after batch
./t-pgsql batch all --notify telegram:TOKEN:CHAT --notify-summary

# Combined: parallel with filtering and notifications
./t-pgsql batch all \
  --yaml sync-myproductions \
  --parallel 3 \
  --exclude "slow_backup" \
  --continue-on-error \
  --notify-summary
```

### Listing Jobs

```bash
# List jobs from default jobs.yaml
./t-pgsql jobs
./t-pgsql jobs list

# List jobs from custom YAML file
./t-pgsql jobs list --yaml sync-30
./t-pgsql jobs list --yaml ~/bin/aschenbrenner
./t-pgsql jobs list --yaml /path/to/custom.yaml

# Show specific job details
./t-pgsql jobs show rftt_sync
./t-pgsql jobs show rftt_sync --yaml sync-30

# Remove a job
./t-pgsql jobs remove old_job
./t-pgsql jobs remove old_job --yaml sync-30

# Output:
# Available jobs:
# ===============
#   - rftt_sync
#   - workarea_sync
#   - daily_backup
```

### jobs.yaml Format

t-pgsql supports three job formats: profile-based, connection string, and legacy args.

#### Profile-Based Format (Recommended)

Define reusable connection profiles and defaults to reduce repetition:

```yaml
# Profiles - reusable connection configurations
profiles:
  production:
    type: ssh
    ssh_user: deploy
    ssh_host: prod.example.com
    db_user: postgres
    db_host: localhost
    db_port: 5432
    password_file: ~/.secrets/prod.pass

  local:
    type: local
    db_user: postgres
    db_host: localhost
    password_file: ~/.secrets/local.pass

# Defaults - inherited by all jobs
defaults:
  output: ~/data/dumps
  from_keep: 1
  force: true
  compress: gzip
  compress_level: 6
  stream_buffer: 256
  exclude_data: "audit.*,public.sessionlog"
  parallel: 4
  continue_on_error: true
  notify:
    telegram:
      chat_id: "-123456789"
      token: "BOT_TOKEN"
      message_thread_id: 12345  # Optional: for forum topics

# Jobs using profiles (inherit defaults)
jobs:
  prod-to-local:
    command: clone
    dump_name: myapp-backup  # Custom dump name (optional)
    from:
      profile: production
      database: myapp
    to:
      profile: local
      database: myapp_dev
    # force, output, exclude_data etc. inherited from defaults
```

#### Connection String Format

Use direct connection strings for simpler jobs:

```yaml
jobs:
  quick-backup:
    command: dump
    from: ssh://user@server/postgres@localhost/mydb
    from_password_file: ~/.secrets/prod.pass
    output: ./dumps
    keep: 7
```

#### Legacy Args Format (Backward Compatible)

Old format still works for backward compatibility:

```yaml
jobs:
  legacy_job:
    command: clone
    args: --from 'ssh://user@server/postgres@localhost/db' --to 'postgres@localhost/db' --force
```

#### Job Options

| Option | Description |
|--------|-------------|
| `force` | Drop and recreate existing database |
| `verbose` | Show detailed output |
| `from_keep` | Number of dumps to keep on source |
| `keep` | Number of local dumps to keep |
| `dump_name` | Custom dump filename (without timestamp) |
| `output` | Output directory for dumps |
| `exclude_table` | Tables to exclude completely |
| `exclude_data` | Tables to exclude data only (supports `schema.*` wildcard) |
| `exclude_schema` | Schemas to exclude |

---

## Advanced Features

### GFS Retention (Grandfather-Father-Son)

Automated backup rotation policy that keeps daily, weekly, monthly, and yearly backups:

```bash
# Enable GFS retention with defaults (7 daily, 4 weekly, 12 monthly, 3 yearly)
./t-pgsql dump \
  --from "postgres@localhost/prod" \
  --password-file .secrets/db.pass \
  --retention

# Custom retention periods
./t-pgsql dump \
  --from "postgres@localhost/prod" \
  --password-file .secrets/db.pass \
  --retention \
  --retention-daily 14 \
  --retention-weekly 8 \
  --retention-monthly 24 \
  --retention-yearly 5

# In jobs.yaml
jobs:
  daily-backup:
    command: dump
    from: postgres@localhost/prod
    from_password_file: .secrets/prod.pass
    output: /backups
    retention: true
    retention_daily: 7
    retention_weekly: 4
```

### Data Masking

Anonymize sensitive data after restore for development/testing environments:

```bash
# Auto-mask common fields in specified tables
./t-pgsql clone \
  --from "ssh://user@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev" \
  --mask \
  --mask-tables "users,customers,orders" \
  --force

# Use custom masking rules file
./t-pgsql clone \
  --from "postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --mask \
  --mask-rules mask-rules.json \
  --force
```

**mask-rules.json format:**

```json
{
  "users.email": "CONCAT(LEFT(email, 2), '***@example.com')",
  "users.phone": "'555-***-****'",
  "users.name": "CONCAT('User_', id)",
  "customers.address": "'[REDACTED]'",
  "orders.notes": "NULL"
}
```

**Auto-masked fields** (when using `--mask-tables`):
- `email` → `ab***@***.com`
- `phone` → `***-***-****`
- `password` / `password_hash` → `********` / `MASKED`
- `address` → `[MASKED]`
- `ssn` → `***-**-****`
- `credit_card` → `****-****-****-****`

### Health Checks

Verify database connections before operations:

```bash
# Enable health check (verify connection before operation)
./t-pgsql clone \
  --from "ssh://user@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev" \
  --health-check \
  --force

# Abort if health check fails
./t-pgsql clone \
  --from "ssh://user@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev" \
  --health-check \
  --health-check-fail \
  --force

# Disable health checks
./t-pgsql clone \
  --from "postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --no-health-check \
  --force
```

### Streaming Mode

Direct pipe transfer without creating temporary files (faster, less disk space):

```bash
# Stream clone (pg_dump | pg_restore)
./t-pgsql clone \
  --from "ssh://user@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev" \
  --stream \
  --force

# With custom buffer size (requires pv installed)
./t-pgsql clone \
  --from "postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --stream \
  --stream-buffer 256 \
  --force
```

> **Note:** Streaming mode doesn't create local dump files. Use regular clone if you need to keep backups.

---

## Password Management

Passwords should not appear in bash history. There are 3 methods:

### 1. Password File (Recommended)

#### Setting Up .secrets Directory

```bash
# Create .secrets directory
mkdir -p .secrets
chmod 700 .secrets

# Add to .gitignore (IMPORTANT!)
echo ".secrets/" >> .gitignore
```

#### Creating Password Files

```bash
# IMPORTANT: Use -n flag to avoid newline at end of file
echo -n "your_password_here" > .secrets/db.pass

# Set secure permissions (read/write only for owner)
chmod 600 .secrets/db.pass

# Verify no newline exists
cat .secrets/db.pass | xxd | tail -1
# Should NOT end with '0a' (newline character)
```

#### Recommended .secrets Structure

```
.secrets/
├── from.pass      # Source database password
├── to.pass        # Target database password
├── prod.pass      # Production database password
├── dev.pass       # Development database password
└── ssh.key        # SSH private key (optional)
```

#### Password File Format

| Requirement | Description |
|-------------|-------------|
| **No newline** | Use `echo -n` to avoid trailing newline |
| **Plain text** | Just the password, nothing else |
| **UTF-8** | Use UTF-8 encoding |
| **Permissions** | `chmod 600` (owner read/write only) |

#### Usage Examples

```bash
# Single password file for both connections
./t-pgsql dump --from "postgres@localhost/mydb" --password-file .secrets/db.pass

# Separate password files for source and target
./t-pgsql clone \
  --from "ssh://user@server/postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/dev.pass
```

### 2. Environment Variable

```bash
# Single password for both connections
export T_PGSQL_PASSWORD="supersecret"
./t-pgsql dump --from "postgres@localhost/mydb"

# Separate passwords for source and target
export T_PGSQL_FROM_PASSWORD="prod_pass"
export T_PGSQL_TO_PASSWORD="local_pass"
./t-pgsql clone --from "..." --to "..."

# Using in scripts (password not visible in ps)
T_PGSQL_PASSWORD="secret" ./t-pgsql dump --from "postgres@localhost/mydb"
```

| Environment Variable | Description |
|---------------------|-------------|
| `T_PGSQL_PASSWORD` | Password for both connections |
| `T_PGSQL_FROM_PASSWORD` | Source connection password |
| `T_PGSQL_TO_PASSWORD` | Target connection password |

### 3. Interactive Prompt

If no password is specified, prompts securely from terminal:

```bash
./t-pgsql dump --from "postgres@localhost/mydb"
# FROM password: ********  (input is hidden)
```

> **Note:** Interactive prompt only works in terminal (TTY). For scripts and cron jobs, use password files or environment variables.

### Password Priority Order

When multiple password sources are available, t-pgsql uses this priority:

1. **Direct parameter** (`--password`, `--from-password`, `--to-password`)
2. **Environment variable** (`T_PGSQL_PASSWORD`, etc.)
3. **Password file** (`--password-file`, etc.)
4. **Interactive prompt** (if TTY available)

### Security Best Practices

| Practice | Description |
|----------|-------------|
| Use `.gitignore` | Never commit password files to git |
| Use `chmod 600` | Restrict file access to owner only |
| Use `chmod 700` | Restrict directory access to owner only |
| Avoid `--password` | Don't use direct password in command line |
| Use separate files | Use different files for prod/dev environments |
| Rotate passwords | Regularly update password files |

---

## Complete Parameter Reference

### Connection Parameters

| Parameter | Description | Default | Required | Example |
|-----------|-------------|---------|----------|---------|
| `--from <conn>` | Source database connection string | - | Yes (dump/clone) | `postgres@localhost/mydb` |
| `--to <conn>` | Target database connection string (repeatable for multiple targets) | - | Yes (restore/clone) | `ssh://user@host/db` |

**Connection String Formats:**
- Local: `[user@]host[:port]/database`
- SSH: `ssh://[ssh_user@]ssh_host[:ssh_port]/[db_user@]db_host[:db_port]/database`

### Password Parameters

| Parameter | Description | Default | Required | Example |
|-----------|-------------|---------|----------|---------|
| `--password <pass>` | Password for both source and target | - | No | `mysecret` |
| `--from-password <pass>` | Password for source connection only | - | No | `srcpass` |
| `--to-password <pass>` | Password for target connection only | - | No | `dstpass` |
| `--password-file <file>` | Read password from file (both connections) | - | No | `.secrets/db.pass` |
| `--from-password-file <file>` | Read source password from file | - | No | `.secrets/from.pass` |
| `--to-password-file <file>` | Read target password from file | - | No | `.secrets/to.pass` |
| `--config <file>` | Configuration file with credentials | - | No | `config.yaml` |

**Environment Variables:**
- `T_PGSQL_PASSWORD` - Password for both connections
- `T_PGSQL_FROM_PASSWORD` - Source password
- `T_PGSQL_TO_PASSWORD` - Target password

### Filtering Parameters

| Parameter | Description | Default | Required | Example |
|-----------|-------------|---------|----------|---------|
| `--exclude-table <tables>` | Comma-separated tables to exclude | - | No | `logs,sessions,temp` |
| `--exclude-schema <schemas>` | Comma-separated schemas to exclude | - | No | `audit,temp` |
| `--exclude-data <tables>` | Exclude data but keep structure (supports `schema.*` wildcard) | - | No | `audit.*,logs` |
| `--only-table <tables>` | Include only these tables | - | No | `users,orders` |
| `--only-schema <schemas>` | Include only these schemas | - | No | `public,app` |

### Compression Parameters

| Parameter | Description | Default | Required | Example |
|-----------|-------------|---------|----------|---------|
| `--compress <type>` | Compression algorithm | `gzip` | No | `zstd`, `xz`, `bzip2`, `none` |
| `--compress-level <1-9>` | Compression level | `6` | No | `9` |
| `--pg-compress-level <0-9>` | pg_dump internal compression | `6` | No | `0` (no compression) |

### Storage Parameters

| Parameter | Description | Default | Required | Example |
|-----------|-------------|---------|----------|---------|
| `--output <dir>` | Output directory for dumps | `./data/dumps` | No | `/backups/daily` |
| `--keep <N>` | Number of local dumps to keep | `-1` (all) | No | `7`, `0` (delete), `-1` (all) |
| `--from-keep <N>` | Number of dumps to keep on source | `1` | No | `3`, `0` (delete), `-1` (all) |
| `--dump-name <name>` | Custom dump filename (without timestamp) | Database name | No | `myapp-backup` |
| `--file <path>` | Specific dump file for restore | - | No | `./dumps/backup.tar.gz` |
| `--from-file [pattern]` | Fetch existing dump (no value = latest) | - | No | `mydb_*.dump` |

### Retention Parameters (GFS - Grandfather-Father-Son)

| Parameter | Description | Default | Required | Example |
|-----------|-------------|---------|----------|---------|
| `--retention` | Enable GFS retention policy | `false` | No | - |
| `--retention-daily <N>` | Daily backups to keep | `7` | No | `14` |
| `--retention-weekly <N>` | Weekly backups to keep | `4` | No | `8` |
| `--retention-monthly <N>` | Monthly backups to keep | `12` | No | `24` |
| `--retention-yearly <N>` | Yearly backups to keep | `3` | No | `5` |

### Health Check Parameters

| Parameter | Description | Default | Required | Example |
|-----------|-------------|---------|----------|---------|
| `--health-check` | Check database before operation | `true` | No | - |
| `--health-check-after` | Check database after operation | `false` | No | - |
| `--no-health-check` | Disable all health checks | `false` | No | - |
| `--health-check-fail` | Abort on health check failure | `false` | No | - |

### Notification Parameters

| Parameter | Description | Default | Required | Example |
|-----------|-------------|---------|----------|---------|
| `--notify <channel>` | Notification channel (repeatable) | - | No | `telegram:TOKEN:CHAT` |
| `--notify-on-error` | Only notify on errors | `false` | No | - |
| `--notify-summary` | Send summary after batch | `false` | No | - |

**Supported Channels:** `telegram`, `slack:URL`, `webhook:URL`, `email:ADDRESS`

### Data Masking Parameters

| Parameter | Description | Default | Required | Example |
|-----------|-------------|---------|----------|---------|
| `--mask` | Enable data masking | `false` | No | - |
| `--mask-rules <file>` | JSON file with masking rules | - | No | `mask-rules.json` |
| `--mask-tables <tables>` | Tables to apply masking | - | No | `users,customers` |

### Streaming Parameters

| Parameter | Description | Default | Required | Example |
|-----------|-------------|---------|----------|---------|
| `--stream` | Stream mode (no temp files) | `false` | No | - |
| `--stream-buffer <MB>` | Buffer size in megabytes | `64` | No | `128` |

### Batch Parameters

| Parameter | Description | Default | Required | Example |
|-----------|-------------|---------|----------|---------|
| `--save <name>` | Save current command as a job | - | No | `daily_backup` |
| `--batch <name\|all>` | Run saved job(s) | - | No | `daily_backup`, `all` |
| `--parallel <N>` | Number of parallel jobs | `1` | No | `4` |
| `--continue-on-error` | Continue batch on job failure | `false` | No | - |
| `--only <jobs>` | Run only these jobs from batch | - | No | `job1,job2` |
| `--exclude <jobs>` | Skip these jobs from batch | - | No | `slow_job` |

### General Parameters

| Parameter | Description | Default | Required | Example |
|-----------|-------------|---------|----------|---------|
| `-f, --force` | Drop and recreate existing database | `false` | No | - |
| `-v, --verbose` | Show detailed output | `false` | No | - |
| `-q, --quiet` | Minimal output | `false` | No | - |
| `-y, --yes` | Skip all confirmations | `false` | No | - |
| `--dry-run` | Show what would be done without executing | `false` | No | - |
| `--sudo` | Use sudo for database operations | `false` | No | - |
| `--log <file>` | Write logs to file | - | No | `/var/log/t-pgsql.log` |
| `--log-level <level>` | Log verbosity level | `info` | No | `debug`, `warn`, `error` |
| `--no-meta` | Don't write metadata to archives | `false` | No | - |
| `-h, --help` | Show help message | - | No | - |
| `--version` | Show version number | - | No | - |

### Internal Default Values

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `FROM_DB_USER` | `postgres` | Default database user |
| `FROM_DB_HOST` | `localhost` | Default database host |
| `FROM_DB_PORT` | `5432` | Default PostgreSQL port |
| `FROM_SSH_PORT` | `22` | Default SSH port |

---

## Practical Examples

### Daily Backup

```bash
# For cron job
0 2 * * * /path/to/t-pgsql dump \
  --from "ssh://user@prod/postgres@localhost/app" \
  --from-password-file /path/to/.secrets/prod.pass \
  --output /backups/daily \
  --keep 7 \
  --from-keep 1 \
  >> /var/log/t-pgsql.log 2>&1
```

### Development Environment Sync

```bash
# Clone from prod to dev
./t-pgsql clone \
  --from "ssh://asimatasert@prod.example.com/postgres@localhost/production" \
  --to "postgres@localhost/development" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --exclude-table "logs,sessions,audit_trail" \
  --force

# Save as job
./t-pgsql clone ... --save prod_to_dev

# Repeat with single command
./t-pgsql --batch prod_to_dev
```

### Deploy to Multiple Environments

```bash
./t-pgsql clone \
  --from "ssh://asimatasert@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev" \
  --to "postgres@localhost/staging" \
  --to "postgres@localhost/test" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --force
```

### Exclude Large Tables

```bash
./t-pgsql dump \
  --from "postgres@localhost/analytics" \
  --password-file .secrets/db.pass \
  --exclude-data "raw_events,page_views,click_stream" \
  --output ./dumps
```

---

## File Structure

```
t-pgsql/
├── t-pgsql              # Main script
├── jobs.yaml           # Batch job definitions
├── README.md           # This document
├── README_TR.md        # Turkish documentation
├── .secrets/           # Password files
│   ├── from.pass
│   └── to.pass
└── dumps/              # Dump files
    ├── mydb_20251230_143022.tar.gz
    └── prod_20251229_090000.tar.gz
```

---

## Troubleshooting

### SSH Connection Error

```bash
# Test SSH access
ssh awesome@192.168.1.31 "echo ok"

# Run with verbose mode
./t-pgsql dump --from "ssh://..." -v
```

### Password Error

```bash
# Check password file
cat .secrets/db.pass | xxd  # Should have no newline

# Fix it
echo -n "password" > .secrets/db.pass
```

### Database Already Exists Error

```bash
# Use --force to drop existing DB
./t-pgsql restore --to "..." --force
```

### Permission Denied

```bash
# Password file permissions
chmod 600 .secrets/*.pass
```

---

## License

MIT License

## Contributing

Pull requests are welcome.
