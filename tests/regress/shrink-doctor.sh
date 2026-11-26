#!/usr/bin/env bash
# Regression: `doctor` compares the newest dump of each base with the one before it using
# the configured --min-size-ratio (warning only), prints the active ratio and reports
# .suspect files; `explain dump` documents the shrink guard.
# Hermetic: no database is contacted; tools are faked.
#   bash tests/regress/shrink-doctor.sh   (T_PGSQL_BIN overrides ./t-pgsql)
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
for t in psql pg_dump pg_isready; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$t"; chmod +x "$TMP/bin/$t"; done
. "$ROOT/tests/regress/lib/fakes.sh"; fake_pg_tools "$TMP/bin"
export PATH="$TMP/bin:$PATH" HOME="$TMP/home" NO_COLOR=1; mkdir -p "$HOME"

OUT="$TMP/out"
mk() { { printf 'PGDMP'; printf '%*s' $(($2 - 5)) '' | tr ' ' x; } > "$1"; touch -t "$3" "$1"; }
doc() { ( cd "$TMP" && t-pgsql doctor --output "$OUT" --yaml "$TMP/none.yaml" "$@" 2>&1 </dev/null ); }

rm -rf "$OUT"; mkdir -p "$OUT"
mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
mk "$OUT/appdb_20200102_000000.dump" 300 202001020000
mk "$OUT/appdb_v2_20200101_000000.dump" 100000 202001010000
mk "$OUT/appdb_v2_20200102_000000.dump" 90000 202001020000

out=$(doc); rc_with=$?
case "$out" in *"Shrink guard"*) ok "doctor has a shrink guard section" ;; *) nok "no shrink guard section" ;; esac
case "$out" in *"at least 50%"*) ok "doctor prints the active ratio" ;; *) nok "ratio not printed" ;; esac
case "$out" in *"appdb — newest dump is 300 bytes, only 30%"*) ok "shrunk base is warned about" ;; *) nok "no shrink warning: $out" ;; esac
case "$out" in *"appdb_v2 — newest dump is 90%"*) ok "second base is compared only with its own history" ;; *) nok "base mix-up: $out" ;; esac

out=$(doc --min-size-ratio 20); rc_ok=$?
case "$out" in *"only 30%"*) nok "warning ignores --min-size-ratio" ;; *"at least 20%"*) ok "doctor honours --min-size-ratio" ;; *) nok "ratio 20 not shown" ;; esac
out=$(doc --min-size-ratio 0)
case "$out" in *"disabled"*) ok "ratio 0 reports the check as disabled" ;; *) nok "ratio 0 not reported" ;; esac
[ "$rc_with" -eq "$rc_ok" ] && ok "the shrink warning does not change the exit status" || nok "exit status changed ($rc_with vs $rc_ok)"

: > "$OUT/appdb_20200103_000000.dump.suspect"
out=$(doc)
case "$out" in *"set aside as .suspect"*) ok "doctor reports .suspect files" ;; *) nok "suspect file not reported" ;; esac

out=$( ( cd "$TMP" && t-pgsql explain dump 2>&1 </dev/null ) )
case "$out" in *"--min-size-ratio"*".suspect"*) ok "explain dump documents the guard" ;; *) nok "explain dump lacks the guard" ;; esac

[ "$FAILS" -eq 0 ]
