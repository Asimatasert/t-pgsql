#!/usr/bin/env bash
# Regression: a failed job of a parallel batch must show its captured output (the temp
# directory holding it is deleted); output of jobs that succeeded stays hidden.
# Usage: bash tests/regress/jobs-parallel-output.sh   (T_PGSQL_BIN=/path/to/t-pgsql for another build)
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
# Fake pg_dump: databases whose name starts with "fail" error out with a recognisable message.
cat > "$TMP/bin/pg_dump" <<'EOF'
#!/bin/sh
f=""; last=""
while [ $# -gt 0 ]; do [ "$1" = "-f" ] && f="$2"; last="$1"; shift; done
case "$last" in fail*) echo "FAKE-PGDUMP-ERROR connection refused for $last" >&2; exit 1 ;; esac
printf 'fake dump\n' >> "$f"
EOF
chmod +x "$TMP/bin/psql" "$TMP/bin/pg_dump"
export PATH="$TMP/bin:$PATH"

mkjob() { # name db
    cat <<EOF
  $1:
    command: dump
    from: postgres@localhost/$2
    password: x
    output: $TMP/out
    no_meta: true
    no_health_check: true
EOF
}
{
    echo "jobs:"
    mkjob job-a faila
    mkjob job-b failb
    mkjob job-c okdb
    mkjob job-d faild
} > "$TMP/jobs.yaml"

( cd "$TMP" && t-pgsql batch all --yaml "$TMP/jobs.yaml" --parallel 2 --continue-on-error >"$TMP/run.out" 2>&1 </dev/null )
RC=$?
[ "$RC" -eq 1 ] && ok "parallel batch with failures exits 1" || nok "parallel batch with failures exits 1 (rc=$RC)"
for db in faila failb faild; do
    grep -q "FAKE-PGDUMP-ERROR connection refused for $db" "$TMP/run.out" && ok "output of the failed job on $db is shown" || nok "output of the failed job on $db is shown"
done
[ "$(grep -c "output of failed job" "$TMP/run.out")" -eq 3 ] && ok "exactly the three failed jobs are announced" || nok "exactly the three failed jobs are announced"
grep -q "Dump complete" "$TMP/run.out" && nok "output of the successful job stays hidden" || ok "output of the successful job stays hidden"

[ "$FAILS" -eq 0 ]
