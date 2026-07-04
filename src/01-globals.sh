# ==============================================================================
# DEFAULT VALUES
# ==============================================================================

# Command
COMMAND=""

# Connection
FROM_CONNECTION=""
TO_CONNECTIONS=()

# Password
FROM_PASSWORD=""
TO_PASSWORD=""
PASSWORD=""
FROM_PASSWORD_FILE=""
TO_PASSWORD_FILES=()
PASSWORD_FILE=""

# Config
CONFIG_FILE=""

# Filtering
EXCLUDE_TABLES=""
EXCLUDE_SCHEMAS=""
EXCLUDE_DATA=""
ONLY_TABLES=""
ONLY_SCHEMAS=""

# Compression
COMPRESS="gzip"
COMPRESS_LEVEL=6
PG_COMPRESS_LEVEL=6
PG_COMPRESS_LEVEL_SET=false  # true if --pg-compress-level passed on CLI

# Storage
OUTPUT_DIR="${T_PGSQL_OUTPUT_DIR:-${SCRIPT_DIR}/../data/dumps}"
OUTPUT_DIR_SET=false          # true once --output is given on the CLI (beats config/env)
KEEP_SET=false                # true once --keep given on CLI (beats config)
FROM_KEEP_SET=false           # true once --from-keep given on CLI
COMPRESS_SET=false            # true once --compress given on CLI
KEEP=-1
FROM_KEEP=1  # 0=delete, N=keep last N, -1=keep all (default: 1)
SKIP_IF_RECENT=""  # Skip if dump exists within timeframe (e.g., 24h, 12h, today)

# Retention (GFS)
RETENTION=false
RETENTION_DAILY=7
RETENTION_WEEKLY=4
RETENTION_MONTHLY=12
RETENTION_YEARLY=3

# Health Check
HEALTH_CHECK=true
HEALTH_CHECK_AFTER=false
HEALTH_CHECK_FAIL=false

# Notifications
NOTIFY=()
NOTIFY_ON_ERROR=false

# Masking
MASK=false
MASK_RULES=""
MASK_TABLES=""

# Streaming
STREAM=false
STREAM_BUFFER=64

# Sudo
SUDO=false

# Common SSH options for transfers: fail fast on connect, and detect a stalled
# link (e.g. a dropped Tailscale route) within ~60s instead of hanging forever.
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

# Transfer resilience / throttling (SSH scp + streaming)
BWLIMIT=""                    # human rate: 10m (MByte/s), 500k (KByte/s), or bare KByte/s
BWLIMIT_KBIT=""               # derived: scp -l wants Kbit/s
PV_RATE=""                    # derived: pv -L rate for streaming clone
RETRIES=0                     # extra retries for scp transfers on failure

# Migration / upgrade
GLOBALS=false                 # also migrate cluster globals (roles, tablespaces)
PG_BINDIR=""                  # dir prepended to PATH so a specific PostgreSQL
                              # client version is used (e.g. dump an old server
                              # with the target major version's tools)

# Batch
PARALLEL=1
PARALLEL_SET=false            # true if --parallel passed on CLI
CONTINUE_ON_ERROR=false
CONTINUE_ON_ERROR_SET=false   # true if --continue-on-error passed on CLI
ONLY_JOBS=""
EXCLUDE_JOBS=""
NOTIFY_SUMMARY=false
SAVE_JOB=""
BATCH_JOB=""
BOT_TOKEN=""
BOT_COOLDOWN="1h"
# Name of the job currently running; inherited from the environment when a job
# re-execs the script, so failure notifications can attach a "re-run" button
# targeting the specific job.
CURRENT_JOB_NAME="${CURRENT_JOB_NAME:-}"
JOBS_FILE="${JOBS_FILE:-${SCRIPT_DIR}/jobs.yaml}"
JOBS_ACTION=""
JOBS_TARGET=""

# General
VERBOSE=false
QUIET=false
DRY_RUN=false
YES=false
FORCE=false
LOG_FILE=""
LOG_LEVEL="info"

# Restore
FILE=""

# Clean (optional positional database/base-name for the "clean" command)
CLEAN_DB=""

# Custom dump base name (also usable by "clean")
DUMP_NAME=""

# Fetch (existing dump from source)
FROM_FILE=""

# Metadata & Timing
META_ENABLED=true
META_START_TIME=""
META_START_EPOCH=""
META_STATUS="unknown"
META_EXIT_CODE=0

# ==============================================================================
# PARSED CONNECTION VARIABLES
# ==============================================================================
FROM_TYPE=""
FROM_SSH_USER=""
FROM_SSH_HOST=""
FROM_SSH_PORT="22"
FROM_DB_USER="postgres"
FROM_DB_HOST="localhost"
FROM_DB_PORT="5432"
FROM_DB_PASSWORD=""
FROM_DATABASE=""

TO_TYPE=""
TO_SSH_USER=""
TO_SSH_HOST=""
TO_SSH_PORT="22"
TO_DB_USER="postgres"
TO_DB_HOST="localhost"
TO_DB_PORT="5432"
TO_DB_PASSWORD=""
TO_DATABASE=""

# ==============================================================================
# SOURCE MODULES
# ==============================================================================
source_module() {
    local module="$1"
    local module_path="${SCRIPT_DIR}/modules/${module}.sh"
    if [ -f "$module_path" ]; then
        source "$module_path"
    fi
}

