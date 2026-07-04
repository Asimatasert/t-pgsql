#!/bin/bash
#
# t-pgsql installer
# Usage: curl -fsSL https://raw.githubusercontent.com/Asimatasert/t-pgsql/master/install.sh | bash
#
# Options:
#   INSTALL_DIR=/path    - Installation directory (default: /usr/local/bin)
#   VERSION=v3.9.0       - Specific version (default: latest)
#   SKIP_COMPLETIONS=1   - Skip completion installation
#   UNINSTALL=1          - Remove t-pgsql and all installed files
#

set -e

REPO="Asimatasert/t-pgsql"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${VERSION:-latest}"
SKIP_COMPLETIONS="${SKIP_COMPLETIONS:-0}"
UNINSTALL="${UNINSTALL:-0}"

# Support --uninstall flag as well as UNINSTALL=1
for arg in "$@"; do
    case "$arg" in
        --uninstall) UNINSTALL=1 ;;
    esac
done

# Choose man/completion directories based on install location.
# When INSTALL_DIR is under $HOME we do a rootless install into user dirs
# (no sudo); otherwise we use the system-wide /usr/local paths.
HOME_DIR="${HOME:-$(eval echo ~"$USER")}"
if [[ -n "$HOME_DIR" && "$INSTALL_DIR" == "$HOME_DIR"* ]]; then
    ROOTLESS=1
    MANDIR="$HOME_DIR/.local/share/man/man1"
    ZSHDIR="$HOME_DIR/.local/share/zsh/site-functions"
    BASHDIR="$HOME_DIR/.local/share/bash-completion/completions"
    FISHDIR="$HOME_DIR/.config/fish/completions"
else
    ROOTLESS=0
    MANDIR="/usr/local/share/man/man1"
    ZSHDIR="/usr/local/share/zsh/site-functions"
    BASHDIR="/usr/local/share/bash-completion/completions"
    FISHDIR="/usr/local/share/fish/vendor_completions.d"
fi

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
    local v
    # The trailing sed always exits 0, so a "|| echo master" on the pipe would
    # never trigger on API failure. Capture the value and default it instead.
    v=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | \
        grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$v" ]]; then
        v="master"
    fi
    echo "$v"
}

# Move a file into a destination, using sudo only when needed
install_file() {
    local src="$1" dst="$2" destdir
    destdir="$(dirname "$dst")"
    if [[ -w "$destdir" ]] 2>/dev/null || mkdir -p "$destdir" 2>/dev/null; then
        mkdir -p "$destdir"
        mv "$src" "$dst"
    else
        sudo mkdir -p "$destdir"
        sudo mv "$src" "$dst"
    fi
}

# Verify the downloaded binary against a SHA256SUMS release asset, if present.
verify_integrity() {
    local bin="$1"
    # master (raw) downloads have no published checksum asset
    if [[ "$VERSION" == "master" ]]; then
        warn "Binary integrity is NOT verified (installing from master/raw)."
        return
    fi

    local sums_url="https://github.com/${REPO}/releases/download/${VERSION}/SHA256SUMS"
    if ! curl -fsSL "$sums_url" -o "$TMP_DIR/SHA256SUMS" 2>/dev/null; then
        warn "No SHA256SUMS asset found for ${VERSION}; binary is UNVERIFIED."
        return
    fi

    local expected actual
    expected=$(grep -E '[[:space:]]\*?t-pgsql$' "$TMP_DIR/SHA256SUMS" | awk '{print $1}' | head -n1)
    if [[ -z "$expected" ]]; then
        warn "SHA256SUMS present but has no entry for t-pgsql; binary is UNVERIFIED."
        return
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$bin" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$bin" | awk '{print $1}')
    else
        warn "No sha256sum/shasum available; binary is UNVERIFIED."
        return
    fi

    if [[ "$actual" == "$expected" ]]; then
        info "Checksum verified (SHA256)."
    else
        error "Checksum mismatch! expected=$expected actual=$actual. Aborting."
    fi
}

