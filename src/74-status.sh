# ==============================================================================
# RUN HISTORY + STATUS COMMAND
# ==============================================================================
# Every dump/clone/restore/upgrade/fetch run appends ONE line to
# <state dir>/history.tsv (tab separated):
#   epoch  iso8601-UTC  command  name  status  exit_code  duration_s  size_bytes  message
# "t-pgsql status" reads it back (read-only). Writing the history never fails or
# changes the exit status of a run: every error is swallowed.

# --- state of the history writer / status command (own block, no other module reads it)
HIST_ACTIVE=false          # true once history_begin armed the exit hook for this run
HIST_START_EPOCH=""
HIST_LAST_ERROR=""         # last log_error text (set by log_error)
HIST_SKIPPED=""            # reason text when --skip-if-recent skipped the run
HIST_ARTIFACT=""           # quarantined (.suspect) dump of this run
HISTORY_MAX_LINES=2000     # trim when the file exceeds this many lines ...
HISTORY_KEEP_LINES=1000    # ... down to the newest this many
STATUS_YAML_SET=false
STATUS_NAME=""
STATUS_JSON=false
STATUS_MAX_AGE=""
STATUS_LIMIT=""

# Per-name summary tables (global associative arrays, filled by status_load_summary)
STATUS_SUMMARY=""          # newest run per name, one US-separated record per line (status_summary_lines)
STATUS_ROWS=()
C_KEPT=0; C_SUS=0; C_INV=0
J_BASE=""; J_DIR=""

# ------------------------------------------------------------------------------
# State directory
# ------------------------------------------------------------------------------
# Directory for writing (created 0700). T_PGSQL_STATE_DIR overrides the default
# per-user directory (same safety rules as bot_state_dir: no symlink, own uid).
history_state_dir_write() {
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
    printf '%s' "$d"
}

# Directory for reading: never created. Prints nothing and fails when absent/unsafe.
history_state_dir_read() {
    local d="${T_PGSQL_STATE_DIR:-}" base
    if [ -z "$d" ]; then
        base="${XDG_STATE_HOME:-}"
        [ -z "$base" ] && [ -n "$HOME" ] && base="$HOME/.local/state"
        [ -z "$base" ] && return 1
        d="$base/t-pgsql"
    fi
    [ -d "$d" ] && [ ! -L "$d" ] && [ "$(bot_file_owner "$d")" = "$(id -u)" ] || return 1
    printf '%s' "$d"
}

# ------------------------------------------------------------------------------
# Writer
# ------------------------------------------------------------------------------
# Arm the exit hook for work commands. Dry runs and every other command write nothing.
history_begin() {
    case "$COMMAND" in
        dump|clone|restore|upgrade|fetch) ;;
        *) return 0 ;;
    esac
    [ "$DRY_RUN" = true ] && return 0
    HIST_ACTIVE=true
    HIST_START_EPOCH=$(date +%s)
    # The line itself is written by the single exit hook (_run_exit_trap, 15-security.sh).
}

history_on_exit() {
    local rc="${1:-0}"
    [ "$HIST_ACTIVE" = true ] || return 0
    HIST_ACTIVE=false
    { history_write "$rc"; } 2>/dev/null || true
    return 0
}

# Single-line, secret-free, length-limited text. Usage: history_clean TEXT MAX
history_clean() {
    local s="$1" max="${2:-200}"
    s=$(strip_ansi "$s")
    s=$(redact_cmd "$s")
    s=$(redact_args "$s")
    s=$(printf '%s' "$s" | sed -E 's#(://[^/:@[:space:]]*):[^@[:space:]]*@#\1:***@#g')
    s="${s//[[:cntrl:]]/ }"
    printf '%s' "${s:0:$max}"
}

