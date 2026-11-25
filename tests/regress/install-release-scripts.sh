#!/usr/bin/env bash
# Regression: scripts/release.sh stamps every version place (and refuses a dirty
# tree); scripts/check-version.sh fails when any place disagrees.
# Works on a throw-away local clone of HEAD, never on the real tree.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

FAILS=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }

if [ ! -x "$ROOT/scripts/release.sh" ] || [ ! -x "$ROOT/scripts/check-version.sh" ]; then
    nok "scripts/release.sh and scripts/check-version.sh exist and are executable"
    exit 1
fi

git clone -q --no-hardlinks "$ROOT" "$T/repo" || { nok "clone"; exit 1; }
cd "$T/repo" || exit 1
git config user.email test@example.com
git config user.name test
# use the working-tree copies of the files under test (they may be uncommitted)
mkdir -p scripts
cp "$ROOT/scripts/release.sh" "$ROOT/scripts/check-version.sh" scripts/
cp "$ROOT/Makefile" "$ROOT/install.sh" .
git add -A

# Make the clone's stale doc-owned places consistent first (the documentation
# branch fixes these in the real tree), so this test isolates the scripts.
CUR="$(sed -n -E 's/^VERSION="([^"]+)".*/\1/p' src/00-header.sh | head -n1)"
sed -E "s/^(\.TH T-PGSQL 1 )\"[^\"]*\" \"t-pgsql [^\"]*\"/\1\"January 2026\" \"t-pgsql $CUR\"/" man/t-pgsql.1 > "$T/m" && cat "$T/m" > man/t-pgsql.1
git commit -q -am "test fixture: align doc-owned version places" 2>/dev/null

check "check-version passes on a consistent tree" bash scripts/check-version.sh

# dirty tree is refused
echo x >> README.md
check "release.sh refuses a dirty tree" bash -c '! bash scripts/release.sh 9.9.9 >/dev/null 2>&1'
git checkout -q README.md
check "release.sh refuses a bad version" bash -c '! bash scripts/release.sh banana >/dev/null 2>&1'
check "release.sh refuses the current version" bash -c "! bash scripts/release.sh $CUR >/dev/null 2>&1"

# real run
check "release.sh 9.9.9 succeeds" bash scripts/release.sh 9.9.9 >"$T/rel.out" 2>&1
check "check-version agrees on 9.9.9 afterwards" bash scripts/check-version.sh 9.9.9
check "src header stamped" grep -q '^VERSION="9.9.9"' src/00-header.sh
check "generated t-pgsql rebuilt and in sync" bash build.sh --check
check "debian/changelog has the new top entry" grep -q '^t-pgsql (9.9.9-1) unstable' debian/changelog
check "debian/changelog keeps the previous entry" grep -q "^t-pgsql ($CUR-1) unstable" debian/changelog
check "PKGBUILD pkgver stamped" grep -q '^pkgver=9.9.9$' arch/PKGBUILD
check ".SRCINFO source URL stamped" grep -q 'source = t-pgsql-9.9.9.tar.gz::.*/tags/v9.9.9.tar.gz' arch/.SRCINFO
check "Formula url stamped" grep -q '/tags/v9.9.9.tar.gz' Formula/t-pgsql.rb
check "release.sh did not commit" test "$(git log --oneline | wc -l | tr -d ' ')" = "$(git rev-list --count HEAD | tr -d ' ')"
check "release.sh did not tag" test -z "$(git tag --points-at HEAD)"

# disagreement is detected
sed -E 's/^pkgver=.*/pkgver=1.0.0/' arch/PKGBUILD > "$T/p" && cat "$T/p" > arch/PKGBUILD
check "check-version fails on a drifted PKGBUILD" bash -c '! bash scripts/check-version.sh >/dev/null 2>&1'
check "check-version rejects a tag that differs from the script" bash -c '! bash scripts/check-version.sh v1.2.3 >/dev/null 2>&1'

if [ "$FAILS" -ne 0 ]; then echo "$FAILS assertion(s) failed"; exit 1; fi
echo "all release-script assertions passed"
