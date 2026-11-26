# ==============================================================================
# RUN LOCK (no two runs write the same target at the same time)
# ==============================================================================
# One lock per target, taken with an atomic mkdir (no flock: it is missing on macOS):
#   <state dir>/locks/<safe-name>-<checksum>.lock/meta
# dump and fetch lock "<output dir> + dump base name"; clone, restore and upgrade lock the
# target database (and a non-streaming clone/upgrade also the dump base it writes).
# A held lock makes the run SKIP with exit status 75 (not a failure: no failure
# notification). A broken lock directory never stops a backup (the run goes on unlocked).

LOCK_WAIT=0                   # --lock-wait: seconds to wait for a held lock before skipping
LOCK_WAIT_SET=false           # true once --lock-wait given on CLI (beats config)
NO_LOCK=false                 # --no-lock: take no lock at all
_LOCK_HELD=()                 # lock directories this process owns (released on exit)
_LOCK_KEYS=()                 # keys of the current command
_LOCK_HOST=""
_LOCK_STALE_WHY=""
_LOCK_HOLDER=""

# Per-user state directory. T_PGSQL_STATE_DIR overrides the location (used by tests);
# otherwise the bot's directory is reused. The same rules apply to both: created 0700,
# never a symlink, owned by the current user.
lock_state_dir() {
    local d="${T_PGSQL_STATE_DIR:-}"
    if [ -z "$d" ]; then
        bot_state_dir
        return $?
    fi
    [ -L "$d" ] && return 1
    if [ ! -e "$d" ]; then
        (umask 077; mkdir -p "$d") 2>/dev/null || return 1
    fi
    [ -d "$d" ] && [ ! -L "$d" ] && [ "$(bot_file_owner "$d")" = "$(id -u)" ] || return 1
    chmod 700 "$d" 2>/dev/null
    printf '%s\n' "$d"
}

# Safe file name for a lock key: unsafe characters replaced, truncated, plus a checksum of
# the FULL key so two different keys never share a name (prod / prod_v2, truncation).
_lock_safe_name() {
    local key="$1" s sum
    s="${key//[^A-Za-z0-9._-]/_}"
    s="${s:0:80}"
    sum="$(printf '%s' "$key" | cksum)"
    sum="${sum%% *}"
    printf '%s-%s' "$s" "$sum"
}

# Absolute, symlink-resolved form of a directory that may not exist yet (the deepest
# existing ancestor is resolved), so spellings of one directory give one key.
_lock_norm_dir() {
    local d="$1" cur tail="" real
    [ -z "$d" ] && d="."
    case "$d" in /*) ;; *) d="$PWD/$d" ;; esac
    while [ "${#d}" -gt 1 ] && [ "${d%/}" != "$d" ]; do d="${d%/}"; done
    cur="$d"
    while [ ! -d "$cur" ] && [ "$cur" != "/" ] && [ -n "$cur" ]; do
        tail="/${cur##*/}$tail"
        cur="${cur%/*}"
        [ -z "$cur" ] && cur="/"
    done
    real="$(cd "$cur" 2>/dev/null && pwd -P)" || real="$cur"
    [ "$real" = "/" ] && real=""
    printf '%s%s' "$real" "$tail"
}

# mtime of a path in epoch seconds (GNU stat, then BSD stat).
_lock_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Process start time text (identifies a process across pid reuse); empty when unavailable.
_lock_pstart() {
    local out
    out="$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null)" || out=""
    out="${out//$'\n'/ }"
    printf '%s' "$(trim "$out")"
}

_lock_fmt_epoch() {
    date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$1"
}

_lock_max_age() {
    local m="${T_PGSQL_LOCK_MAX_AGE:-86400}"
    [[ "$m" =~ ^[1-9][0-9]*$ ]] || m=86400
    printf '%s' "$m"
}

# Read <dir>/meta into m_pid m_host m_start m_pstart m_cmd m_job. Fails without meta.
_lock_read_meta() {
    local f="$1/meta" k v line
    m_pid=""; m_host=""; m_start=""; m_pstart=""; m_cmd=""; m_job=""
    [ -f "$f" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            pid) m_pid="$v" ;;
            host) m_host="$v" ;;
            start) m_start="$v" ;;
            pstart) m_pstart="$v" ;;
            cmd) m_cmd="$v" ;;
            job) m_job="$v" ;;
        esac
    done < "$f"
    [[ "$m_pid" =~ ^[0-9]+$ ]] || return 1
    return 0
}

