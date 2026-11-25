#!/usr/bin/env bash
# Regression: rotation must not run when the new dump is unusable (empty, no
# PGDMP header, failing compression test), the unusable file must be kept as
# <name>.invalid, and a dump that merely cannot be listed by the local
# pg_restore (older client than the server that wrote it) must stay valid.
# Hermetic: every PostgreSQL, ssh and compression tool is faked.
#   bash tests/regress/staging-integrity.sh   (T_PGSQL_BIN overrides ./t-pgsql)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

FAKE="$TMP/fake"; REC="$TMP/rec"; SB="$TMP/sandbox"
mkdir -p "$FAKE" "$REC" "$SB"

# pg_dump writes DUMP_BODY (empty string leaves the file empty).
cat > "$FAKE/pg_dump" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
    if [ "$1" = -f ]; then [ -n "$DUMP_BODY" ] && printf '%s\n' "$DUMP_BODY" > "$2"; fi
    shift
done
exit 0
EOF
# pg_restore -l result is controlled by PGR_RC (default 0).
cat > "$FAKE/pg_restore" <<'EOF'
#!/usr/bin/env bash
exit "${PGR_RC:-0}"
EOF
# zstd: -t fails when the file contains BADSTREAM; -dc prints the file;
# compression (--rm) turns FILE into FILE.zst with the same bytes.
cat > "$FAKE/zstd" <<'EOF'
#!/usr/bin/env bash
echo "zstd $*" >> "$REC/zstd.log"
for last; do :; done
case " $* " in
    *" -t "*) grep -q BADSTREAM "$last" && exit 1; exit 0 ;;
    *" -dc "*) cat "$last"; exit 0 ;;
    *) cp "$last" "$last.zst" && rm -f "$last"; exit 0 ;;
esac
EOF
for t in psql pg_isready createdb dropdb pg_dumpall xz bzip2; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/$t"
done
# ssh: run the received command locally; /tmp/t-pgsql lives in the sandbox.
cat > "$FAKE/ssh" <<'EOF'
#!/usr/bin/env bash
cmd="${!#}"
cmd="${cmd//\/tmp\/t-pgsql/$SB/t-pgsql}"
sed "s#/tmp/t-pgsql#$SB/t-pgsql#g" | sh -c "$cmd"
EOF
cat > "$FAKE/scp" <<'EOF'
#!/usr/bin/env bash
a=("$@"); src="${a[$((${#a[@]}-2))]}"; dst="${a[$((${#a[@]}-1))]}"
src="${src#*@*:}"; src="${src//\/tmp\/t-pgsql/$SB/t-pgsql}"
cp "$src" "$dst"
EOF
chmod +x "$FAKE"/*
export SB REC
export PATH="$FAKE:$PATH"
export T_PGSQL_FROM_PASSWORD=x
export HOME="$TMP/home"; mkdir -p "$HOME"

OUT="$TMP/out"
OLD="$OUT/appdb_20200101_000000.dump"
seed() { rm -rf "$OUT" "$SB/t-pgsql" "$REC"/*; mkdir -p "$OUT"; printf 'PGDMP old\n' > "$OLD"; touch -t 202001010000 "$OLD"; }
# run BODY [extra args...]  (local dump)
run() { local body="$1"; shift; seed
    DUMP_BODY="$body" "$BIN" dump --from "postgres@localhost/appdb" --output "$OUT" --keep 1 "$@" </dev/null 2>&1; }
new_dumps()  { ls "$OUT" | grep -v '^appdb_20200101_000000' | grep -c -E '^appdb_[0-9]{8}_[0-9]{6}(_[0-9]+)?\.(dump|dump\.zst)$'; }
invalid_files() { ls "$OUT" | grep -c '\.invalid$'; }

# 1. valid magic, local pg_restore cannot list it: valid, warning, rotation runs
out=$(PGR_RC=1 run "PGDMP newer-server" --compress none); rc=$?
[ $rc -eq 0 ] && ok "unlistable dump with valid magic succeeds" || nok "unlistable dump failed: $out"
case "$out" in *"could not be listed"*) ok "warning explains the pg_restore mismatch" ;; *) nok "no warning: $out" ;; esac
[ ! -e "$OLD" ] && ok "rotation runs for the unlistable dump" || nok "older dump kept although the new dump is valid"
[ "$(invalid_files)" -eq 0 ] && ok "valid dump not renamed" || nok "valid dump renamed to .invalid"

# 2. empty dump
out=$(run "" --compress none); rc=$?
[ $rc -ne 0 ] && ok "empty dump fails the job" || nok "empty dump reported success"
[ -e "$OLD" ] && ok "older dump kept after empty dump" || nok "older dump rotated after empty dump"
[ "$(new_dumps)" -eq 0 ] && [ "$(invalid_files)" -eq 1 ] && ok "empty dump renamed to .invalid" || nok "empty dump handling wrong: $(ls "$OUT")"

# 3. wrong magic
out=$(run "NOTADUMP" --compress none); rc=$?
[ $rc -ne 0 ] && ok "dump without PGDMP header fails" || nok "wrong-magic dump reported success"
[ -e "$OLD" ] && ok "older dump kept after wrong-magic dump" || nok "older dump rotated after wrong-magic dump"
[ "$(new_dumps)" -eq 0 ] && [ "$(invalid_files)" -eq 1 ] && ok "wrong-magic dump kept as .invalid" || nok "wrong-magic handling wrong: $(ls "$OUT")"
case "$out" in *".invalid"*) ok "error message names the .invalid file" ;; *) nok "message does not mention .invalid: $out" ;; esac

# 4. failing compression test
out=$(run "PGDMP BADSTREAM" --compress zstd); rc=$?
[ $rc -ne 0 ] && ok "failing zstd -t fails the job" || nok "bad stream reported success"
[ -e "$OLD" ] && ok "older dump kept after bad stream" || nok "older dump rotated after bad stream"
[ "$(new_dumps)" -eq 0 ] && [ "$(invalid_files)" -eq 1 ] && ok "bad stream kept as .invalid" || nok "bad-stream handling wrong: $(ls "$OUT")"

# 5. good compressed dump
out=$(run "PGDMP fine" --compress zstd); rc=$?
[ $rc -eq 0 ] && ok "good zstd dump succeeds" || nok "good zstd dump failed: $out"
[ ! -e "$OLD" ] && ok "rotation runs after a good zstd dump" || nok "older dump not rotated"

# 6. ssh source with source-side compression: verified once per run
seed
out=$(DUMP_BODY="PGDMP remote" "$BIN" dump --from "ssh://u@192.0.2.1/postgres@localhost/appdb" \
    --output "$OUT" --keep 1 --from-keep 1 --compress zstd --compress-where source </dev/null 2>&1); rc=$?
[ $rc -eq 0 ] && ok "ssh dump with source compression succeeds" || nok "ssh dump failed: $out"
n=$(grep -c ' -t ' "$REC/zstd.log" 2>/dev/null)
[ "$n" -eq 1 ] && ok "dump verified once per run" || nok "zstd -t ran $n times"

exit $FAIL