history_write() {
    local rc="$1" now dur status msg="" size="" name file="" dir f line
    [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
    now=$(date +%s)
    dur=$(( now - HIST_START_EPOCH ))
    [ "$dur" -lt 0 ] && dur=0

    if [ "$rc" -eq 0 ]; then
        if [ -n "$HIST_SKIPPED" ]; then
            status="skipped"; msg="$HIST_SKIPPED"
        else
            status="ok"
        fi
    elif [ -n "$SHRINK_DETAIL" ]; then
        status="suspect"; msg="Shrink guard: $SHRINK_DETAIL"
    else
        status="failed"; msg="$HIST_LAST_ERROR"
        if [ -z "$msg" ]; then
            case "$rc" in
                130) msg="interrupted (SIGINT)" ;;
                143) msg="terminated (SIGTERM)" ;;
                *)   msg="exit code $rc" ;;
            esac
        fi
    fi

    # Run name: job name, else the dump base name, else the target database.
    if [ -n "$CURRENT_JOB_NAME" ]; then
        name="$CURRENT_JOB_NAME"
    else
        case "$COMMAND" in
            dump|fetch) name="${DUMP_NAME:-$FROM_DATABASE}" ;;
            *)          name="${TO_DATABASE:-$FROM_DATABASE}" ;;
        esac
        if [ -z "$name" ] && [ -n "$FILE" ]; then
            name="${FILE##*/}"
            name=$(printf '%s' "$name" | sed -E 's/_[0-9]{8}_[0-9]{6}(_[0-9]+)?\.(tar\.gz|dump(\.zst|\.xz|\.bz2)?)$//')
        fi
    fi
    [ -z "$name" ] && name="(unnamed)"

    # Size of the final artifact, when there is one.
    if [ "$status" = "ok" ]; then
        file="$META_ARTIFACT"
        if [ -z "$file" ] && [ "$COMMAND" = "dump" ]; then
            file=$(list_dumps_for_base "$OUTPUT_DIR" "${DUMP_NAME:-$FROM_DATABASE}" | head -1)
        fi
    elif [ "$status" = "suspect" ]; then
        file="$HIST_ARTIFACT"
    fi
    if [ -n "$file" ] && [ -f "$file" ]; then
        size=$(file_size_bytes "$file") || size=""
    fi

    name=$(history_clean "$name" 200)
    msg=$(history_clean "$msg" 200)
    line=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$now" "$(date -u -r "$now" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$now" '+%Y-%m-%dT%H:%M:%SZ')" \
        "$COMMAND" "$name" "$status" "$rc" "$dur" "$size" "$msg")

    dir=$(history_state_dir_write) || return 0
    f="$dir/history.tsv"
    [ -L "$f" ] && return 0
    if [ -e "$f" ] && ! bot_safe_file "$f"; then return 0; fi

    # mkdir-based lock, short wait, fail-open: without the lock the line is still
    # appended (a single short write) and only the trimming is skipped.
    local lock="$dir/history.lock" got=false tries=0
    while [ "$tries" -lt 20 ]; do
        if mkdir "$lock" 2>/dev/null; then got=true; break; fi
        if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
            rmdir "$lock" 2>/dev/null
        fi
        tries=$((tries + 1))
        sleep 0.1 2>/dev/null || sleep 1
    done

    ( umask 077; printf '%s\n' "$line" >> "$f" ) 2>/dev/null

    if [ "$got" = true ]; then
        local n tmp
        n=$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]')
        if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$HISTORY_MAX_LINES" ]; then
            tmp=$(umask 077; mktemp "$dir/history.tsv.XXXXXX" 2>/dev/null) || tmp=""
            if [ -n "$tmp" ]; then
                if tail -n "$HISTORY_KEEP_LINES" "$f" > "$tmp" 2>/dev/null; then
                    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
                else
                    rm -f "$tmp"
                fi
            fi
        fi
        rmdir "$lock" 2>/dev/null
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Reader helpers
# ------------------------------------------------------------------------------
# Path of the readable history file (nothing printed when there is none).
status_history_file() {
    local d f
    d=$(history_state_dir_read) || return 0
    f="$d/history.tsv"
    [ -f "$f" ] && [ ! -L "$f" ] && printf '%s' "$f"
    return 0
}

