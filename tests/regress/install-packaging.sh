#!/usr/bin/env bash
# Regression: optional runtime tools are declared consistently across the
# Debian control file, the Makefile deb target, PKGBUILD and .SRCINFO.
# Override the repository root under test with T_REPO.
set -u

ROOT="${T_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

FAILS=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }

ctl="$ROOT/debian/control"
deb_depends="$(sed -n -E 's/^Depends: \$\{misc:Depends\}, (.*)$/\1/p' "$ctl")"
deb_recommends="$(sed -n -E 's/^Recommends: (.*)$/\1/p' "$ctl")"
mk_depends="$(sed -n -E 's/^.*echo "Depends: ([^"]*)".*$/\1/p' "$ROOT/Makefile")"
mk_recommends="$(sed -n -E 's/^.*echo "Recommends: ([^"]*)".*$/\1/p' "$ROOT/Makefile")"

for pkg in zstd xz-utils bzip2 pv python3; do
    check "debian/control Recommends $pkg" bash -c "[[ ', $deb_recommends,' == *', $pkg,'* ]]"
done
check "Makefile deb Depends equals debian/control Depends" test "$mk_depends" = "$deb_depends"
check "Makefile deb Recommends equals debian/control Recommends" \
    bash -c "[ -n '$deb_recommends' ] && [ '$mk_recommends' = '$deb_recommends' ]"
check "Depends still lists curl" bash -c "[[ '$deb_depends' == *curl* ]]"

for tool in zstd xz bzip2 pv python; do
    check "PKGBUILD optdepends has $tool" grep -qE "^ +'$tool: " "$ROOT/arch/PKGBUILD"
    check ".SRCINFO optdepends has $tool" grep -qE "^[[:space:]]+optdepends = $tool: " "$ROOT/arch/.SRCINFO"
done

pk="$(sed -n -E "s/^ +'([^:']+: [^']*)'\$/\1/p" "$ROOT/arch/PKGBUILD")"
si="$(sed -n -E 's/^[[:space:]]+optdepends = (.*)$/\1/p' "$ROOT/arch/.SRCINFO")"
check "PKGBUILD and .SRCINFO optdepends are identical" test "$pk" = "$si"

check "Formula documents what Homebrew cannot express" grep -q 'cannot express' "$ROOT/Formula/t-pgsql.rb"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS assertion(s) failed"; exit 1; fi
echo "all packaging assertions passed"
