#!/usr/bin/env bash
# INT/TERM must run the temp-file cleanup AND terminate the script (130/143) so no later
# step runs with the credential files already deleted.
# Usage: bash tests/regress/stream-signal-trap.sh   (T_PGSQL_BIN overrides the script under test)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }

sed '$d' "$BIN" > "$TMP/lib.sh"

# The child shell signals itself while "working", exactly like a timeout/Ctrl-C would.
cat > "$TMP/run.sh" <<EOS
source "$TMP/lib.sh"
install_cleanup_trap
reg_tmp "$TMP/secret"
sleep 2 &
kill -"\$1" \$\$
wait \$!
echo later > "$TMP/later"
EOS

for spec in TERM:143 INT:130; do
    sig="${spec%%:*}"; want="${spec##*:}"
    rm -f "$TMP/later"; : > "$TMP/secret"
    "$BASH" "$TMP/run.sh" "$sig" >/dev/null 2>&1
    rc=$?
    [ "$rc" = "$want" ] && ok "$sig: exit status $rc" || nok "$sig: exit status $rc (want $want)"
    [ ! -e "$TMP/later" ] && ok "$sig: no step ran after the signal" || nok "$sig: script continued after the signal"
    [ ! -e "$TMP/secret" ] && ok "$sig: registered temp file cleaned up" || nok "$sig: temp file left behind"
done
exit "$fail"
