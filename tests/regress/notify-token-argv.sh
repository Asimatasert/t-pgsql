#!/usr/bin/env bash
# Regression: a Telegram bot token from jobs.yaml must not appear on the argv of the
# re-executed job (visible in `ps`), while --notify typed on the command line keeps working.
# Usage: bash tests/regress/notify-token-argv.sh   (T_PGSQL_BIN=/path/to/t-pgsql for another build)
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
# Fake pg_dump: snapshot every process command line and our environment while the job runs.
cat > "$TMP/bin/pg_dump" <<'EOF'
#!/bin/sh
f=""
while [ $# -gt 0 ]; do [ "$1" = "-f" ] && f="$2"; shift; done
printf 'fake dump\n' >> "$f"
ps -axww -o args= > "$REC/ps.$$" 2>/dev/null
env > "$REC/env.$$"
EOF
# Fake curl: record argv and the config read from stdin.
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
n=$(ls "$REC"/curl.*.argv 2>/dev/null | wc -l | tr -d ' '); n=$((n + 1))
printf '%s\n' "$@" > "$REC/curl.$n.argv"
if [ ! -t 0 ]; then cat > "$REC/curl.$n.stdin"; fi
printf '{"ok":true}\n'
EOF
chmod +x "$TMP/bin/psql" "$TMP/bin/pg_dump" "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" REC="$TMP/rec"

TOKEN="424242:SECRETTOKENVALUE"
cat > "$TMP/jobs.yaml" <<EOF
defaults:
  notify:
    telegram:
      token: "$TOKEN"
      chat_id: "-100777"
jobs:
  nightly:
    command: dump
    from: postgres@localhost/appdb
    password: x
    output: $TMP/out
    no_meta: true
    no_health_check: true
EOF

( cd "$TMP" && t-pgsql batch nightly --yaml "$TMP/jobs.yaml" >/dev/null 2>&1 </dev/null )

ls "$TMP"/rec/ps.* >/dev/null 2>&1 && ok "job ran and pg_dump was reached" || nok "job ran and pg_dump was reached"
if grep -q "SECRETTOKENVALUE" "$TMP"/rec/ps.* 2>/dev/null; then nok "token is not in any process argv during the job"; else ok "token is not in any process argv during the job"; fi
if grep -q "T_PGSQL_NOTIFY_SPECS" "$TMP"/rec/env.* 2>/dev/null; then nok "pg_dump does not inherit the notify environment variable"; else ok "pg_dump does not inherit the notify environment variable"; fi
if cat "$TMP"/rec/curl.*.argv 2>/dev/null | grep -q "SECRETTOKENVALUE"; then nok "token is not on curl argv"; else ok "token is not on curl argv"; fi
if cat "$TMP"/rec/curl.*.stdin 2>/dev/null | grep -q "bot$TOKEN/sendMessage"; then ok "the job's child still sent the Telegram notification (token via curl stdin)"; else nok "the job's child still sent the Telegram notification"; fi

# --notify on the command line keeps working
rm -f "$TMP"/rec/curl.*
( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --password x --output "$TMP/out2" \
    --no-meta --no-health-check --notify "telegram:$TOKEN:-100888" >/dev/null 2>&1 </dev/null )
if cat "$TMP"/rec/curl.*.stdin 2>/dev/null | grep -q "bot$TOKEN/sendMessage"; then ok "--notify on the command line still notifies"; else nok "--notify on the command line still notifies"; fi

[ "$FAILS" -eq 0 ]
