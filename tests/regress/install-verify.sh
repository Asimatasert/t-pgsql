#!/usr/bin/env bash
# Regression: install.sh must verify the release checksum and fail closed.
# Runs install.sh with a fake curl serving a local fixture release into a temp
# prefix. No network, no sudo. Override the script under test with T_INSTALL_SH.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_SH="${T_INSTALL_SH:-$ROOT/install.sh}"
SHELL_BIN="${BASH:-bash}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

FAILS=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAILS=$((FAILS + 1)); }
check() { # description, command...
    local d="$1"; shift
    if "$@"; then ok "$d"; else nok "$d"; fi
}

sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

BIN="$T/bin"; FIX="$T/fixture"; mkdir -p "$BIN" "$FIX"

# Fake curl: serves $FIX/<basename of URL>; GitHub API URL serves latest.json.
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
url=""; out=""; prev=""
for a in "$@"; do
    case "$a" in https://*) url="$a" ;; esac
    [ "$prev" = "-o" ] && out="$a"
    prev="$a"
done
echo "$* " >> "$FAKE_LOG/curl.log"
case "$url" in
    */download/v9.9.9/*) exit 22 ;;
    */releases/latest) name=latest.json ;;
    *) name="$(basename "$url")" ;;
esac
[ -f "$FAKE_FIX/$name" ] || exit 22
if [ -n "$out" ]; then cp "$FAKE_FIX/$name" "$out"; else cat "$FAKE_FIX/$name"; fi
EOF
cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$FAKE_LOG/sudo.log"
exit 1
EOF
chmod +x "$BIN/curl" "$BIN/sudo"

VER="3.99.0"
# Fixture release
printf '#!/bin/bash\necho "t-pgsql v%s"\n' "$VER" > "$FIX/t-pgsql"
PK="$T/pkg/t-pgsql-$VER"; mkdir -p "$PK/man" "$PK/completions"
echo ".TH T-PGSQL 1" > "$PK/man/t-pgsql.1"
echo "# zsh" > "$PK/completions/_t-pgsql"
echo "# bash" > "$PK/completions/t-pgsql.bash"
echo "# fish" > "$PK/completions/t-pgsql.fish"
( cd "$T/pkg" && tar -czf "$FIX/t-pgsql-$VER.tar.gz" "t-pgsql-$VER" )
printf '{"tag_name": "v%s"}\n' "$VER" > "$FIX/latest.json"

write_sums() { # binary-hash tarball-hash
    printf '%s  t-pgsql\n%s  t-pgsql-%s.tar.gz\n' "$1" "$2" "$VER" > "$FIX/SHA256SUMS"
}
GOOD_BIN="$(sha "$FIX/t-pgsql")"
GOOD_TAR="$(sha "$FIX/t-pgsql-$VER.tar.gz")"
BAD="0000000000000000000000000000000000000000000000000000000000000000"

run() { # extra args...; env from caller
    rm -rf "$T/home" "$T/log"; mkdir -p "$T/home" "$T/log"
    env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" HOME="$T/home" \
        INSTALL_DIR="$T/home/bin" FAKE_FIX="$FIX" FAKE_LOG="$T/log" \
        ${ENVX:-} "$SHELL_BIN" "$INSTALL_SH" "$@" > "$T/out.txt" 2>&1
    RC=$?
}
installed() { [ -x "$T/home/bin/t-pgsql" ]; }
man_installed() { [ -f "$T/home/.local/share/man/man1/t-pgsql.1" ]; }
nothing_installed() { ! installed && ! man_installed; }
no_sudo() { [ ! -f "$T/log/sudo.log" ]; }
rc_fail() { [ "$RC" -ne 0 ]; }
out_has() { grep -q -- "$1" "$T/out.txt"; }

# 1. correct checksums install, extras come from the verified tarball
write_sums "$GOOD_BIN" "$GOOD_TAR"
ENVX="VERSION=v$VER"; run
check "valid checksums: exit 0" test "$RC" -eq 0
check "valid checksums: binary installed" installed
check "valid checksums: man page installed from tarball" man_installed
check "valid checksums: no sudo used" no_sudo
check "curl uses --fail, --proto =https and --tlsv1.2" \
    grep -q -- "--fail.*--proto =https.*--tlsv1.2" "$T/log/curl.log"