# Valid history lines only (corrupt/short lines are skipped), normalized to US-separated
# fields: epoch US iso US command US name US status US rc US duration US size US message.
status_valid_lines() {
    awk 'BEGIN { FS = "\t"; OFS = "\037" }
    NF >= 8 && $1 ~ /^[0-9]+$/ && $4 != "" && $3 != "" &&
    ($5 == "ok" || $5 == "failed" || $5 == "skipped" || $5 == "suspect") &&
    $6 ~ /^[0-9]+$/ && ($7 == "" || $7 ~ /^[0-9]+$/) && ($8 == "" || $8 ~ /^[0-9]+$/) {
        print $1, $2, $3, $4, $5, $6, $7, $8, $9
    }' "$1"
}

# Newest run per name plus the newest success per name.
# Output: name US epoch US command US status US rc US duration US size US message US okEpoch US goodEpoch
status_summary_lines() {
    status_valid_lines "$1" | awk 'BEGIN { FS = "\037"; OFS = "\037" }
    {
        n = $4; e = $1 + 0
        if (!(n in seen) || e >= le[n]) {
            seen[n] = 1; le[n] = e
            c[n] = $3; s[n] = $5; r[n] = $6; d[n] = $7; z[n] = $8; m[n] = $9
        }
        if ($5 == "ok" && (!(n in oe) || e > oe[n])) oe[n] = e
        if (($5 == "ok" || $5 == "skipped") && (!(n in ge) || e > ge[n])) ge[n] = e
    }
    END {
        for (n in seen)
            print n, sprintf("%.0f", le[n]), c[n], s[n], r[n], d[n], z[n], m[n], \
                  (n in oe) ? sprintf("%.0f", oe[n]) : "", (n in ge) ? sprintf("%.0f", ge[n]) : ""
    }'
}

status_load_summary() {
    STATUS_SUMMARY=""
    [ -n "$1" ] || return 0
    STATUS_SUMMARY=$(status_summary_lines "$1")
}

# Record of one name from STATUS_SUMMARY (empty when the name never ran).
status_lookup() {
    [ -n "$STATUS_SUMMARY" ] || return 0
    printf '%s\n' "$STATUS_SUMMARY" | LOOKUP_NAME="$1" awk -F $'\037' '$1 == ENVIRON["LOOKUP_NAME"] { print; exit }'
}

# "3h ago" style age. Usage: status_age SECONDS
status_age() {
    local s="$1"
    [ "$s" -lt 0 ] && s=0
    if [ "$s" -lt 60 ]; then printf '%ss ago' "$s"
    elif [ "$s" -lt 3600 ]; then printf '%sm ago' $((s / 60))
    elif [ "$s" -lt 86400 ]; then printf '%sh ago' $((s / 3600))
    else printf '%sd ago' $((s / 86400))
    fi
}

# Distinct base names of dump files found in the output directory (one per line).
status_dir_bases() {
    [ -d "$OUTPUT_DIR" ] || return 0
    local re='^(.+)_[0-9]{8}_[0-9]{6}(_[0-9]+)?\.(tar\.gz|dump(\.zst|\.xz|\.bz2)?)(\.suspect|\.invalid)?$'
    local f b
    for f in "$OUTPUT_DIR"/*; do
        [ -e "$f" ] || continue
        b="${f##*/}"
        if [[ "$b" =~ $re ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
        fi
    done | LC_ALL=C sort -u
}

# Sets C_KEPT (dumps of exactly this base), C_SUS and C_INV (quarantined files).
# Usage: status_counts BASE DIR
status_counts() {
    local base="$1" dir="$2" f rest
    local re='^[0-9]{8}_[0-9]{6}(_[0-9]+)?\.(tar\.gz|dump(\.zst|\.xz|\.bz2)?)\.(suspect|invalid)$'
    local -a kept=()
    C_KEPT=0; C_SUS=0; C_INV=0
    [ -d "$dir" ] || return 0
    mapfile -t kept < <(list_dumps_for_base "$dir" "$base")
    C_KEPT=${#kept[@]}
    for f in "$dir/$base"_*.suspect "$dir/$base"_*.invalid; do
        [ -e "$f" ] || continue
        rest="${f##*/}"
        rest="${rest#"$base"_}"
        [[ "$rest" =~ $re ]] || continue
        case "$f" in
            *.suspect) C_SUS=$((C_SUS + 1)) ;;
            *)         C_INV=$((C_INV + 1)) ;;
        esac
    done
}

