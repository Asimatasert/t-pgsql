#!/usr/bin/env bash
# Regression: --min-size-ratio is honoured from a config file (underscore and hyphen
# keys, CLI wins) and from a jobs.yaml job key (min_size_ratio), is a known job key,
# shows up in `jobs show` and is written by --save; a failing guard makes the batch
# exit non-zero.
# Hermetic: pg_dump, psql and friends are faked.
#   bash tests/regress/shrink-jobs.sh   (T_PGSQL_BIN overrides ./t-pgsql)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_SRC="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAILS=$((FAILS + 1)); }

mkdir -p "$TMP/bin"
sed '1s|.*|#!/usr/bin/env bash|' "$BIN_SRC" > "$TMP/bin/t-pgsql"; chmod +x "$TMP/bin/t-pgsql"
ln -s "$BASH" "$TMP/bin/bash"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/psql"
cat > "$TMP/bin/pg_dump" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
    if [ "$1" = -f ]; then { printf 'PGDMP'; printf '%*s' $((DUMP_BYTES - 5)) '' | tr ' ' x; } > "$2"; fi
    shift
done
exit 0
EOF
chmod +x "$TMP/bin/psql" "$TMP/bin/pg_dump"
. "$ROOT/tests/regress/lib/fakes.sh"; fake_pg_tools "$TMP/bin"
export PATH="$TMP/bin:$PATH" DUMP_BYTES=800 HOME="$TMP/home"; mkdir -p "$HOME"

OUT="$TMP/out"
mk() { { printf 'PGDMP'; printf '%*s' $(($2 - 5)) '' | tr ' ' x; } > "$1"; touch -t "$3" "$1"; }
seed() { rm -rf "$OUT"; mkdir -p "$OUT"; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000; }
suspects() { ls "$OUT" | grep -c '\.suspect$'; }

# 1. config file: underscore key, hyphen key, CLI wins
printf 'min_size_ratio: 90\n' > "$TMP/a.conf"
seed; ( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --password x --output "$OUT" --compress none --no-health-check --config "$TMP/a.conf" >"$TMP/o1" 2>&1 </dev/null ); rc=$?
[ $rc -ne 0 ] && [ "$(suspects)" -eq 1 ] && ok "config min_size_ratio is applied" || nok "config min_size_ratio ignored (rc=$rc)"
printf 'min-size-ratio: 90\n' > "$TMP/b.conf"
seed; ( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --password x --output "$OUT" --compress none --no-health-check --config "$TMP/b.conf" >"$TMP/o2" 2>&1 </dev/null ); rc=$?
[ $rc -ne 0 ] && [ "$(suspects)" -eq 1 ] && ok "config min-size-ratio (hyphen) is applied" || nok "config min-size-ratio ignored (rc=$rc)"
seed; ( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --password x --output "$OUT" --compress none --no-health-check --config "$TMP/a.conf" --min-size-ratio 10 >"$TMP/o3" 2>&1 </dev/null ); rc=$?
[ $rc -eq 0 ] && ok "CLI value beats the config file" || nok "CLI did not beat config (rc=$rc)"

# 2. jobs.yaml job key
cat > "$TMP/jobs.yaml" <<EOF
jobs:
  strict-job:
    command: dump
    from: postgres@localhost/appdb
    password: x
    output: $OUT
    compress: none
    no_health_check: true
    min_size_ratio: 90
  lax-job:
    command: dump
    from: postgres@localhost/appdb
    password: x
    output: $OUT
    compress: none
    no_health_check: true
    min_size_ratio: 0
EOF
seed; ( cd "$TMP" && t-pgsql batch strict-job --yaml "$TMP/jobs.yaml" >"$TMP/o4" 2>&1 </dev/null ); rc=$?
[ $rc -ne 0 ] && [ "$(suspects)" -eq 1 ] && ok "job key min_size_ratio is applied and the batch exits non-zero" || nok "job key ignored (rc=$rc): $(cat "$TMP/o4")"
grep -q "unknown key" "$TMP/o4" && nok "min_size_ratio reported as an unknown job key" || ok "min_size_ratio is a known job key"
seed; ( cd "$TMP" && t-pgsql batch lax-job --yaml "$TMP/jobs.yaml" >"$TMP/o5" 2>&1 </dev/null ); rc=$?
[ $rc -eq 0 ] && ok "job min_size_ratio: 0 disables the check" || nok "lax job failed (rc=$rc)"
seed; ( cd "$TMP" && t-pgsql batch --yaml "$TMP/jobs.yaml" --continue-on-error >"$TMP/o6" 2>&1 </dev/null ); rc=$?
[ $rc -ne 0 ] && ok "a batch with one guarded failure exits non-zero" || nok "batch hid the guard failure"

# 3. jobs show
( cd "$TMP" && t-pgsql jobs show strict-job --yaml "$TMP/jobs.yaml" >"$TMP/o7" 2>&1 </dev/null )
grep -q -- "--min-size-ratio" "$TMP/o7" && ok "jobs show lists --min-size-ratio" || nok "jobs show omits the ratio: $(cat "$TMP/o7")"

# 4. --save writes the option (only when set)
: > "$TMP/saved.yaml"
( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --password x --output "$OUT" --min-size-ratio 25 --save saved-job --yaml "$TMP/saved.yaml" >"$TMP/o8" 2>&1 </dev/null )
grep -q -- "--min-size-ratio 25" "$TMP/saved.yaml" && ok "--save writes --min-size-ratio" || nok "--save dropped the ratio: $(cat "$TMP/saved.yaml" "$TMP/o8")"
: > "$TMP/saved2.yaml"
( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --password x --output "$OUT" --save plain-job --yaml "$TMP/saved2.yaml" >"$TMP/o9" 2>&1 </dev/null )
grep -q -- "min-size-ratio" "$TMP/saved2.yaml" && nok "--save wrote the default ratio" || ok "--save leaves the default out"

[ "$FAILS" -eq 0 ]
