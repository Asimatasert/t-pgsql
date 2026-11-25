#!/usr/bin/env bash
# Regression: the Telegram failure alert must survive an oversized or awkward callback_data:
# long names fall back to backup:<job> (or no button), reply_markup is URL-encoded, and the
# plain-text retry does not resend the button.
# Usage: bash tests/regress/notify-callback-data.sh   (T_PGSQL_BIN=/path/to/t-pgsql for another build)
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
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/pg_dump"      # the dump fails -> failure alert
# Fake curl: records argv. TG_MD_FAIL=1 makes the Markdown attempt fail (like a 400).
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
n=$(ls "$REC"/curl.*.argv 2>/dev/null | wc -l | tr -d ' '); n=$((n + 1))
printf '%s\n' "$@" > "$REC/curl.$n.argv"
if [ ! -t 0 ]; then cat > "$REC/curl.$n.stdin"; fi
if [ "$TG_MD_FAIL" = 1 ] && grep -q '^parse_mode=Markdown$' "$REC/curl.$n.argv"; then
    printf '{"ok":false,"description":"can not parse entities"}\n'
else
    printf '{"ok":true}\n'
fi
EOF
chmod +x "$TMP/bin/psql" "$TMP/bin/pg_dump" "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" REC="$TMP/rec"

run_failing_dump() { # $1 = yaml file name, $2 = job name
    rm -f "$TMP"/rec/curl.*
    ( cd "$TMP" && JOBS_FILE="$TMP/$1" CURRENT_JOB_NAME="$2" t-pgsql dump \
        --from postgres@localhost/appdb --password x --output "$TMP/out" \
        --no-meta --no-health-check --notify "telegram:777888:CBSECRET:-100" >/dev/null 2>&1 </dev/null )
}
# value of the reply_markup parameter in the first recorded call ("" when absent) and the flag before it
markup_of() { awk '/^reply_markup=/{sub(/^reply_markup=/,""); print; exit}' "$TMP/rec/curl.${1:-1}.argv" 2>/dev/null; }
markup_flag() { awk 'prev && /^reply_markup=/{print prev; exit} {prev=$0}' "$TMP/rec/curl.${1:-1}.argv" 2>/dev/null; }

# 1. short names: button with the full form, sent URL-encoded
run_failing_dump jobs.yaml nightly
case "$(markup_of 1)" in *'"callback_data":"backup:jobs.yaml:nightly"'*) ok "short names keep backup:<yaml>:<job>";; *) nok "short names keep backup:<yaml>:<job>";; esac
[ "$(markup_flag 1)" = "--data-urlencode" ] && ok "reply_markup is sent with --data-urlencode" || nok "reply_markup is sent with --data-urlencode (got: $(markup_flag 1))"

# 2. an ampersand in the yaml name must survive intact
run_failing_dump 'a&b.yaml' nightly
case "$(markup_of 1)" in *'backup:a&b.yaml:nightly'*) ok "ampersand in the yaml name is kept in the payload";; *) nok "ampersand in the yaml name is kept in the payload";; esac
[ "$(markup_flag 1)" = "--data-urlencode" ] && ok "reply_markup stays URL-encoded for an awkward name" || nok "reply_markup stays URL-encoded for an awkward name"

# 3. yaml+job over 64 bytes: fall back to backup:<job>
run_failing_dump team-databases-production-environment-backups.yaml nightly-prod-to-staging-restore
m="$(markup_of 1)"
case "$m" in *'"callback_data":"backup:nightly-prod-to-staging-restore"'*) ok "over-long callback_data falls back to backup:<job>";; *) nok "over-long callback_data falls back to backup:<job> (got: $m)";; esac

# 4. even the short form too long: alert without a button
long="$(printf 'j%.0s' $(seq 1 70))"
run_failing_dump jobs.yaml "$long"
[ -f "$TMP/rec/curl.1.argv" ] && ok "the alert is still sent" || nok "the alert is still sent"
[ -z "$(markup_of 1)" ] && ok "no button when even backup:<job> exceeds 64 bytes" || nok "no button when even backup:<job> exceeds 64 bytes"

# 5. Markdown attempt fails: the plain-text retry must not carry the button
TG_MD_FAIL=1 run_failing_dump jobs.yaml nightly
[ "$(ls "$TMP"/rec/curl.*.argv | wc -l | tr -d ' ')" -eq 2 ] && ok "a plain-text retry happens after the Markdown failure" || nok "a plain-text retry happens after the Markdown failure"
[ -n "$(markup_of 1)" ] && [ -z "$(markup_of 2)" ] && ok "retry drops reply_markup" || nok "retry drops reply_markup"

[ "$FAILS" -eq 0 ]
