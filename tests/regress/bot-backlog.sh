#!/usr/bin/env bash
# Regression: with no known poll offset the bot must not start at 0 (Telegram would redeliver
# up to 24 hours of old updates and every old /backup would run again). It asks for the newest
# update only (offset -1, limit 1), continues after it without executing it, and persists the
# offset atomically.
# Usage: bash tests/regress/bot-backlog.sh   (T_PGSQL_BIN overrides the script under test)
. "$(dirname "${BASH_SOURCE[0]}")/bot-lib.sh"

STATE="$TMP/state/t-pgsql"
HEAD='{"ok":true,"result":[{"update_id":500,"message":{"message_id":1,"chat":{"id":-100500},"text":"/backup jobs nightly"}}]}'
getupd() { grep '^getUpdates|' "$FAKE/curl.log"; }

# 1. Fresh start: newest update skipped, next poll continues after it.
printf '%s' "$HEAD" > "$FAKE/head.json"
run_bot ""
getupd | head -1 | grep -q 'offset=-1 .*limit=1' && ok "first request asks for the newest update only (offset=-1, limit=1)" || nok "first request was: $(getupd | head -1)"
getupd | sed -n 2p | grep -q 'offset=501 ' && ok "next poll continues after the newest update (501)" || nok "second request was: $(getupd | sed -n 2p)"
[ "$(started)" = 0 ] && ok "backlog update was not executed" || nok "backlog update was executed"
[ "$(cat "$STATE/bot-offset" 2>/dev/null)" = 501 ] && ok "offset 501 persisted" || nok "offset not persisted ($(cat "$STATE/bot-offset" 2>/dev/null))"
grep -q 'skipped the pending backlog' "$TMP/bot.out" && ok "backlog skip is logged" || nok "backlog skip not logged"
ls "$STATE" | grep -q 'bot-offset\.' && nok "temporary offset file left behind: $(ls "$STATE")" || ok "no temporary offset file left behind"

# 2. Known offset: no skip request at all, polling resumes at the stored value.
echo 42 > "$STATE/bot-offset"
run_bot ""
getupd | head -1 | grep -q 'offset=42 ' && ok "stored offset resumed" || nok "first request was: $(getupd | head -1)"
getupd | grep -q 'offset=-1' && nok "stored offset ignored, backlog skipped" || ok "no backlog skip when the offset is known"

# 3. Garbage offset file counts as unknown.
echo 'abc' > "$STATE/bot-offset"
run_bot ""
getupd | head -1 | grep -q 'offset=-1 ' && ok "garbage offset file triggers the backlog skip" || nok "first request was: $(getupd | head -1)"

# 4. Unusable state directory: offset kept in memory, backlog skipped on every start.
printf 'x' > "$TMP/notadir"
run_bot "" XDG_STATE_HOME="$TMP/notadir"
getupd | head -1 | grep -q 'offset=-1 ' && ok "no state directory: backlog skipped" || nok "first request was: $(getupd | head -1)"

# 5. Nothing pending: the first poll starts at 0.
printf '%s' '{"ok":true,"result":[]}' > "$FAKE/head.json"; rm -rf "$TMP/state"
run_bot ""
getupd | sed -n 2p | grep -q 'offset=0 ' && ok "empty backlog: polling starts at 0" || nok "second request was: $(getupd | sed -n 2p)"

exit $fail
