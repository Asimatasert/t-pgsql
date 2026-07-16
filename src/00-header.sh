#!/bin/bash
#
# t-pgsql - PostgreSQL Database Sync & Clone Tool
# https://github.com/Asimatasert/t-pgsql
#
# Usage: t-pgsql <command> [options]
#
# ┌────────────────────────────────────────────────────────────────────────────┐
# │ GENERATED FILE — do not edit directly.                                     │
# │ Sources live in src/*.sh; rebuild with `./build.sh` (or `make build`).     │
# │ Order is defined by src/build.manifest. CI runs `./build.sh --check`.      │
# └────────────────────────────────────────────────────────────────────────────┘
#

# NOTE: 'set -e' (errexit) intentionally NOT enabled. This script uses explicit
# "cmd; result=$?; if ...; else <failure handling> fi" patterns, background-job
# .exit tracking, and multi-target/--continue-on-error logic throughout. Under
# errexit those failure branches would abort the script before running, making
# all error-handling dead code. Failures are handled explicitly instead.

# ==============================================================================
# VERSION & PATHS
# ==============================================================================
VERSION="3.10.0"
SCRIPT_NAME="t-pgsql"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# COLORS
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

