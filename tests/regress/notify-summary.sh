#!/usr/bin/env bash
# Regression: --notify-summary must use the Telegram config that exists only in jobs.yaml
# (like the jobs do), and must still be sent when a fail-fast batch stops after a failure.
# Usage: bash tests/regress/notify-summary.sh   (T_PGSQL_BIN=/path/to/t-pgsql for another build)
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
# Fake pg_dump: fails for the database called faildb.
cat > "$TMP/bin/pg_dump" <<'EOF'
#!/bin/sh
f=""; last=""
while [ $# -gt 0 ]; do [ "$1" = "-f" ] && f="$2"; last="$1"; shift; done
[ "$last" = faildb ] && exit 1
printf 'fake dump\n' >> "$f"
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
n=$(ls "$REC"/curl.*.argv 2>/dev/null | wc -l | tr -d ' '); n=$((n + 1))
printf '%s\n' "$@" > "$REC/curl.$n.argv"
if [ ! -t 0 ]; then cat > "$REC/curl.$n.stdin"; fi
printf '{"ok":true}\n'
EOF
chmod +x "$TMP/bin/psql" "$TMP/bin/pg_dump" "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" REC="$TMP/rec"
unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID

cat > "$TMP/jobs.yaml" <<EOF
defaults:
  notify:
    telegram:
      token: "313131:SUMSECRET"
      chat_id: "-100999"
jobs:
  a-failing:
    command: dump
    from: postgres@localhost/faildb
    password: x
    output: $TMP/out
    no_meta: true
    no_health_check: true
  b-healthy:
    command: dump
    from: postgres@localhost/okdb
    password: x
    output: $TMP/out
    no_meta: true
    no_health_check: true
EOF
summary_calls() { grep -l "Batch completed" "$TMP"/rec/curl.*.argv 2>/dev/null | wc -l | tr -d ' '; }

# 1. all jobs OK (single healthy job selected), summary requested, channel only in YAML
rm -f "$TMP"/rec/curl.*
( cd "$TMP" && t-pgsql batch all --yaml "$TMP/jobs.yaml" --only-jobs b-healthy --notify-summary >"$TMP/run1.out" 2>&1 </dev/null )
RC=$?
[ "$RC" -eq 0 ] && ok "batch with a healthy job exits 0" || nok "batch with a healthy job exits 0 (rc=$RC)"
[ "$(summary_calls)" -eq 1 ] && ok "--notify-summary sends the summary using the YAML-only Telegram config" || nok "--notify-summary sends the summary using the YAML-only Telegram config (calls=$(summary_calls))"

# 2. fail-fast sequential batch: first job fails, summary still sent, exit status 1
rm -f "$TMP"/rec/curl.*
( cd "$TMP" && t-pgsql batch all --yaml "$TMP/jobs.yaml" --notify-summary >"$TMP/run2.out" 2>&1 </dev/null )
RC=$?
[ "$RC" -eq 1 ] && ok "fail-fast batch still exits 1" || nok "fail-fast batch still exits 1 (rc=$RC)"
[ "$(summary_calls)" -eq 1 ] && ok "summary is sent after a fail-fast stop" || nok "summary is sent after a fail-fast stop (calls=$(summary_calls))"
cat "$TMP"/rec/curl.*.argv 2>/dev/null | grep -q "Not run: 1" && ok "summary reports the job that was not run" || nok "summary reports the job that was not run"

# 3. without --notify-summary no summary is sent
rm -f "$TMP"/rec/curl.*
( cd "$TMP" && t-pgsql batch all --yaml "$TMP/jobs.yaml" --only-jobs b-healthy >"$TMP/run3.out" 2>&1 </dev/null )
[ "$(summary_calls)" -eq 0 ] && ok "no summary without --notify-summary" || nok "no summary without --notify-summary"

[ "$FAILS" -eq 0 ]