# Is the lock directory a leftover nobody owns? Sets _LOCK_STALE_WHY. Never true for a
# live owner on this host (unless it is older than the hard maximum).
_lock_is_stale() {
    local dir="$1" now age mt cur
    now="$(date +%s)"
    if ! _lock_read_meta "$dir"; then
        # No (valid) meta: the owner may be between mkdir and writing it. Give it a grace period.
        mt="$(_lock_mtime "$dir")"
        [[ "$mt" =~ ^[0-9]+$ ]] || return 1
        if [ $((now - mt)) -gt 10 ]; then _LOCK_STALE_WHY="lock without owner information"; return 0; fi
        return 1
    fi
    if [[ "$m_start" =~ ^[0-9]+$ ]]; then
        age=$((now - m_start))
        if [ "$age" -gt "$(_lock_max_age)" ]; then
            _LOCK_STALE_WHY="owner pid $m_pid on ${m_host:-unknown host} older than $(_lock_max_age)s"
            return 0
        fi
    fi
    [ "$m_host" = "$_LOCK_HOST" ] || return 1       # another host: only the hard maximum applies
    if ! kill -0 "$m_pid" 2>/dev/null; then
        _LOCK_STALE_WHY="owner pid $m_pid is not running"
        return 0
    fi
    if [ -n "$m_pstart" ]; then
        cur="$(_lock_pstart "$m_pid")"
        if [ -n "$cur" ] && [ "$cur" != "$m_pstart" ]; then
            _LOCK_STALE_WHY="pid $m_pid was reused by another process"
            return 0
        fi
    fi
    return 1
}

# Write the meta file atomically into a lock directory we just created.
_lock_write_meta() {
    local dir="$1" key="$2" tmp="$1/meta.$$"
    {
        printf 'pid=%s\n' "$$"
        printf 'host=%s\n' "$_LOCK_HOST"
        printf 'start=%s\n' "$(date +%s)"
        printf 'pstart=%s\n' "$(_lock_pstart "$$")"
        printf 'cmd=%s\n' "$COMMAND"
        printf 'job=%s\n' "$(printf '%s' "${CURRENT_JOB_NAME:-}" | tr '\n' ' ')"
        printf 'key=%s\n' "$(printf '%s' "$key" | tr '\n' ' ')"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/meta" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Try once to take one lock. 0 = acquired, 1 = held by a live owner (_LOCK_HOLDER set),
# 2 = the lock directory cannot be used (caller runs without it).
_lock_try() {
    local dir="$1" key="$2" mx old now mt
    if mkdir "$dir" 2>/dev/null; then
        _lock_write_meta "$dir" "$key" || { rm -rf "$dir" 2>/dev/null; return 2; }
        _LOCK_HELD+=("$dir")
        return 0
    fi
    [ -d "$dir" ] || return 2                          # failed for a reason other than "exists"
    if _lock_is_stale "$dir"; then
        # Take-over is serialised by a second mkdir mutex, then the stale directory is
        # renamed away (atomic) before the new lock is created; the staleness is re-checked
        # under the mutex so a lock a faster process just created is never removed.
        mx="$dir.take"
        if ! mkdir "$mx" 2>/dev/null; then
            now="$(date +%s)"; mt="$(_lock_mtime "$mx")"
            if [[ "$mt" =~ ^[0-9]+$ ]] && [ $((now - mt)) -gt 60 ]; then
                rmdir "$mx" 2>/dev/null
                mkdir "$mx" 2>/dev/null || { _lock_describe "$dir"; return 1; }
            else
                _lock_describe "$dir"; return 1
            fi
        fi
        if [ -d "$dir" ]; then
            if _lock_is_stale "$dir"; then
                old="$dir.old.$$"
                log_warn "Taking over stale lock (${_LOCK_STALE_WHY}; held by ${m_cmd:-unknown command}${m_job:+, job $m_job})"
                if ! mv "$dir" "$old" 2>/dev/null; then rmdir "$mx" 2>/dev/null; return 2; fi
                rm -rf "$old" 2>/dev/null
            else
                rmdir "$mx" 2>/dev/null
                _lock_describe "$dir"; return 1
            fi
        fi
        if mkdir "$dir" 2>/dev/null && _lock_write_meta "$dir" "$key"; then
            rmdir "$mx" 2>/dev/null
            _LOCK_HELD+=("$dir")
            return 0
        fi
        rmdir "$mx" 2>/dev/null
        [ -d "$dir" ] && [ ! -f "$dir/meta" ] && rmdir "$dir" 2>/dev/null
        return 2
    fi
    _lock_describe "$dir"
    return 1
}

# Fill _LOCK_HOLDER with a one-line description of the lock's owner.
_lock_describe() {
    local dir="$1" now
    now="$(date +%s)"
    if _lock_read_meta "$dir"; then
        _LOCK_HOLDER="pid $m_pid on ${m_host:-unknown host}, command ${m_cmd:-unknown}"
        [ -n "$m_job" ] && _LOCK_HOLDER+=", job $m_job"
        if [[ "$m_start" =~ ^[0-9]+$ ]]; then
            _LOCK_HOLDER+=", since $(_lock_fmt_epoch "$m_start") ($(format_elapsed $((now - m_start))) ago)"
        fi
    else
        _LOCK_HOLDER="an owner that is still starting"
    fi
}

# Release every lock this process owns. Only a lock whose meta names THIS pid is removed.
lock_release() {
    local dir old
    [ "${#_LOCK_HELD[@]}" -gt 0 ] || return 0
    for dir in "${_LOCK_HELD[@]}"; do
        if _lock_read_meta "$dir" && [ "$m_pid" = "$$" ]; then
            old="$dir.rel.$$"
            if mv "$dir" "$old" 2>/dev/null; then rm -rf "$old" 2>/dev/null; fi
        fi
    done
    _LOCK_HELD=()
    return 0
}

# Build _LOCK_KEYS for the current command from the already-parsed options. Parsing
# errors are left to the command itself (it reports them): no key, no lock.
_lock_compute_keys() {
    local dir base i
    _LOCK_KEYS=()
    case "$COMMAND" in
        dump|fetch)
            [ -n "$FROM_CONNECTION" ] || return 0
            parse_connection "$FROM_CONNECTION" "FROM" >/dev/null 2>&1 || return 0
            _LOCK_KEYS+=("dump|$(_lock_norm_dir "$OUTPUT_DIR")|${DUMP_NAME:-$FROM_DATABASE}")
            ;;
        restore|clone|upgrade)
            [ "${#TO_CONNECTIONS[@]}" -gt 0 ] || return 0
            if [ "$COMMAND" != restore ] && [ "$STREAM" != true ] && [ -n "$FROM_CONNECTION" ]; then
                # A non-streaming clone/upgrade also writes a dump of the source here.
                parse_connection "$FROM_CONNECTION" "FROM" >/dev/null 2>&1 \
                    && _LOCK_KEYS+=("dump|$(_lock_norm_dir "$OUTPUT_DIR")|${DUMP_NAME:-$FROM_DATABASE}")
            fi
            for i in "${!TO_CONNECTIONS[@]}"; do
                parse_connection "${TO_CONNECTIONS[$i]}" "TO" >/dev/null 2>&1 || continue
                _LOCK_KEYS+=("db|$(_clone_endpoint_key TO)")
            done
            ;;
    esac
    return 0
}