# Dump base name and output directory of a job (same rules as the bot cooldown check).
status_job_base() {
    local job="$1" b prof d
    b=$(get_job_value "$job" "dump_name" 2>/dev/null) || true
    if [ -z "$b" ]; then
        prof=$(get_job_field "$job" "from" "profile" 2>/dev/null) || true
        b=$(get_job_field "$job" "from" "database" 2>/dev/null) || true
        if [ -z "$b" ] && [ -n "$prof" ]; then
            b=$(get_profile_value "$prof" "database" 2>/dev/null) || true
        fi
    fi
    [ -z "$b" ] && b="$job"
    d=$(get_job_value "$job" "output" 2>/dev/null) || true
    [ -z "$d" ] && d="$OUTPUT_DIR"
    d="${d/#\~/$HOME}"
    J_BASE="$b"; J_DIR="$d"
}

# Job names under "jobs:" in the YAML file.
status_job_names() {
    awk '/^jobs:/{found=1;next} found && /^  [a-zA-Z0-9_-]+:/{name=$1; gsub(/:$/,"",name); print name} found && /^[a-zA-Z]/ && !/^  /{exit}' "$1"
}

# Build one summary row (US separated) into STATUS_ROWS.
# Fields: name last_run age result command exit duration size kept suspect invalid
#         last_success last_success_age message stale
# Usage: status_add_row NAME BASE DIR NOTE_IF_NEVER
status_add_row() {
    local name="$1" base="$2" dir="$3" never_note="$4" now="$5"
    local US=$'\037' rec n e c r rc d z m ok good age="" okage="" stale=false
    rec=$(status_lookup "$name")
    e=""
    if [ -n "$rec" ]; then
        IFS="$US" read -r n e c r rc d z m ok good <<< "$rec"
    fi
    if [ -n "$e" ]; then
        age=$(( now - e )); [ "$age" -lt 0 ] && age=0
        [ -n "$ok" ] && { okage=$(( now - ok )); [ "$okage" -lt 0 ] && okage=0; }
    else
        c=""; r="never"; rc=""; d=""; z=""; m="$never_note"; ok=""; good=""
    fi
    status_counts "$base" "$dir"
    if [ -n "$STATUS_MAX_AGE_S" ]; then
        if [ -z "$good" ] || [ $(( now - good )) -gt "$STATUS_MAX_AGE_S" ]; then
            stale=true
        fi
    fi
    name="${name//[[:cntrl:]]/ }"
    m="${m//[[:cntrl:]]/ }"
    STATUS_ROWS+=("${name}${US}${e}${US}${age}${US}${r}${US}${c}${US}${rc}${US}${d}${US}${z}${US}${C_KEPT}${US}${C_SUS}${US}${C_INV}${US}${ok}${US}${okage}${US}${m}${US}${stale}")
}

