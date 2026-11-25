# Shared helper for the regress tests (sourced, not run).
# fake_pg_tools DIR: create harmless stand-ins for the PostgreSQL client tools a dump may
# call besides pg_dump/psql, so a test never depends on which real tools are installed.
# pg_restore -l succeeds and lists nothing; createdb/dropdb succeed. A dump written by the
# tests' fake pg_dump starts with the PGDMP magic bytes, which dump verification expects.
# Compressors are not faked: tests use the default gzip path, which pg_dump -Z performs
# itself (no external compressor is called).
fake_pg_tools() {
    local d="$1" t
    for t in pg_restore createdb dropdb; do
        printf '#!/bin/sh\nexit 0\n' > "$d/$t"
        chmod +x "$d/$t"
    done
}
