#!/usr/bin/env bash
# Regression: dumps and log files must be created private (umask 077) by default,
# with T_PGSQL_UMASK as an explicit override.
# Usage: bash tests/regress/cli-umask.sh   (T_PGSQL_BIN=/path/to/t-pgsql to test another build)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_SRC="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAILS=$((FAILS + 1)); }

mkdir -p "$TMP/bin"
sed '1s|.*|#!/usr/bin/env bash|' "$BIN_SRC" > "$TMP/bin/t-pgsql"; chmod +x "$TMP/bin/t-pgsql"
ln -s "$BASH" "$TMP/bin/bash"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/psql"
# Fake pg_dump: like the real one, it writes into the file named by -f (keeping its mode).
cat > "$TMP/bin/pg_dump" <<'EOF'
#!/bin/sh
f=""
while [ $# -gt 0 ]; do [ "$1" = "-f" ] && f="$2"; shift; done
printf 'fake dump\n' >> "$f"
EOF
chmod +x "$TMP/bin/psql" "$TMP/bin/pg_dump"
export PATH="$TMP/bin:$PATH"

mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

run_dump() { # $1 = output dir, $2 = log file
    ( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --password x \
        --output "$1" --log "$2" --no-meta --no-health-check >/dev/null 2>&1 )
}

# Default: private files
( umask 022; run_dump "$TMP/out1" "$TMP/logs1/run.log" )
d="$(ls "$TMP"/out1/appdb_*.dump 2>/dev/null | head -n 1)"
[ -n "$d" ] && ok "dump file created" || nok "dump file created"
[ -n "$d" ] && [ "$(mode "$d")" = "600" ] && ok "dump file mode is 600 under a permissive caller umask" || nok "dump file mode is 600 (got: $( [ -n "$d" ] && mode "$d"))"
[ "$(mode "$TMP/logs1/run.log")" = "600" ] && ok "log file mode is 600" || nok "log file mode is 600 (got: $(mode "$TMP/logs1/run.log" 2>&1))"
[ "$(mode "$TMP/out1")" = "700" ] && ok "output directory mode is 700" || nok "output directory mode is 700 (got: $(mode "$TMP/out1"))"

# Override: T_PGSQL_UMASK=007 gives group access
( umask 022; T_PGSQL_UMASK=007 run_dump "$TMP/out2" "$TMP/logs2/run.log" )
d="$(ls "$TMP"/out2/appdb_*.dump 2>/dev/null | head -n 1)"
[ -n "$d" ] && [ "$(mode "$d")" = "660" ] && ok "T_PGSQL_UMASK=007 override gives 660" || nok "T_PGSQL_UMASK=007 override gives 660 (got: $( [ -n "$d" ] && mode "$d"))"

# Invalid override falls back to private
( umask 022; T_PGSQL_UMASK=banana run_dump "$TMP/out3" "$TMP/logs3/run.log" )
d="$(ls "$TMP"/out3/appdb_*.dump 2>/dev/null | head -n 1)"
[ -n "$d" ] && [ "$(mode "$d")" = "600" ] && ok "invalid T_PGSQL_UMASK falls back to 077" || nok "invalid T_PGSQL_UMASK falls back to 077"

[ "$FAILS" -eq 0 ]
