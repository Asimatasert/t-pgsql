#!/usr/bin/env bash
# Regression test: upgrade globals here-doc cannot be closed by dump content
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

# Fake ssh: ignore arguments, run the script it gets on stdin with a local shell
# (this is what the remote side does with it).
cat > "$TMP/bin/ssh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SSH_ARGV_LOG"
exec bash
EOS
# Fake psql: record stdin.
cat > "$TMP/bin/psql" <<'EOS'
#!/usr/bin/env bash
cat > "$PSQL_STDIN_LOG"
EOS
chmod +x "$TMP/bin/ssh" "$TMP/bin/psql"
export SSH_ARGV_LOG="$TMP/ssh.argv" PSQL_STDIN_LOG="$TMP/psql.stdin"
MARKER="$TMP/pwned"

printf '%s\n' "CREATE ROLE a;" "__TPG_GLOBALS_EOF__" "touch '$MARKER'" "SELECT 1;" > "$TMP/globals.sql"

# shellcheck disable=SC1090
source "$TMP/lib.sh" >/dev/null 2>&1
TO_TYPE=ssh TO_SSH_HOST=192.0.2.10 TO_SSH_PORT=22 TO_SSH_USER=ops
TO_DB_HOST=localhost TO_DB_PORT=5432 TO_DB_USER=postgres TO_DB_PASSWORD=secret
SUDO=false
apply_globals_to_target "$TMP/globals.sql" >/dev/null 2>&1

[ ! -e "$MARKER" ] && ok "dump content did not run as shell on the target" || nok "dump content ran as shell on the target"
if [ -f "$PSQL_STDIN_LOG" ] && grep -q "touch '$MARKER'" "$PSQL_STDIN_LOG" && grep -qx "CREATE ROLE a;" "$PSQL_STDIN_LOG"; then
    ok "psql received the full globals SQL, including the hostile lines"
else
    nok "psql did not receive the full globals SQL"
fi
grep -q 'secret' "$SSH_ARGV_LOG" && nok "password appeared on ssh argv" || ok "password not on ssh argv"

# A terminator that collides with the dump must never be used.
if grep -q "__TPG_GLOBALS_EOF__" <<<"$(declare -f apply_globals_to_target)"; then
    nok "fixed terminator still present in apply_globals_to_target"
else
    ok "no fixed terminator in apply_globals_to_target"
fi
exit "$fails"
