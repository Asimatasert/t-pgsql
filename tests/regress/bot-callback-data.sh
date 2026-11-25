#!/usr/bin/env bash
# Regression: the bot must accept the short callback form backup:<job> as well as
# backup:<yaml>:<job> (Telegram limits callback_data to 64 bytes).
# Usage: bash tests/regress/bot-callback-data.sh   (T_PGSQL_BIN overrides the script under test)
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
    ( cd "$TMP" && env PATH="$FAKEBIN:$PATH" FAKE_DIR="$FAKE" HOME="$TMP/home" TMPDIR="$TMP/tmp" \
        XDG_STATE_HOME="$TMP/state" "$@" "${BASH:-bash}" "$APP/t-pgsql" bot --yaml jobs --cooldown 0 \
        > "$TMP/bot.out" 2>&1 ) &
    BOT_PID=$!
    local i; for i in $(seq 1 150); do [ -e "$FAKE/done" ] && break; sleep 0.2; done
    kill "$BOT_PID" 2>/dev/null; wait "$BOT_PID" 2>/dev/null; BOT_PID=""
    sleep 0.3
}
started() { grep -c 'Starting backup' "$FAKE/curl.log"; }

# Short callback form "backup:<job>" (sent when the full callback would exceed 64 bytes).
run_bot "$(cb 10 222 $CHAT 'backup:nightly')"
[ "$(started)" = 1 ] && ok "short callback backup:<job> starts the job" || nok "short callback did not start the job"

run_bot "$(cb 11 222 $CHAT 'backup:jobs.yaml:nightly')"
[ "$(started)" = 1 ] && ok "full callback backup:<yaml>:<job> still works" || nok "full callback broken"

run_bot "$(cb 12 222 $CHAT 'backup:jobs.yaml:')"
[ "$(started)" = 0 ] && ok "callback with empty job starts nothing" || nok "empty-job callback started a job"

exit $fail
