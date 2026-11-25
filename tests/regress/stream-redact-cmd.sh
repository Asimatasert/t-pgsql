#!/usr/bin/env bash
# redact_cmd must hide passwords containing quotes, backslashes and colons even after they
# were quoted by pgpass_escape/shq/pq (the shape of the logged ssh stream command).
# Usage: bash tests/regress/stream-redact-cmd.sh   (T_PGSQL_BIN overrides the script under test)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }

sed '$d' "$BIN" > "$TMP/lib.sh"
# shellcheck disable=SC1091
source "$TMP/lib.sh"

# Each password has a unique marker (Zq / Wv / Kj) that must not survive redaction.
check() {
    local pw="$1" marker="$2" label="$3" line cmd out
    FROM_DB_PASSWORD="$pw"; TO_DB_PASSWORD=""
    line="*:*:*:u:$(pgpass_escape "$pw")"
    cmd="ssh -p 22 u@h $(shq "printf '%s\\n' $(shq "$line")") | pg_restore -h h -W $(pq "$pw") --pw=$pw"
    out="$(redact_cmd "$cmd")"
    if [[ "$out" == *"$marker"* ]]; then nok "$label: password fragment '$marker' still visible: $out"
    else ok "$label"; fi
}
check "Zq'x:y\\w9"        "Zq" "single quote, colon, backslash"
check "Wv\\\\'q'z:1"      "Wv" "backslashes and several quotes"
check "Kj plain:pw"       "Kj" "space and colon"

# Two-target case: both passwords redacted in one string.
FROM_DB_PASSWORD="Zq'a"; TO_DB_PASSWORD="Wv\\b"
out="$(redact_cmd "x $(shq "$(pgpass_escape "$FROM_DB_PASSWORD")") y $(pq "$TO_DB_PASSWORD")")"
if [[ "$out" != *Zq* && "$out" != *Wv* ]]; then ok "both source and target passwords redacted"; else nok "leak: $out"; fi

# Unrelated text is untouched.
FROM_DB_PASSWORD="Zq'a"; TO_DB_PASSWORD=""
out="$(redact_cmd "pg_dump -h db.example.com")"
[ "$out" = "pg_dump -h db.example.com" ] && ok "unrelated text unchanged" || nok "unrelated text altered: $out"
exit "$fail"
