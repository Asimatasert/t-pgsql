# t-pgsql — Audit & Remediation Report

**Date:** 2026-07-03
**Branch:** `audit-hardening` (branched from `fix/audit-remediation`, itself off `master` @ `089065a`)
**Baseline audited:** `t-pgsql` v3.7.1 (single-file bash CLI, ~3,203 lines) + packaging, completions, docs
**Target after remediation:** v3.9.0

---

## 1. Executive summary

An automated multi-agent audit swept the whole repository across six lenses (shell
correctness, logic/flow, security, packaging consistency, install/make/completions,
docs-vs-behavior). Each candidate finding was then handed to an independent skeptic
agent that tried to *refute* it. **75 raw findings → 74 confirmed, 1 refuted.**

The confirmed findings collapse into **five root causes** plus a cluster of
packaging/version drift. The single most damaging issue was that the script ran under
`set -e` while being written as if it did not: every `cmd; result=$?; if … else
<handle failure> fi` block was dead code, so failures aborted the script *before* any
notification, retry, or multi-target logic ran. The second was that restore always
reported success regardless of the real `pg_restore` exit code.

All 74 findings have been remediated on `fix/audit-remediation` (5 commits, 19 files,
+1007/−373). An independent verification agent plus manual spot-checks confirmed the
fixes empirically (syntax, smoke, an unreachable-host failure probe, and grep-level
confirmation of the security/wiring changes). This branch carries those fixes forward
and adds this report.

---

## 2. Scope & method

| | |
|---|---|
| Audit workflow | 82 agents (1 structure map + 6 finder lenses + per-finding adversarial verifiers) |
| Remediation workflow | 10 agents (5 sequential core-script groups + 4 parallel ancillary + 1 verifier) |
| Files in scope | `t-pgsql`, `install.sh`, `Makefile`, `completions/*`, `man/t-pgsql.1`, `Formula/`, `debian/`, `arch/`, `.github/workflows/release.yml`, `README*`, `CHANGELOG.md`, `jobs.yaml.example` |
| Verification | `bash -n` on all shell files; `--version`/`--help`/`version` smoke; dump against an unreachable host (expect graceful exit 1); grep-level confirmation of secret handling and flag wiring |

**Why the core script was fixed sequentially:** all core bugs live in one 3,200-line
file, so parallel edits would collide. The five root-cause groups were applied in a
strict chain (each agent re-reads the current state), while the disjoint ancillary
files (install/make, completions, packaging, docs) were fixed in parallel.

---

## 3. Architecture (as-audited)

Single-file bash CLI; entry point `main "$@"`; dispatch is the `case "$COMMAND"` block.
All state is global; parsed connections use `FROM_*`/`TO_*` prefixes.

**User-facing commands:** `dump`, `restore`, `clone` (incl. `--stream` no-temp-file
pipe), `fetch`, `batch [job|all]`, `jobs [list|show|remove]`, `list`, `meta`, `clean`,
`version`, `help`.

**Functional areas:** globals/defaults · logging · notifications (Telegram w/ forum
thread, webhook, Slack, email) · metadata + tar.gz archives · skip-if-recent ·
connection parsing (local + `ssh://`) · password resolution · health checks · flat
`--config` loader · dump/restore/fetch/masking/stream/clone/list/meta/clean · batch &
jobs YAML engine (awk-based) · compression & retention (keep-N + GFS) · arg parser · main.

**Config precedence (highest wins):** CLI flags → password env vars (`T_PGSQL_*`) →
`--config` file (only fills unset values) → password file / prompt → `jobs.yaml`
(batch path only).

---

## 4. What already worked well

- Rich, coherent command surface; the happy path (no errors) produces correct dumps,
  restores, clones, and streamed clones across all four SSH/local direction combos.
- `pv`-based streaming clone with no temporary files.
- Metadata system (dump + `metadata.yaml` → `.tar.gz`) is well designed.
- Notification fan-out is structurally sound (Telegram thread support, Slack, webhook,
  email).
- macOS/Linux portability fallbacks for `stat`/`date` in most places.
- GFS retention concept (daily / weekly-Sunday / monthly-last-day / yearly-Dec-31).

The problems were almost entirely in **error paths, security, and advertised-but-unwired
features** — not in the core data flow.

---

## 5. Root causes & remediation

### RC1 — `set -e` turned all error handling into dead code  *(CRITICAL)*

The script had `set -e` yet used `cmd; result=$?; if … else <handle> fi` throughout, so
a failing command aborted the whole script before the `else`. Consequences: dump/clone
failure notifications and failed-metadata never fired; `((idx++))` (returns status 1)
killed `cmd_restore` after the first `--to` target on bash ≥ 4.1; health-check soft-fail
always aborted; parallel batch died on the first failed job and never wrote its `.exit`
file, so `--continue-on-error` was inert in parallel mode.

