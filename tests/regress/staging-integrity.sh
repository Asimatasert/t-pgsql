#!/usr/bin/env bash
# Regression: keep-N rotation must not delete older dumps when the new dump is
# empty or unreadable. Run from the repo root:
#   bash tests/regress/staging-integrity.sh   (T_PGSQL_BIN overrides ./t-pgsql)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

FAKE="$TMP/fake"; mkdir -p "$FAKE"
# pg_dump writes what DUMP_BODY says (empty string = leave the file empty).
cat > "$FAKE/pg_dump" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
    if [ "$1" = -f ]; then [ -n "$DUMP_BODY" ] && printf '%s\n' "$DUMP_BODY" > "$2"; fi
    shift
done
exit 0
EOF
# pg_restore -l succeeds only for files containing the marker GOOD.
cat > "$FAKE/pg_restore" <<'EOF'
#!/usr/bin/env bash
for last; do :; done
grep -q GOOD "$last" 2>/dev/null
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/psql"
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH"
export T_PGSQL_FROM_PASSWORD=x
export HOME="$TMP/home"; mkdir -p "$HOME"

OUT="$TMP/out"
run() {
    rm -rf "$OUT"; mkdir -p "$OUT"
    printf 'GOOD old\n' > "$OUT/appdb_20200101_000000.dump"
    touch -t 202001010000 "$OUT/appdb_20200101_000000.dump"
    DUMP_BODY="$1" "$BIN" dump --from "postgres@localhost/appdb" --output "$OUT" --keep 1 --compress none </dev/null 2>&1
}
count_new() { ls "$OUT" | grep -v '^appdb_20200101_000000' | grep -c '^appdb_'; }

# 1. truncated (unreadable) dump: old dump survives, job fails, no new artifact
out=$(run "PGDMP-truncated"); rc=$?
[ $rc -ne 0 ] && ok "unreadable dump fails the job" || nok "unreadable dump reported success"
[ -e "$OUT/appdb_20200101_000000.dump" ] && ok "older dump kept after unreadable new dump" || nok "older dump was rotated away"
[ "$(count_new)" -eq 0 ] && ok "unreadable new dump removed" || nok "unreadable new dump left behind: $(ls "$OUT")"

# 2. empty dump: same
out=$(run ""); rc=$?
[ $rc -ne 0 ] && ok "empty dump fails the job" || nok "empty dump reported success"
[ -e "$OUT/appdb_20200101_000000.dump" ] && ok "older dump kept after empty new dump" || nok "older dump rotated after empty dump"

# 3. good dump: rotation still happens
out=$(run "GOOD new"); rc=$?
[ $rc -eq 0 ] && ok "readable dump succeeds" || nok "readable dump failed: $out"
[ ! -e "$OUT/appdb_20200101_000000.dump" ] && ok "older dump rotated after a good dump" || nok "older dump not rotated"

exit $FAIL