check "no raw.githubusercontent.com download for a release" \
    bash -c "! grep -q raw.githubusercontent '$T/log/curl.log'"

# 2. latest resolves via the API
ENVX=""; run
check "latest: installs the API tag" installed

# 3. wrong binary checksum aborts and installs nothing
write_sums "$BAD" "$GOOD_TAR"
ENVX="VERSION=v$VER"; run
check "bad binary checksum: aborts" rc_fail
check "bad binary checksum: nothing installed" nothing_installed
check "bad binary checksum: mismatch reported" out_has "mismatch"

# 4. wrong tarball checksum aborts before the binary is installed
write_sums "$GOOD_BIN" "$BAD"
ENVX="VERSION=v$VER"; run
check "bad tarball checksum: aborts" rc_fail
check "bad tarball checksum: nothing installed" nothing_installed

# 5. mismatch is fatal even with the opt-in
write_sums "$BAD" "$GOOD_TAR"
ENVX="VERSION=v$VER T_PGSQL_ALLOW_UNVERIFIED=1"; run
check "mismatch with opt-in still aborts" rc_fail
check "mismatch with opt-in: nothing installed" nothing_installed

# 6. missing entry aborts unless opted in
printf '%s  other-file\n' "$BAD" > "$FIX/SHA256SUMS"
ENVX="VERSION=v$VER"; run
check "missing entry: aborts" rc_fail
check "missing entry: nothing installed" nothing_installed

# 7. missing SHA256SUMS aborts; env opt-in and flag opt-in install with a warning
rm -f "$FIX/SHA256SUMS"
ENVX="VERSION=v$VER"; run
check "missing SHA256SUMS: aborts" rc_fail
check "missing SHA256SUMS: nothing installed" nothing_installed
check "missing SHA256SUMS: tells how to opt in" out_has "allow-unverified"
ENVX="VERSION=v$VER T_PGSQL_ALLOW_UNVERIFIED=1"; run
check "missing SHA256SUMS + env opt-in: installs" test "$RC" -eq 0 -a -x "$T/home/bin/t-pgsql"
check "env opt-in prints a warning" out_has "UNVERIFIED"
ENVX="VERSION=v$VER"; run --allow-unverified
check "missing SHA256SUMS + --allow-unverified: installs" installed

# 8. no silent fallback to master
write_sums "$GOOD_BIN" "$GOOD_TAR"
ENVX="VERSION=v9.9.9"; run
check "missing release asset: aborts" rc_fail
check "missing release asset: no master fallback" \
    bash -c "! grep -q raw.githubusercontent '$T/log/curl.log'"
check "missing release asset: nothing installed" nothing_installed
mv "$FIX/latest.json" "$FIX/latest.json.off"
ENVX=""; run
check "latest API failure: aborts" rc_fail
check "latest API failure: no master fallback" \
    bash -c "! grep -q raw.githubusercontent '$T/log/curl.log'"
check "latest API failure: nothing installed" nothing_installed
mv "$FIX/latest.json.off" "$FIX/latest.json"

# 9. master needs the opt-in
ENVX="VERSION=master"; run
check "VERSION=master without opt-in: aborts" rc_fail
check "VERSION=master without opt-in: nothing downloaded" \
    bash -c "[ ! -s '$T/log/curl.log' ]"

# 10. an HTML error page is never installed
cp "$FIX/t-pgsql" "$T/t-pgsql.good"
echo "<html>rate limited</html>" > "$FIX/t-pgsql"
rm -f "$FIX/SHA256SUMS"
ENVX="VERSION=v$VER T_PGSQL_ALLOW_UNVERIFIED=1"; run
check "HTML body with opt-in: aborts" rc_fail
check "HTML body with opt-in: nothing installed" nothing_installed
cp "$T/t-pgsql.good" "$FIX/t-pgsql"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS assertion(s) failed"; exit 1; fi
echo "all install-verify assertions passed"
