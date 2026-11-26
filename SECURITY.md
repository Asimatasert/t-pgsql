# Security Policy

t-pgsql handles database credentials, SSH access to database hosts and, for
notifications and the `bot` command, a Telegram bot token. Security reports are
taken seriously.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through GitHub's private vulnerability reporting:
[**Report a vulnerability**](https://github.com/Asimatasert/t-pgsql/security/advisories/new)
(repository **Security** tab → **Advisories**). Include:

- what the issue is and how to reproduce it,
- the impact you foresee, and
- the affected version (`t-pgsql --version`) and how you installed it.

Please **redact real hostnames, IP addresses, passwords and tokens** from your
report; use placeholders such as `example.com` and `192.0.2.10`.

You can expect an initial response within a few days. Once a fix is available it
ships in a tagged release, with credit to the reporter unless you prefer to stay
anonymous.

## Supported versions

This is a small project. Fixes land on the **latest release** only; please
upgrade to the newest tag before reporting.

## What is in scope

- Leaking or logging of passwords, `.pgpass` content, SSH details or the Telegram
  bot token (for example through process arguments, log files, temporary files or
  notifications).
- Command or SQL injection through connection strings, database or table names,
  jobs/config file values or other user-controlled input that reaches a local or
  remote shell, `psql`, `pg_dump` or `pg_restore`.
- Unsafe handling of temporary files, dump files or file permissions.
- The Telegram bot acting on messages from a chat other than the configured one.
- Flaws in the install script or release artifacts that could lead to running
  unintended code.

## Out of scope

- Weaknesses of PostgreSQL, OpenSSH or other tools that t-pgsql only calls.
- Issues that need an attacker who already controls your account, your
  `jobs.yaml` or your SSH keys.
- Passing `--password` on the command line: it is visible in `ps` by design and
  documented as discouraged; use `--password-file` or the `T_PGSQL_*_PASSWORD`
  environment variables instead.