# JSON array from US-separated rows on stdin. Usage: status_json KEYS TYPES  (s string,
# n number-or-null, b boolean); strings are escaped (quote, backslash, control chars).
status_json() {
    awk -F $'\037' -v keys="$1" -v types="$2" '
    BEGIN {
        nk = split(keys, K, ","); split(types, T, ",")
        for (i = 1; i < 32; i++) esc[sprintf("%c", i)] = sprintf("\\u%04x", i)
        esc["\b"] = "\\b"; esc["\f"] = "\\f"; esc["\n"] = "\\n"; esc["\r"] = "\\r"; esc["\t"] = "\\t"
        first = 1
        printf "["
    }
    function jstr(s,   out, i, ch, n) {
        out = ""; n = length(s)
        for (i = 1; i <= n; i++) {
            ch = substr(s, i, 1)
            if (ch == "\"") out = out "\\\""
            else if (ch == "\\") out = out "\\\\"
            else if (ch in esc) out = out esc[ch]
            else out = out ch
        }
        return "\"" out "\""
    }
    {
        if (!first) printf ","
        first = 0
        printf "\n  {"
        for (i = 1; i <= nk; i++) {
            v = $i
            if (T[i] == "s") o = jstr(v)
            else if (T[i] == "n") o = (v ~ /^[0-9]+$/) ? v : "null"
            else o = (v == "true") ? "true" : "false"
            printf "%s\"%s\": %s", (i > 1 ? ", " : ""), K[i], o
        }
        printf "}"
    }
    END { if (!first) printf "\n"; print "]" }'
}

# Pad TEXT to WIDTH (display text only; colour is applied by the caller).
status_pad() { printf '%-*s' "$2" "$1"; }

status_color_for() {
    case "$1" in
        ok)      printf '%s' "$GREEN" ;;
        failed)  printf '%s' "$RED" ;;
        suspect) printf '%s' "$YELLOW" ;;
        skipped) printf '%s' "$CYAN" ;;
        *)       printf '%s' "$YELLOW" ;;
    esac
}

