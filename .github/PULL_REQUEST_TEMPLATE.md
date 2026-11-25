<!-- Thanks for the PR! Keep it focused: one logical change per pull request. -->

## What & why

<!-- What does this change do, and what problem does it solve? Link issues: Closes #NN -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Docs / examples
- [ ] Refactor / chore

## Checklist

- [ ] Changes are in `src/` and the generated `t-pgsql` was rebuilt with `./build.sh` (`./build.sh --check` passes)
- [ ] `bash -n t-pgsql` and `shellcheck -S error t-pgsql` pass
- [ ] Tests added or updated under `tests/regress/` (or explained below why not)
- [ ] Docs updated where behaviour changed: `--help`, man page, completions, README, `jobs.yaml.example`
- [ ] `CHANGELOG.md` updated under `## [Unreleased]`
- [ ] Commit subjects follow `type(scope): summary`; text is in English
- [ ] No real hostnames, IP addresses, passwords or tokens in the diff (use `example.com` / `192.0.2.x`)

## Notes for reviewers

<!-- Behaviour changes a user could notice, alternatives you considered, how you tested. -->
