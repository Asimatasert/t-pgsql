# ==============================================================================
# HEARTBEAT PING (dead-man's switch)
# ==============================================================================
# A run of dump/clone/restore/upgrade/fetch pings an external monitor: <url>/start when it
# begins, then <url> on success or <url>/fail on failure (healthchecks.io convention).
# The monitor alerts when pings stop arriving, which covers a job that never started.
# A ping never changes the exit code and never delays a run beyond curl's own timeouts.

# Reduce a ping URL to scheme://host[:port]/*** for logs (drops user info, path and query).
ping_mask_url() {
    local u="$1" scheme rest
    scheme="${u%%://*}"
    rest="${u#*://}"
    rest="${rest%%[/?#]*}"
    rest="${rest##*@}"
    printf '%s://%s/***' "$scheme" "$rest"
}

# Only plain http(s) URLs without whitespace are accepted.
ping_url_ok() {
    [[ "$1" =~ ^https?://[^[:space:]/?#]+[^[:space:]]*$ ]]
}

# Validate every configured ping URL; prints an error (without the URL) and returns 1.
ping_validate() {
    local pair name url
    for pair in "--ping:$PING_URL" "--ping-start:$PING_START_URL" "--ping-fail:$PING_FAIL_URL"; do
        name="${pair%%:*}"
        url="${pair#*:}"
        [ -z "$url" ] && continue
        if ! ping_url_ok "$url"; then
            log_error "Invalid ${name} value: expected an http:// or https:// URL"
            return 1
        fi
    done
    return 0
}

# Build the URL for a ping kind (start|success|fail); empty when none applies.
ping_target_url() {
    local kind="$1" base query="" path
    case "$kind" in
        start) [ -n "$PING_START_URL" ] && { printf '%s' "$PING_START_URL"; return 0; } ;;
        fail)  [ -n "$PING_FAIL_URL" ]  && { printf '%s' "$PING_FAIL_URL"; return 0; } ;;
    esac
    [ -z "$PING_URL" ] && return 0
    [ "$kind" = success ] && { printf '%s' "$PING_URL"; return 0; }
    path="${PING_URL%%\?*}"
    [[ "$PING_URL" == *\?* ]] && query="?${PING_URL#*\?}"
    while [[ "$path" == */ ]]; do path="${path%/}"; done
    base="$path"
    printf '%s/%s%s' "$base" "$kind" "$query"
}

# Send one ping. The URL travels to curl through a config on stdin (never argv).
# Usage: ping_send <url> [body]. Always returns 0.
ping_send() {
    local url="$1" body="${2:-}" rc
    [ -z "$url" ] && return 0
    if ! command -v curl >/dev/null 2>&1; then
        log_warn "Heartbeat ping skipped: curl not found"
        return 0
    fi
    printf 'url = "%s"\n' "$(_curl_cfg_quote "$url")" \
        | curl --silent --show-error --fail --max-time 10 --connect-timeout 5 \
               --retry 2 --retry-max-time 20 -o /dev/null -K - -X POST -d "$body" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log_warn "Heartbeat ping failed (curl exit ${rc}): $(ping_mask_url "$url")"
    fi
    return 0
}

# Body text: one line, no secrets.
ping_body() {
    local code="$1" label
    label="${CURRENT_JOB_NAME:-${DUMP_NAME:-${FROM_DATABASE:-$TO_DATABASE}}}"
    label="${label//[^A-Za-z0-9._-]/_}"
    [ -z "$label" ] && label="-"
    printf 't-pgsql %s %s exit=%s duration=%ss' "$COMMAND" "$label" "$code" "$(( SECONDS - _PING_T0 ))"
}

# Called from main() right after validation, before the work starts. Pings only for the
# commands that do work, never on a dry run, and never when T_PGSQL_PING_DISABLE=1.
_PING_ACTIVE=false
_PING_DONE=false
_PING_T0=0
ping_begin() {
    [ "${T_PGSQL_PING_DISABLE:-}" = 1 ] && return 0
    [ "$DRY_RUN" = true ] && return 0
    case "$COMMAND" in
        dump|restore|clone|upgrade|fetch) ;;
        *) return 0 ;;
    esac
    [ -z "$PING_URL$PING_START_URL$PING_FAIL_URL" ] && return 0
    _PING_ACTIVE=true
    _PING_T0=$SECONDS
    # The final ping is sent by the single exit hook (_run_exit_trap, 15-security.sh), so
    # every exit path (including INT/TERM, which exit through it) ends with one ping.
    ping_send "$(ping_target_url start)" ""
}

# Send the final ping once. Usage: ping_finish <exit code>
ping_finish() {
    [ "$_PING_ACTIVE" = true ] && [ "$_PING_DONE" != true ] || return 0
    _PING_DONE=true
    if [ "$1" -eq 0 ]; then
        ping_send "$(ping_target_url success)" "$(ping_body "$1")"
    else
        ping_send "$(ping_target_url fail)" "$(ping_body "$1")"
    fi
}