status_print_table() {
    local US=$'\037' row i
    local -a H=("NAME" "LAST RUN" "RESULT" "DURATION" "SIZE" "DUMPS KEPT" "NOTE")
    local -a W=(4 8 6 8 4 10 4)
    local -a T0=() T1=() T2=() T3=() T4=() T5=() T6=()
    local name e age r c rc d z kept sus inv ok okage m stale note t
    for row in "${STATUS_ROWS[@]}"; do
        IFS="$US" read -r name e age r c rc d z kept sus inv ok okage m stale <<< "$row"
        if [ -n "$e" ]; then t=$(status_age "$age"); else t="-"; fi
        note=""
        case "$r" in
            failed|suspect)
                if [ -n "$okage" ]; then note="last ok $(status_age "$okage")"; else note="no success on record"; fi
                [ -n "$m" ] && note="$note; $m"
                ;;
            skipped) [ -n "$m" ] && note="$m" ;;
            never)   [ -n "$m" ] && note="$m" ;;
        esac
        if [ "$sus" -gt 0 ]; then note="${note:+$note; }${sus} .suspect file(s)"; fi
        if [ "$inv" -gt 0 ]; then note="${note:+$note; }${inv} .invalid file(s)"; fi
        if [ "$stale" = true ]; then note="${note:+$note; }STALE (no success within ${STATUS_MAX_AGE})"; fi
        T0+=("$name"); T1+=("$t"); T2+=("$r")
        if [ -n "$d" ]; then T3+=("$(format_elapsed "$d")"); else T3+=("-"); fi
        if [ -n "$z" ]; then T4+=("$(human_bytes "$z")"); else T4+=("-"); fi
        T5+=("$kept"); T6+=("$note")
    done
    for i in "${!T0[@]}"; do
        [ "${#T0[i]}" -gt "${W[0]}" ] && W[0]=${#T0[i]}
        [ "${#T1[i]}" -gt "${W[1]}" ] && W[1]=${#T1[i]}
        [ "${#T2[i]}" -gt "${W[2]}" ] && W[2]=${#T2[i]}
        [ "${#T3[i]}" -gt "${W[3]}" ] && W[3]=${#T3[i]}
        [ "${#T4[i]}" -gt "${W[4]}" ] && W[4]=${#T4[i]}
    done
    printf '%s  %s  %s  %s  %s  %s  %s\n' \
        "$(status_pad "${H[0]}" "${W[0]}")" "$(status_pad "${H[1]}" "${W[1]}")" "$(status_pad "${H[2]}" "${W[2]}")" \
        "$(status_pad "${H[3]}" "${W[3]}")" "$(status_pad "${H[4]}" "${W[4]}")" "${H[5]}" "${H[6]}"
    for i in "${!T0[@]}"; do
        printf '%s  %s  %b%s%b  %s  %s  %s  %s\n' \
            "$(status_pad "${T0[i]}" "${W[0]}")" "$(status_pad "${T1[i]}" "${W[1]}")" \
            "$(status_color_for "${T2[i]}")" "$(status_pad "${T2[i]}" "${W[2]}")" "$NC" \
            "$(status_pad "${T3[i]}" "${W[3]}")" "$(status_pad "${T4[i]}" "${W[4]}")" \
            "$(status_pad "${T5[i]}" 10)" "${T6[i]}"
    done
}

# --limit N: the last N runs of one name, newest first.
status_history_view() {
    local file="$1" now="$2" US=$'\037' line i
    local -a lines=() rows=()
    if [ -n "$file" ]; then
        mapfile -t lines < <(status_valid_lines "$file" | \
            NAME_FILTER="$STATUS_NAME" awk 'BEGIN { FS = "\037" } $4 == ENVIRON["NAME_FILTER"]' | tail -n "$STATUS_LIMIT")
    fi
    for (( i = ${#lines[@]} - 1; i >= 0; i-- )); do
        rows+=("${lines[i]}")
    done
    if [ "$STATUS_JSON" = true ]; then
        if [ "${#rows[@]}" -eq 0 ]; then echo "[]"; return 0; fi
        printf '%s\n' "${rows[@]}" | status_json "epoch,time,command,name,result,exit_code,duration_s,size_bytes,message" "n,s,s,s,s,n,n,n,s"
        return 0
    fi
    if [ "${#rows[@]}" -eq 0 ]; then
        echo "No runs recorded for: ${STATUS_NAME//[[:cntrl:]]/ }"
        return 0
    fi
    local e iso c n s rc d z m
    printf '%-20s  %-8s  %-8s  %-4s  %-9s  %-9s  %s\n' "WHEN (UTC)" "COMMAND" "RESULT" "EXIT" "DURATION" "SIZE" "MESSAGE"
    for line in "${rows[@]}"; do
        IFS="$US" read -r e iso c n s rc d z m <<< "$line"
        local dd="-" zz="-"
        [ -n "$d" ] && dd=$(format_elapsed "$d")
        [ -n "$z" ] && zz=$(human_bytes "$z")
        printf '%-20s  %-8s  %b%-8s%b  %-4s  %-9s  %-9s  %s\n' \
            "${iso//[[:cntrl:]]/ }" "${c//[[:cntrl:]]/ }" "$(status_color_for "$s")" "$s" "$NC" "$rc" "$dd" "$zz" "${m//[[:cntrl:]]/ }"
    done
}

# ------------------------------------------------------------------------------
# status command
# Exit status: 0 report printed (and, with --max-age, every name is fresh);
#              2 usage error; 3 --max-age given and some name has no fresh success.
# ------------------------------------------------------------------------------
STATUS_MAX_AGE_S=""
cmd_status() {
    local num unit
    STATUS_MAX_AGE_S=""
    if [ -n "$STATUS_MAX_AGE" ]; then
        if ! [[ "$STATUS_MAX_AGE" =~ ^[0-9]{1,9}[smhd]$ ]]; then
            log_error "Invalid --max-age '$STATUS_MAX_AGE' (use a number with a unit: 90s, 30m, 26h, 2d)"
            return 2
        fi
        num="${STATUS_MAX_AGE%[smhd]}"; unit="${STATUS_MAX_AGE: -1}"
        num=$((10#$num))
        case "$unit" in
            s) STATUS_MAX_AGE_S=$num ;;
            m) STATUS_MAX_AGE_S=$((num * 60)) ;;
            h) STATUS_MAX_AGE_S=$((num * 3600)) ;;
            d) STATUS_MAX_AGE_S=$((num * 86400)) ;;
        esac
    fi
    if [ -n "$STATUS_LIMIT" ]; then
        if ! [[ "$STATUS_LIMIT" =~ ^[1-9][0-9]{0,5}$ ]]; then
            log_error "Invalid --limit '$STATUS_LIMIT' (expected a positive integer)"
            return 2
        fi
        if [ -z "$STATUS_NAME" ]; then
            log_error "--limit needs --name NAME (it shows the last runs of one name)"
            return 2
        fi
        if [ -n "$STATUS_MAX_AGE" ]; then
            log_error "--max-age cannot be combined with --limit"
            return 2
        fi
    fi
    if [ "$STATUS_YAML_SET" = true ] && [ ! -f "$JOBS_FILE" ]; then
        log_error "Jobs file not found: $JOBS_FILE"
        return 2
    fi

    local now file
    now=$(date +%s)
    file=$(status_history_file)

    if [ -n "$STATUS_LIMIT" ]; then
        status_history_view "$file" "$now"
        return 0
    fi

    status_load_summary "$file"
    STATUS_ROWS=()
    local n job
    if [ "$STATUS_YAML_SET" = true ]; then
        while IFS= read -r job; do
            [ -n "$job" ] || continue
            [ -n "$STATUS_NAME" ] && [ "$job" != "$STATUS_NAME" ] && continue
            status_job_base "$job"
            status_add_row "$job" "$J_BASE" "$J_DIR" "" "$now"
        done < <(status_job_names "$JOBS_FILE")
    else
        local -a sorted=()
        mapfile -t sorted < <({
            [ -n "$STATUS_SUMMARY" ] && printf '%s\n' "$STATUS_SUMMARY" | awk -F $'\037' '{ print $1 }'
            status_dir_bases
            [ -n "$STATUS_NAME" ] && printf '%s\n' "$STATUS_NAME"
        } | LC_ALL=C sort -u)
        for n in "${sorted[@]}"; do
            [ -n "$n" ] || continue
            [ -n "$STATUS_NAME" ] && [ "$n" != "$STATUS_NAME" ] && continue
            status_add_row "$n" "$n" "$OUTPUT_DIR" "no recorded run" "$now"
        done
    fi

    local stale_count=0 row
    for row in "${STATUS_ROWS[@]}"; do
        [ "${row##*$'\037'}" = true ] && stale_count=$((stale_count + 1))
    done
    # --max-age with nothing to check must not pass silently in a monitoring check.
    if [ -n "$STATUS_MAX_AGE_S" ] && [ "${#STATUS_ROWS[@]}" -eq 0 ]; then
        stale_count=1
    fi

    if [ "$STATUS_JSON" = true ]; then
        if [ "${#STATUS_ROWS[@]}" -eq 0 ]; then
            echo "[]"
        else
            printf '%s\n' "${STATUS_ROWS[@]}" | status_json \
                "name,last_run,age_s,result,command,exit_code,duration_s,size_bytes,dumps_kept,suspect_files,invalid_files,last_success,last_success_age_s,message,stale" \
                "s,n,n,s,s,n,n,n,n,n,n,n,n,s,b"
        fi
    elif [ "${#STATUS_ROWS[@]}" -eq 0 ]; then
        echo "No runs recorded yet."
    else
        status_print_table
    fi

    [ "$stale_count" -gt 0 ] && return 3
    return 0
}
