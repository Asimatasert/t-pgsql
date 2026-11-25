#!/usr/bin/env bash
# Regression: the bot must not use predictable files in a shared temp dir. Symlinks at the
# old paths are not followed, the offset lives in a private state dir, scratch is removed.
# Usage: bash tests/regress/bot-tmpfiles.sh   (T_PGSQL_BIN overrides the script under test)
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

UID_=$(id -u)
STATE="$TMP/state/t-pgsql"
perm() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
first_offset() { grep '^getUpdates|' "$FAKE/curl.log" | head -1 | grep -o 'offset=[0-9]*'; }

# 1. Symlinks planted at the old predictable paths must not be followed.
echo KEEP > "$TMP/victim1"; echo KEEP > "$TMP/victim2"
ln -s "$TMP/victim1" "$TMP/tmp/.t-pgsql-bot-offset-$UID_"
ln -s "$TMP/victim2" "$TMP/tmp/.t-pgsql-bot-resp-$UID_.json"
run_bot "$(msg 10 111 $CHAT '/help')"
[ "$(cat "$TMP/victim1")" = KEEP ] && ok "symlink at old offset path not followed" || nok "old offset symlink target was modified"
[ "$(cat "$TMP/victim2")" = KEEP ] && ok "symlink at old response path not followed" || nok "old response symlink target was modified"

# 2. Offset lives in a private per-user state directory.
[ -d "$STATE" ] && [ "$(perm "$STATE")" = 700 ] && ok "state dir exists with mode 700" || nok "state dir missing or not mode 700"
[ "$(cat "$STATE/bot-offset" 2>/dev/null)" = 11 ] && ok "offset persisted in state dir" || nok "offset not persisted in state dir"

# 3. Nothing is left behind in the shared temp dir after the bot stops.
left=$(ls -A "$TMP/tmp" | grep -v '^\.t-pgsql-bot-\(offset\|resp\)-' | wc -l | tr -d ' ')
[ "$left" = 0 ] && ok "no scratch files left in TMPDIR" || nok "scratch files left in TMPDIR: $(ls -A "$TMP/tmp")"

# 4. A legacy offset (regular file we own) is imported once.
rm -f "$TMP/tmp/.t-pgsql-bot-offset-$UID_" "$TMP/tmp/.t-pgsql-bot-resp-$UID_.json"; rm -rf "$TMP/state"
echo 55 > "$TMP/tmp/.t-pgsql-bot-offset-$UID_"
run_bot ""
[ "$(first_offset)" = offset=55 ] && ok "legacy offset imported on first start" || nok "legacy offset not imported ($(first_offset))"
[ "$(cat "$STATE/bot-offset" 2>/dev/null)" = 55 ] && ok "imported offset saved in state dir" || nok "imported offset not saved"

# 5. A legacy offset that is a symlink is not read.
rm -rf "$TMP/state" "$TMP/tmp/.t-pgsql-bot-offset-$UID_"
echo 77 > "$TMP/target"; ln -s "$TMP/target" "$TMP/tmp/.t-pgsql-bot-offset-$UID_"
run_bot ""
[ "$(first_offset)" = offset=0 ] && ok "legacy offset symlink ignored" || nok "legacy offset symlink was read ($(first_offset))"

# 6. A symlinked offset file inside the state dir is refused, target untouched.
rm -rf "$TMP/state" "$TMP/tmp/.t-pgsql-bot-offset-$UID_"
mkdir -p "$STATE"; chmod 700 "$STATE"
echo KEEP > "$TMP/victim3"; ln -s "$TMP/victim3" "$STATE/bot-offset"
run_bot "$(msg 20 111 $CHAT '/help')"
[ "$(cat "$TMP/victim3")" = KEEP ] && ok "symlinked offset file in state dir not followed" || nok "state offset symlink target modified"

# 7. A non-numeric offset file is not trusted.
rm -rf "$TMP/state"; mkdir -p "$STATE"; chmod 700 "$STATE"; echo 'abc; x' > "$STATE/bot-offset"
run_bot ""
[ "$(first_offset)" = offset=0 ] && ok "non-numeric stored offset treated as 0" || nok "non-numeric offset used ($(first_offset))"

exit $fail
