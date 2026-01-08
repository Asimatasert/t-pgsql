#!/bin/bash
#
# t-pgsql installer
# Usage: curl -fsSL https://raw.githubusercontent.com/Asimatasert/t-pgsql/master/install.sh | bash
#
# Options:
#   INSTALL_DIR=/path    - Installation directory (default: /usr/local/bin)
#   VERSION=v3.3.0       - Specific version (default: latest)
#   SKIP_COMPLETIONS=1   - Skip completion installation
#

set -e

REPO="Asimatasert/t-pgsql"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${VERSION:-latest}"
SKIP_COMPLETIONS="${SKIP_COMPLETIONS:-0}"
MANDIR="/usr/local/share/man/man1"
ZSHDIR="/usr/local/share/zsh/site-functions"
BASHDIR="/usr/local/share/bash-completion/completions"
FISHDIR="/usr/local/share/fish/vendor_completions.d"

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

    # Install completions and man page
    if [[ "$SKIP_COMPLETIONS" != "1" ]]; then
        install_extras
    fi

    # Check dependencies
    check_deps

    echo ""
    info "Usage: t-pgsql --help"
    info "Man page: man t-pgsql"
}

# Install completions and man page
install_extras() {
    info "Installing shell completions and man page..."

    RAW_URL="https://raw.githubusercontent.com/${REPO}/${VERSION}"

    # Man page
    if [[ -d "$(dirname $MANDIR)" ]]; then
        info "Installing man page..."
        curl -fsSL "$RAW_URL/man/t-pgsql.1" -o "$TMP_DIR/t-pgsql.1" 2>/dev/null || true
        if [[ -f "$TMP_DIR/t-pgsql.1" ]]; then
            if [[ -w "$MANDIR" ]] 2>/dev/null; then
                mkdir -p "$MANDIR"
                mv "$TMP_DIR/t-pgsql.1" "$MANDIR/t-pgsql.1"
            else
                sudo mkdir -p "$MANDIR"
                sudo mv "$TMP_DIR/t-pgsql.1" "$MANDIR/t-pgsql.1"
            fi
        fi
    fi

    # Zsh completion
    if command -v zsh >/dev/null 2>&1; then
        info "Installing zsh completion..."
        curl -fsSL "$RAW_URL/completions/_t-pgsql" -o "$TMP_DIR/_t-pgsql" 2>/dev/null || true
        if [[ -f "$TMP_DIR/_t-pgsql" ]]; then
            if [[ -w "$ZSHDIR" ]] 2>/dev/null; then
                mkdir -p "$ZSHDIR"
                mv "$TMP_DIR/_t-pgsql" "$ZSHDIR/_t-pgsql"
            else
                sudo mkdir -p "$ZSHDIR"
                sudo mv "$TMP_DIR/_t-pgsql" "$ZSHDIR/_t-pgsql"
            fi
        fi
    fi

    # Bash completion
    if command -v bash >/dev/null 2>&1; then
        info "Installing bash completion..."
        curl -fsSL "$RAW_URL/completions/t-pgsql.bash" -o "$TMP_DIR/t-pgsql.bash" 2>/dev/null || true
        if [[ -f "$TMP_DIR/t-pgsql.bash" ]]; then
            if [[ -w "$BASHDIR" ]] 2>/dev/null; then
                mkdir -p "$BASHDIR"
                mv "$TMP_DIR/t-pgsql.bash" "$BASHDIR/t-pgsql"
            else
                sudo mkdir -p "$BASHDIR"
                sudo mv "$TMP_DIR/t-pgsql.bash" "$BASHDIR/t-pgsql"
            fi
        fi
    fi

    # Fish completion
    if command -v fish >/dev/null 2>&1; then
        info "Installing fish completion..."
        curl -fsSL "$RAW_URL/completions/t-pgsql.fish" -o "$TMP_DIR/t-pgsql.fish" 2>/dev/null || true
        if [[ -f "$TMP_DIR/t-pgsql.fish" ]]; then
            # Prefer user directory (no sudo needed)
            USER_FISHDIR="$HOME/.config/fish/completions"
            mkdir -p "$USER_FISHDIR" 2>/dev/null
            if [[ -d "$USER_FISHDIR" ]]; then
                cp "$TMP_DIR/t-pgsql.fish" "$USER_FISHDIR/t-pgsql.fish"
                info "Fish completion installed to $USER_FISHDIR"
            elif [[ -w "$FISHDIR" ]] 2>/dev/null; then
                mkdir -p "$FISHDIR"
                mv "$TMP_DIR/t-pgsql.fish" "$FISHDIR/t-pgsql.fish"
            else
                sudo mkdir -p "$FISHDIR" 2>/dev/null && \
                sudo mv "$TMP_DIR/t-pgsql.fish" "$FISHDIR/t-pgsql.fish" || \
                warn "Could not install fish completion"
            fi
        fi
    fi
}

main "$@"
