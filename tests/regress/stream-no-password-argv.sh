#!/usr/bin/env bash
# The database password must never appear on any local or remote argv in the ssh stream
# clone and in the ssh masking batch. A fake `ssh` records its argv (what `ps` would show)
# and its stdin (the remote script, which is where the pgpass line is allowed to travel).
# Usage: bash tests/regress/stream-no-password-argv.sh   (T_PGSQL_BIN overrides the script under test)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }

SECRET="Zq9Marker"
mkdir "$TMP/bin"
cat > "$TMP/bin/ssh" <<EOS
#!/bin/sh
# argv, one record per call
printf 'ARGV: %s\n' "\$*" >> "$TMP/argv"
script="\$(cat)"
printf '%s\n' "\$script" >> "$TMP/stdin"
# probes (psql) answer "1"; the pgpass creation script (no psql in it) asks for a path back
case "\$script" in
    *psql*"-d srcdb"*|*psql*pg_database*) echo 1 ;;
    *psql*) ;;
    *mktemp*) echo "/tmp/tpgfake.\$\$" ;;
esac
exit 0
EOS
chmod +x "$TMP/bin/ssh"
for c in psql pg_dump pg_restore createdb dropdb; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"; done

# --- stream clone, ssh source and ssh target -------------------------------------------
: > "$TMP/argv"; : > "$TMP/stdin"
PATH="$TMP/bin:$PATH" PGCONNECT_TIMEOUT=1 T_PGSQL_FROM_PASSWORD="$SECRET-src" T_PGSQL_TO_PASSWORD="$SECRET-dst" \
    "$BASH" "$BIN" clone --stream --force --yes --from 'ssh://u@192.0.2.1/src@localhost/srcdb' \
    --to 'ssh://u@192.0.2.2/dst@localhost/dstdb' </dev/null >"$TMP/out" 2>&1
grep -q "$SECRET" "$TMP/argv" && nok "stream: password found in ssh argv" || ok "stream: no password in any ssh argv"
grep -q '\*:\*:\*:' "$TMP/argv" && nok "stream: pgpass line found in ssh argv" || ok "stream: no pgpass line in any ssh argv"
grep -q "$SECRET-src" "$TMP/stdin" && grep -q "$SECRET-dst" "$TMP/stdin" \
    && ok "stream: passwords were delivered on ssh stdin (remote pgpass created)" || nok "stream: passwords never reached the remote"
grep -q 'ARGV: .*PGPASSFILE=/tmp/tpgfake.* pg_dump' "$TMP/argv" && ok "stream: dump command uses PGPASSFILE=<path>" || nok "stream: dump command lacks PGPASSFILE"
grep -q 'ARGV: .*PGPASSFILE=/tmp/tpgfake.* pg_restore' "$TMP/argv" && ok "stream: restore command uses PGPASSFILE=<path>" || nok "stream: restore command lacks PGPASSFILE"
n="$(grep -c 'rm -f /tmp/tpgfake' "$TMP/stdin")"
[ "$n" -ge 2 ] && ok "stream: both remote pgpass files removed afterwards ($n rm calls)" || nok "stream: remote pgpass files not removed ($n)"

# --- masking batch over ssh --------------------------------------------------------------
sed '$d' "$BIN" > "$TMP/lib.sh"
printf '{\n  "users.email": "'"'"'x'"'"'"\n}\n' > "$TMP/rules.json"
: > "$TMP/argv"; : > "$TMP/stdin"
(
    # shellcheck disable=SC1091
    source "$TMP/lib.sh"
    PATH="$TMP/bin:$PATH"
    MASK=true MASK_RULES="$TMP/rules.json" MASK_TABLES=""
    TO_TYPE=ssh TO_SSH_USER=u TO_SSH_HOST=192.0.2.2 TO_SSH_PORT=22
    TO_DB_HOST=localhost TO_DB_PORT=5432 TO_DB_USER=dst TO_DB_PASSWORD="$SECRET-mask" TO_DATABASE=dstdb
    apply_masking TO </dev/null >/dev/null 2>&1
)
grep -q "$SECRET" "$TMP/argv" && nok "mask: password found in ssh argv" || ok "mask: no password in any ssh argv"
grep -q "$SECRET-mask" "$TMP/stdin" && ok "mask: password delivered on ssh stdin" || nok "mask: password never reached the remote"
grep -q 'ARGV: .*PGPASSFILE=/tmp/tpgfake.* psql' "$TMP/argv" && ok "mask: batch command uses PGPASSFILE=<path>" || nok "mask: batch command lacks PGPASSFILE"
grep -q 'rm -f /tmp/tpgfake' "$TMP/stdin" && ok "mask: remote pgpass removed afterwards" || nok "mask: remote pgpass not removed"

# --- a remote pgpass left behind by an interrupted run is removed by the exit cleanup -----
: > "$TMP/argv"; : > "$TMP/stdin"
(
    # shellcheck disable=SC1091
    source "$TMP/lib.sh"
    PATH="$TMP/bin:$PATH"
    install_cleanup_trap
    remote_pgpass_create 22 u@192.0.2.9 dst "$SECRET-x" >/dev/null 2>&1
    kill -TERM "$BASHPID"
    sleep 1
) </dev/null >/dev/null 2>&1
grep -q 'rm -f /tmp/tpgfake' "$TMP/stdin" && ok "interrupt: leftover remote pgpass removed by the exit trap" || nok "interrupt: remote pgpass left behind"
exit "$fail"
