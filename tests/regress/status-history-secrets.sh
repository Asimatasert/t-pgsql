#!/usr/bin/env bash
# Regression: the run history must never store a credential, user or host name. The message of
# a failed run is the last error text; connection strings without a scheme (user:pw@host) and
# health-check errors (user@host:port/db) used to be stored as written.
# Hermetic: pg_dump, psql, pg_isready, curl and friends are fakes.
#   bash tests/regress/status-history-secrets.sh   (T_PGSQL_BIN overrides ./t-pgsql)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

FAKE="$TMP/fake"; OUT="$TMP/out"; ST="$TMP/state"
mkdir -p "$FAKE" "$OUT" "$TMP/home"
for t in pg_dump psql pg_isready createdb dropdb pg_dumpall pg_restore ssh scp curl; do
    printf '#!/usr/bin/env bash\nexit "${FAKE_RC:-0}"\n' > "$FAKE/$t"
done
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH" HOME="$TMP/home" T_PGSQL_STATE_DIR="$ST"
unset XDG_STATE_HOME T_PGSQL_FROM_PASSWORD
HF="$ST/history.tsv"
fresh() { rm -rf "$ST" "$OUT"; mkdir -p "$OUT"; }
msg() { tail -n 1 "$HF" 2>/dev/null | awk -F'\t' '{print $9}'; }

# 1. the exact leak: a connection string with a password but no scheme, rejected as invalid
fresh
out=$("$BASH" "$BIN" dump --from 'u:SeCrEt9@h.example.net/-bad' --output "$OUT" --compress none </dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "invalid connection string fails" || nok "invalid connection string fails (rc=$rc)"
[ -s "$HF" ] && ok "a history line was written" || nok "a history line was written"
grep -q 'SeCrEt9' "$HF" 2>/dev/null && nok "password stored in the history: $(msg)" || ok "password is not stored in the history"
grep -q 'h.example.net' "$HF" 2>/dev/null && nok "host stored in the history: $(msg)" || ok "host is not stored in the history"
grep -q 'u:' "$HF" 2>/dev/null && nok "user stored in the history: $(msg)" || ok "user is not stored in the history"
case "$(msg)" in *[Ii]nvalid*) ok "message still says what was wrong: $(msg)" ;; *) nok "message still says what was wrong: '$(msg)'" ;; esac

# 2. a URL with a password and a bare user@host in the same message
fresh
out=$("$BASH" "$BIN" dump --from 'postgres://bob:Hunter2pw@db.example.net:5432/' --output "$OUT" --compress none </dev/null 2>&1); rc=$?
grep -q 'Hunter2pw\|bob\|db.example.net' "$HF" 2>/dev/null && nok "URL parts stored: $(msg)" || ok "URL user, password and host are not stored"

# 3. health-check failure: "<user>@<host>:<port>/<db>" must not be stored
fresh
out=$(FAKE_RC=1 T_PGSQL_FROM_PASSWORD=x "$BASH" "$BIN" dump --from 'appuser@db.example.net/appdb' --output "$OUT" --compress none \
    --health-check-fail </dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "failing health check fails the run" || nok "failing health check fails the run (rc=$rc)"
grep -q 'appuser\|db.example.net' "$HF" 2>/dev/null && nok "health-check error leaks user/host: $(msg)" || ok "health-check error does not leak user or host"
[ -n "$(msg)" ] && ok "health-check failure still has a message: $(msg)" || nok "health-check failure still has a message"

# 4. the sanitiser itself (taken from the source tree): health-check texts, PGPASSWORD, URLs
san=$(sed -n '/^history_sanitize_msg()/,/^}/p' "$ROOT/src/74-status.sh")
if [ -n "$san" ]; then
    eval "$san"
    r=$(history_sanitize_msg 'SSH connection failed: appuser@db.example.net:2222')
    case "$r" in *appuser*|*example.net*) nok "SSH health text keeps user/host: $r" ;; "SSH connection failed:"*) ok "SSH health text: $r" ;; *) nok "SSH health text unexpected: $r" ;; esac
    r=$(history_sanitize_msg 'Database connection failed: appuser@db.example.net:5432/appdb')
    case "$r" in *appuser*|*example.net*|*appdb*) nok "database health text keeps user/host/db: $r" ;; "Database connection failed:"*) ok "database health text: $r" ;; *) nok "database health text unexpected: $r" ;; esac
    r=$(history_sanitize_msg 'run PGPASSWORD=Zz9secret pg_dump failed')
    case "$r" in *Zz9secret*) nok "PGPASSWORD value kept: $r" ;; *) ok "PGPASSWORD value dropped: $r" ;; esac
    r=$(history_sanitize_msg 'bad Password: Zz9secret more')
    case "$r" in *Zz9secret*) nok "password text kept: $r" ;; *) ok "text after password dropped: $r" ;; esac
    r=$(history_sanitize_msg 'fetch from https://backup.example.net/x?token=Zz9 failed')
    case "$r" in *Zz9*|*example.net*) nok "URL kept: $r" ;; *) ok "URL dropped: $r" ;; esac
    r=$(history_sanitize_msg 'Dump failed: exit 1')
    [ "$r" = 'Dump failed: exit 1' ] && ok "plain message unchanged" || nok "plain message changed: $r"
else
    nok "history_sanitize_msg exists in the source"
fi

[ "$FAIL" -eq 0 ]
