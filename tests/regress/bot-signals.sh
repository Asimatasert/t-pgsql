#!/usr/bin/env bash
# Regression: TERM stops the bot with status 143 and INT with 130 (cleaning up its scratch
# directory), and the log of a job started by the bot is not kept in a directory that the
# exit cleanup removes: it lives in the per-user state dir and is removed only after the job
# has finished and been reported. A job that is already running keeps running when the bot stops.
# Usage: bash tests/regress/bot-signals.sh   (T_PGSQL_BIN overrides the script under test)
. "$(dirname "${BASH_SOURCE[0]}")/bot-lib.sh"

rc=$(run_bot_signal TERM)
[ "$rc" = 143 ] && ok "TERM exits with status 143" || nok "TERM exit status was '$rc'"
ls -A "$TMP/tmp" | grep -q 't-pgsql-bot' && nok "scratch directory left after TERM" || ok "scratch directory removed after TERM"

rc=$(run_bot_signal INT)
[ "$rc" = 130 ] && ok "INT exits with status 130" || nok "INT exit status was '$rc'"
ls -A "$TMP/tmp" | grep -q 't-pgsql-bot' && nok "scratch directory left after INT" || ok "scratch directory removed after INT"

# Run log lifetime. The job script is this helper itself (bot_run_backup runs "$0" batch ...).
sed '$d' "$BIN" > "$TMP/script-lib.sh"
cat > "$TMP/jobcheck.sh" <<'EOF2'
#!/usr/bin/env bash
if [ "$1" = batch ]; then echo "ERROR: boom from job"; sleep 1; exit 1; fi
RUNS=$1; REPORT=$2; SCRIPT_LIB=$3
. "$SCRIPT_LIB"
bot_send_message() { printf '%s\n' "$4" >> "$REPORT"; }
_BOT_RUNS_DIR="$RUNS"
bot_run_backup /nonexistent.yaml nightly tok 1 ""
sleep 0.3
for f in "$RUNS"/run-*/log; do [ -f "$f" ] && echo "$f"; done > "$RUNS/../during.txt"
exit 0
EOF2
chmod +x "$TMP/jobcheck.sh"
mkdir -p "$TMP/runs"; chmod 700 "$TMP/runs"
# The parent exits right after starting the job (like a bot that is stopped); the job goes on.
"${BASH:-bash}" "$TMP/jobcheck.sh" "$TMP/runs" "$TMP/report" "$TMP/script-lib.sh" > /dev/null 2>&1
grep -q "$TMP/runs/run-" "$TMP/during.txt" 2>/dev/null && ok "run log lives in the runs directory while the job runs" || nok "run log not in the runs directory ($(cat "$TMP/during.txt" 2>/dev/null))"
for i in $(seq 1 50); do [ -s "$TMP/report" ] && break; sleep 0.2; done
grep -q 'boom from job' "$TMP/report" 2>/dev/null && ok "job kept running after its parent exited and its error line was reported" || nok "no report with the job's log line ($(cat "$TMP/report" 2>/dev/null))"
for i in $(seq 1 15); do [ -z "$(ls -A "$TMP/runs")" ] && break; sleep 0.2; done
[ -z "$(ls -A "$TMP/runs")" ] && ok "run log removed after the job was reported" || nok "run log left behind: $(ls -A "$TMP/runs")"

exit $fail
