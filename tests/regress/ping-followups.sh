#!/usr/bin/env bash
# Regression: heartbeat ping follow-ups. A legacy "args:" job must not put the ping URL on the
# child's command line; the masker stops the host at ? and #; the /start suffix goes before a
# #fragment; HTTP:// is accepted in any case; no validation on --dry-run or
# T_PGSQL_PING_DISABLE=1; --ping-start/--ping-fail work alone; batch --ping is rejected; a run
# without --from sends no start ping. Hermetic: pg_dump, curl and friends are fakes.
#   bash tests/regress/ping-followups.sh   (T_PGSQL_BIN overrides ./t-pgsql)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_SRC="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

BINDIR="$TMP/bin"; REC="$TMP/rec"; OUT="$TMP/out"; ST="$TMP/state"
mkdir -p "$BINDIR" "$REC" "$OUT" "$TMP/home"
sed '1s|.*|#!/usr/bin/env bash|' "$BIN_SRC" > "$BINDIR/t-pgsql"; chmod +x "$BINDIR/t-pgsql"
BIN="$BINDIR/t-pgsql"
REAL_BASH="$BASH"; export REAL_BASH
# bash wrapper: records the argv of every re-exec'd job (what "ps" would show), then runs bash
cat > "$BINDIR/bash" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$REC/bash.argv"
exec "$REAL_BASH" "$@"
EOF
cat > "$BINDIR/pg_dump" <<'EOF'
#!/usr/bin/env bash
f=""
while [ $# -gt 0 ]; do [ "$1" = -f ] && f="$2"; shift; done
[ -n "${PGD_RC:-}" ] && exit "$PGD_RC"
{ printf 'PGDMP'; printf '%*s' 195 '' | tr ' ' x; } > "$f"
exit 0
EOF
cat > "$BINDIR/curl" <<'EOF'
#!/usr/bin/env bash
[ -t 0 ] || cat | sed -n 's/^url = "\(.*\)"$/\1/p' >> "$REC/pings.log"
exit 0
EOF
for t in psql pg_isready createdb dropdb pg_dumpall pg_restore; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/$t"; done
chmod +x "$BINDIR"/*
export PATH="$BINDIR:$PATH" REC
export HOME="$TMP/home" T_PGSQL_FROM_PASSWORD=x T_PGSQL_STATE_DIR="$ST"
unset T_PGSQL_PING_DISABLE XDG_STATE_HOME

reset() { rm -rf "${REC:?}"/* "${OUT:?}" "${ST:?}"; mkdir -p "$OUT" "$REC"; }
dump() { out=$(env "${ENVV[@]}" "$BASH" "$BIN" dump --from postgres@localhost/appdb --output "$OUT" --compress none \
    --no-meta --no-health-check --min-size-ratio 0 "$@" </dev/null 2>&1); rc=$?; }
ENVV=(X=1)
pings() { cat "$REC/pings.log" 2>/dev/null; }
nl='
'
SEC="LEGSECRET7"
BASEURL="https://hc.example.test/ping/$SEC"

# (a) legacy args: job: URL not on any command line, pings still sent, jobs show masked
reset
cat > "$TMP/jobs.yaml" <<EOF
jobs:
  legacy:
    command: dump
    args: --from postgres@localhost/appdb --output $OUT --compress none --no-meta --no-health-check --min-size-ratio 0 --ping $BASEURL
EOF
out=$("$BASH" "$BIN" batch legacy --yaml "$TMP/jobs.yaml" </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "legacy args job runs" || nok "legacy args job runs (rc=$rc: $out)"
[ "$(pings)" = "$BASEURL/start${nl}$BASEURL" ] && ok "legacy args job still pings (start + success)" || nok "legacy args job pings: $(pings)"
if grep -q "$SEC" "$REC/bash.argv" 2>/dev/null; then nok "ping URL is on a child command line"; else ok "ping URL is on no child command line"; fi
out=$("$BASH" "$BIN" jobs show legacy --yaml "$TMP/jobs.yaml" </dev/null 2>&1)
case "$out" in *"$SEC"*) nok "jobs show leaks the URL: $out" ;; *) ok "jobs show masks the URL" ;; esac
# --save keeps the real URL in the file
reset; rm -f "$TMP/saved.yaml"
dump --ping "$BASEURL" --save svd --yaml "$TMP/saved.yaml"
grep -q "$SEC" "$TMP/saved.yaml" 2>/dev/null && ok "--save keeps the real URL in the saved job" || nok "--save lost the URL: $(cat "$TMP/saved.yaml" 2>&1)"
out=$("$BASH" "$BIN" jobs show svd --yaml "$TMP/saved.yaml" </dev/null 2>&1)
case "$out" in *"$SEC"*) nok "jobs show of a saved job leaks the URL: $out" ;; *) ok "jobs show of a saved job is masked" ;; esac
# quoted and escaped forms are taken out as well
reset
cat > "$TMP/jobs2.yaml" <<EOF
jobs:
  legacy:
    command: dump
    args: --from postgres@localhost/appdb --output $OUT --compress none --no-meta --no-health-check --min-size-ratio 0 --ping 'https://hc.example.test/ping/LEGSECRET7?create=1' --ping-fail https://hc.example.test/f/LEGSECRET7\?x=1
EOF
out=$("$BASH" "$BIN" batch legacy --yaml "$TMP/jobs2.yaml" </dev/null 2>&1); rc=$?
if grep -q "$SEC" "$REC/bash.argv" 2>/dev/null; then nok "quoted ping URLs are on a child command line"; else ok "quoted/escaped ping URLs are on no child command line"; fi
[ "$(pings)" = "https://hc.example.test/ping/LEGSECRET7/start?create=1${nl}https://hc.example.test/ping/LEGSECRET7?create=1" ] && ok "quoted URL pings are right (suffix before the query)" || nok "quoted URL pings: $(pings)"

# (b) the masker stops the host at ? and #
src=$(sed -n '/^redact_notify_args()/,/^}/p' "$ROOT/src/20-notifications.sh")
eval "$src"
for a in "--ping-fail https://h3.example.test?SECRET4" "--ping 'https://h3.example.test#SECRET4'" "--ping https://u:SECRET4@h3.example.test/p?x" "--ping HTTPS://h3.example.test/SECRET4" "--ping-start https://h3.example.test:8443/SECRET4#f"; do
    r=$(redact_notify_args "$a")
    case "$r" in *SECRET4*) nok "masker leaks: '$a' -> '$r'" ;; *h3.example.test*) ok "masked: '$a' -> '$r'" ;; *) nok "masker removed the host: '$r'" ;; esac
done

# (c) #fragment: the /start suffix goes before it
reset; dump --ping "https://hc.example.test/p/abc#frag"
[ "$(pings | head -n 1)" = "https://hc.example.test/p/abc/start#frag" ] && ok "start ping: suffix before #fragment" || nok "start ping with fragment: $(pings)"
reset; dump --ping "https://hc.example.test/p/abc?a=1#frag"
[ "$(pings | head -n 1)" = "https://hc.example.test/p/abc/start?a=1#frag" ] && ok "start ping: suffix before query and fragment" || nok "start ping with query+fragment: $(pings)"

# (d) upper-case scheme
reset; dump --ping "HTTPS://hc.example.test/p/abc"
[ "$rc" -eq 0 ] && [ "$(pings | wc -l | tr -d ' ')" -eq 2 ] && ok "HTTPS:// is accepted" || nok "HTTPS:// (rc=$rc, pings: $(pings))"

# (e) no validation on a dry run or with the kill switch; still validated otherwise
reset; dump --ping "ftp://x.example.test/p" --dry-run
[ "$rc" -eq 0 ] && ok "--dry-run does not reject a bad ping URL" || nok "--dry-run with a bad ping URL (rc=$rc: $out)"
reset; ENVV=(T_PGSQL_PING_DISABLE=1); dump --ping "ftp://x.example.test/p"; ENVV=(X=1)
[ "$rc" -eq 0 ] && [ -z "$(pings)" ] && ok "T_PGSQL_PING_DISABLE=1 does not reject a bad ping URL" || nok "T_PGSQL_PING_DISABLE=1 with a bad URL (rc=$rc)"
reset; dump --ping "ftp://x.example.test/p"
[ "$rc" -eq 1 ] && ok "a bad ping URL is still rejected on a real run" || nok "bad ping URL on a real run (rc=$rc)"

# (f) --ping-start / --ping-fail without --ping
reset; dump --ping-start "https://hc.example.test/s" --ping-fail "https://hc.example.test/f"
[ "$rc" -eq 0 ] && [ "$(pings)" = "https://hc.example.test/s" ] && ok "only start/fail URLs: start ping on a good run, nothing on success" || nok "start/fail only, ok run (rc=$rc: $(pings))"
reset; ENVV=(PGD_RC=1); dump --ping-start "https://hc.example.test/s" --ping-fail "https://hc.example.test/f"; ENVV=(X=1)
[ "$rc" -eq 1 ] && [ "$(pings)" = "https://hc.example.test/s${nl}https://hc.example.test/f" ] && ok "only start/fail URLs: start + fail on a failed run" || nok "start/fail only, failed run (rc=$rc: $(pings))"
reset; dump --ping-fail "https://hc.example.test/f"
[ "$rc" -eq 0 ] && [ -z "$(pings)" ] && ok "only --ping-fail: nothing is sent on success" || nok "only --ping-fail, ok run: $(pings)"

# (g) batch --ping is rejected
reset
out=$("$BASH" "$BIN" batch legacy --yaml "$TMP/jobs.yaml" --ping "$BASEURL" </dev/null 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "batch --ping is rejected" || nok "batch --ping (rc=$rc)"
case "$out" in *"do not apply to batch"*) ok "batch --ping says why" ;; *) nok "batch --ping message: $out" ;; esac
out=$("$BASH" "$BIN" --batch legacy --yaml "$TMP/jobs.yaml" --ping-fail "$BASEURL" </dev/null 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "--batch with --ping-fail is rejected" || nok "--batch --ping-fail (rc=$rc)"

# (h) a dump without --from sends no start ping
reset
out=$("$BASH" "$BIN" dump --output "$OUT" --ping "$BASEURL" </dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "dump without --from fails" || nok "dump without --from fails (rc=$rc)"
[ -z "$(pings)" ] && ok "dump without --from sends no ping at all" || nok "dump without --from pinged: $(pings)"

[ "$FAIL" -eq 0 ]
