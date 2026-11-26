#!/usr/bin/env bash
# With several --to targets, a target that has no password of its own must not inherit the
# previous target's password. Fake pg_* binaries record the pgpass file they were given.
# Usage: bash tests/regress/stream-cred-reuse.sh   (T_PGSQL_BIN overrides the script under test)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }

mkdir "$TMP/bin"
cat > "$TMP/bin/pg_dump" <<'EOS'
#!/bin/sh
printf 'dump-data'
EOS
cat > "$TMP/bin/pg_restore" <<EOS
#!/bin/sh
cat "\$PGPASSFILE" >> "$TMP/restore_pgpass"
cat >/dev/null
EOS
for c in psql createdb dropdb ssh scp; do
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$c"
done
chmod +x "$TMP/bin/"*

printf 'pwOne\n' > "$TMP/pw1"
printf 'pwTwo\n' > "$TMP/pw2"
: > "$TMP/restore_pgpass"
PATH="$TMP/bin:$PATH" PGCONNECT_TIMEOUT=1 T_PGSQL_FROM_PASSWORD=srcpw \
    "$BASH" "$BIN" clone --stream --yes --from 'src@192.0.2.1/srcdb' \
    --to 'u1@192.0.2.2/db1' --to 'u2@192.0.2.3/db2' --to 'u3@192.0.2.4/db3' \
    --to-password-file "$TMP/pw1" --to-password-file "$TMP/pw2" >"$TMP/out" 2>&1
rc=$?

grep -q 'u1:pwOne' "$TMP/restore_pgpass" && ok "target 1 restored with its own password" || nok "target 1 missing"
grep -q 'u2:pwTwo' "$TMP/restore_pgpass" && ok "target 2 restored with its own password" || nok "target 2 missing"
if grep -q 'u3:' "$TMP/restore_pgpass"; then nok "target 3 (no password) was restored using another target's credential"; else ok "target 3 without a password was not restored"; fi
[ "$rc" -ne 0 ] && ok "overall exit status is non-zero (rc=$rc)" || nok "exit status 0 although target 3 failed"
exit "$fail"
