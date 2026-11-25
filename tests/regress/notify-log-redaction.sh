#!/usr/bin/env bash
# Regression: notification secrets (Telegram token, webhook URL) must not be written to the
# console or to --log files: not by the unknown-channel warning, not by the job debug line.
# Usage: bash tests/regress/notify-log-redaction.sh   (T_PGSQL_BIN=/path/to/t-pgsql for another build)
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
printf 'fake dump\n' >> "$f"
EOF
printf '#!/bin/sh\ncat >/dev/null 2>&1 </dev/null\nprintf "{\\"ok\\":true}\\n"\n' > "$TMP/bin/curl"
chmod +x "$TMP/bin/psql" "$TMP/bin/pg_dump" "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

# 1. Misspelled channel name: the warning must not print the token.
( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --password x --output "$TMP/out" \
    --no-meta --no-health-check --notify "telgram:111222:TYPOSECRET:-100" \
    --log "$TMP/typo.log" >"$TMP/typo.out" 2>&1 </dev/null )
grep -q "Unknown notification channel" "$TMP/typo.out" && ok "unknown channel is still reported" || nok "unknown channel is still reported"
if grep -q "TYPOSECRET" "$TMP/typo.out" "$TMP/typo.log"; then nok "unknown-channel warning does not leak the spec (console and log)"; else ok "unknown-channel warning does not leak the spec (console and log)"; fi
grep -q "telgram:\*\*\*" "$TMP/typo.out" && ok "channel name is kept, the rest is masked" || nok "channel name is kept, the rest is masked"

# 2. Legacy args: job under --verbose: the debug "Command:" line must not print --notify values.
cat > "$TMP/jobs.yaml" <<EOF
jobs:
  legacy:
    command: dump
    args: --from 'postgres@localhost/appdb' --password-file /nonexistent --output '$TMP/out2' --no-meta --no-health-check --notify 'telegram:333444:ARGSSECRET:-100' --notify 'webhook:https://hooks.example.com/ARGSHOOK'
EOF
( cd "$TMP" && t-pgsql batch legacy --yaml "$TMP/jobs.yaml" -v --log "$TMP/job.log" >"$TMP/job.out" 2>&1 </dev/null )
grep -q "Command: dump" "$TMP/job.out" && ok "debug command line is printed" || nok "debug command line is printed"
if grep -q "ARGSSECRET\|ARGSHOOK" "$TMP/job.log" "$TMP/job.out"; then nok "job debug line masks --notify values (console and log)"; else ok "job debug line masks --notify values (console and log)"; fi

[ "$FAILS" -eq 0 ]
