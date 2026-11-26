# ==============================================================================
# SECURITY HELPERS (credential handling, shell/SQL escaping, redaction)
# ==============================================================================
# Trim leading/trailing whitespace WITHOUT mangling backslashes or quotes the way
# "echo \$x | xargs" does (that silently corrupted an identifier so its filter was ignored).
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }


# Shell-quote a value for safe re-parsing by a shell (local eval or remote sh).
pq() { printf '%q' "$1"; }

# POSIX single-quote a value (portable for remote shells that lack $'...').
shq() {
    local s
    s=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
    printf "'%s'" "$s"
}

# Escape a value for use inside a SQL single-quoted string literal.
sqllit() {
    local s="$1" sq="'"
    s="${s//$sq/$sq$sq}"
    printf '%s' "$s"
}

# Quote a value as a SQL identifier (double-quoted, embedded quotes doubled).
sqlid() {
    local s="$1"
    s="${s//\"/\"\"}"
    printf '"%s"' "$s"
}

# Quote a possibly schema-qualified table name: "schema"."table" (or "table"). The LAST
# dotted segment is the table; everything before it is the (possibly dotted) schema.
sqlid_table() {
    local t="$1"
    if [[ "$t" == *.* ]]; then
        printf '%s.%s' "$(sqlid "${t%.*}")" "$(sqlid "${t##*.}")"
    else
        sqlid "$t"
    fi
}

# Escape a field for the libpq .pgpass file (backslash and colon are special).
pgpass_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g'
}

# Redact known passwords from a command string before logging.
redact_cmd() {
    local s="$1" p
    # Redact both the raw and the .pgpass-escaped form of each known password.
    for p in "$FROM_DB_PASSWORD" "$TO_DB_PASSWORD"; do
        [ -z "$p" ] && continue
        s="${s//"$p"/***}"
        s="${s//"$(pgpass_escape "$p")"/***}"
    done
    # Fallback: neutralize any lingering PGPASSWORD=<value> tokens.
    s="$(printf '%s' "$s" | sed -E "s/PGPASSWORD=([\"'])[^\"']*\1/PGPASSWORD=***/g; s/PGPASSWORD=[^[:space:]'\"]*/PGPASSWORD=***/g")"
    printf '%s' "$s"
}

# Redact inline password FLAG values (--password/--from-password/--to-password <value>)
# from an argv-style string before logging it. Complements redact_cmd (which redacts known
# password VALUES); this catches the flag form used by legacy job 'args:' strings.
redact_args() {
    # Quote-aware value matcher: consume a whole '...'/"..." token (which may contain spaces)
    # or a bare token, so a space-containing quoted password is fully masked, not just its
    # first word.
    printf '%s' "$1" | sed -E "s/(--(from-|to-)?password)[[:space:]]+('[^']*'|\"[^\"]*\"|[^[:space:]]+)/\1 ***/g"
}

# Create a 600-mode .pgpass file for the given credentials and echo its path.
make_pgpass_file() {
    local user="$1" password="$2" f
    f="$(umask 077; mktemp "${TMPDIR:-/tmp}/t-pgsql-pgpass.XXXXXX")" || return 1
    chmod 600 "$f"
    printf '%s\n' "*:*:*:$(pgpass_escape "$user"):$(pgpass_escape "$password")" > "$f"
    printf '%s' "$f"
}

# Create a local 600-mode .pgpass file and export PGPASSFILE for local commands.
# Sets global _PGPASS_TMP so cleanup_local_pgpass can remove it.
# Temp paths to remove on exit/interruption. A SIGINT/SIGTERM (or "timeout") used to
# kill the shell before cleanup_* ran, leaking the plaintext-password .pgpass files and
# decompressed dumps. install_cleanup_trap (called from main) wires the trap.
_TMP_TO_CLEAN=()
reg_tmp() { [ -n "$1" ] && _TMP_TO_CLEAN+=("$1"); }
run_tmp_cleanup() { local p; for p in "${_TMP_TO_CLEAN[@]}"; do rm -rf "$p" 2>/dev/null; done; }
install_cleanup_trap() { trap 'run_tmp_cleanup' EXIT INT TERM; }

_PGPASS_TMP=""
setup_local_pgpass() {
    _PGPASS_TMP="$(make_pgpass_file "$1" "$2")" || return 1
    reg_tmp "$_PGPASS_TMP"
    unset PGPASSWORD
    export PGPASSFILE="$_PGPASS_TMP"
}
cleanup_local_pgpass() {
    unset PGPASSFILE
    [ -n "$_PGPASS_TMP" ] && rm -f "$_PGPASS_TMP"
    _PGPASS_TMP=""
}

# Run a remote command over ssh WITHOUT placing it — and any password embedded in a
# remote_pgpass_preamble — into the LOCAL process argv (where another local user's `ps`
# could read it). The command is fed to the remote shell via stdin instead. Use this for
# any ssh call whose own stdin is otherwise unused; sites that pipe data through ssh
# stdin (stream, globals-apply, masking batch) cannot use it and keep the secret only
# transiently in argv. Returns the remote command's exit status; stdout/stderr pass
# through so `out=$(ssh_exec ...)` and redirections on the call still work.
# Usage: ssh_exec <port> <user@host> <command> [extra ssh options...]
# The remote command is executed by bash when the remote has it, else /bin/sh. bash is
# preferred because call sites escape values with pq() (printf %q), whose $'...' output for
# control characters is bash-only; falling back to sh keeps minimal remotes (busybox/ash,
# no bash) working for the common case of values without control characters.
ssh_exec() {
    local port="$1" dest="$2" cmd="$3"; shift 3
    # Probe for bash with the redirect scoped to the PROBE (command -v), then exec cleanly.
    # NOT 'exec bash 2>/dev/null': that redirect survives the exec and would permanently
    # send the remote command's stderr to /dev/null (breaking stderr capture). NOT
    # 'exec bash || exec sh': a failed exec makes a non-interactive shell exit before the
    # ||, so the sh fallback would be dead code on a bash-less (busybox/ash) remote.
    printf '%s\n' "$cmd" | ssh -p "$port" "${SSH_OPTS[@]}" "$@" "$dest" 'command -v bash >/dev/null 2>&1 && exec bash; exec sh'
}

# Emit a remote shell preamble that writes a 600-mode .pgpass, exports
# PGPASSFILE via an assignment (never argv), and cleans it up on exit.
# The password only appears as an argument to the printf builtin, not to
# any long-lived process (psql/pg_dump/pg_restore) argv.
remote_pgpass_preamble() {
    local line
    line=$(shq "*:*:*:$(pgpass_escape "$1"):$(pgpass_escape "$2")")
    printf '%s' \
'PGPASSFILE=$(umask 077; mktemp 2>/dev/null || { f="/tmp/.tpg.$$"; :>"$f"; echo "$f"; }); export PGPASSFILE; chmod 600 "$PGPASSFILE"; printf '"'"'%s\n'"'"' '"$line"' >"$PGPASSFILE"; trap '"'"'rm -f "$PGPASSFILE"'"'"' EXIT; '
}

