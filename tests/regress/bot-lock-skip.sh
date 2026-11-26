#!/usr/bin/env bash
# Regression: a bot-started job skipped by the run lock (exit 75, or batch's exit 0 with a
# "Skipped (locked)" log line) is reported as "already running", not as failed/complete.
# Usage: bash tests/regress/bot-lock-skip.sh   (T_PGSQL_BIN overrides the script under test)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }

sed '$d' "$BIN" > "$TMP/lib.sh"
mkdir -p "$TMP/fakebin" "$TMP/tmp"
# Fake curl: records the request body (stdin config + args) of every call.
cat > "$TMP/fakebin/curl" <<'EOF'
#!/bin/sh
cat >> "$FAKE_LOG"
printf '%s\n' "$*" >> "$FAKE_LOG"
echo '{"ok":true,"result":true}'
EOF
chmod +x "$TMP/fakebin/curl"

run() {   # run <label> <exit code> <log line> -> sets $sent
    : > "$TMP/sent.log"
    # The driver calls "$0 batch all ..."; make $0 a fake t-pgsql via a wrapper script.
    cat > "$TMP/t-fake" <<EOF
#!/bin/sh
[ -n "$3" ] && echo "$3"
exit $2
EOF
    chmod +x "$TMP/t-fake"
    PATH="$TMP/fakebin:$PATH" FAKE_LOG="$TMP/sent.log" LIB="$TMP/lib.sh" TMPDIR="$TMP/tmp" HOME="$TMP" \
        "${BASH:-bash}" -c 'source "$LIB"; bot_run_backup /dev/null nightly 111:AAA -100500 ""; wait' "$TMP/t-fake" > /dev/null 2>&1
    sent=$(cat "$TMP/sent.log")
}

run a 75 ""
case "$sent" in *"Already running"*) ok "exit 75 reported as already running" ;; *) nok "exit 75 not reported as already running: $sent" ;; esac
case "$sent" in *"Backup failed"*) nok "exit 75 reported as failed" ;; *) ok "exit 75 not reported as failed" ;; esac

run b 0 "[WARN] [1/1] Skipped (locked): nightly"
case "$sent" in *"Already running"*) ok "batch skip (exit 0 + log line) reported as already running" ;; *) nok "batch skip not reported: $sent" ;; esac

run c 1 "ERROR: boom"
case "$sent" in *"Backup failed"*) ok "real failure still reported as failed" ;; *) nok "real failure not reported: $sent" ;; esac

run d 0 ""
case "$sent" in *"Backup complete"*) ok "success still reported as complete" ;; *) nok "success not reported: $sent" ;; esac

exit $fail
