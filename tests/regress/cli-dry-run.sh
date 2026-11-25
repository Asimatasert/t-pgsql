#!/usr/bin/env bash
# Regression: --dry-run must send nothing and write nothing: no summary notification, no
# jobs file created by --save, no job removed by `jobs remove`.
# Usage: bash tests/regress/cli-dry-run.sh   (T_PGSQL_BIN=/path/to/t-pgsql for another build)
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

# --save under --dry-run
( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --dry-run --save nightly --yaml "$TMP/new.yaml" >/dev/null 2>&1 </dev/null )
[ ! -e "$TMP/new.yaml" ] && ok "--save with --dry-run writes no jobs file" || nok "--save with --dry-run writes no jobs file"

# control: without --dry-run the job is saved
( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --save nightly --yaml "$TMP/new.yaml" >/dev/null 2>&1 </dev/null )
grep -q "^  nightly:" "$TMP/new.yaml" 2>/dev/null && ok "--save without --dry-run still saves the job" || nok "--save without --dry-run still saves the job"

# jobs remove under --dry-run
cp "$TMP/new.yaml" "$TMP/before.yaml"
( cd "$TMP" && t-pgsql jobs remove nightly --dry-run --yaml "$TMP/new.yaml" >/dev/null 2>&1 </dev/null )
cmp -s "$TMP/new.yaml" "$TMP/before.yaml" && ok "jobs remove with --dry-run leaves the file untouched" || nok "jobs remove with --dry-run leaves the file untouched"

# control: a real remove removes
( cd "$TMP" && t-pgsql jobs remove nightly --yaml "$TMP/new.yaml" >/dev/null 2>&1 </dev/null )
grep -q "^  nightly:" "$TMP/new.yaml" 2>/dev/null && nok "jobs remove without --dry-run still removes the job" || ok "jobs remove without --dry-run still removes the job"

# batch --dry-run --notify-summary
cat > "$TMP/jobs.yaml" <<EOF
defaults:
  notify:
    telegram:
      token: "515151:DRYSECRET"
      chat_id: "-100111"
jobs:
  only-job:
    command: dump
    from: postgres@localhost/appdb
    password: x
    output: $TMP/out
    no_meta: true
    no_health_check: true
EOF
( cd "$TMP" && t-pgsql batch all --yaml "$TMP/jobs.yaml" --notify-summary --notify "telegram:515151:DRYSECRET:-100111" --dry-run >/dev/null 2>&1 </dev/null )
CALLS=$(ls "$TMP"/rec/curl.*.argv 2>/dev/null | wc -l | tr -d ' ')
[ "$CALLS" -eq 0 ] && ok "batch --dry-run --notify-summary sends nothing" || nok "batch --dry-run --notify-summary sends nothing (curl calls=$CALLS)"
ls "$TMP"/out/*.dump >/dev/null 2>&1 && nok "dry-run batch creates no dump file" || ok "dry-run batch creates no dump file"

# control: without --dry-run the summary is sent
( cd "$TMP" && t-pgsql batch all --yaml "$TMP/jobs.yaml" --notify-summary --notify "telegram:515151:DRYSECRET:-100111" >/dev/null 2>&1 </dev/null )
grep -l "Batch completed" "$TMP"/rec/curl.*.argv >/dev/null 2>&1 && ok "summary is sent without --dry-run" || nok "summary is sent without --dry-run"

[ "$FAILS" -eq 0 ]
