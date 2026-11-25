#!/usr/bin/env bash
# The clone source==target guard must treat loopback spellings, default/explicit port and
# host case as the same endpoint, and keep different databases/ports/hosts apart.
# Runs the real `clone` command with fake psql/pg_dump so nothing can touch a database.
# Usage: bash tests/regress/stream-same-target.sh   (T_PGSQL_BIN overrides the script under test)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }

mkdir "$TMP/bin"
for c in psql pg_dump pg_restore createdb dropdb ssh scp; do
    printf '#!/bin/sh\necho "$0 $*" >> "%s/calls"\nexit 1\n' "$TMP" > "$TMP/bin/$c"
    chmod +x "$TMP/bin/$c"
done

# expect <refuse|allow> <from> <to>
expect() {
    local want="$1" from="$2" to="$3" out
    : > "$TMP/calls"
    out="$(PATH="$TMP/bin:$PATH" PGCONNECT_TIMEOUT=1 T_PGSQL_PASSWORD=pw "$BASH" "$BIN" clone --stream --force --yes --from "$from" --to "$to" 2>&1)"
    if [[ "$out" == *"are the same database"* || "$out" == *"same database"* ]]; then got=refuse; else got=allow; fi
    if [ "$got" = "$want" ]; then ok "$want: $from -> $to"; else nok "wanted $want got $got: $from -> $to"; fi
    if [ "$want" = refuse ] && grep -q 'dropdb' "$TMP/calls"; then nok "dropdb was called for $from -> $to"; fi
}

expect refuse 'postgres@localhost/app'            'postgres@localhost/app'
expect refuse 'postgres@localhost/app'            'postgres@127.0.0.1/app'
expect refuse 'postgres@localhost:5432/app'       'postgres@127.0.0.1/app'
expect refuse 'postgres@localhost/app'            'other@[::1]:5432/app'
expect refuse 'postgres@LOCALHOST/app'            'postgres@127.0.0.2:05432/app'
expect refuse 'app'                               'postgres@localhost:5432/app'
expect refuse 'ssh://u@192.0.2.10/postgres@localhost/app' 'ssh://u@192.0.2.10/postgres@127.0.0.1:5432/app'
expect allow  'ssh://u@192.0.2.10:2222/postgres@localhost/app' 'postgres@192.0.2.10/app'
expect allow  'ssh://u@localhost:2201/postgres@localhost/app' 'ssh://u@localhost:2202/postgres@localhost/app'
expect allow  'postgres@localhost/app' 'ssh://u@localhost:2222/postgres@localhost/app'
expect refuse 'postgres@localhost/app' 'ssh://u@localhost:22/postgres@localhost/app'
expect refuse 'postgres@localhost/app' 'ssh://u@127.0.0.1/postgres@localhost:5432/app'
expect refuse 'ssh://u@LocalHost:2201/postgres@localhost/app' 'ssh://u@localhost:2201/postgres@127.0.0.1/app'
expect refuse 'ssh://u@Host.example.com/postgres@localhost/app' 'ssh://u@host.example.com:22/postgres@localhost/app'
expect refuse 'ssh://u@Host.example.com:02222/postgres@localhost/app' 'ssh://u@host.example.com:2222/postgres@localhost/app'
expect allow  'postgres@localhost/app'            'postgres@localhost/app2'
expect allow  'postgres@localhost:5432/app'       'postgres@localhost:5433/app'
expect allow  'postgres@localhost/app'            'postgres@192.0.2.10/app'
expect allow  'ssh://u@192.0.2.10/postgres@localhost/app' 'ssh://u@192.0.2.11/postgres@localhost/app'
expect allow  'ssh://u@192.0.2.10/postgres@localhost/app' 'postgres@localhost/app'
exit "$fail"
