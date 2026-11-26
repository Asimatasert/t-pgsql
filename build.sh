#!/usr/bin/env bash
#
# build.sh — assemble the single-file `t-pgsql` executable from the modules in
# src/, concatenated in the order listed in src/build.manifest.
#
# The committed `t-pgsql` is a GENERATED artifact: edit files under src/ and run
# `./build.sh` (or `make build`), never hand-edit `t-pgsql`.
#
# Usage:
#   ./build.sh [output]     Build to <output> (default: ./t-pgsql), chmod +x
#   ./build.sh --check      Build to a temp file and diff against ./t-pgsql;
#                           exit non-zero if they differ (for CI / pre-commit)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
MANIFEST="$SRC/build.manifest"

[ -f "$MANIFEST" ] || { echo "build.sh: missing $MANIFEST" >&2; exit 1; }

assemble() {
    local out="$1" name
    : > "$out"
    while IFS= read -r name; do
        # skip blank lines and comments in the manifest
        case "$name" in ''|\#*) continue ;; esac
        [ -f "$SRC/$name" ] || { echo "build.sh: missing module $SRC/$name" >&2; exit 1; }
        cat "$SRC/$name" >> "$out"
    done < "$MANIFEST"
}

if [ "${1:-}" = "--check" ]; then
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    assemble "$tmp"
    if diff -u "$ROOT/t-pgsql" "$tmp" >/dev/null 2>&1; then
        echo "build.sh: OK — t-pgsql matches src/ (manifest order)"
    else
        echo "build.sh: MISMATCH — t-pgsql is out of sync with src/. Run ./build.sh" >&2
        diff -u "$ROOT/t-pgsql" "$tmp" | head -40 >&2
        exit 1
    fi
else
    out="${1:-$ROOT/t-pgsql}"
    assemble "$out"
    chmod +x "$out"
    echo "build.sh: wrote $out ($(wc -l < "$out") lines from $(grep -cvE '^\s*(#|$)' "$MANIFEST") modules)"
fi
