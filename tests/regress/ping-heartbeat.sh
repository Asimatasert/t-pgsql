#!/usr/bin/env bash
# Feature: heartbeat ping (--ping / --ping-start / --ping-fail, config + jobs.yaml key "ping").
# A run of dump/clone/restore/upgrade/fetch pings <url>/start, then <url> or <url>/fail. The URL
# is a secret: it must never be on a curl argv or in log output, and a failing ping must
# never change the exit code. Hermetic: pg_dump, psql, curl and friends are fakes.
#   bash tests/regress/ping-heartbeat.sh   (T_PGSQL_BIN overrides ./t-pgsql)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_SRC="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
BGPID=""
cleanup() { [ -n "$BGPID" ] && kill "$BGPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

BINDIR="$TMP/bin"; REC="$TMP/rec"; OUT="$TMP/out"
mkdir -p "$BINDIR" "$REC" "$OUT" "$TMP/home"
sed '1s|.*|#!/usr/bin/env bash|' "$BIN_SRC" > "$BINDIR/t-pgsql"; chmod +x "$BINDIR/t-pgsql"
ln -s "$BASH" "$BINDIR/bash"
BIN="$BINDIR/t-pgsql"

# pg_dump: PGDMP header padded to DUMP_BYTES; PGD_RC makes it fail; PGD_SLEEP (tenths of a
# second, bounded) makes it linger so a signal can arrive mid-dump.
cat > "$BINDIR/pg_dump" <<'EOF'
#!/usr/bin/env bash
f=""
while [ $# -gt 0 ]; do [ "$1" = -f ] && f="$2"; shift; done
touch "$REC/pg_dump.started"
n=0; while [ "$n" -lt "${PGD_SLEEP:-0}" ] && [ "$n" -lt 40 ]; do sleep 0.1; n=$((n + 1)); done
[ -n "${PGD_RC:-}" ] && exit "$PGD_RC"
{ printf 'PGDMP'; printf '%*s' $(( ${DUMP_BYTES:-200} - 5)) '' | tr ' ' x; } > "$f"
exit 0
EOF
# curl: record argv, stdin config and the -d body of every call; exit with CURL_RC.
cat > "$BINDIR/curl" <<'EOF'
#!/usr/bin/env bash
n=$(ls "$REC"/curl.*.argv 2>/dev/null | wc -l | tr -d ' '); n=$((n + 1))
printf '%s\n' "$@" > "$REC/curl.$n.argv"
[ -t 0 ] || cat > "$REC/curl.$n.stdin"
while [ $# -gt 0 ]; do [ "$1" = -d ] && printf '%s' "$2" > "$REC/curl.$n.body"; shift; done
exit "${CURL_RC:-0}"
EOF
for t in psql pg_isready createdb dropdb pg_dumpall pg_restore; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/$t"
done
chmod +x "$BINDIR"/*
export PATH="$BINDIR:$PATH" REC
export HOME="$TMP/home" T_PGSQL_FROM_PASSWORD=x
unset T_PGSQL_PING_DISABLE

SECRET="tok3nSECRET9"
URL="https://hc.example.com/ping/$SECRET"
URLQ="$URL?create=1"

reset() { rm -rf "${REC:?}"/* "$OUT"; mkdir -p "$OUT"; out=""; rc=0; }
run() { out=$("$BIN" "$@" </dev/null 2>&1); rc=$?; }
dumpit() { run dump --from postgres@localhost/appdb --output "$OUT" --compress none --no-meta --no-health-check "$@"; }
ncurl() { ls "$REC"/curl.*.stdin 2>/dev/null | wc -l | tr -d ' '; }
cfg() { cat "$REC/curl.$1.stdin" 2>/dev/null; }
argv_has_secret() { cat "$REC"/curl.*.argv 2>/dev/null | grep -q "$SECRET"; }

# 1. success path: exactly start + success, URL only in the stdin config
reset; dumpit --ping "$URL"
[ $rc -eq 0 ] && ok "dump with --ping succeeds" || nok "dump failed rc=$rc: $out"
[ "$(ncurl)" = 2 ] && ok "exactly two pings (start + success)" || nok "ping count $(ncurl)"
case "$(cfg 1)" in *"$URL/start\""*) ok "start ping goes to <url>/start" ;; *) nok "start url: $(cfg 1)" ;; esac
case "$(cfg 2)" in *"url = \"$URL\""*) ok "success ping goes to <url>" ;; *) nok "success url: $(cfg 2)" ;; esac
argv_has_secret && nok "secret on curl argv" || ok "secret never on curl argv"
case "$out" in *"$SECRET"*) nok "secret in log output" ;; *) ok "secret not in log output" ;; esac
grep -q -- '--max-time' "$REC/curl.1.argv" && grep -q -- '--connect-timeout' "$REC/curl.1.argv" && ok "ping has timeouts" || nok "no timeouts: $(cat "$REC/curl.1.argv")"
case "$(cat "$REC/curl.2.body" 2>/dev/null)" in "t-pgsql dump appdb exit=0 duration="*"s") ok "success body names command, db, exit and duration" ;; *) nok "body: $(cat "$REC/curl.2.body" 2>/dev/null)" ;; esac

# 2. query string: suffix goes before the query
reset; dumpit --ping "$URLQ"
case "$(cfg 1)" in *"$URL/start?create=1\""*) ok "/start inserted before ?query" ;; *) nok "query url: $(cfg 1)" ;; esac
case "$(cfg 2)" in *"url = \"$URLQ\""*) ok "success keeps the query" ;; *) nok "success query: $(cfg 2)" ;; esac
reset; dumpit --ping "$URLQ" -q
[ "$(ncurl)" = 2 ] && ok "--quiet does not disable pings" || nok "quiet ping count $(ncurl)"

# 3. fail on a failing dump; exit code unchanged
reset; dumpit; base_rc=0; PGD_RC=1 dumpit; base_rc=$rc
reset; PGD_RC=1 dumpit --ping "$URL"
[ $rc -ne 0 ] && [ $rc -eq "$base_rc" ] && ok "failed dump keeps its exit code" || nok "rc $rc vs $base_rc"
[ "$(ncurl)" = 2 ] && case "$(cfg 2)" in *"$URL/fail\""*) true ;; *) false ;; esac && ok "start + fail pings on a failed dump" || nok "failed dump pings: n=$(ncurl) $(cfg 2)"
case "$(cat "$REC/curl.2.body" 2>/dev/null)" in *"exit=$rc "*) ok "fail body carries the exit code" ;; *) nok "fail body: $(cat "$REC/curl.2.body" 2>/dev/null)" ;; esac

# 4. shrink guard failure -> fail ping
reset; { printf 'PGDMP'; printf '%*s' 995 '' | tr ' ' x; } > "$OUT/appdb_20200101_000000.dump"
touch -t 202001010000 "$OUT/appdb_20200101_000000.dump"
DUMP_BYTES=100 run dump --from postgres@localhost/appdb --output "$OUT" --compress none --no-meta --no-health-check --ping "$URL"
[ $rc -ne 0 ] && [ "$(ncurl)" = 2 ] && case "$(cfg 2)" in *"$URL/fail\""*) true ;; *) false ;; esac && ok "shrink guard failure sends the fail ping" || nok "shrink: rc=$rc n=$(ncurl) $(cfg 2)"

# 5. overrides win
reset; dumpit --ping "$URL" --ping-start "http://up.example.com/s?status=up" --ping-fail "http://up.example.com/f?status=down"
case "$(cfg 1)" in *"http://up.example.com/s?status=up\""*) ok "--ping-start overrides the start url" ;; *) nok "override start: $(cfg 1)" ;; esac
reset; PGD_RC=1 dumpit --ping "$URL" --ping-start "http://up.example.com/s" --ping-fail "http://up.example.com/f?status=down"
case "$(cfg 2)" in *"http://up.example.com/f?status=down\""*) ok "--ping-fail overrides the fail url" ;; *) nok "override fail: $(cfg 2)" ;; esac

# 6. no pings: dry run, non-work commands, disable switch
reset; dumpit --ping "$URL" --dry-run
[ "$(ncurl)" = 0 ] && ok "no ping under --dry-run" || nok "dry-run pinged"
reset; run list --output "$OUT" --ping "$URL"; run version --ping "$URL"; run doctor --ping "$URL"; run explain --ping "$URL"
[ "$(ncurl)" = 0 ] && ok "list/version/doctor/explain never ping" || nok "non-work command pinged"
reset; T_PGSQL_PING_DISABLE=1 dumpit --ping "$URL"
[ $rc -eq 0 ] && [ "$(ncurl)" = 0 ] && ok "T_PGSQL_PING_DISABLE=1 disables pings" || nok "disable switch: n=$(ncurl)"

# 7. broken monitor: exit code 0, warning without the secret
reset; CURL_RC=22 dumpit --ping "$URL"
[ $rc -eq 0 ] && ok "failing ping leaves exit code 0" || nok "ping failure changed rc to $rc"
case "$out" in *"Heartbeat ping failed"*) ok "failing ping logs a warning" ;; *) nok "no warning: $out" ;; esac
case "$out" in *"$SECRET"*) nok "warning leaks the secret" ;; *) ok "warning masks the url" ;; esac
case "$out" in *"hc.example.com/***"*) ok "warning shows host only" ;; *) nok "masked host missing: $out" ;; esac

# 8. invalid URL is a startup error
reset; dumpit --ping "ftp://hc.example.com/x"
[ $rc -ne 0 ] && ok "non-http url rejected" || nok "ftp url accepted"
case "$out" in *"Invalid --ping"*) ok "error names the option" ;; *) nok "error text: $out" ;; esac
[ -z "$(ls "$OUT")" ] && ok "no dump was made" || nok "dump ran with an invalid ping url"
reset; dumpit --ping "hc.example.com/x"
[ $rc -ne 0 ] && ok "scheme-less url rejected" || nok "scheme-less url accepted"
[ "$(ncurl)" = 0 ] && ok "invalid url sends nothing" || nok "invalid url pinged"

# 9. config file key
printf 'ping: %s\n' "$URL" > "$TMP/t.conf"
reset; dumpit --config "$TMP/t.conf"
[ "$(ncurl)" = 2 ] && ok "config key ping works" || nok "config ping count $(ncurl)"

# 10. batch job with ping in yaml (defaults + job), URL off argv
cat > "$TMP/jobs.yaml" <<EOF
defaults:
  ping_fail: "$URL/failure-route"
jobs:
  nightly:
    command: dump
    from: postgres@localhost/appdb
    output: $OUT
    no_meta: true
    no_health_check: true
    compress: none
    ping: "$URL"
EOF
reset; ( cd "$TMP" && "$BIN" batch nightly --yaml "$TMP/jobs.yaml" </dev/null >"$TMP/batch.log" 2>&1 ); rc=$?
[ $rc -eq 0 ] && [ "$(ncurl)" = 2 ] && ok "batch job pings by itself (start + success)" || nok "batch: rc=$rc n=$(ncurl): $(cat "$TMP/batch.log")"
argv_has_secret && nok "batch: secret on curl argv" || ok "batch: secret never on curl argv"
grep -q "$SECRET" "$TMP/batch.log" && nok "batch: secret in log" || ok "batch: secret not in log"
grep -qi "unknown" "$TMP/batch.log" && nok "batch: unknown-key warning for ping" || ok "batch: ping is a known job key"
reset; PGD_RC=1 bash -c "cd '$TMP' && '$BIN' batch nightly --yaml '$TMP/jobs.yaml' </dev/null >/dev/null 2>&1"
case "$(cfg 2)" in *"url = \"$URL/failure-route\""*) ok "defaults.ping_fail is used by a failing batch job" ;; *) nok "batch fail url: $(cfg 2)" ;; esac
run jobs show nightly --yaml "$TMP/jobs.yaml"
case "$out" in *"$SECRET"*) nok "jobs show leaks the ping url" ;; *) ok "jobs show does not print the ping url" ;; esac

# 11. --save writes the real url, jobs show masks it
rm -f "$TMP/saved.yaml"
run dump --from postgres@localhost/appdb --output "$OUT" --ping "$URL" --save s1 --yaml "$TMP/saved.yaml"
grep -q "$SECRET" "$TMP/saved.yaml" && ok "--save keeps the real url" || nok "--save lost the url"
run jobs show s1 --yaml "$TMP/saved.yaml"
case "$out" in *"$SECRET"*) nok "jobs show leaks a saved ping url" ;; *"hc.example.com/***"*) ok "jobs show masks a saved ping url" ;; *) nok "jobs show output: $out" ;; esac

# 12. SIGTERM during a dump -> fail ping
reset
( PGD_SLEEP=40 exec "$BIN" dump --from postgres@localhost/appdb --output "$OUT" --compress none --no-meta --no-health-check --ping "$URL" </dev/null >/dev/null 2>&1 ) &
BGPID=$!
n=0; while [ ! -e "$REC/pg_dump.started" ] && [ $n -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
kill -TERM "$BGPID" 2>/dev/null
wait "$BGPID" 2>/dev/null; BGPID=""
case "$(cfg 2)" in *"$URL/fail\""*) ok "SIGTERM during the dump sends the fail ping" ;; *) nok "SIGTERM pings: n=$(ncurl) $(cfg 2)" ;; esac
[ "$(ncurl)" = 2 ] && ok "exactly start + one final ping after SIGTERM" || nok "SIGTERM ping count $(ncurl)"

exit $FAIL