# Main install
main() {
    if [[ "$UNINSTALL" == "1" ]]; then
        uninstall
        return
    fi

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

    if ! curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DIR/t-pgsql"; then
        if [[ "$VERSION" != "master" ]]; then
            warn "======================================================================"
            warn "Could not download the pinned asset for ${VERSION}."
            warn "Falling back to the 'master' branch. This is NOT the requested"
            warn "version and the binary and extras will come from master instead."
            warn "======================================================================"
            VERSION="master"
        fi
        curl -fsSL "https://raw.githubusercontent.com/${REPO}/master/t-pgsql" -o "$TMP_DIR/t-pgsql"
    fi

    chmod +x "$TMP_DIR/t-pgsql"

    # Integrity check
    verify_integrity "$TMP_DIR/t-pgsql"

    # Install
    info "Installing to $INSTALL_DIR..."
    install_file "$TMP_DIR/t-pgsql" "$INSTALL_DIR/t-pgsql"

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
    info "Installing man page..."
    curl -fsSL "$RAW_URL/man/t-pgsql.1" -o "$TMP_DIR/t-pgsql.1" 2>/dev/null || true
    if [[ -f "$TMP_DIR/t-pgsql.1" ]]; then
        install_file "$TMP_DIR/t-pgsql.1" "$MANDIR/t-pgsql.1"
    fi

    # Zsh completion
    if command -v zsh >/dev/null 2>&1; then
        info "Installing zsh completion..."
        curl -fsSL "$RAW_URL/completions/_t-pgsql" -o "$TMP_DIR/_t-pgsql" 2>/dev/null || true
        if [[ -f "$TMP_DIR/_t-pgsql" ]]; then
            install_file "$TMP_DIR/_t-pgsql" "$ZSHDIR/_t-pgsql"
        fi
    fi

    # Bash completion
    if command -v bash >/dev/null 2>&1; then
        info "Installing bash completion..."
        curl -fsSL "$RAW_URL/completions/t-pgsql.bash" -o "$TMP_DIR/t-pgsql.bash" 2>/dev/null || true
        if [[ -f "$TMP_DIR/t-pgsql.bash" ]]; then
            install_file "$TMP_DIR/t-pgsql.bash" "$BASHDIR/t-pgsql"
        fi
    fi

    # Fish completion (always into the user config dir; no sudo needed)
    if command -v fish >/dev/null 2>&1; then
        info "Installing fish completion..."
        curl -fsSL "$RAW_URL/completions/t-pgsql.fish" -o "$TMP_DIR/t-pgsql.fish" 2>/dev/null || true
        if [[ -f "$TMP_DIR/t-pgsql.fish" ]]; then
            USER_FISHDIR="$HOME_DIR/.config/fish/completions"
            if [[ -n "$USER_FISHDIR" ]] && mkdir -p "$USER_FISHDIR" 2>/dev/null; then
                cp "$TMP_DIR/t-pgsql.fish" "$USER_FISHDIR/t-pgsql.fish"
                info "Fish completion installed to $USER_FISHDIR"
            elif [[ -w "$FISHDIR" ]] 2>/dev/null; then
                mkdir -p "$FISHDIR"
                mv "$TMP_DIR/t-pgsql.fish" "$FISHDIR/t-pgsql.fish"
            else
                sudo mkdir -p "$FISHDIR" 2>/dev/null && \
                sudo mv "$TMP_DIR/t-pgsql.fish" "$FISHDIR/t-pgsql.fish" || \
                warn "Could not install fish completion. Run: mkdir -p ~/.config/fish/completions && curl -fsSL $RAW_URL/completions/t-pgsql.fish -o ~/.config/fish/completions/t-pgsql.fish"
            fi
        fi
    fi
}

# Remove everything the installer places
remove_file() {
    local f="$1"
    [[ -e "$f" ]] || return 0
    if [[ -w "$(dirname "$f")" ]] 2>/dev/null; then
        rm -f "$f" && info "Removed $f"
    else
        sudo rm -f "$f" && info "Removed $f"
    fi
}

uninstall() {
    info "Uninstalling t-pgsql..."
    remove_file "$INSTALL_DIR/t-pgsql"
    remove_file "$MANDIR/t-pgsql.1"
    remove_file "$ZSHDIR/_t-pgsql"
    remove_file "$BASHDIR/t-pgsql"
    remove_file "$FISHDIR/t-pgsql.fish"
    # Fish is always installed to the user config dir; remove it too.
    remove_file "$HOME_DIR/.config/fish/completions/t-pgsql.fish"
    # Also clean up the system-wide locations in case of a prior root install.
    remove_file "/usr/local/bin/t-pgsql"
    remove_file "/usr/local/share/man/man1/t-pgsql.1"
    remove_file "/usr/local/share/zsh/site-functions/_t-pgsql"
    remove_file "/usr/local/share/bash-completion/completions/t-pgsql"
    remove_file "/usr/local/share/fish/vendor_completions.d/t-pgsql.fish"
    info "Uninstall complete."
}

main "$@"
