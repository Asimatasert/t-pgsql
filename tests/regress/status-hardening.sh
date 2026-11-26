#!/usr/bin/env bash
# Regression: history/status hardening. Multibyte-safe truncation (C locale, valid UTF-8 and
# JSON), numeric fields normalised, --max-age accepts bare seconds and upper-case units,
# unknown status options exit 2, job names with dots/quotes listed by status --yaml.
# Hermetic: only the history file and a jobs file are read.
#   bash tests/regress/status-hardening.sh   (T_PGSQL_BIN overrides ./t-pgsql)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

ST="$TMP/state"; OUT="$TMP/out"; FAKE="$TMP/fake"
mkdir -p "$ST" "$OUT" "$TMP/home" "$FAKE"
for t in psql pg_isready createdb dropdb pg_dumpall pg_restore curl; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/$t"; done
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE/pg_dump"
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH" HOME="$TMP/home" T_PGSQL_STATE_DIR="$ST" T_PGSQL_FROM_PASSWORD=x
unset XDG_STATE_HOME NO_COLOR
HF="$ST/history.tsv"
now=$(date +%s)
hist() { # epoch name status rc dur size msg
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" 2026-01-01T00:00:00Z dump "$2" "$3" "$4" "$5" "$6" "$7" >> "$HF"; }
st() { sout=$("$BASH" "$BIN" status "$@" --output "$OUT" 2>&1 </dev/null); src=$?; }
validjson() { if command -v python3 >/dev/null 2>&1; then printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; else return 0; fi; }
validutf8() { command -v iconv >/dev/null 2>&1 || return 0; iconv -f UTF-8 -t UTF-8 "$1" >/dev/null 2>&1; }

# 1. truncation: a multibyte name/message cut in the C locale stays valid UTF-8 and valid JSON
rm -f "$HF"
E=$(printf '\303\251')           # one e-acute (two bytes)
LONG="a"; i=0; while [ "$i" -lt 150 ]; do LONG="$LONG$E"; i=$((i + 1)); done
out=$(LC_ALL=C "$BASH" "$BIN" dump --from postgres@localhost/appdb --dump-name "$LONG" --output "$OUT" --compress none </dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ -s "$HF" ] && ok "failed dump with a long multibyte name was recorded" || nok "failed dump recorded (rc=$rc)"
validutf8 "$HF" && ok "C locale: history file is valid UTF-8 (name cut)" || nok "C locale: history file is not valid UTF-8"
st --json
validjson "$sout" && ok "C locale: status --json is valid JSON" || nok "C locale: status --json is invalid: $sout"
# the message cutter itself (function taken from the source, helpers stubbed)
strip_ansi() { printf '%s' "$1"; }; redact_cmd() { printf '%s' "$1"; }; redact_args() { printf '%s' "$1"; }
fn=$(sed -n '/^history_clean()/,/^}/p' "$ROOT/src/74-status.sh")
if [ -n "$fn" ]; then
    eval "$fn"
    LONGM="a"; i=0; while [ "$i" -lt 300 ]; do LONGM="$LONGM$E"; i=$((i + 1)); done
    r=$(LC_ALL=C history_clean "$LONGM" 200 ascii); printf '%s' "$r" > "$TMP/r1"
    validutf8 "$TMP/r1" && [ "${#r}" -le 200 ] && ok "message cut in the C locale is valid UTF-8 and at most 200 bytes" || nok "message cut (C): ${#r} bytes"
    case "$r" in *[!\ -~]*) nok "message keeps non-ASCII bytes" ;; *) ok "message is plain ASCII (non-ASCII bytes became ?)" ;; esac
    r=$(LC_ALL=en_US.UTF-8 history_clean "$LONGM" 200 ascii); printf '%s' "$r" > "$TMP/r2"
    validutf8 "$TMP/r2" && ok "message cut in a UTF-8 locale is valid UTF-8" || nok "message cut (UTF-8 locale) is invalid"
    r=$(LC_ALL=C history_clean "caf$E" 200); [ "$r" = "caf$E" ] && ok "a short name keeps its characters" || nok "short name changed: $r"
