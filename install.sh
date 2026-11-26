#!/bin/bash
#
# t-pgsql installer
# Usage: curl -fsSL https://raw.githubusercontent.com/Asimatasert/t-pgsql/master/install.sh | bash
#
# Options:
#   INSTALL_DIR=/path    - Installation directory (default: /usr/local/bin)
#   VERSION=v3.15.0      - Specific release tag (default: latest release)
#   SKIP_COMPLETIONS=1   - Skip completion installation
#   UNINSTALL=1          - Remove t-pgsql and all installed files
#
#   T_PGSQL_ALLOW_UNVERIFIED=1  (or the --allow-unverified flag)
#                        - Install even when the release has no usable
#                          SHA256SUMS entry, or from the unreleased master
#                          branch (VERSION=master). Prints a warning. A
#                          checksum MISMATCH always aborts.
#                          With a pipe: ... | bash -s -- --allow-unverified
#
# The installer is fail-closed: the binary is verified against the SHA256SUMS
# asset of the same release before anything is installed, and the man page and
# completions are taken from the verified release tarball.
#

set -e

REPO="Asimatasert/t-pgsql"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${VERSION:-latest}"
SKIP_COMPLETIONS="${SKIP_COMPLETIONS:-0}"
UNINSTALL="${UNINSTALL:-0}"
ALLOW_UNVERIFIED="${T_PGSQL_ALLOW_UNVERIFIED:-0}"

# Support --uninstall flag as well as UNINSTALL=1
for arg in "$@"; do
    case "$arg" in
        --uninstall) UNINSTALL=1 ;;
        --allow-unverified) ALLOW_UNVERIFIED=1 ;;
    esac
done

# Choose man/completion directories based on install location.
# When INSTALL_DIR is under $HOME we do a rootless install into user dirs
# (no sudo); otherwise we use the system-wide /usr/local paths.
HOME_DIR="${HOME:-$(eval echo ~"$USER")}"
if [[ -n "$HOME_DIR" && ( "$INSTALL_DIR" == "$HOME_DIR" || "$INSTALL_DIR" == "$HOME_DIR"/* ) ]]; then
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
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

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

# Download URL to a file: fail on HTTP errors, HTTPS only, TLS 1.2+.
fetch() {
    curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        "$1" -o "$2"
}

# Resolve the latest release tag. Never falls back to another ref.
get_latest_version() {
    local v
    if ! fetch "https://api.github.com/repos/${REPO}/releases/latest" "$TMP_DIR/latest.json" 2>/dev/null; then
        error "Could not query the latest release from GitHub (network error or API rate limit). Retry later or pin one with VERSION=vX.Y.Z"
    fi
    v=$(grep '"tag_name"' "$TMP_DIR/latest.json" | sed -E 's/.*"tag_name"[^"]*"([^"]+)".*/\1/' | head -n1)
    [[ -n "$v" ]] || error "GitHub did not return a release tag (unexpected response). Pin one with VERSION=vX.Y.Z"
    echo "$v"
}

# Install a file with the given mode. sudo is used only here, for the final
# install step, and only when the destination is not writable by this user.
install_file() {
    local src="$1" dst="$2" mode="${3:-0644}" destdir
    destdir="$(dirname "$dst")"
    if mkdir -p "$destdir" 2>/dev/null && [[ -w "$destdir" ]]; then
        install -m "$mode" "$src" "$dst"
    else
        sudo install -d -m 0755 "$destdir"
        sudo install -m "$mode" "$src" "$dst"
    fi
}

# Print the SHA-256 of a file; return 1 when no hashing tool exists.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

# Abort unless the user explicitly opted in to unverified installs.
require_unverified_optin() {
    if [[ "$ALLOW_UNVERIFIED" == "1" ]]; then
        warn "$1"
        warn "Continuing UNVERIFIED because --allow-unverified / T_PGSQL_ALLOW_UNVERIFIED=1 was given."
    else
        error "$1 Refusing to install. To install an unverified build anyway, re-run with --allow-unverified or T_PGSQL_ALLOW_UNVERIFIED=1."
    fi
}

# Verify a downloaded asset against $TMP_DIR/SHA256SUMS (exact file-name match).
# A missing sums file is only reachable after the opt-in was accepted.
verify_asset() {
    local file="$1" name="$2" expected actual
    [[ -f "$TMP_DIR/SHA256SUMS" ]] || return 0

    expected=$(awk -v n="$name" '{f=$2; sub(/^\*/, "", f); if (f == n) {print $1; exit}}' "$TMP_DIR/SHA256SUMS")
    if [[ -z "$expected" ]]; then
        require_unverified_optin "SHA256SUMS has no entry for $name."
        return 0
    fi
    if ! actual=$(sha256_of "$file"); then
        require_unverified_optin "No sha256sum/shasum available to verify $name."
        return 0
    fi
    if [[ "$actual" == "$expected" ]]; then
        info "Checksum verified (SHA256): $name"
    else
        error "Checksum mismatch for $name! expected=$expected actual=$actual. Nothing was installed."
    fi
}

# Normalise and validate the requested version (also keeps it URL-safe).
check_version() {
    [[ "$VERSION" == "master" ]] && return 0
    [[ "$VERSION" =~ ^[0-9] ]] && VERSION="v$VERSION"
    [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.+-]*)?$ ]] || \
        error "Invalid VERSION '$VERSION' (expected vX.Y.Z)."
}