**Fix:** removed `set -e` (with an explanatory note — this matches the author's clear
intent, since the failure branches already existed); added targeted guards only where
continuing after a failure is unsafe; replaced `((x++))` with `x=$((x+1))`; made the
parallel-batch subshell always record its exit status and read status from the `.exit`
file rather than `wait`.

### RC2 — Restore always reported success  *(CRITICAL/HIGH)*

`restore_local` ended in `[ $r -eq 0 ] && log_success || log_warn` → returned 0
regardless. `restore_ssh` was worse: the remote command chain ended in `rm -f` (so the
ssh exit code was `rm`'s) and the success test read `$?` of `apply_masking`, which always
`return 0`. `clone_stream` inspected only `PIPESTATUS[0]` (dump side), ignoring a failed
restore side.

**Fix:** both restore functions now capture and `return` the real `pg_restore`/`createdb`
status; the cleanup `rm` no longer determines the result; `clone_stream` checks the full
`PIPESTATUS` (dump **and** restore). Failure notifications are now reachable.

### RC3 — Password leaks & command/SQL injection  *(CRITICAL/HIGH)*

Passwords were passed as `env PGPASSWORD=<literal>` (visible in `ps aux` locally *and*,
when embedded in ssh remote commands, on the remote host); `--log` wrote full commands
incl. cleartext passwords to a debug log; `get_password`/`parse_*` used
`eval "…='$value'"`, so a single quote crashed the run or injected shell; DB/host/user
names were interpolated unquoted into ssh-remote and `eval`'d command strings; the remote
temp dir `/tmp/t-pgsql` was a fixed world-readable path.

**Fix:** switched to a 600-mode `PGPASSFILE` (local and remote) — no secret in argv;
replaced eval-based assignment with `printf -v`; `printf %q` on identifiers interpolated
into remote/eval'd commands; redact secrets before logging; `chmod 700` the remote temp
dir.

### RC4 — Advertised flags/commands that did nothing  *(CRITICAL → LOW)*

`--only-table` / `--only-schema` were parsed, saved into jobs, written to metadata, and
used by shipped example jobs — but **never added to `pg_dump`**, so "dump only these
tables" silently dumped and restored the *entire* database (a data-safety bug).
`--health-check-after`, `--log-level`, `--compress none`, `--compress-level` (for gzip),
the `clean` command, bare `telegram` channel, and `-y` skipping batch prompts were all
no-ops.

**Fix:** implemented them (rather than deleting the docs) — `-t`/`-n` now flow to
`pg_dump` in both `cmd_dump` and `clone_stream`; post-op health check; level-gated
logging; `-Z0` for `none` and honored `--compress-level`; `clean` takes a source; bare
`telegram` accepted; `-y` suppresses batch prompts.

### RC5 — YAML/config fragility, retention globs, save_job gaps  *(HIGH → LOW)*

Inline YAML comments leaked into values (`keep: 7  # note` → the `#` truncated the
generated `bash -c` command and dropped every later flag); retention/skip globs
(`${db}_*`) matched prefix-overlapping databases (`prod` counted/deleted `prod_v2`
backups); `save_job` dropped `--exclude-data` and most other settings; external
compression ran *before* `meta_write`, silently skipping metadata/tar for zstd/xz/bzip2;
`load_config` quote-stripping was a no-op on macOS; `--from-file` swallowed a following
short flag; batch exited 0 even when jobs failed.

**Fix:** strip inline comments in the awk parsers; anchor retention/skip globs to the
`_YYYYMMDD_HHMMSS` timestamp pattern; `save_job` serializes the full option set; write
metadata before external compression; portable quote-stripping; reject `-`-prefixed
`--from-file` values; batch returns non-zero on any job failure.

### Packaging & version drift

Version strings disagreed across the repo (script 3.7.1, man 3.4.0, `jobs.yaml.example`
3.3.0, CHANGELOG 3.6.0, README example 3.0.0); the `release.yml` homebrew-update job was a
complete no-op (its seds matched nonexistent strings and it pushed from a detached HEAD
with failures masked); completions advertised a nonexistent `jobs delete` and omitted real
batch-filter flags; READMEs linked a missing `README_TR.md`; the man page advertised a
nonexistent `discord` channel.

**Fix:** all version strings synced to **3.9.0**; `release.yml` homebrew job rewritten to
target real patterns and push to the default branch; completions corrected (`remove`, +
`--only`/`--exclude`/`--notify-summary`/`--health-check-fail`, zsh `_describe` fix); dead
doc links/channels removed; `curl` added to Debian deps.

---

## 6. Commits on this line of work

| Commit | Scope |
|---|---|
| `d3e7bff` | `fix(core)` — RC1–RC5 in `t-pgsql` (+772 lines) |
| `6d728ea` | `fix(install)` — `install.sh` + `Makefile` |
| `fd10b27` | `fix(completions)` — bash / zsh / fish |
| `6e8446d` | `fix(packaging)` — Formula / arch / debian / `release.yml` |
| `cc0b88a` | `docs` — man / README×4 / CHANGELOG / `jobs.yaml.example` |
| *(this)* | `docs(audit)` — this report |

Total (excluding this report): 19 files, +1007 / −373.

---

## 7. Verification results

All 8 checks passed empirically (independent verifier + manual spot-check):

1. **Syntax** — `bash -n` clean on `t-pgsql`, `install.sh`, `completions/t-pgsql.bash`.
2. **Smoke** — `--version` → `t-pgsql v3.9.0`; `version` subcommand and `--help` exit 0.
3. **errexit** — no `set -e` at line 9 (replaced by a note); no risky `((x++))` remains.
4. **Failure probe** — `dump` to an unreachable host exits **1** with clear errors
   (`Database connection failed`, `Dump failed`), i.e. no false success, no silent death.
5. **Wiring** — `pg_dump` receives `-t`/`-n` when `ONLY_TABLES`/`ONLY_SCHEMAS` set;
   `restore_local`/`restore_ssh` return real codes.
6. **Security** — no `env PGPASSWORD=` argv form remains (PGPASSFILE used); `get_password`
   no longer uses `eval`.
7. **Completions** — `delete` gone, `remove` present; `--only`/`--exclude` added; `bash -n`
   clean.
8. **Version sync** — 3.9.0 across `t-pgsql`, man, `jobs.yaml.example`, Formula, PKGBUILD,
   debian/changelog (only historical changelog entries retain old numbers, as expected).

---

## 8. Remaining TODOs (not yet done)

1. **Regenerate sha256 hashes** in `Formula/t-pgsql.rb`, `arch/PKGBUILD`, `arch/.SRCINFO`
   after the `v3.9.0` tag is cut — the real tarball hash is only known post-tag (marked
   with `# TODO` comments in those files).
2. ~~Empty-artifact-on-failure~~ **DONE** — a failed dump no longer leaves a misleading
   empty `.tar.gz`; the partial `.dump` is removed on the failure path (exit code stays 1).
3. ~~Push / PR~~ **DONE** — pushed to `origin/audit-hardening`; PR #1 opened against `master`.

---

## 9. Appendix — confirmed findings by severity

**Critical (5):** dead error-handling under `set -e`; `((idx++))` aborts multi-target
restore; `--only-table`/`--only-schema` never applied to `pg_dump`; restore always
reports success; DB password exposed in `ps` via `env PGPASSWORD=`.

**High (16):** parallel-batch aborts on first failure; health-check soft-fail always
aborts; `restore_ssh`/`restore_local` swallow failures; `clone_stream` ignores restore
side; dump/stream failure handling dead; inline YAML comment truncates job command; clone
re-derives a possibly-stale archive; plaintext password in `--log`; eval/interpolation
command injection (connection strings, passwords, identifiers); version drift across repo
files; `release.yml` homebrew job no-op; `install.sh` empty-`master` fallback and missing
`mkdir`; `--only-*` documented-but-no-op; `clean` always no-op.

**Medium (26):** health-check probes wrong host; single-quote-in-password crash;
`shift 2` silent exit; unquoted path globs; external compression disables metadata; YAML
defaults override CLI; batch exits 0 on failure & `--batch` hijacks commands; dual batch
syntax trap; retention glob over-matches; `save_job` drops settings; predictable remote
temp dir; `curl|bash` unverified install; stale CHANGELOG/man/version-in-tarball;
hardcoded man/completion dirs; pinned-version skew; Makefile ignores DESTDIR; phantom
`.PHONY` targets; completions miss flags / wrong `jobs delete` / broken zsh candidates;
`--health-check-after` no-op; man FILES wrong; wrong default-output-dir docs; help uses
`--config` instead of `--yaml`.

**Low (27):** no trap cleanup; GFS membership regex; unused `--health-check-after`/
`--log-level` + Linux GFS monthly bug; macOS quote-strip no-op; `--from-file` swallows
short flag; deb dep set disagreement; hand-rolled `.deb` ignores `debian/`; stale README
version string; no uninstall; invalid deb version; missing zsh jobs completion; wrong
bash `--batch` completion; `--log-level` no-op; bare `telegram` rejected; man `discord`
channel; man `jobs delete`; man PGPASSWORD env; missing `--force`/`--save`/`--batch` in
help; `--compress none`/`--compress-level` ignored; broken `README_TR.md` links; version
drift in man/example; `-y` doesn't skip batch prompts.

*One finding was refuted during verification and is not counted above.*
