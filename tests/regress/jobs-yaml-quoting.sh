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
printf 'PGDMP\nfake dump\n' >> "$f"
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
n=$(ls "$REC"/curl.*.argv 2>/dev/null | wc -l | tr -d ' '); n=$((n + 1))
printf '%s\n' "$@" > "$REC/curl.$n.argv"
if [ ! -t 0 ]; then cat > "$REC/curl.$n.stdin"; fi
printf '{"ok":true}\n'
EOF
chmod +x "$TMP/bin/psql" "$TMP/bin/pg_dump" "$TMP/bin/curl"
. "$ROOT/tests/regress/lib/fakes.sh"; fake_pg_tools "$TMP/bin"
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
has() { local f; for f in "$TMP"/out/*; do case "${f##*/}" in *"$1"*) return 0 ;; esac; done; return 1; }
has 'q #name_'      && ok "double-quoted value keeps ' #'"                || nok "double-quoted value keeps ' #'"
has "it's_"         && ok "single-quoted '' becomes one apostrophe"        || nok "single-quoted '' becomes one apostrophe"
has 'say "hi"_'     && ok "escaped double quotes inside double quotes"      || nok "escaped double quotes inside double quotes"
has 'plain_'        && ok "an unquoted ' #' still starts a comment"         || nok "an unquoted ' #' still starts a comment"
has 'plain #' && nok "the comment is not part of the plain value" || ok "the comment is not part of the plain value"
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

# --- Corpus: new clean_value versus the base one (copied below), LF and CRLF.
# Rows are  class@@raw value@@expected  ("<empty>" = empty string). "same" rows must come out
# exactly as the base parser returned them; "diff" rows are the intended differences.
BASE_AWK='
function clean_value(v,   q, rest, idx) {
    if (v ~ /^["'\'']/) {
        q = substr(v, 1, 1)
        rest = substr(v, 2)
        idx = index(rest, q)
        if (idx > 0) return substr(rest, 1, idx - 1)
        return rest
    }
    sub(/[ \t]+#.*$/, "", v)
    sub(/^#.*$/, "", v)
    sub(/[ \t]+$/, "", v)
    return v
}
'
eval "$(sed -n "/^_YAML_AWK_LIB='/,/^'\$/p" "$BIN_SRC")"
run_cv() { V="$2" awk "$1"'BEGIN { printf "%s", clean_value(ENVIRON["V"]) }'; }
CR="$(printf '\r')"
check_row() { # class raw expected
    local class="$1" raw="$2" want="$3" new base
    [ "$want" = "<empty>" ] && want=""
    new="$(run_cv "$_YAML_AWK_LIB" "$raw"; echo x)"; new="${new%x}"
    base="$(run_cv "$BASE_AWK" "$raw"; echo x)"; base="${base%x}"
    [ "$new" = "$want" ] && ok "value [$raw] -> [$want]" || nok "value [$raw] -> [$want] (got [$new])"
    if [ "$class" = same ]; then
        [ "$new" = "$base" ] && ok "  unchanged from base: [$raw]" || nok "  unchanged from base: [$raw] (base [$base], new [$new])"
        new="$(run_cv "$_YAML_AWK_LIB" "$raw$CR"; echo x)"; new="${new%x}"
        base="$(run_cv "$BASE_AWK" "$raw$CR"; echo x)"; base="${base%x}"
        [ "$new" = "$base" ] && ok "  unchanged from base with CRLF: [$raw]" || nok "  unchanged from base with CRLF: [$raw]"
    else
        [ "$base" != "$want" ] && ok "  differs from base on purpose: [$raw] (base [$base])" || nok "  expected a difference from base: [$raw]"
    fi
}
while IFS= read -r row; do
    [ -z "$row" ] && continue
    class="${row%%@@*}"; rest="${row#*@@}"; raw="${rest%%@@*}"; want="${rest#*@@}"
    check_row "$class" "$raw" "$want"
done <<'ROWS'
same@@plain@@plain
same@@plain # comment@@plain
same@@# only a comment@@<empty>
same@@a#b@@a#b
same@@http://h:1/x?y=1@@http://h:1/x?y=1
same@@C:\dir\file@@C:\dir\file
same@@"double"@@double
same@@'single'@@single
same@@"a\\b"@@a\\b
same@@"C:\path\"@@C:\path\
same@@"trail\"@@trail\
same@@"x" # c@@x
same@@"a#b"@@a#b
same@@"q #name"@@q #name
same@@'it' # c@@it
same@@it's # comment@@it's
same@@"unterminated@@unterminated
same@@'unterminated@@unterminated
same@@""@@<empty>
diff@@'it''s'@@it's
diff@@"say \"hi\""@@say "hi"
diff@@"abc\" # c"@@abc" # c
diff@@--a 'b # c' --d@@--a 'b # c' --d
diff@@--a "b # c" --d@@--a "b # c" --d
ROWS

[ "$FAILS" -eq 0 ]
