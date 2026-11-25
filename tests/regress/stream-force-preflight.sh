#!/usr/bin/env bash
# `clone --stream --force` must prove the source is reachable BEFORE it terminates sessions
# on / drops the target database. Fake binaries record every call.
# Usage: bash tests/regress/stream-force-preflight.sh   (T_PGSQL_BIN overrides the script under test)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }

mkdir "$TMP/bin"
# psql: a connection to the source database (-d srcdb) fails when SRC_DOWN=1; everything else
# answers "1" (so the target looks like an existing database).
cat > "$TMP/bin/psql" <<EOS
#!/bin/sh
echo "psql \$*" >> "$TMP/calls"
case "\$*" in *"-d srcdb"*) [ "\$SRC_DOWN" = 1 ] && exit 2 ;; esac
echo 1
EOS
for c in dropdb createdb pg_restore; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\ncat >/dev/null 2>&1\nexit 0\n' "$c" "$TMP" > "$TMP/bin/$c"
done
printf '#!/bin/sh\necho "pg_dump $*" >> "%s/calls"\nprintf data\n' "$TMP" > "$TMP/bin/pg_dump"
# ssh: records argv and stdin (the remote script); SRC_DOWN=1 makes the source probe fail.
cat > "$TMP/bin/ssh" <<EOS
#!/bin/sh
echo "ssh \$*" >> "$TMP/calls"
script="\$(cat)"
printf '%s\n' "\$script" >> "$TMP/remote_scripts"
case "\$script" in *"-d srcdb"*) [ "\$SRC_DOWN" = 1 ] && exit 255 ;; esac
case "\$script" in *pg_database*) echo 1 ;; esac
case "\$script" in *"-d srcdb"*) echo 1 ;; esac
exit 0
EOS
chmod +x "$TMP/bin/"*

run() { # run <src_down> <from> <to>
    : > "$TMP/calls"; : > "$TMP/remote_scripts"
    SRC_DOWN="$1" PATH="$TMP/bin:$PATH" PGCONNECT_TIMEOUT=1 T_PGSQL_PASSWORD=pw \
        "$BASH" "$BIN" clone --stream --force --yes --from "$2" --to "$3" >"$TMP/out" 2>&1
    echo $?
}

# 1. local source down, local target
rc=$(run 1 'src@192.0.2.1/srcdb' 'dst@192.0.2.2/dstdb')
grep -q '^dropdb' "$TMP/calls" && nok "local: dropdb ran although the source was unreachable" || ok "local: dropdb never ran"
grep -q 'pg_terminate_backend' "$TMP/calls" && nok "local: target sessions were terminated" || ok "local: no pg_terminate_backend"
[ "$rc" -ne 0 ] && ok "local: non-zero exit ($rc)" || nok "local: exit 0"
# 2. ssh source down, ssh target
rc=$(run 1 'ssh://u@192.0.2.1/src@localhost/srcdb' 'ssh://u@192.0.2.2/dst@localhost/dstdb')
grep -q 'dropdb' "$TMP/remote_scripts" && nok "ssh: remote dropdb was sent although the source was unreachable" || ok "ssh: remote dropdb never sent"
[ "$rc" -ne 0 ] && ok "ssh: non-zero exit ($rc)" || nok "ssh: exit 0"
# 3. control: source up => the existing target is dropped as before
rc=$(run 0 'src@192.0.2.1/srcdb' 'dst@192.0.2.2/dstdb')
grep -q '^dropdb' "$TMP/calls" && ok "control (local): dropdb runs when the source is reachable" || nok "control (local): dropdb did not run"
rc=$(run 0 'ssh://u@192.0.2.1/src@localhost/srcdb' 'ssh://u@192.0.2.2/dst@localhost/dstdb')
grep -q 'dropdb' "$TMP/remote_scripts" && ok "control (ssh): remote dropdb sent when the source is reachable" || nok "control (ssh): remote dropdb not sent"
exit "$fail"
