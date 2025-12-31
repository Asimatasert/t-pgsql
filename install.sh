#!/bin/bash
#
# t-pgsql installer
# Usage: curl -fsSL https://raw.githubusercontent.com/Asimatasert/t-pgsql/master/install.sh | bash
#

set -e

REPO="Asimatasert/t-pgsql"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${VERSION:-latest}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check dependencies
check_deps() {
    local missing=()

    command -v pg_dump >/dev/null 2>&1 || missing+=("postgresql-client")
    command -v ssh >/dev/null 2>&1 || missing+=("openssh-client")

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing dependencies: ${missing[*]}"
        warn "Please install them before using t-pgsql"
    fi
}

# Detect OS
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    else
        echo "unknown"
    fi
}

# Get latest version
get_latest_version() {
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | \
        grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' || echo "master"
}

# Main install
main() {
    info "Installing t-pgsql..."

    OS=$(detect_os)
    info "Detected OS: $OS"

    # Get version
    if [[ "$VERSION" == "latest" ]]; then
        VERSION=$(get_latest_version)
    fi
    info "Version: $VERSION"

    # Create temp directory
    TMP_DIR=$(mktemp -d)
    trap "rm -rf $TMP_DIR" EXIT

    # Download
    info "Downloading t-pgsql..."
    if [[ "$VERSION" == "master" ]]; then
        DOWNLOAD_URL="https://raw.githubusercontent.com/${REPO}/master/t-pgsql"
    else
        DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/t-pgsql"
    fi

    curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DIR/t-pgsql" || \
        curl -fsSL "https://raw.githubusercontent.com/${REPO}/master/t-pgsql" -o "$TMP_DIR/t-pgsql"

    chmod +x "$TMP_DIR/t-pgsql"

    # Install
    info "Installing to $INSTALL_DIR..."
    if [[ -w "$INSTALL_DIR" ]]; then
        mv "$TMP_DIR/t-pgsql" "$INSTALL_DIR/t-pgsql"
    else
        sudo mv "$TMP_DIR/t-pgsql" "$INSTALL_DIR/t-pgsql"
    fi

    # Verify
    if command -v t-pgsql >/dev/null 2>&1; then
        info "t-pgsql installed successfully!"
        t-pgsql --version 2>/dev/null || true
    else
        warn "t-pgsql installed to $INSTALL_DIR/t-pgsql"
        warn "Make sure $INSTALL_DIR is in your PATH"
    fi

    # Check dependencies
    check_deps

    echo ""
    info "Usage: t-pgsql --help"
}

main "$@"
