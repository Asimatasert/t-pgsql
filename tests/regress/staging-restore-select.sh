#!/usr/bin/env bash
# Regression: `restore` without --file must not pick the newest dump of an
# unrelated database when the output directory holds several bases. Run from
# the repo root:
#   bash tests/regress/staging-restore-select.sh   (T_PGSQL_BIN overrides ./t-pgsql)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

FAKE="$TMP/fake"; mkdir -p "$FAKE"
for t in psql pg_restore createdb dropdb pg_dump pg_isready pg_dumpall; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/$t"
done
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH"
export T_PGSQL_TO_PASSWORD=x
export HOME="$TMP/home"; mkdir -p "$HOME"

D="$TMP/dumps"; mkdir -p "$D"
printf 'PGDMP-fake\n' > "$D/appdb_20200101_000000.dump"
printf 'PGDMP-fake\n' > "$D/otherdb_20200201_000000.dump"
touch -t 202001010000 "$D/appdb_20200101_000000.dump"
touch -t 202002010000 "$D/otherdb_20200201_000000.dump"

rs() { "$BIN" restore --output "$D" --dry-run "$@" </dev/null 2>&1; }

# 1. target database picks its own dump although another base is newer
out=$(rs --to "postgres@localhost/appdb")
case "$out" in *"Using latest: appdb_20200101_000000.dump"*) ok "target db selects its own dump" ;; *) nok "wrong selection: $out" ;; esac

# 2. --dump-name wins
out=$(rs --to "postgres@localhost/appdb" --dump-name otherdb)
case "$out" in *"Using latest: otherdb_20200201_000000.dump"*) ok "--dump-name selects that base" ;; *) nok "dump-name ignored: $out" ;; esac

# 3. no matching base: error listing bases, non-zero exit
out=$(rs --to "postgres@localhost/zzz"); rc=$?
[ $rc -ne 0 ] && ok "no matching base fails" || nok "no matching base succeeded"
case "$out" in *"appdb"*"otherdb"*"--file"*) ok "error lists bases and mentions --file" ;; *) nok "unhelpful error: $out" ;; esac

# 4. single base: behaviour unchanged (newest of that base, any target name)
rm -f "$D/appdb_20200101_000000.dump"
out=$(rs --to "postgres@localhost/zzz")
case "$out" in *"Using latest: otherdb_20200201_000000.dump"*) ok "single base unchanged" ;; *) nok "single base changed: $out" ;; esac

exit $FAIL
