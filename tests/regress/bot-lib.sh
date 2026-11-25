#!/usr/bin/env bash
# Shared helpers for the tests/regress/bot-*.sh scripts (source this file; it has no tests).
#
# Hermetic: fake curl/psql/pg_dump/pg_restore/ssh/scp first in PATH, private HOME/TMPDIR/state.
# Bounded: the fake curl stops the bot (TERM to the recorded PID) after a fixed number of
# polls, every bot start is wrapped in `timeout 60` when that command exists, and the exit
# trap stops exactly the recorded PID (TERM, bounded wait, KILL).

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "ok - bot-lib.sh is a helper library (no tests)"
    exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
unset TELEGRAM_ALLOWED_USERS JOBS_FILE
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }

CHAT=-100500
APP="$TMP/app"; FAKE="$TMP/fake"; FAKEBIN="$TMP/fakebin"
mkdir -p "$APP" "$FAKE" "$FAKEBIN" "$TMP/home" "$TMP/tmp" "$TMP/dumps"
cp "$BIN" "$APP/t-pgsql"
write_jobs_yaml() {   # write_jobs_yaml <path> [extra defaults line]
    cat > "$1" <<YAML
defaults:
  notify:
    telegram:
      token: "111:AAA"
      chat_id: "$CHAT"
${2:+  $2}

jobs:
  nightly:
    command: dump
    output: $TMP/dumps
    from:
      database: mydb
YAML
}
write_jobs_yaml "$APP/jobs.yaml"

# Fake curl: records "<method>|<args>" per call. getUpdates with offset=-1 answers from
# $FAKE/head.json; other polls count: the first serves $FAKE/updates.json, later ones are
# empty, and poll number $FAKE/maxpoll (default 3) sends TERM to the recorded bot PID.
cat > "$FAKEBIN/curl" <<'EOF2'
#!/usr/bin/env bash
cfg=$(cat)
method=${cfg##*/}; method=${method%%\"*}
args=$(printf '%s ' "$@" | tr '\n' ' ')
printf '%s|%s\n' "$method" "$args" >> "$FAKE_DIR/curl.log"
if [ "$method" = getUpdates ]; then
    case "$args" in
        *offset=-1*) cat "$FAKE_DIR/head.json" 2>/dev/null || echo '{"ok":true,"result":[]}'; exit 0 ;;
    esac
    n=$(cat "$FAKE_DIR/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_DIR/n"
    if [ "$n" = 1 ]; then cat "$FAKE_DIR/updates.json"; else echo '{"ok":true,"result":[]}'; fi
    if [ "$n" -ge "$(cat "$FAKE_DIR/maxpoll" 2>/dev/null || echo 3)" ]; then
        : > "$FAKE_DIR/done"
        pid=$(cat "$FAKE_DIR/botpid" 2>/dev/null) && [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
    else
        sleep 0.2
    fi
else
    echo '{"ok":true,"result":true}'
fi
EOF2
cat > "$FAKEBIN/pg_dump" <<'EOF2'
#!/bin/sh
# Fake pg_dump: writes a custom-format magic header to the -f/--file target.
out=""; prev=""
for a in "$@"; do
    case "$prev" in -f|--file) out="$a" ;; esac
    case "$a" in --file=*) out="${a#--file=}" ;; esac
    prev="$a"
done
[ -n "$out" ] && printf 'PGDMP' > "$out"
exit 0
EOF2
for c in psql pg_restore ssh scp; do printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/$c"; done
chmod +x "$FAKEBIN"/*

# Launcher: records its own PID (it becomes the bot via exec) so exactly that PID is stopped.
cat > "$TMP/launch.sh" <<'EOF2'
#!/bin/sh
echo $$ > "$FAKE_DIR/botpid"
exec "$BASH_BIN" "$APP/t-pgsql" bot --yaml "$YAML_ARG" --cooldown "${COOLDOWN_ARG:-0}"
EOF2
chmod +x "$TMP/launch.sh"
TIMEOUT_CMD=""; command -v timeout > /dev/null 2>&1 && TIMEOUT_CMD="timeout 60"

stop_bot() {
    local pid i
    pid=$(cat "$FAKE/botpid" 2>/dev/null) || return 0
    [ -n "$pid" ] || return 0
    kill -TERM "$pid" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    rm -f "$FAKE/botpid"
}
trap 'stop_bot; rm -rf "$TMP"' EXIT

# msg <update_id> <user_id|-> <chat> <text> ; cb <update_id> <user_id> <chat> <data>
msg() { local from=""; [ "$2" != "-" ] && from="\"from\":{\"id\":$2,\"first_name\":\"U\"},"
    printf '{"update_id":%s,"message":{"message_id":1,%s"chat":{"id":%s,"type":"supergroup"},"text":"%s"}}' "$1" "$from" "$3" "$4"; }
cb() { printf '{"update_id":%s,"callback_query":{"id":"cb%s","from":{"id":%s,"first_name":"U"},"message":{"message_id":2,"chat":{"id":%s}},"data":"%s"}}' "$1" "$1" "$2" "$3" "$4"; }

# run_bot <updates-json-array-body> [ENV=value ...]
# Starts the bot, waits (bounded) until it stops itself, then makes sure it is gone.
# Optional per-call settings: YAML_ARG (default "jobs"), $FAKE/head.json, $FAKE/maxpoll.
run_bot() {
    local upd="$1" pid i; shift
    printf '{"ok":true,"result":[%s]}' "$upd" > "$FAKE/updates.json"
    rm -f "$FAKE/done" "$FAKE/n" "$FAKE/botpid"; : > "$FAKE/curl.log"
    ( cd "$TMP" && exec $TIMEOUT_CMD env PATH="$FAKEBIN:$PATH" FAKE_DIR="$FAKE" HOME="$TMP/home" \
        TMPDIR="$TMP/tmp" XDG_STATE_HOME="$TMP/state" BASH_BIN="${BASH:-bash}" APP="$APP" \
        YAML_ARG="${YAML_ARG:-jobs}" "$@" sh "$TMP/launch.sh" > "$TMP/bot.out" 2>&1 ) &
    for i in $(seq 1 150); do [ -e "$FAKE/done" ] && break; sleep 0.2; done
    pid=$(cat "$FAKE/botpid" 2>/dev/null)
    for i in $(seq 1 25); do { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || break; sleep 0.2; done
    stop_bot
    wait 2>/dev/null
    sleep 0.3
}
started() { grep -c 'Starting backup' "$FAKE/curl.log"; }
