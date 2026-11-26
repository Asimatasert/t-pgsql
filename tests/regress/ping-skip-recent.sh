#!/usr/bin/env bash
# Regression: a --skip-if-recent skip with --ping is a healthy state. It still sends the
# start and success pings, and the success body carries the line "skipped (recent dump)".
# A normal (non-skipped) run must not carry that line. Hermetic: pg_dump and curl are fakes.
#   bash tests/regress/ping-skip-recent.sh   (T_PGSQL_BIN overrides ./t-pgsql)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_SRC="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

BINDIR="$TMP/bin"; REC="$TMP/rec"; OUT="$TMP/out"
mkdir -p "$BINDIR" "$REC" "$OUT" "$TMP/home"
sed '1s|.*|#!/usr/bin/env bash|' "$BIN_SRC" > "$BINDIR/t-pgsql"; chmod +x "$BINDIR/t-pgsql"
BIN="$BINDIR/t-pgsql"
cat > "$BINDIR/pg_dump" <<'EOF'
#!/usr/bin/env bash
f=""
while [ $# -gt 0 ]; do [ "$1" = -f ] && f="$2"; shift; done
{ printf 'PGDMP'; printf '%*s' 195 '' | tr ' ' x; } > "$f"
exit 0
EOF
# curl fake: URL comes on stdin (-K -), the POST body follows -d
cat > "$BINDIR/curl" <<'EOF'
#!/usr/bin/env bash
url=""; [ -t 0 ] || url="$(sed -n 's/^url = "\(.*\)"$/\1/p')"
body=""
while [ $# -gt 0 ]; do [ "$1" = -d ] && body="$2"; shift; done
{ printf 'URL %s\n' "$url"; printf 'BODY %s\n' "$body"; } >> "$REC/pings.log"
exit 0
EOF
for t in psql pg_isready createdb dropdb pg_dumpall pg_restore; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/$t"; done
chmod +x "$BINDIR"/*
export PATH="$BINDIR:$PATH" REC
export HOME="$TMP/home" T_PGSQL_FROM_PASSWORD=x T_PGSQL_STATE_DIR="$TMP/state"
unset T_PGSQL_PING_DISABLE XDG_STATE_HOME

URL="https://hc.example.test/ping/abc"
run() { "$BASH" "$BIN" dump --from postgres@localhost/appdb --output "$OUT" --compress none \
    --no-meta --no-health-check --min-size-ratio 0 --ping "$URL" "$@" </dev/null >/dev/null 2>&1; }

# 1. first run dumps: success ping without the skip line
run; rc=$?
[ "$rc" -eq 0 ] && ok "first run exits 0" || nok "first run exit $rc"
grep -q "^URL $URL\$" "$REC/pings.log" && ok "first run sent success ping" || nok "first run success ping missing"
grep -q 'skipped (recent dump)' "$REC/pings.log" && nok "normal run body mentions skip" || ok "normal run body has no skip line"

# 2. second run is skipped: success ping (not /fail) with the skip line
rm -f "$REC/pings.log"
run --skip-if-recent 24h; rc=$?
[ "$rc" -eq 0 ] && ok "skipped run exits 0" || nok "skipped run exit $rc"
grep -q "^URL $URL\$" "$REC/pings.log" && ok "skipped run sent success ping" || nok "skipped run success ping missing"
grep -q '/fail' "$REC/pings.log" && nok "skipped run sent a fail ping" || ok "skipped run sent no fail ping"
grep -q '^skipped (recent dump)$' "$REC/pings.log" && ok "success body has 'skipped (recent dump)' line" || nok "success body lacks skip line"

exit "$FAIL"
