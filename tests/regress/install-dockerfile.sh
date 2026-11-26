#!/usr/bin/env bash
# Regression: the Dockerfile must verify the PGDG signing key fingerprint and a
# mismatch must fail the build step. The check is extracted from the Dockerfile
# and run with a fake gpg. Override the file under test with T_DOCKERFILE.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DF="${T_DOCKERFILE:-$ROOT/Dockerfile}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

FAILS=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }

FPR="$(sed -n -E 's/^ARG PGDG_KEY_FPR=([0-9A-F]{40})$/\1/p' "$DF")"
check "Dockerfile declares a 40-hex PGDG_KEY_FPR" test -n "$FPR"
check "Dockerfile checks the downloaded key with gpg --show-keys" grep -q 'gpg --show-keys' "$DF"

# Extract the verification snippet (from actual_fpr= to its closing fi;) and
# turn the line continuations into plain shell lines.
sed -n '/actual_fpr=/,/^ *fi; *\\$/p' "$DF" | sed -E 's/ *\\$//; s/^ +//' > "$T/snippet.sh"
check "verification snippet is present in the Dockerfile" test -s "$T/snippet.sh"

mkdir -p "$T/bin"
cat > "$T/bin/gpg" <<'EOF'
#!/usr/bin/env bash
echo "pub:-:4096:1:7FCC7D46ACCC4CF8:1:::-:::scESC::::::23::0:"
echo "fpr:::::::::${FAKE_FPR}:"
echo "fpr:::::::::SUBKEYFPR0000000000000000000000000000:"
EOF
chmod +x "$T/bin/gpg"

run_snippet() { PATH="$T/bin:$PATH" FAKE_FPR="$1" PGDG_KEY_FPR="$FPR" bash -e "$T/snippet.sh" > "$T/out" 2>&1; }

if [ -s "$T/snippet.sh" ]; then
    check "matching fingerprint passes" run_snippet "$FPR"
    check "mismatching fingerprint fails the step" bash -c "! PATH='$T/bin:$PATH' FAKE_FPR=AAAA PGDG_KEY_FPR='$FPR' bash -e '$T/snippet.sh' >/dev/null 2>&1"
    check "mismatch message names both fingerprints" \
        bash -c "PATH='$T/bin:$PATH' FAKE_FPR=AAAA PGDG_KEY_FPR='$FPR' bash -e '$T/snippet.sh' 2>&1 | grep -q 'mismatch.*AAAA.*$FPR'"
    check "an empty key (gpg printed nothing) fails the step" \
        bash -c "printf '#!/bin/sh\n' > '$T/bin/gpg'; ! PATH='$T/bin:$PATH' PGDG_KEY_FPR='$FPR' bash -e '$T/snippet.sh' >/dev/null 2>&1"
fi

if [ "$FAILS" -ne 0 ]; then echo "$FAILS assertion(s) failed"; exit 1; fi
echo "all dockerfile assertions passed"