else
    nok "history_clean exists in the source"
fi

# 2. numeric fields: leading zeros normalised, non-numbers skipped
rm -f "$HF"
hist "$now" zeroed ok 0 007 0012 ""
hist "$now" badrc ok 1x 3 100 ""
hist "$now" negdur ok 0 -5 100 ""
st --json
validjson "$sout" && ok "leading zeros give valid JSON" || nok "invalid JSON: $sout"
case "$sout" in *'"duration_s": 7,'*'"size_bytes": 12,'*) ok "007 / 0012 normalised to 7 / 12" ;; *) nok "numbers not normalised: $sout" ;; esac
case "$sout" in *badrc*|*negdur*) nok "a line with an invalid number was not skipped: $sout" ;; *) ok "lines with invalid numbers are skipped" ;; esac

# 3. --max-age: bare seconds, upper-case units, no octal trap
rm -f "$HF"; hist $((now - 300)) fresh ok 0 3 100 ""
st --max-age 3600; [ "$src" -eq 0 ] && ok "--max-age 3600 (bare seconds) accepts a 5 minute old run" || nok "--max-age 3600 (rc=$src: $sout)"
st --max-age 60;   [ "$src" -eq 3 ] && ok "--max-age 60 (bare seconds) flags a 5 minute old run" || nok "--max-age 60 (rc=$src: $sout)"
st --max-age 1H;   [ "$src" -eq 0 ] && ok "--max-age 1H (upper case)" || nok "--max-age 1H (rc=$src: $sout)"
st --max-age 4M;   [ "$src" -eq 3 ] && ok "--max-age 4M (upper case minutes) is stale" || nok "--max-age 4M (rc=$src: $sout)"
st --max-age 10m;  [ "$src" -eq 0 ] && ok "--max-age 10m" || nok "--max-age 10m (rc=$src: $sout)"
st --max-age 1D;   [ "$src" -eq 0 ] && ok "--max-age 1D" || nok "--max-age 1D (rc=$src: $sout)"
st --max-age 08h;  [ "$src" -eq 0 ] && ok "--max-age 08h is not an octal error" || nok "--max-age 08h (rc=$src: $sout)"
st --max-age 1.5h; [ "$src" -eq 2 ] && ok "--max-age 1.5h is a usage error" || nok "--max-age 1.5h (rc=$src)"

# 4. unknown status options exit 2
st --bogus;   [ "$src" -eq 2 ] && ok "status --bogus exits 2" || nok "status --bogus (rc=$src)"
out=$("$BASH" "$BIN" status stray </dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "status with a stray argument exits 2" || nok "status stray (rc=$rc)"

# 5. job names with dots and quotes
cat > "$TMP/jobs.yaml" <<'EOF'
defaults:
  compress: none
jobs:
  good-job:
    command: dump
  dotted.job:
    command: dump
  "quoted job":
    command: dump
  'single q':
    command: dump
  UPPER_job:
    command: dump
other:
  not-a-job:
    command: dump
EOF
rm -f "$HF"
st --yaml "$TMP/jobs.yaml" --json
for n in good-job dotted.job 'quoted job' 'single q' UPPER_job; do
    case "$sout" in *"\"name\": \"$n\""*) ok "status --yaml lists '$n'" ;; *) nok "status --yaml misses '$n': $sout" ;; esac
done
case "$sout" in *not-a-job*) nok "a key outside jobs: was listed" ;; *) ok "keys outside jobs: are not listed" ;; esac
st --yaml "$TMP/jobs.yaml" --max-age 1h
[ "$src" -eq 3 ] && ok "a never-run job with a dotted name trips --max-age" || nok "--max-age with never-run jobs (rc=$src)"

[ "$FAIL" -eq 0 ]
