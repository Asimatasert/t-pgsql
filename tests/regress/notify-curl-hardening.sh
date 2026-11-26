#!/usr/bin/env bash
# Regression: notification curl calls keep secret URLs/tokens off argv (config on stdin),
# use timeouts and --fail, log every delivery failure and never fail the backup.
# Usage: bash tests/regress/notify-curl-hardening.sh   (T_PGSQL_BIN=/path/to/t-pgsql for another build)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_SRC="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAILS=$((FAILS + 1)); }

mkdir -p "$TMP/bin" "$TMP/rec"
sed '1s|.*|#!/usr/bin/env bash|' "$BIN_SRC" > "$TMP/bin/t-pgsql"; chmod +x "$TMP/bin/t-pgsql"
ln -s "$BASH" "$TMP/bin/bash"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/psql"
cat > "$TMP/bin/pg_dump" <<'EOF'
#!/bin/sh
f=""
while [ $# -gt 0 ]; do [ "$1" = "-f" ] && f="$2"; shift; done
printf 'PGDMP\nfake dump\n' >> "$f"
EOF
# Fake curl: records argv and stdin. CURL_MODE=fail makes webhook/slack calls exit 22 and
# Telegram answer {"ok":false}. A call counter bounds it; it never loops or sleeps.
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
n=$(ls "$REC"/curl.*.argv 2>/dev/null | wc -l | tr -d ' '); n=$((n + 1))
printf '%s\n' "$@" > "$REC/curl.$n.argv"
if [ ! -t 0 ]; then cat > "$REC/curl.$n.stdin"; fi
if grep -q "api.telegram.org" "$REC/curl.$n.stdin" 2>/dev/null; then
    if [ "$CURL_MODE" = fail ]; then printf '{"ok":false,"description":"Unauthorized"}\n'; else printf '{"ok":true}\n'; fi
    exit 0
fi
if [ "$CURL_MODE" = fail ]; then echo "curl: (22) The requested URL returned error: 500" >&2; exit 22; fi
printf 'ok\n'
EOF
chmod +x "$TMP/bin/psql" "$TMP/bin/pg_dump" "$TMP/bin/curl"
. "$ROOT/tests/regress/lib/fakes.sh"; fake_pg_tools "$TMP/bin"
export PATH="$TMP/bin:$PATH" REC="$TMP/rec"

run_dump() { # extra args = --notify options; output in $TMP/run.out, rc in $RC
    ( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --password x --output "$TMP/out" \
        --no-meta --no-health-check "$@" >"$TMP/run.out" 2>&1 </dev/null )
    RC=$?
}
all_argv() { cat "$TMP"/rec/curl.*.argv 2>/dev/null; }
all_stdin() { cat "$TMP"/rec/curl.*.stdin 2>/dev/null; }

# --- A. healthy delivery
run_dump --notify "webhook:https://hooks.example.com/WEBSECRET" \
         --notify "slack:https://hooks.example.com/SLACKSECRET" \
         --notify "telegram:555666:TGSECRET:-100"
[ "$RC" -eq 0 ] && ok "dump succeeds with three channels" || nok "dump succeeds with three channels (rc=$RC)"
if all_argv | grep -q "WEBSECRET\|SLACKSECRET\|TGSECRET"; then nok "no secret URL or token on any curl argv"; else ok "no secret URL or token on any curl argv"; fi
all_stdin | grep -q 'url = "https://hooks.example.com/WEBSECRET"' && ok "webhook URL is passed through the stdin config" || nok "webhook URL is passed through the stdin config"
all_stdin | grep -q 'url = "https://hooks.example.com/SLACKSECRET"' && ok "slack URL is passed through the stdin config" || nok "slack URL is passed through the stdin config"
for needle in --fail --connect-timeout --max-time; do
    all_argv | grep -q -- "^$needle\$" && ok "curl is called with $needle" || nok "curl is called with $needle"
done

# --- B. every channel failing: logged, never fatal
rm -f "$TMP"/rec/curl.*; rm -rf "$TMP/out"
CURL_MODE=fail run_dump --notify "webhook:https://hooks.example.com/WEBSECRET" \
         --notify "slack:https://hooks.example.com/SLACKSECRET" \
         --notify "telegram:555666:TGSECRET:-100"
[ "$RC" -eq 0 ] && ok "failed deliveries do not fail the dump" || nok "failed deliveries do not fail the dump (rc=$RC)"
grep -q "Webhook notification failed" "$TMP/run.out" && ok "webhook failure is logged" || nok "webhook failure is logged"
grep -q "Slack notification failed" "$TMP/run.out" && ok "slack failure is logged" || nok "slack failure is logged"
grep -q "Telegram notification failed" "$TMP/run.out" && ok "telegram failure is logged" || nok "telegram failure is logged"
if grep -q "WEBSECRET\|SLACKSECRET\|TGSECRET" "$TMP/run.out"; then nok "failure messages do not contain secrets"; else ok "failure messages do not contain secrets"; fi

# --- C. option-injection attempt through the URL is rejected before curl runs
rm -f "$TMP"/rec/curl.*; rm -rf "$TMP/out"
run_dump --notify "webhook:-K/etc/hosts"
[ "$RC" -eq 0 ] && ok "dump succeeds with a bad webhook value" || nok "dump succeeds with a bad webhook value"
grep -q "Webhook notification skipped" "$TMP/run.out" && ok "bad webhook URL is rejected with a warning" || nok "bad webhook URL is rejected with a warning"
if all_argv | grep -q -- "-K/etc/hosts"; then nok "bad URL never reaches curl"; else ok "bad URL never reaches curl"; fi

[ "$FAILS" -eq 0 ]
