#!/usr/bin/env bash
# Regression: every supported form of the sender allowlist is understood, and a configured
# allowlist that yields no valid numeric id rejects everyone (never runs open).
# Usage: bash tests/regress/bot-allowlist.sh   (T_PGSQL_BIN overrides the script under test)
. "$(dirname "${BASH_SOURCE[0]}")/bot-lib.sh"

sed '$d' "$BIN" > "$TMP/script-lib.sh"
# allowed <yaml> [env-value]: print the normalized allowlist as the bot computes it.
allowed() ( [ -n "$2" ] && TELEGRAM_ALLOWED_USERS="$2"; JOBS_FILE="$1"; . "$TMP/script-lib.sh"; bot_allowed_users )
check() {   # check <label> <expected> <actual>
    [ "$2" = "$3" ] && ok "$1" || nok "$1 (expected '$2', got '$3')"
}

Y="$TMP/y.yaml"
write_jobs_yaml "$Y" 'telegram_allowed_users: [111, 222]';          check "inline list"          ",111,222," "$(allowed "$Y")"
write_jobs_yaml "$Y" 'telegram_allowed_users: "111,222"';           check "quoted string"        ",111,222," "$(allowed "$Y")"
write_jobs_yaml "$Y" $'telegram_allowed_users:\n    - 111\n    - "222"  # admin'
check "block list"          ",111,222," "$(allowed "$Y")"
write_jobs_yaml "$Y" 'telegram_allowed_users:';                     check "present but empty"    "," "$(allowed "$Y")"
write_jobs_yaml "$Y" $'telegram_allowed_users:\n    - abc';         check "block list, no valid id" "," "$(allowed "$Y")"
write_jobs_yaml "$Y";                                               check "key absent"           "" "$(allowed "$Y")"
check "env var only"        ",5,6," "$(allowed "$Y" 5,6)"
check "env var invalid"     "," "$(allowed "$Y" @alice)"
write_jobs_yaml "$Y" 'telegram_allowed_users: [111]'
check "env var wins over yaml" ",5," "$(allowed "$Y" 5)"

# End to end: block list in the yaml admits only the listed sender.
BACKUP="/backup jobs nightly"
write_jobs_yaml "$APP/jobs.yaml" $'telegram_allowed_users:\n    - 111\n    - 222'
run_bot "$(msg 1 111 $CHAT "$BACKUP"),$(msg 2 999 $CHAT "$BACKUP")"
[ "$(started)" = 1 ] && ok "block list: listed sender runs the job, other sender does not" || nok "block list: $(started) jobs started (expected 1)"

# End to end: key present but empty -> everyone rejected, error names the key.
write_jobs_yaml "$APP/jobs.yaml" 'telegram_allowed_users:'
run_bot "$(msg 3 111 $CHAT "$BACKUP")"
[ "$(started)" = 0 ] && ok "present-but-empty key rejects every sender" || nok "present-but-empty key let a sender through"
grep -q 'telegram_allowed_users' "$TMP/bot.out" && ok "startup error names the key" || nok "no startup error naming the key"

# End to end: invalid environment variable -> everyone rejected.
write_jobs_yaml "$APP/jobs.yaml"
run_bot "$(msg 4 111 $CHAT "$BACKUP")" TELEGRAM_ALLOWED_USERS=@alice
[ "$(started)" = 0 ] && ok "invalid TELEGRAM_ALLOWED_USERS rejects every sender" || nok "invalid env allowlist let a sender through"

exit $fail
