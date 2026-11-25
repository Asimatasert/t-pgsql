#!/usr/bin/env bash
#
# release.sh VERSION — stamp a new version everywhere the repository records it.
#
#   scripts/release.sh 3.13.0
#
# What it does (working tree only; it never commits, tags or pushes):
#   - src/00-header.sh VERSION, then ./build.sh to regenerate t-pgsql
#   - CHANGELOG.md: renames "## [Unreleased]" to "## [VERSION] - DATE", or
#     inserts a heading with a TODO line when there is none
#   - debian/changelog: new top entry VERSION-1
#   - arch/PKGBUILD and arch/.SRCINFO (pkgver, pkgrel=1, source URL; text
#     substitution, no makepkg)
#   - Formula/t-pgsql.rb (url and test assertion)
#   - man/t-pgsql.1 .TH line, jobs.yaml.example header, Makefile fallback,
#     install.sh usage example
# and finishes by running scripts/check-version.sh.
#
# It refuses to run on a dirty working tree. After the tag exists, the
# sha256 values in arch/PKGBUILD, arch/.SRCINFO and Formula/t-pgsql.rb must be
# updated (the release workflow updates the formula; the Arch files are manual).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { echo "release: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: scripts/release.sh X.Y.Z"
NEW="${1#v}"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must look like X.Y.Z (got '$1')"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git work tree"
[ -z "$(git status --porcelain)" ] || die "working tree is dirty; commit or stash first"

CURRENT="$(sed -n -E 's/^VERSION="([^"]+)".*/\1/p' src/00-header.sh | head -n1)"
[ -n "$CURRENT" ] || die "cannot read the current VERSION from src/00-header.sh"
[ "$NEW" != "$CURRENT" ] || die "VERSION is already $CURRENT"

DATE_ISO="$(date '+%Y-%m-%d')"
DATE_MAN="$(date '+%B %Y')"
DATE_RFC="$(LC_ALL=C date -R)"

# sedi EXPR FILE — portable in-place sed -E (no -i differences between GNU/BSD)
sedi() {
    local tmp
    tmp="$(mktemp)"
    sed -E "$1" "$2" > "$tmp"
    cat "$tmp" > "$2"
    rm -f "$tmp"
}

echo "release: $CURRENT -> $NEW"

# 1. source of truth and generated file
sedi "s/^VERSION=\"[^\"]+\"/VERSION=\"$NEW\"/" src/00-header.sh
./build.sh >/dev/null

# 2. CHANGELOG.md
if grep -q '^## \[Unreleased\]' CHANGELOG.md; then
    sedi "s/^## \[Unreleased\].*/## [$NEW] - $DATE_ISO/" CHANGELOG.md
else
    tmp="$(mktemp)"
    awk -v h="## [$NEW] - $DATE_ISO" '
        !done && /^## \[/ { print h; print ""; print "### Changed"; print "- TODO: write the release notes"; print ""; done = 1 }
        { print }' CHANGELOG.md > "$tmp"
    cat "$tmp" > CHANGELOG.md
    rm -f "$tmp"
    echo "release: CHANGELOG.md has a TODO placeholder for $NEW; fill it in"
fi

# 3. debian/changelog
trailer="$(grep -m1 -E '^ -- ' debian/changelog | sed -E 's/^ -- (.*)  .*/\1/')"
[ -n "$trailer" ] || die "cannot find a maintainer line in debian/changelog"
tmp="$(mktemp)"
{
    printf 't-pgsql (%s-1) unstable; urgency=medium\n\n' "$NEW"
    printf '  * Release %s. See CHANGELOG.md for details.\n\n' "$NEW"
    printf ' -- %s  %s\n\n' "$trailer" "$DATE_RFC"
    cat debian/changelog
} > "$tmp"
cat "$tmp" > debian/changelog
rm -f "$tmp"

# 4. Arch packaging (text substitution; no makepkg available everywhere)
sedi "s/^pkgver=.*/pkgver=$NEW/; s/^pkgrel=.*/pkgrel=1/" arch/PKGBUILD
sedi "s/^([[:space:]]*pkgver = ).*/\1$NEW/; s/^([[:space:]]*pkgrel = ).*/\11/; s#^([[:space:]]*source = t-pgsql-)[^:]*(\.tar\.gz::.*/tags/v)[^/]*(\.tar\.gz)\$#\1$NEW\2$NEW\3#" arch/.SRCINFO

# 5. Homebrew formula (url version and test assertion; sha256 is updated after tagging)
sedi "s#(/tags/v)[0-9][^/\"]*(\.tar\.gz)#\1$NEW\2#; s/(assert_match \"v)[^\"]+(\")/\1$NEW\2/" Formula/t-pgsql.rb

# 6. man page, example config, Makefile fallback, installer usage text
sedi "s/^(\.TH T-PGSQL 1 )\"[^\"]*\" \"t-pgsql [^\"]*\"/\1\"$DATE_MAN\" \"t-pgsql $NEW\"/" man/t-pgsql.1
sedi "2s/\(v[0-9][^)]*\)/(v$NEW)/" jobs.yaml.example
sedi "s/(git describe.*echo \")[0-9][^\"]*(\")/\1$NEW\2/" Makefile
sedi "s/^(#   VERSION=v)[0-9][^ ]*/\1$NEW/" install.sh

echo "release: running scripts/check-version.sh"
"$ROOT/scripts/check-version.sh" "$NEW"

cat <<EOF

release: done. Nothing was committed, tagged or pushed.
Next: review 'git diff', run the tests, commit, then tag v$NEW.
After the tag exists, update the sha256 values in arch/PKGBUILD,
arch/.SRCINFO and Formula/t-pgsql.rb (the release workflow updates the formula).
EOF
