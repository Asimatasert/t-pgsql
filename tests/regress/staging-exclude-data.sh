#!/usr/bin/env bash
# Regression: --exclude-data 'schema.*' must fail closed when the table lookup
# fails, and must hand correctly quoted names to pg_dump. Run from the repo root:
#   bash tests/regress/staging-exclude-data.sh   (T_PGSQL_BIN overrides ./t-pgsql)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

FAKE="$TMP/fake"; REC="$TMP/rec"
mkdir -p "$FAKE" "$REC" "$TMP/out"

# psql: health/other queries succeed; the pg_tables lookup fails when
# PSQL_FAIL=1, otherwise it prints names the way the query asked for them
# (quoted when the query uses format(%I), raw otherwise).
cat > "$FAKE/psql" <<'EOF'
#!/usr/bin/env bash
q="$*"
case "$q" in
    *pg_tables*)
        [ "${PSQL_FAIL:-0}" = 1 ] && { echo "ERROR: simulated failure" >&2; exit 2; }
        case "$q" in
            *"format("*) printf 'audit."Mixed Case"\naudit.plain\n' ;;
            *)           printf 'audit.Mixed Case\naudit.plain\n' ;;
        esac ;;
esac
exit 0
EOF
cat > "$FAKE/pg_dump" <<'EOF'
#!/usr/bin/env bash
: > "$REC/pg_dump.args"
for a in "$@"; do printf '%s\n' "$a" >> "$REC/pg_dump.args"; done
while [ $# -gt 0 ]; do [ "$1" = -f ] && { printf 'PGDMP-fake\n' > "$2"; }; shift; done
exit 0
EOF
cat > "$FAKE/pg_restore" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REC/curl.log"
cat >> "$REC/curl.log" 2>/dev/null
exit 0
EOF
for t in pg_isready createdb dropdb pg_dumpall; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/$t"
done
chmod +x "$FAKE"/*
export REC
export PATH="$FAKE:$PATH"
export T_PGSQL_FROM_PASSWORD=x
export HOME="$TMP/home"; mkdir -p "$HOME"

run() { "$BIN" dump --from "postgres@localhost/appdb" --output "$TMP/out" --exclude-data 'audit.*' </dev/null 2>&1; }

# 1. lookup failure aborts the dump
rm -f "$REC/pg_dump.args"
out=$(PSQL_FAIL=1 run); rc=$?
[ $rc -ne 0 ] && ok "dump fails when the table lookup fails" || nok "dump continued after lookup failure"
[ ! -e "$REC/pg_dump.args" ] && ok "pg_dump never ran after lookup failure" || nok "pg_dump ran without the exclusion"
case "$out" in *"--exclude-data"*) ok "clear error mentions --exclude-data" ;; *) nok "no clear error: $out" ;; esac

# 1b. the abort sends the failure notification
rm -f "$REC/curl.log"
out=$(PSQL_FAIL=1 "$BIN" dump --from "postgres@localhost/appdb" --output "$TMP/out" --exclude-data 'audit.*' \
    --notify webhook:http://192.0.2.9/hook </dev/null 2>&1)
grep -q "Dump failed" "$REC/curl.log" 2>/dev/null && ok "failure notification sent on lookup failure" || nok "no failure notification"

# 2. names needing quoting reach pg_dump as one correctly quoted argument
out=$(PSQL_FAIL=0 run); rc=$?
[ $rc -eq 0 ] && ok "dump succeeds with a working lookup" || nok "dump failed: $out"
grep -qxF 'audit."Mixed Case"' <(sed -n 's/^--exclude-table-data=//p' "$REC/pg_dump.args") \
    && ok "mixed-case table passed quoted to pg_dump" || nok "quoted name missing: $(cat "$REC/pg_dump.args")"
grep -qxF -- '--exclude-table-data=audit.plain' "$REC/pg_dump.args" \
    && ok "plain table passed to pg_dump" || nok "plain table missing"

exit $FAIL
