#!/usr/bin/env bash
# Static regression checks for the GitHub workflows: least-privilege permissions,
# SHA-pinned actions, no expression interpolation in shell, release gates and a
# SHA256SUMS asset. Override the directory under test with T_WORKFLOW_DIR.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WF="${T_WORKFLOW_DIR:-$ROOT/.github/workflows}"
DEP="${T_DEPENDABOT:-$ROOT/.github/dependabot.yml}"
CI="$WF/ci.yml"
REL="$WF/release.yml"

FAILS=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }

has() { grep -Eq -- "$1" "$2"; }
hasnt() { ! grep -Eq -- "$1" "$2"; }

# top-level permissions: contents: read (a line starting at column 0)
toplevel_read() { awk '/^permissions:/{p=1;next} p&&/^[^ ]/{exit} p&&/contents: read/{f=1} END{exit f?0:1}' "$1"; }

check "ci.yml has top-level permissions: contents: read" toplevel_read "$CI"
check "release.yml defaults to contents: read" toplevel_read "$REL"
check "release.yml grants contents: write only per job (2 jobs)" \
    test "$(grep -c 'contents: write' "$REL")" = "2"
check "no top-level contents: write in release.yml" \
    bash -c "! awk '/^permissions:/{p=1;next} p&&/^[^ ]/{exit} p&&/contents: write/{f=1} END{exit f?0:1}' '$REL'"

unpinned() { # print uses: lines whose ref is not a 40-hex SHA
    grep -hE '^[[:space:]]*(-[[:space:]]*)?uses:' "$@" | grep -Ev '@[0-9a-f]{40}( |$)'
}
check "every action in workflows is pinned to a 40-hex SHA" test -z "$(unpinned "$CI" "$REL")"
check "pinned actions keep a version comment" \
    test -z "$(grep -hE '^[[:space:]]*(-[[:space:]]*)?uses:' "$CI" "$REL" | grep -Ev '# v[0-9]')"

# Print lines of run: blocks (indented 10+ spaces under a run: key) and the run:
# line itself that contain a ${{ expression. Strict POSIX awk: literal spaces,
# index(), no interval expressions.
run_expr_hits() {
    awk '
        /^[[:space:]]*run:/ { r = 1; if (index($0, "${{") > 0) { print; f = 1 } ; next }
        /^[[:space:]]*$/ { next }
        r && /^          / { if (index($0, "${{") > 0) { print; f = 1 } ; next }
        { r = 0 }
        END { exit f ? 0 : 1 }
    ' "$@"
}
no_expr_in_run() { ! run_expr_hits "$CI" "$REL"; }
check "no github/steps expression inside run: scripts" no_expr_in_run

check "ShellCheck is blocking in ci.yml (no || true)" hasnt 'shellcheck.*\|\| *true' "$CI"
check "ci.yml has a tests job using the timeout runner" has 'scripts/run-tests\.sh' "$CI"
check "ci.yml has an advisory version-consistency job" has 'version-consistency' "$CI"
check "release.yml publishes SHA256SUMS" has 'SHA256SUMS' "$REL"
check "release.yml checks tag against ./t-pgsql --version" has 't-pgsql --version' "$REL"
check "release.yml runs build.sh --check before publishing" has 'build\.sh --check' "$REL"
check "release.yml runs shellcheck before publishing" has 'shellcheck -S error' "$REL"
check "release.yml runs the regression tests through the timeout runner" has 'scripts/run-tests\.sh' "$REL"
check "release job needs the verify job" has 'needs: verify' "$REL"
check "dependabot covers github-actions and docker" \
    bash -c "grep -q 'package-ecosystem: github-actions' '$DEP' && grep -q 'package-ecosystem: docker' '$DEP'"

# multi-line run steps run under bash with strict mode
for f in "$CI" "$REL"; do
    n_run="$(grep -c 'run: |' "$f")"
    check "$(basename "$f"): every multi-line run step has set -euo pipefail" \
        test "$n_run" = "$(grep -c 'set -euo pipefail' "$f")"
    check "$(basename "$f"): every multi-line run step sets shell: bash" \
        test "$n_run" = "$(grep -c 'shell: bash' "$f")"
done
check "formula step does not hash a curl pipe" hasnt 'curl[^|]*\|[^|]*sha256sum' "$REL"
check "formula step rejects the empty-input sha256" \
    has 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' "$REL"
check "formula step downloads to a file and rejects an empty file" has '\[ ! -s "\$ARCHIVE" \]' "$REL"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS assertion(s) failed"; exit 1; fi
echo "all workflow assertions passed"