# Download the binary (and the sums + tarball for releases) and verify all
# of it BEFORE anything is installed.
download_and_verify() {
    local num tarball d m
    if [[ "$VERSION" == "master" ]]; then
        require_unverified_optin "VERSION=master (unreleased branch) has no published checksums."
        fetch "https://raw.githubusercontent.com/${REPO}/master/t-pgsql" "$TMP_DIR/t-pgsql" || \
            error "Could not download t-pgsql from master."
    else
        local base="https://github.com/${REPO}/releases/download/${VERSION}"
        fetch "$base/t-pgsql" "$TMP_DIR/t-pgsql" || \
            error "Could not download t-pgsql ${VERSION} (no such release asset?). Not falling back to another version."
        if ! fetch "$base/SHA256SUMS" "$TMP_DIR/SHA256SUMS" 2>/dev/null; then
            rm -f "$TMP_DIR/SHA256SUMS"
            require_unverified_optin "Release ${VERSION} has no SHA256SUMS asset."
        fi
    fi

    # A GitHub HTML error page would not start with a shebang.
    [[ "$(head -c 2 "$TMP_DIR/t-pgsql")" == '#!' ]] || \
        error "Downloaded t-pgsql is not a script (HTML error page?). Nothing was installed."

    verify_asset "$TMP_DIR/t-pgsql" "t-pgsql"
    chmod +x "$TMP_DIR/t-pgsql"

    # Man page and completions come from the same release tarball.
    EXTRAS_DIR=""
    if [[ "$SKIP_COMPLETIONS" != "1" && "$VERSION" != "master" ]]; then
        num="${VERSION#v}"
        tarball="t-pgsql-${num}.tar.gz"
        if fetch "https://github.com/${REPO}/releases/download/${VERSION}/${tarball}" "$TMP_DIR/$tarball" 2>/dev/null; then
            verify_asset "$TMP_DIR/$tarball" "$tarball"
            EXTRAS_WORK="$(mktemp -d "$TMP_DIR/extras.XXXXXX")"
            if tar -xzf "$TMP_DIR/$tarball" -C "$EXTRAS_WORK" \
                "t-pgsql-${num}/man/t-pgsql.1" \
                "t-pgsql-${num}/completions/_t-pgsql" \
                "t-pgsql-${num}/completions/t-pgsql.bash" \
                "t-pgsql-${num}/completions/t-pgsql.fish" 2>/dev/null; then
                EXTRAS_DIR="$EXTRAS_WORK/t-pgsql-${num}"
                # Only plain files may be installed: refuse symlinks (also as
                # parent directories) and anything that is not a regular file.
                for d in "$EXTRAS_DIR" "$EXTRAS_DIR/man" "$EXTRAS_DIR/completions"; do
                    [[ -d "$d" && ! -L "$d" ]] || error "Release tarball has an unexpected directory layout. Nothing was installed."
                done
                for m in man/t-pgsql.1 completions/_t-pgsql completions/t-pgsql.bash completions/t-pgsql.fish; do
                    [[ -f "$EXTRAS_DIR/$m" && ! -L "$EXTRAS_DIR/$m" ]] || \
                        error "Release tarball member $m is not a regular file. Nothing was installed."
                done
            else
                warn "Release tarball has no man page/completions; skipping them."
            fi
        else
            warn "Release tarball ${tarball} not available; skipping man page and completions."
        fi
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

    # Create temp directory (removed on exit)
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    # Get version
    if [[ "$VERSION" == "latest" ]]; then
        VERSION=$(get_latest_version)
    fi
    check_version
    info "Version: $VERSION"

    info "Downloading t-pgsql..."
    download_and_verify

    # Install
    info "Installing to $INSTALL_DIR..."
    install_file "$TMP_DIR/t-pgsql" "$INSTALL_DIR/t-pgsql" 0755

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

# Install completions and man page (from the verified release tarball; for the
# opt-in master install they come from the raw master branch).
install_extras() {
    local src="$EXTRAS_DIR" RAW_URL="https://raw.githubusercontent.com/${REPO}/master"

    if [[ "$VERSION" == "master" ]]; then
        mkdir -p "$TMP_DIR/extras/man" "$TMP_DIR/extras/completions"
        src="$TMP_DIR/extras"
        fetch "$RAW_URL/man/t-pgsql.1" "$src/man/t-pgsql.1" 2>/dev/null || true
        fetch "$RAW_URL/completions/_t-pgsql" "$src/completions/_t-pgsql" 2>/dev/null || true
        fetch "$RAW_URL/completions/t-pgsql.bash" "$src/completions/t-pgsql.bash" 2>/dev/null || true
        fetch "$RAW_URL/completions/t-pgsql.fish" "$src/completions/t-pgsql.fish" 2>/dev/null || true
    fi
    [[ -n "$src" ]] || return 0

    info "Installing shell completions and man page..."

    # Man page
    if [[ -f "$src/man/t-pgsql.1" ]]; then
        info "Installing man page..."
        install_file "$src/man/t-pgsql.1" "$MANDIR/t-pgsql.1"
    fi

    # Zsh completion
    if command -v zsh >/dev/null 2>&1 && [[ -f "$src/completions/_t-pgsql" ]]; then
        info "Installing zsh completion..."
        install_file "$src/completions/_t-pgsql" "$ZSHDIR/_t-pgsql"
    fi

    # Bash completion
    if command -v bash >/dev/null 2>&1 && [[ -f "$src/completions/t-pgsql.bash" ]]; then
        info "Installing bash completion..."
        install_file "$src/completions/t-pgsql.bash" "$BASHDIR/t-pgsql"
    fi

    # Fish completion (user config dir when possible, else system dir)
    if command -v fish >/dev/null 2>&1 && [[ -f "$src/completions/t-pgsql.fish" ]]; then
        info "Installing fish completion..."
        local USER_FISHDIR="$HOME_DIR/.config/fish/completions"
        if [[ -n "$HOME_DIR" ]] && mkdir -p "$USER_FISHDIR" 2>/dev/null; then
            install -m 0644 "$src/completions/t-pgsql.fish" "$USER_FISHDIR/t-pgsql.fish"
            info "Fish completion installed to $USER_FISHDIR"
        else
            install_file "$src/completions/t-pgsql.fish" "$FISHDIR/t-pgsql.fish" || \
                warn "Could not install fish completion into $FISHDIR."
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
