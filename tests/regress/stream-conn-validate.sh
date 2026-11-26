#!/usr/bin/env bash
# parse_connection must reject values that would become ssh/psql options or a libpq
# connection string, and still accept ordinary connection strings.
# Usage: bash tests/regress/stream-conn-validate.sh   (T_PGSQL_BIN overrides the script under test)
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

reject() {
    if parse_connection "$1" X >/dev/null 2>&1; then nok "accepted: $1"; else ok "rejected: $1"; fi
}
accept() {
    if parse_connection "$1" X >/dev/null 2>&1; then ok "accepted: $1"; else nok "rejected valid: $1"; fi
}

# option injection through ssh user / host / port and db fields
reject 'ssh://-oProxyCommand=id@192.0.2.10/appdb'
reject 'ssh://admin@-oProxyCommand=id/appdb'
reject 'ssh://admin@192.0.2.10:-1/appdb'
reject 'ssh://admin@192.0.2.10:22x/appdb'
reject 'ssh://adm in@192.0.2.10/appdb'
reject 'ssh://admin@192.0.2.10;id/appdb'
reject 'ssh://admin@host$(id)/appdb'
reject 'ssh://admin@192.0.2.10/-U@localhost/appdb'
reject 'ssh://admin@192.0.2.10/postgres@-evil/appdb'
reject 'ssh://admin@192.0.2.10/postgres@localhost:-5/appdb'
reject '-U@192.0.2.10/appdb'
reject 'postgres@-host/appdb'
reject 'postgres@192.0.2.10:abc/appdb'
reject 'postgres@192.0.2.10/-appdb'
# libpq conninfo through the database name
reject 'postgres@192.0.2.10/app hostaddr=203.0.113.9'
reject 'ssh://admin@192.0.2.10/postgres@localhost/dbname=x'
# normal forms keep working
accept 'ssh://admin@192.0.2.10/appdb'
accept 'ssh://deploy.user@db-1.example.com:2222/postgres@localhost:5433/app_db'
accept 'ssh://admin@192.0.2.10/postgres@127.0.0.1/appdb'
accept 'postgres@localhost/appdb'
accept 'dbadmin@192.0.2.10:5433/postgres@appdb'
accept 'postgres@[::1]:5432/appdb'
accept 'appdb'
accept 'postgres@appdb'
exit "$fail"