# Take the locks the current command needs. Returns 0 to go on (locks held, or running
# unlocked on purpose / because the lock directory is unusable) and 75 when another run
# holds one of them (nothing is held then). Callers do: lock_acquire_command || exit $?
lock_acquire_command() {
    local sd locks key dir rc deadline now waited=false
    [ "$NO_LOCK" = true ] && return 0
    [ "$DRY_RUN" = true ] && return 0
    case "$COMMAND" in dump|fetch|restore|clone|upgrade) ;; *) return 0 ;; esac
    if ! [[ "$LOCK_WAIT" =~ ^(0|[1-9][0-9]*)$ ]]; then
        log_error "Invalid --lock-wait '${LOCK_WAIT}': expected a non-negative number of seconds"
        return 1
    fi
    _lock_compute_keys
    [ "${#_LOCK_KEYS[@]}" -gt 0 ] || return 0
    _LOCK_HOST="$(hostname 2>/dev/null)"

    sd="$(lock_state_dir)" || { log_warn "Run lock disabled: state directory is not usable; continuing without a lock"; return 0; }
    locks="$sd/locks"
    if [ -L "$locks" ] || { [ ! -d "$locks" ] && ! (umask 077; mkdir -p "$locks") 2>/dev/null; } || [ ! -d "$locks" ] || [ ! -w "$locks" ]; then
        log_warn "Run lock disabled: cannot use $locks; continuing without a lock"
        return 0
    fi

    deadline=$(( $(date +%s) + LOCK_WAIT ))
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        dir="$locks/$(_lock_safe_name "$key").lock"
        while :; do
            _lock_try "$dir" "$key"; rc=$?
            [ "$rc" -ne 1 ] && break
            now="$(date +%s)"
            if [ "$now" -ge "$deadline" ]; then
                lock_release
                log_warn "Skipping: another run is already working on ${key//|/ } (held by ${_LOCK_HOLDER}). Not an error; exit status 75."
                [ "$LOCK_WAIT" -eq 0 ] && log_info "Use --lock-wait <seconds> to wait for it, or --no-lock to disable the lock"
                return 75
            fi
            if [ "$waited" != true ]; then
                log_info "Waiting up to ${LOCK_WAIT}s for ${key//|/ } (held by ${_LOCK_HOLDER})"
                waited=true
            fi
            sleep 1
        done
        if [ "$rc" -eq 2 ]; then
            log_warn "Run lock disabled for ${key//|/ }: lock directory cannot be created; continuing without a lock"
        fi
    done < <(printf '%s\n' "${_LOCK_KEYS[@]}" | LC_ALL=C sort -u)
    return 0
}
