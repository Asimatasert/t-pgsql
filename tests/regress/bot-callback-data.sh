#!/usr/bin/env bash
# Regression: the bot must accept the short callback form backup:<job> as well as
# backup:<yaml>:<job> (Telegram limits callback_data to 64 bytes).
# Usage: bash tests/regress/bot-callback-data.sh   (T_PGSQL_BIN overrides the script under test)
. "$(dirname "${BASH_SOURCE[0]}")/bot-lib.sh"

# Short callback form "backup:<job>" (sent when the full callback would exceed 64 bytes).
run_bot "$(cb 10 222 $CHAT 'backup:nightly')"
[ "$(started)" = 1 ] && ok "short callback backup:<job> starts the job" || nok "short callback did not start the job"

run_bot "$(cb 11 222 $CHAT 'backup:jobs.yaml:nightly')"
[ "$(started)" = 1 ] && ok "full callback backup:<yaml>:<job> still works" || nok "full callback broken"

run_bot "$(cb 12 222 $CHAT 'backup:jobs.yaml:')"
[ "$(started)" = 0 ] && ok "callback with empty job starts nothing" || nok "empty-job callback started a job"

exit $fail
