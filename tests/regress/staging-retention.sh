#!/usr/bin/env bash
# Regression: remote keep-N / stale purge / fetch "latest" must match exactly
# one base name (base_YYYYMMDD_HHMMSS...), so base "appdb" never touches
# "appdb_v2_..." dumps. Run from the repo root:
#   bash tests/regress/staging-retention.sh   (T_PGSQL_BIN overrides ./t-pgsql)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

SB="$TMP/sandbox"; FAKE="$TMP/fake"; REC="$TMP/rec"
mkdir -p "$SB" "$FAKE" "$REC" "$TMP/out"

cat > "$FAKE/ssh" <<'EOF'
#!/usr/bin/env bash
cmd="${!#}"
echo "$cmd" >> "$REC/ssh.log"
cmd="${cmd//\/tmp\/t-pgsql/$SB/t-pgsql}"
sed "s#/tmp/t-pgsql#$SB/t-pgsql#g" | tee -a "$REC/script.log" | sh -c "$cmd"
EOF
cat > "$FAKE/scp" <<'EOF'
#!/usr/bin/env bash
a=("$@"); src="${a[$((${#a[@]}-2))]}"; dst="${a[$((${#a[@]}-1))]}"
echo "scp $src $dst" >> "$REC/scp.log"
src="${src#*@*:}"
src="${src//\/tmp\/t-pgsql/$SB/t-pgsql}"
cp "$src" "$dst"
EOF
cat > "$FAKE/pg_dump" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = -f ] && { printf 'PGDMP-fake\n' > "$2"; }; shift; done
exit 0
EOF
for t in pg_isready createdb dropdb pg_dumpall; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/$t"
done
cat > "$FAKE/pg_restore" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKE/psql" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE"/*
export SB REC
export PATH="$FAKE:$PATH"
export T_PGSQL_FROM_PASSWORD=x T_PGSQL_TO_PASSWORD=x
export HOME="$TMP/home"; mkdir -p "$HOME"

SRC="ssh://u@192.0.2.1/postgres@localhost/appdb"
seed() {
    rm -rf "$SB/t-pgsql" "$TMP/out"; mkdir -p "$SB/t-pgsql" "$TMP/out"; chmod 700 "$SB/t-pgsql"
    for f in appdb_20200101_000000.dump appdb_20200102_000000.dump \
             appdb_v2_20200101_000000.dump appdb_v2_20200102_000000.dump; do
        printf 'PGDMP-fake\n' > "$SB/t-pgsql/$f"
    done
    touch -t 202001010000 "$SB/t-pgsql/appdb_20200101_000000.dump" "$SB/t-pgsql/appdb_v2_20200101_000000.dump"
    touch -t 202001020000 "$SB/t-pgsql/appdb_20200102_000000.dump" "$SB/t-pgsql/appdb_v2_20200102_000000.dump"
}

# --- keep-N ------------------------------------------------------------------
seed
"$BIN" dump --from "$SRC" --output "$TMP/out" --from-keep 1 </dev/null >/dev/null 2>&1
[ -e "$SB/t-pgsql/appdb_v2_20200101_000000.dump" ] && [ -e "$SB/t-pgsql/appdb_v2_20200102_000000.dump" ] \
    && ok "keep-N leaves appdb_v2 dumps alone" || nok "keep-N deleted appdb_v2 dumps"
[ ! -e "$SB/t-pgsql/appdb_20200101_000000.dump" ] && [ ! -e "$SB/t-pgsql/appdb_20200102_000000.dump" ] \
    && ok "keep-N still removes older appdb dumps" || nok "keep-N did not rotate appdb dumps"

# --- stale purge (--from-keep 0) ---------------------------------------------
seed
"$BIN" dump --from "$SRC" --output "$TMP/out" --from-keep 0 --from-stale 1h </dev/null >/dev/null 2>&1
[ -e "$SB/t-pgsql/appdb_v2_20200101_000000.dump" ] && [ -e "$SB/t-pgsql/appdb_v2_20200102_000000.dump" ] \
    && ok "stale purge leaves appdb_v2 dumps alone" || nok "stale purge deleted appdb_v2 dumps"
[ ! -e "$SB/t-pgsql/appdb_20200101_000000.dump" ] \
    && ok "stale purge removes stale appdb dumps" || nok "stale appdb dump not purged"

# --- fetch latest ------------------------------------------------------------
seed
rm -f "$REC/scp.log"
touch -t 202001030000 "$SB/t-pgsql/appdb_v2_20200102_000000.dump"
"$BIN" fetch --from "$SRC" --output "$TMP/out" </dev/null >/dev/null 2>&1
grep -q "appdb_20200102_000000.dump " "$REC/scp.log" && ! grep -q "appdb_v2" "$REC/scp.log" \
    && ok "fetch latest picks the appdb dump, not appdb_v2" || nok "fetch latest picked the wrong base: $(cat "$REC/scp.log")"

# --- regex metacharacters in the base are literal; no "\/" escapes -----------
seed
for f in a.b_20200101_000000.dump a.b_20200102_000000.dump aXb_20200101_000000.dump; do
    printf 'PGDMP-fake\n' > "$SB/t-pgsql/$f"
done
touch -t 202001010000 "$SB/t-pgsql/a.b_20200101_000000.dump" "$SB/t-pgsql/aXb_20200101_000000.dump"
touch -t 202001020000 "$SB/t-pgsql/a.b_20200102_000000.dump"
rm -f "$REC/script.log"
"$BIN" dump --from "$SRC" --output "$TMP/out" --dump-name a.b --from-keep 1 </dev/null >/dev/null 2>&1
[ -e "$SB/t-pgsql/aXb_20200101_000000.dump" ] && ok "'.' in the base name is matched literally" || nok "base a.b deleted an aXb dump"
[ ! -e "$SB/t-pgsql/a.b_20200101_000000.dump" ] && ok "older a.b dump rotated" || nok "a.b dump not rotated"
if grep -q '\\/' "$REC/script.log"; then nok "remote pattern contains a backslash before a slash"; else ok "remote pattern has no backslash before a slash"; fi

# The helper itself: a '/' in the base is not escaped, other metacharacters are literal.
FN="$TMP/fn.sh"
sed -n '/^remote_dump_match_re() {/,/^}/p' "$BIN" > "$FN"
re=$(bash -c 'source "$1"; remote_dump_match_re "$2"' _ "$FN" 'a/b.c]d')
case "$re" in *'a/b[.]c[]]d_'*) ok "helper keeps '/' and bracket-escapes metacharacters" ;; *) nok "unexpected helper output: $re" ;; esac
case "$re" in *'\/'*) nok "helper emits a backslash before a slash" ;; *) ok "helper emits no backslash before a slash" ;; esac

exit $FAIL
