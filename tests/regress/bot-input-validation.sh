#!/usr/bin/env bash
# Regression: yaml and job names that arrive through bot chat/callback data must be
# plain names. Paths, "..", leading dashes and odd characters are rejected.
# Usage: bash tests/regress/bot-input-validation.sh   (T_PGSQL_BIN overrides the script under test)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }

sed '$d' "$BIN" > "$TMP/lib.sh"
# shellcheck disable=SC1090,SC1091
source "$TMP/lib.sh"
SCRIPT_DIR="$TMP/app"; mkdir -p "$SCRIPT_DIR"

for n in /etc/passwd ../x a/b .hidden -x 'a b' 'a;b' '$(id)' 'x..y'; do
    r=$(bot_resolve_yaml "$n")
    [ -z "$r" ] && ok "yaml name rejected: $n" || nok "yaml name accepted: $n -> $r"
done
r=$(bot_resolve_yaml prod);      [ "$r" = "$SCRIPT_DIR/prod.yaml" ] && ok "plain name resolves" || nok "plain name: $r"
r=$(bot_resolve_yaml prod.yaml); [ "$r" = "$SCRIPT_DIR/prod.yaml" ] && ok "name with .yaml resolves" || nok "name with .yaml: $r"

# End to end through /backup: an absolute path to a real yaml must not start a job.
cat > "$TMP/evil.yaml" <<YAML
jobs:
  j1:
    command: dump
YAML
STARTED="$TMP/started"; : > "$STARTED"
bot_send_message() { :; }
bot_run_backup() { echo "$2" >> "$STARTED"; }
bot_check_cooldown() { :; }
bot_cmd_backup tok 1 "" "$TMP/evil.yaml" j1 1h >/dev/null 2>&1
[ ! -s "$STARTED" ] && ok "absolute yaml path does not start a job" || nok "absolute yaml path started a job"

cp "$TMP/evil.yaml" "$SCRIPT_DIR/good.yaml"
bot_cmd_backup tok 1 "" good j1 1h >/dev/null 2>&1
[ "$(cat "$STARTED")" = "j1" ] && ok "plain yaml name still starts the job" || nok "plain yaml name did not start the job"

: > "$STARTED"
bot_cmd_backup tok 1 "" good "--x" 1h >/dev/null 2>&1
[ ! -s "$STARTED" ] && ok "job name starting with a dash is rejected" || nok "dash job name started a job"

exit $fail
