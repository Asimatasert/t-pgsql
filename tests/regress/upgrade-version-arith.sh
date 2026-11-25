#!/usr/bin/env bash
# Regression test: upgrade version preflight rejects non-numeric server_version_num
# Runs against ./t-pgsql, or T_PGSQL_BIN to test another build (e.g. the base version).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; fails=$((fails+1)); }
# Source the CLI without running main (drop the final 'main "$@"' call).
grep -v '^main "\$@"$' "$BIN" > "$TMP/lib.sh"
mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

MARKER="$TMP/pwned"
cat > "$TMP/bin/psql" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_VERSION"
EOS
chmod +x "$TMP/bin/psql"

# shellcheck disable=SC1090
source "$TMP/lib.sh" >/dev/null 2>&1
CLONED="$TMP/cloned"
cmd_clone() { : > "$CLONED"; }
get_password() { :; }
QUIET=true
FROM_CONNECTION="u@src.example.com/a"; TO_CONNECTIONS=("u@dst.example.com/b")

export FAKE_VERSION='a[$(touch${IFS}'"$MARKER"')]'
out=$(cmd_upgrade 2>&1 </dev/null); rc=$?
[ ! -e "$MARKER" ] && ok "subscript payload did not execute" || nok "subscript payload executed locally"
[ -e "$CLONED" ] && ok "non-numeric answer treated as unknown; upgrade continues" || nok "upgrade did not continue (rc=$rc)"

FROM_TYPE=local FROM_DB_HOST=src.example.com FROM_DB_PORT=5432 FROM_DB_USER=u FROM_DB_PASSWORD=
v=$(server_version_num FROM 2>/dev/null)
[ -z "$v" ] && ok "server_version_num prints nothing for a non-numeric answer" || nok "server_version_num returned '$v'"

rm -f "$CLONED"
FAKE_VERSION=160014
v=$(server_version_num FROM 2>/dev/null)
[ "$v" = 160014 ] && ok "valid numeric answer passes through" || nok "valid answer mangled: '$v'"

rm -f "$CLONED"
cat > "$TMP/bin/psql" <<'EOS'
#!/usr/bin/env bash
# source says 17, target says 16
case "$PGHOST$*" in *src.example.com*) echo 170002 ;; *) echo 160014 ;; esac
EOS
unset FAKE_VERSION
cmd_upgrade >/dev/null 2>&1 </dev/null
[ ! -e "$CLONED" ] && ok "downgrade still refused" || nok "downgrade was not refused"
exit "$fails"
