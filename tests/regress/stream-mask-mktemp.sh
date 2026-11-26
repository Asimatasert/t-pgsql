#!/usr/bin/env bash
# apply_masking must FAIL (non-zero) when the temporary credential file cannot be created,
# instead of returning 0 and letting unmasked data be reported as masked.
# Usage: bash tests/regress/stream-mask-mktemp.sh   (T_PGSQL_BIN overrides the script under test)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }

sed '$d' "$BIN" > "$TMP/lib.sh"   # drop the trailing `main "$@"` so the functions can be sourced

(
    # shellcheck disable=SC1091
    source "$TMP/lib.sh"
    MASK=true MASK_TABLES=users MASK_RULES=""
    TO_TYPE=local TO_DB_HOST=localhost TO_DB_PORT=5432 TO_DB_USER=u TO_DB_PASSWORD=pw TO_DATABASE=db
    export TMPDIR="$TMP/does-not-exist"
    apply_masking TO >/dev/null 2>&1
    echo "rc=$?" > "$TMP/rc"
)
rc="$(sed 's/rc=//' "$TMP/rc")"
if [ "$rc" != "0" ]; then ok "apply_masking returns non-zero when mktemp fails (rc=$rc)"; else nok "apply_masking returned 0 although mktemp failed"; fi
exit "$fail"
