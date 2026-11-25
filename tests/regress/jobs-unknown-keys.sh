#!/usr/bin/env bash
# Regression: unknown or misspelled keys in jobs.yaml must produce a warning (job name + key,
# with the closest valid key for hyphen/underscore slips), once per key, and never an error.
# Usage: bash tests/regress/jobs-unknown-keys.sh   (T_PGSQL_BIN=/path/to/t-pgsql for another build)
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
cat > "$TMP/bin/pg_dump" <<'EOF'
#!/bin/sh
f=""
while [ $# -gt 0 ]; do [ "$1" = "-f" ] && f="$2"; shift; done
printf 'fake dump\n' >> "$f"
EOF
chmod +x "$TMP/bin/psql" "$TMP/bin/pg_dump"
export PATH="$TMP/bin:$PATH"

cat > "$TMP/jobs.yaml" <<EOF
jobs:
  typo-job:
    command: dump
    from: postgres@localhost/appdb
    password: x
    output: $TMP/out
    no_meta: true
    no_health_check: true
    from-keep: 0
    retention_dayly: 3
    from-keep: 2
  clean-job:
    command: dump
    from: postgres@localhost/appdb
    password: x
    output: $TMP/out
    no_meta: true
    no_health_check: true
EOF

( cd "$TMP" && t-pgsql batch typo-job --yaml "$TMP/jobs.yaml" >"$TMP/typo.out" 2>&1 </dev/null )
RC=$?
[ "$RC" -eq 0 ] && ok "a job with unknown keys still runs and succeeds" || nok "a job with unknown keys still runs and succeeds (rc=$RC)"
grep -q "Job 'typo-job': unknown key 'from-keep' is ignored (did you mean 'from_keep'?)" "$TMP/typo.out" && ok "hyphenated key is reported with the valid spelling" || nok "hyphenated key is reported with the valid spelling"
grep -q "Job 'typo-job': unknown key 'retention_dayly' is ignored" "$TMP/typo.out" && ok "misspelled key is reported" || nok "misspelled key is reported"
[ "$(grep -c "unknown key 'from-keep'" "$TMP/typo.out")" -eq 1 ] && ok "a repeated key is reported once" || nok "a repeated key is reported once"
[ "$(grep -c "unknown key" "$TMP/typo.out")" -eq 2 ] && ok "valid keys are not reported" || nok "valid keys are not reported ($(grep -c "unknown key" "$TMP/typo.out") warnings)"

( cd "$TMP" && t-pgsql batch clean-job --yaml "$TMP/jobs.yaml" >"$TMP/clean.out" 2>&1 </dev/null )
grep -q "unknown key" "$TMP/clean.out" && nok "a clean job produces no warning" || ok "a clean job produces no warning"

[ "$FAILS" -eq 0 ]
