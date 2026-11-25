#!/usr/bin/env bash
# Regression: the bot must not use predictable files in a shared temp dir. Symlinks at the
# old paths are not followed, the offset lives in a private state dir, scratch is removed.
# Usage: bash tests/regress/bot-tmpfiles.sh   (T_PGSQL_BIN overrides the script under test)
. "$(dirname "${BASH_SOURCE[0]}")/bot-lib.sh"

UID_=$(id -u)
STATE="$TMP/state/t-pgsql"
perm() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
first_offset() { grep '^getUpdates|' "$FAKE/curl.log" | head -1 | grep -o 'offset=-\{0,1\}[0-9]*'; }

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
case "$(first_offset)" in offset=77) nok "legacy offset symlink was read" ;; *) ok "legacy offset symlink ignored" ;; esac

# 6. A symlinked offset file inside the state dir is refused, target untouched.
rm -rf "$TMP/state" "$TMP/tmp/.t-pgsql-bot-offset-$UID_"
mkdir -p "$STATE"; chmod 700 "$STATE"
echo KEEP > "$TMP/victim3"; ln -s "$TMP/victim3" "$STATE/bot-offset"
run_bot "$(msg 20 111 $CHAT '/help')"
[ "$(cat "$TMP/victim3")" = KEEP ] && ok "symlinked offset file in state dir not followed" || nok "state offset symlink target modified"

# 7. A non-numeric offset file is not trusted.
rm -rf "$TMP/state"; mkdir -p "$STATE"; chmod 700 "$STATE"; echo 'abc; x' > "$STATE/bot-offset"
run_bot ""
case "$(first_offset)" in offset=abc*) nok "non-numeric offset used" ;; *) ok "non-numeric stored offset not used" ;; esac

exit $fail
