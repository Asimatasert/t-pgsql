#!/usr/bin/env bash
# Regression: with TELEGRAM_ALLOWED_USERS (or defaults.telegram_allowed_users) set, messages
# and button callbacks from other senders must not start jobs.
# Usage: bash tests/regress/bot-auth.sh   (T_PGSQL_BIN overrides the script under test)
unset TELEGRAM_ALLOWED_USERS
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
BOT_PID=""
trap '[ -n "$BOT_PID" ] && kill "$BOT_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }

CHAT=-100500
APP="$TMP/app"; FAKE="$TMP/fake"; FAKEBIN="$TMP/fakebin"
mkdir -p "$APP" "$FAKE" "$FAKEBIN" "$TMP/home" "$TMP/tmp" "$TMP/dumps"
cp "$BIN" "$APP/t-pgsql"
cat > "$APP/jobs.yaml" <<YAML
defaults:
  notify:
    telegram:
      token: "111:AAA"
      chat_id: "$CHAT"

jobs:
  nightly:
    command: dump
    output: $TMP/dumps
    from:
      database: mydb
YAML

# Fake curl: records "<method>|<args>" per call, serves $FAKE/updates.json on the first
# getUpdates call and an empty result afterwards (touching $FAKE/done on the second).
cat > "$FAKEBIN/curl" <<'EOF2'
#!/usr/bin/env bash
cfg=$(cat)
method=${cfg##*/}; method=${method%%\"*}
printf '%s|%s\n' "$method" "$(printf '%s ' "$@" | tr '\n' ' ')" >> "$FAKE_DIR/curl.log"
if [ "$method" = getUpdates ]; then
    n=$(cat "$FAKE_DIR/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_DIR/n"
    if [ "$n" = 1 ]; then cat "$FAKE_DIR/updates.json"; else
        echo '{"ok":true,"result":[]}'; : > "$FAKE_DIR/done"; sleep 0.2
    fi
else
    echo '{"ok":true,"result":true}'
fi
EOF2
for c in psql pg_dump pg_restore ssh scp; do printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/$c"; done
chmod +x "$FAKEBIN"/*

# msg <update_id> <user_id|-> <chat> <text> ; cb <update_id> <user_id> <chat> <data>
msg() { local from=""; [ "$2" != "-" ] && from="\"from\":{\"id\":$2,\"first_name\":\"U\"},"
    printf '{"update_id":%s,"message":{"message_id":1,%s"chat":{"id":%s,"type":"supergroup"},"text":"%s"}}' "$1" "$from" "$3" "$4"; }
cb() { printf '{"update_id":%s,"callback_query":{"id":"cb%s","from":{"id":%s,"first_name":"U"},"message":{"message_id":2,"chat":{"id":%s}},"data":"%s"}}' "$1" "$1" "$2" "$3" "$4"; }

# run_bot <updates-json-array-body> [ENV=value ...]: runs the bot until its second poll,
# then stops it. Extra arguments are environment assignments for the bot process.
run_bot() {
    local upd="$1"; shift
    printf '{"ok":true,"result":[%s]}' "$upd" > "$FAKE/updates.json"
    rm -f "$FAKE/done" "$FAKE/n"; : > "$FAKE/curl.log"
    ( cd "$TMP" && exec env PATH="$FAKEBIN:$PATH" FAKE_DIR="$FAKE" HOME="$TMP/home" TMPDIR="$TMP/tmp" \
        XDG_STATE_HOME="$TMP/state" "$@" "${BASH:-bash}" "$APP/t-pgsql" bot --yaml jobs --cooldown 0 \
        > "$TMP/bot.out" 2>&1 ) &
    BOT_PID=$!
    local i; for i in $(seq 1 150); do [ -e "$FAKE/done" ] && break; sleep 0.2; done
    kill "$BOT_PID" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$BOT_PID" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$BOT_PID" 2>/dev/null   # older versions ignore TERM
    wait "$BOT_PID" 2>/dev/null; BOT_PID=""
    sleep 0.3
}
started() { grep -c 'Starting backup' "$FAKE/curl.log"; }

BACKUP="/backup jobs nightly"

# Allowlist set: only user 111 may act.
export_env="TELEGRAM_ALLOWED_USERS=111,222"
run_bot "$(msg 10 111 $CHAT "$BACKUP")" "$export_env"
[ "$(started)" = 1 ] && ok "(a) allowed sender starts the job" || nok "(a) allowed sender did not start the job"

run_bot "$(msg 11 999 $CHAT "$BACKUP")" "$export_env"
[ "$(started)" = 0 ] && ok "(b) disallowed sender in the right chat starts nothing" || nok "(b) disallowed sender started a job"
grep -q 'unauthorized user: 999' "$TMP/bot.out" && ok "(b) rejection is logged" || nok "(b) rejection not logged"

run_bot "$(cb 12 999 $CHAT 'backup:jobs.yaml:nightly')" "$export_env"
[ "$(started)" = 0 ] && ok "(c) callback from disallowed sender starts nothing" || nok "(c) disallowed callback started a job"
grep -q 'answerCallbackQuery|.*Not authorized' "$FAKE/curl.log" && ok "(c) callback is answered as not authorized" || nok "(c) callback not answered as unauthorized"

run_bot "$(cb 13 222 $CHAT 'backup:jobs.yaml:nightly')" "$export_env"
[ "$(started)" = 1 ] && ok "callback from allowed sender starts the job" || nok "allowed callback did not start the job"

run_bot "$(msg 14 - $CHAT "$BACKUP")" "$export_env"
[ "$(started)" = 0 ] && ok "message without a sender id is rejected (fail closed)" || nok "message without sender id started a job"

run_bot "$(msg 15 111 -999 "$BACKUP")" "$export_env"
[ "$(started)" = 0 ] && ok "allowed sender in a different chat is still rejected" || nok "wrong chat started a job"

run_bot "$(msg 16 111 $CHAT "$BACKUP")" TELEGRAM_ALLOWED_USERS=abc
[ "$(started)" = 0 ] && ok "allowlist without a valid id rejects everyone" || nok "invalid allowlist let a sender through"

# YAML default under defaults:
awk '{print} /^defaults:/{print "  telegram_allowed_users: \"111\""}' "$APP/jobs.yaml" > "$APP/jobs.new" && mv "$APP/jobs.new" "$APP/jobs.yaml"
run_bot "$(msg 17 999 $CHAT "$BACKUP")" TELEGRAM_ALLOWED_USERS=
[ "$(started)" = 0 ] && ok "YAML allowlist rejects other senders" || nok "YAML allowlist ignored"
run_bot "$(msg 18 111 $CHAT "$BACKUP")" TELEGRAM_ALLOWED_USERS=
[ "$(started)" = 1 ] && ok "YAML allowlist admits listed sender" || nok "YAML allowlist rejected a listed sender"

# No allowlist: behaviour as before, but a startup warning is logged.
awk '!/telegram_allowed_users/' "$APP/jobs.yaml" > "$APP/jobs.new" && mv "$APP/jobs.new" "$APP/jobs.yaml"
run_bot "$(msg 19 999 $CHAT "$BACKUP")" TELEGRAM_ALLOWED_USERS=
[ "$(started)" = 1 ] && ok "no allowlist: any chat member still works (unchanged)" || nok "no allowlist: behaviour changed"
grep -q 'ANY member of the configured chat' "$TMP/bot.out" && ok "no allowlist: startup warning logged" || nok "no allowlist: no startup warning"

exit $fail
