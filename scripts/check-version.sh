#!/usr/bin/env bash
#
# check-version.sh [VERSION] — fail when the version stamped in the repository
# disagrees between files. Without an argument the reference is the VERSION in
# src/00-header.sh; with one (e.g. the pushed tag, with or without "v") every
# place must equal it.
#
# This is the list scripts/release.sh stamps; keep the two in sync.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# label | file | sed -E expression printing the version (first match wins)
ITEMS=(
    'src/00-header.sh VERSION|src/00-header.sh|s/^VERSION="([^"]+)".*/\1/p'
    't-pgsql (built) VERSION|t-pgsql|s/^VERSION="([^"]+)".*/\1/p'
    'CHANGELOG.md top heading|CHANGELOG.md|s/^## \[([0-9][^]]*)\].*/\1/p'
    'debian/changelog top entry|debian/changelog|s/^t-pgsql \(([^)-]+)-[^)]*\).*/\1/p'
    'arch/PKGBUILD pkgver|arch/PKGBUILD|s/^pkgver=(.*)/\1/p'
    'arch/.SRCINFO pkgver|arch/.SRCINFO|s/^[[:space:]]*pkgver = (.*)/\1/p'
    'arch/.SRCINFO source URL|arch/.SRCINFO|s/^[[:space:]]*source = .*\/tags\/v([^/]+)\.tar\.gz$/\1/p'
    'Formula url|Formula/t-pgsql.rb|s/^[[:space:]]*url .*\/tags\/v([^/"]+)\.tar\.gz".*/\1/p'
    'Formula test assertion|Formula/t-pgsql.rb|s/.*assert_match "v([^"]+)".*/\1/p'
    'man page .TH line|man/t-pgsql.1|s/^\.TH .*"t-pgsql ([^"]+)".*/\1/p'
    'Makefile VERSION fallback|Makefile|s/.*git describe.*echo "([0-9][^"]*)".*/\1/p'
    'install.sh usage example|install.sh|s/^#   VERSION=v([0-9][^ ]*) .*/\1/p'
)

expected="${1:-}"
expected="${expected#v}"
if [ -z "$expected" ]; then
    expected="$(sed -n -E 's/^VERSION="([^"]+)".*/\1/p' src/00-header.sh | head -n1)"
fi
if [ -z "$expected" ]; then
    echo "check-version: cannot read VERSION from src/00-header.sh" >&2
    exit 2
fi

bad=0
echo "check-version: expecting $expected"
for item in "${ITEMS[@]}"; do
    IFS='|' read -r label file expr <<< "$item"
    if [ ! -f "$file" ]; then
        echo "  MISSING  $label ($file not found)"
        bad=$((bad + 1))
        continue
    fi
    found="$(sed -n -E "$expr" "$file" | head -n1)"
    if [ -z "$found" ]; then
        echo "  MISSING  $label: no version found in $file"
        bad=$((bad + 1))
    elif [ "$found" != "$expected" ]; then
        echo "  MISMATCH $label: $found (in $file)"
        bad=$((bad + 1))
    else
        echo "  ok       $label: $found"
    fi
done

if [ "$bad" -ne 0 ]; then
    echo "check-version: $bad place(s) disagree with $expected" >&2
    exit 1
fi
echo "check-version: all places agree on $expected"
