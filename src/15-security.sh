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

# Fill _RV_SORTED with every textual form of $1 that can appear in a logged command,
# longest first. Works on arbitrary bytes (quotes, backslashes, colons).
_redact_variants() {
    local -A seen=()
    local -a cur=("$1") next=()
    local v t sq="'" i j tmp
    seen["$1"]=1
    for _ in 1 2 3; do
        next=()
        for v in "${cur[@]}"; do
            t="${v//\\/\\\\}"; t="${t//:/\\:}"                 # .pgpass escaping
            [ -n "$t" ] && [ -z "${seen[$t]+x}" ] && { seen["$t"]=1; next+=("$t"); }
            t="${v//$sq/$sq\\$sq$sq}"                              # inside shq(...)
            [ -z "${seen[$t]+x}" ] && { seen["$t"]=1; next+=("$t"); }
            t="$(printf '%q' "$v")"                                 # pq(...)
            [ -z "${seen[$t]+x}" ] && { seen["$t"]=1; next+=("$t"); }
        done
        cur=("${next[@]}")
    done
    _RV_SORTED=("${!seen[@]}")
    for ((i = 1; i < ${#_RV_SORTED[@]}; i++)); do        # insertion sort, longest first
        tmp="${_RV_SORTED[i]}"
        for ((j = i - 1; j >= 0 && ${#_RV_SORTED[j]} < ${#tmp}; j--)); do
            _RV_SORTED[j+1]="${_RV_SORTED[j]}"
        done
        _RV_SORTED[j+1]="$tmp"
    done
}

# Redact known passwords from a command string before logging.
redact_cmd() {
    local s="$1" p k
    # Redact the raw password and every rendering a command string can carry: the
    # .pgpass-escaped form, POSIX single-quoted (shq) and printf-%q (pq) forms, and
    # those layered up to three deep (pgpass line inside shq inside shq). Longest first so
    # a shorter variant never leaves a fragment of a longer one behind.
    for p in "$FROM_DB_PASSWORD" "$TO_DB_PASSWORD"; do
        [ -z "$p" ] && continue
        _redact_variants "$p"
        for k in "${_RV_SORTED[@]}"; do
            s="${s//"$k"/***}"
        done
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
# Remote credential files (port<TAB>dest<TAB>path) created by remote_pgpass_create and not
# yet removed; the exit/signal cleanup removes them over ssh.
_REMOTE_TMP_TO_CLEAN=()
run_tmp_cleanup() {
    local p e port dest path
    for p in "${_TMP_TO_CLEAN[@]}"; do rm -rf "$p" 2>/dev/null; done; _TMP_TO_CLEAN=()
    local -a pending=("${_REMOTE_TMP_TO_CLEAN[@]}")
    _REMOTE_TMP_TO_CLEAN=()
    for e in "${pending[@]}"; do
        IFS=$'\t' read -r port dest path <<< "$e"
        ssh_exec "$port" "$dest" "rm -f $(pq "$path")" >/dev/null 2>&1 </dev/null
    done
    # Run lock (src/37-lock.sh): released last, on every exit path; only if we own it.
    lock_release
}
# INT/TERM must clean up AND stop the script: a handler that only cleaned up let the run
# continue (compress, metadata, notifications) with its credential files already deleted.
# \`exit\` fires the EXIT trap, which performs the cleanup exactly once.
#
# ONE exit hook for the whole program (a second `trap ... EXIT` would silently replace it):
# history line, then temp cleanup + lock release, then the final heartbeat ping. A failing
# step never stops the next one and the exit status of the run is preserved.
_run_exit_trap() {
    local rc=$?
    history_on_exit "$rc" 2>/dev/null || true
    run_tmp_cleanup || true
    ping_finish "$rc" 2>/dev/null || true
    return "$rc"
}
install_cleanup_trap() { trap '_run_exit_trap' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; }

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
# stdin (stream, masking batch) create the remote .pgpass first with remote_pgpass_create
# and pass only PGPASSFILE=<path> in argv. Returns the remote command's exit status; stdout/stderr pass
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

# Create a 600-mode .pgpass on a remote host and return its path in _RPGPASS_PATH, WITHOUT the password ever
# appearing in a local or remote argv: the script that writes the file travels on ssh stdin
# (via ssh_exec). Callers that must keep stdin free for a data stream (stream clone, masking
# batch) then reference only `PGPASSFILE=<path>` in their ssh command line and remove the
# file with remote_pgpass_remove. The file is also removed by run_tmp_cleanup if the
# caller never gets to (interrupt, early exit).
# The path is a global (not stdout) so the registration for run_tmp_cleanup survives: a
# $(...) capture would run this in a subshell and lose it.
# Usage: remote_pgpass_create <ssh_port> <user@host> <db_user> <db_password>
_RPGPASS_PATH=""
remote_pgpass_create() {
    local port="$1" dest="$2" line out path
    _RPGPASS_PATH=""
    line=$(shq "*:*:*:$(pgpass_escape "$3"):$(pgpass_escape "$4")")
    out=$(ssh_exec "$port" "$dest" \
'f=$(umask 077; mktemp 2>/dev/null || { f="/tmp/.tpg.$$"; :>"$f"; echo "$f"; }) || exit 1; chmod 600 "$f" || { rm -f "$f"; exit 1; }; printf '"'"'%s\n'"'"' '"$line"' >"$f" || { rm -f "$f"; exit 1; }; printf '"'"'%s\n'"'"' "$f"' 2>/dev/null) || return 1
    path="${out##*$'\n'}"
    # Only accept a plain absolute path; anything else could not be removed safely.
    [[ "$path" =~ ^/[A-Za-z0-9._/+-]+$ ]] || return 1
    _REMOTE_TMP_TO_CLEAN+=("$port"$'\t'"$dest"$'\t'"$path")
    _RPGPASS_PATH="$path"
}

# Remove a remote file made by remote_pgpass_create (and forget it).
# Usage: remote_pgpass_remove <ssh_port> <user@host> <path>
remote_pgpass_remove() {
    local port="$1" dest="$2" path="$3" e kept=()
    [ -z "$path" ] && return 0
    for e in "${_REMOTE_TMP_TO_CLEAN[@]}"; do
        [ "$e" = "$port"$'\t'"$dest"$'\t'"$path" ] || kept+=("$e")
    done
    _REMOTE_TMP_TO_CLEAN=("${kept[@]}")
    ssh_exec "$port" "$dest" "rm -f $(pq "$path")" >/dev/null 2>&1 </dev/null
}

