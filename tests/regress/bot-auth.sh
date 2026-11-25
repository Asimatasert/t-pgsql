#!/usr/bin/env bash
# Regression: with TELEGRAM_ALLOWED_USERS (or defaults.telegram_allowed_users) set, messages
# and button callbacks from other senders must not start jobs.
# Usage: bash tests/regress/bot-auth.sh   (T_PGSQL_BIN overrides the script under test)
. "$(dirname "${BASH_SOURCE[0]}")/bot-lib.sh"

BACKUP="/backup jobs nightly"

# Allowlist set: only users 111 and 222 may act.
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

# No allowlist: behaviour as before, but a startup warning is logged.
run_bot "$(msg 19 999 $CHAT "$BACKUP")"
[ "$(started)" = 1 ] && ok "no allowlist: any chat member still works (unchanged)" || nok "no allowlist: behaviour changed"
grep -q 'ANY member of the configured chat' "$TMP/bot.out" && ok "no allowlist: startup warning logged" || nok "no allowlist: no startup warning"

exit $fail
