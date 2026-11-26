# Contributing to t-pgsql

Thanks for taking the time to contribute! t-pgsql is a small Bash CLI for dumping,
restoring, cloning and masking PostgreSQL databases. This guide gets you from a
clone to a pull request that CI accepts.

## Ways to help

- **File a bug** with the *Bug report* issue template.
- **Propose a feature** with the *Feature request* template. Small, composable
  additions fit the tool best.
- **Improve the docs**: `README.md`, the man page, the shell completions and
  `jobs.yaml.example` are all fair game.
- **Report a vulnerability** privately, not as an issue: see [SECURITY.md](SECURITY.md).

## Project layout

| Path | What it is |
|---|---|
| `src/NN-*.sh` | the sources: function fragments, concatenated in the order of `src/build.manifest` |
| `t-pgsql` | the **generated** single-file CLI. **Never edit it by hand.** |
| `build.sh` | builds `t-pgsql` from `src/` (`./build.sh`) or verifies it (`./build.sh --check`) |
| `completions/` | bash, zsh and fish completions |
| `man/t-pgsql.1` | the man page |
| `jobs.yaml.example` | annotated example of the batch jobs file |
| `tests/regress/` | regression tests (plain Bash scripts), where present |

## Development workflow

Requirements: **Bash 4.0 or newer** (the macOS system Bash 3.2 is too old; on
macOS install a newer one, for example with Homebrew), `shellcheck`, and the
PostgreSQL client tools if you want to run the tool for real.

1. Edit the fragment(s) under `src/`.
2. Rebuild the single file and commit it together with your source change:

   ```sh
   ./build.sh            # or: make build
   ./build.sh --check    # must report that t-pgsql matches src/ (CI runs this)
   ```

3. Run the checks CI runs:

   ```sh
   bash -n t-pgsql
   shellcheck -S error t-pgsql
   ```

4. Run the regression tests, if the repository has any:

   ```sh
   for t in tests/regress/*.sh; do bash "$t" || echo "FAILED: $t"; done
   ```

   Each test is self-contained: it uses fake `psql`/`pg_dump`/`ssh`/`curl`
   binaries placed first on `PATH`, needs no network, no database and no SSH,
   and prints one `ok - ...` / `not ok - ...` line per assertion. A new fix
   should come with a test that fails without the fix and passes with it.

## Coding conventions

- Target Bash 4+; keep the code portable between macOS (BSD tools) and Linux
  (GNU tools).
- Quote expansions. Values that reach a remote shell must be escaped with the
  existing `pq` helper; values that reach SQL must be escaped with `sqllit`.
- Never put a password in a process argument or a log line; use the existing
  `.pgpass` helpers.
- Keep user-facing text in sync: when you add or change an option, update
  `src/30-help.sh`, the man page, the three completion files and the README.

## Commits and pull requests

- **English only** (code, comments, docs, commit messages, issues).
- Commit subjects follow `type(scope): short imperative summary`, for example
  `fix(restore): keep the target database when pg_restore fails` or
  `docs(man): document the doctor command`. Common types: `fix`, `feat`, `docs`,
  `chore`, `test`, `refactor`.
- Explain *what was wrong and what changed* in the body.
- **One logical change per pull request.** Smaller pull requests get reviewed faster.
- Add a line under `## [Unreleased]` in `CHANGELOG.md` for user-visible changes.
- Never put real hostnames, IP addresses, credentials or tokens in code, tests,
  docs, commits or issues. Use `example.com` and the `192.0.2.x` documentation range.

## Releases

Maintainer-only: pushing a `vX.Y.Z` tag triggers `.github/workflows/release.yml`.
