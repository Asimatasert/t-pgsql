#!/usr/bin/env bash
# Regression: YAML values must not be silently truncated or corrupted: ' #' and embedded quotes
# inside quoted values, a quoted Telegram token followed by a comment, a saved args: line with
# a quoted ' #', and a config value with a lone trailing quote. An unquoted ' #' still starts a comment.
# Usage: bash tests/regress/jobs-yaml-quoting.sh   (T_PGSQL_BIN=/path/to/t-pgsql for another build)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_SRC="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAILS=$((FAILS + 1)); }

mkdir -p "$TMP/bin" "$TMP/rec"
sed '1s|.*|#!/usr/bin/env bash|' "$BIN_SRC" > "$TMP/bin/t-pgsql"; chmod +x "$TMP/bin/t-pgsql"
ln -s "$BASH" "$TMP/bin/bash"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/psql"
cat > "$TMP/bin/pg_dump" <<'EOF'
#!/bin/sh
f=""
while [ $# -gt 0 ]; do [ "$1" = "-f" ] && f="$2"; shift; done
printf 'fake dump\n' >> "$f"
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
n=$(ls "$REC"/curl.*.argv 2>/dev/null | wc -l | tr -d ' '); n=$((n + 1))
printf '%s\n' "$@" > "$REC/curl.$n.argv"
if [ ! -t 0 ]; then cat > "$REC/curl.$n.stdin"; fi
printf '{"ok":true}\n'
EOF
chmod +x "$TMP/bin/psql" "$TMP/bin/pg_dump" "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" REC="$TMP/rec"
unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID

COMMON="    from: postgres@localhost/appdb
    password: x
    output: $TMP/out
    no_meta: true
    no_health_check: true"
cat > "$TMP/jobs.yaml" <<EOF
defaults:
  notify:
    telegram:
      token: "616161:CMTSECRET"  # the bot
      chat_id: '-100222' # the chat
jobs:
  j1:
    command: dump
    dump_name: "q #name"
$COMMON
  j2:
    command: dump
    dump_name: 'it''s'
$COMMON
  j3:
    command: dump
    dump_name: "say \"hi\""
$COMMON
  j4:
    command: dump
    dump_name: plain # trailing comment
$COMMON
  j5:
    command: dump
    args: --from 'postgres@localhost/appdb' --password x --output '$TMP/out' --no-meta --no-health-check --dump-name 'arg #name'
EOF

( cd "$TMP" && t-pgsql batch all --yaml "$TMP/jobs.yaml" --continue-on-error >"$TMP/run.out" 2>&1 </dev/null )
has() { ls "$TMP/out" 2>/dev/null | grep -qF -- "$1"; }
has 'q #name_'      && ok "double-quoted value keeps ' #'"                || nok "double-quoted value keeps ' #'"
has "it's_"         && ok "single-quoted '' becomes one apostrophe"        || nok "single-quoted '' becomes one apostrophe"
has 'say "hi"_'     && ok "escaped double quotes inside double quotes"      || nok "escaped double quotes inside double quotes"
has 'plain_'        && ok "an unquoted ' #' still starts a comment"         || nok "an unquoted ' #' still starts a comment"
ls "$TMP/out" 2>/dev/null | grep -q '^plain #' && nok "the comment is not part of the plain value" || ok "the comment is not part of the plain value"
has 'arg #name_'    && ok "a quoted ' #' inside an args: line is kept"      || nok "a quoted ' #' inside an args: line is kept"

if cat "$TMP"/rec/curl.*.stdin 2>/dev/null | grep -q 'bot616161:CMTSECRET/sendMessage'; then
    ok "quoted Telegram token followed by a comment is parsed cleanly"
else
    nok "quoted Telegram token followed by a comment is parsed cleanly"
fi

# --config: a lone trailing quote is part of the value, a matching pair is stripped
cat > "$TMP/c1.conf" <<EOF
output: $TMP/cfgout"
EOF
cat > "$TMP/c2.conf" <<EOF
output: "$TMP/cfgout2"
EOF
( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --password x --config "$TMP/c1.conf" --no-meta --no-health-check >/dev/null 2>&1 </dev/null )
[ -d "$TMP/cfgout\"" ] && ok "config: a lone trailing quote is kept" || nok "config: a lone trailing quote is kept"
( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --password x --config "$TMP/c2.conf" --no-meta --no-health-check >/dev/null 2>&1 </dev/null )
[ -d "$TMP/cfgout2" ] && ok "config: a matching pair of quotes is stripped" || nok "config: a matching pair of quotes is stripped"

[ "$FAILS" -eq 0 ]
