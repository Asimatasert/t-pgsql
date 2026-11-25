#!/usr/bin/env bash
# Regression: the bot cooldown must look for dumps by the name the dump code uses
# (dump_name, else the source database), not by the job name.
# Usage: bash tests/regress/bot-cooldown.sh   (T_PGSQL_BIN overrides the script under test)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }

# Source the script without running main (drop the final `main "$@"` line).
sed '$d' "$BIN" > "$TMP/lib.sh"
# shellcheck disable=SC1090,SC1091
source "$TMP/lib.sh"

OUT="$TMP/dumps"; mkdir -p "$OUT"
cat > "$TMP/jobs.yaml" <<YAML
profiles:
  stage:
    database: profdb

jobs:
  nightly:
    command: dump
    output: $OUT
    from:
      database: mydb
  named:
    command: dump
    output: $OUT
    dump_name: custom
    from:
      database: other
  viaprofile:
    command: dump
    output: $OUT
    from:
      profile: stage
YAML
touch "$OUT/mydb_20260101_000000.dump" "$OUT/custom_20260101_000000.dump" "$OUT/profdb_20260101_000000.dump"

for job in nightly named viaprofile; do
    msg=$(bot_check_cooldown "$TMP/jobs.yaml" "$job" "1h")
    [ -n "$msg" ] && ok "fresh dump found for job '$job' (cooldown applies)" || nok "fresh dump NOT found for job '$job'"
done

touch -t 202001010000 "$OUT/mydb_20260101_000000.dump"
msg=$(bot_check_cooldown "$TMP/jobs.yaml" nightly "1h")
[ -z "$msg" ] && ok "old dump does not trigger cooldown" || nok "old dump triggered cooldown"

# A dump named after the job (not the database) must not be what is matched.
rm -f "$OUT"/*; touch "$OUT/nightly_20260101_000000.dump"
msg=$(bot_check_cooldown "$TMP/jobs.yaml" nightly "1h")
[ -z "$msg" ] && ok "file named after the job is not matched" || nok "file named after the job was matched"

exit $fail
