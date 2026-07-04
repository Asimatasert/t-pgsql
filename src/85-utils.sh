# ==============================================================================
# UTILITIES
# ==============================================================================

# Copy a file over SSH with optional bandwidth limit (--bwlimit), retries
# (--retries) and stalled-link detection (SSH_OPTS). Usage: scp_transfer PORT SRC DST
scp_transfer() {
    local port="$1" src="$2" dst="$3"
    local args=(-P "$port" "${SSH_OPTS[@]}")
    [ -n "$BWLIMIT_KBIT" ] && args+=(-l "$BWLIMIT_KBIT")

    local attempt=1 max=$(( RETRIES + 1 ))
    while :; do
        if scp "${args[@]}" "$src" "$dst"; then
            return 0
        fi
        if [ "$attempt" -ge "$max" ]; then
            log_error "scp failed after ${attempt} attempt(s)"
            return 1
        fi
        log_warn "scp attempt ${attempt}/${max} failed; retrying in $(( attempt * 3 ))s..."
        sleep $(( attempt * 3 ))
        attempt=$(( attempt + 1 ))
    done
}

compress_file() {
    local file="$1" lvl="$COMPRESS_LEVEL"
    log_info "Compressing ($COMPRESS)..."

    # Clamp the level to each tool's valid range so a multi-digit value is not silently
    # split into repeated single-digit flags (e.g. bzip2 -22 is parsed as -2 -2 = level 2).
    [ "$lvl" -lt 1 ] && lvl=1
    case "$COMPRESS" in
        zstd)  [ "$lvl" -gt 19 ] && lvl=19; zstd -"$lvl" --rm "$file" ;;
        xz)    [ "$lvl" -gt 9 ] && lvl=9; xz -"$lvl" "$file" ;;
        bzip2) [ "$lvl" -gt 9 ] && lvl=9; bzip2 -"$lvl" "$file" ;;
    esac

    local rc=$?
    [ $rc -eq 0 ] && log_success "Compressed" || log_error "Compression failed"
    return $rc
}

cleanup_old_dumps() {
    [ -z "$FROM_DATABASE" ] && return 0

    # Use GFS retention if enabled
    if [ "$RETENTION" = true ]; then
        cleanup_gfs
        return 0
    fi

    # Simple keep-N retention
    [ "$KEEP" -le 0 ] && return 0

    local dump_base_name="${DUMP_NAME:-$FROM_DATABASE}"
    # Count all dump formats (tar.gz, compressed dumps, plain dumps) belonging
    # to exactly this base name (a prefix-overlapping db is not counted).
    local count=$(list_dumps_for_base "$OUTPUT_DIR" "$dump_base_name" | wc -l | tr -d ' ')

    if [ "$count" -gt "$KEEP" ]; then
        local del=$((count - KEEP))
        log_info "Deleting $del old dump(s)..."

        # list_dumps_for_base is newest-first; tail -n takes the oldest to delete.
        list_dumps_for_base "$OUTPUT_DIR" "$dump_base_name" | tail -n "$del" | \
            while read f; do
                rm -f "$f"
                log_debug "Deleted: $f"
            done
    fi
}

# GFS (Grandfather-Father-Son) Retention Policy
cleanup_gfs() {
    log_info "Applying GFS retention policy..."
    log_debug "Daily: $RETENTION_DAILY, Weekly: $RETENTION_WEEKLY, Monthly: $RETENTION_MONTHLY, Yearly: $RETENTION_YEARLY"

    local dump_base_name="${DUMP_NAME:-$FROM_DATABASE}"
    local keep_files=""
    # List all dump formats for exactly this base name, newest first
    # (a prefix-overlapping db is excluded by the anchored match).
    local all_files=$(list_dumps_for_base "$OUTPUT_DIR" "$dump_base_name")

    [ -z "$all_files" ] && return 0

    # FLOOR: unconditionally keep the single newest dump, regardless of the configured
    # retention counts (even if all four are 0) — GFS must never delete the just-created
    # backup and leave the base with nothing.
    local _newest; _newest=$(printf '%s\n' "$all_files" | head -1)
    [ -n "$_newest" ] && keep_files="$keep_files
$_newest"

    local now_date=$(date +%Y%m%d)
    # GFS = keep the NEWEST backup of each recent day/week/month/year, up to N of each.
    # Process files in DATE order from the FILENAME (newest first), independent of mtime,
    # so the first file of a period bucket really is that bucket's newest. Counts DAYS
    # (not files-per-day), works for any weekday (not only Sunday/month-end), and keeps
    # future-dated, calendar-invalid, or unnameable files as a safety net.
    local sorted
    sorted=$(while read -r f; do
        [ -z "$f" ] && continue
        local b=$(basename "$f")
        if [[ "$b" =~ _([0-9]{8})_([0-9]{6})(_[0-9]+)?\. ]]; then
            printf '%s%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$f"
        else
            printf 'ZZZZZZZZZZZZZZ\t%s\n' "$f"   # unnameable -> sorts last, always kept
        fi
    done <<< "$all_files" | sort -rk1,1)

    local seen_day=" " seen_week=" " seen_month=" " seen_year=" "
    local daily_kept=0 weekly_kept=0 monthly_kept=0 yearly_kept=0

    while IFS=$'\t' read -r stamp file; do
        [ -z "$file" ] && continue
        local file_date="${stamp:0:8}"
        # Unnameable: keep (safety).
        if [ "$stamp" = "ZZZZZZZZZZZZZZ" ]; then keep_files="$keep_files
$file"; continue; fi

        # Round-trip the date: BSD 'date' rolls an invalid day (20260231 -> 20260303),
        # so a value that doesn't reformat back to itself is calendar-invalid -> keep,
        # don't count. Future-dated files are also kept without consuming quota.
        local rt=$(date -j -f "%Y%m%d" "$file_date" "+%Y%m%d" 2>/dev/null || date -d "$file_date" "+%Y%m%d" 2>/dev/null)
        if [ "$rt" != "$file_date" ] || [ "$file_date" -gt "$now_date" ]; then
            keep_files="$keep_files
$file"; continue
        fi

        local wk=$(date -j -f "%Y%m%d" "$file_date" "+%G-%V" 2>/dev/null || date -d "$file_date" "+%G-%V" 2>/dev/null)
        local mo="${file_date:0:6}" yr="${file_date:0:4}"
        local keep=false reason=""

        if [ "$daily_kept" -lt "$RETENTION_DAILY" ] && [[ "$seen_day" != *" $file_date "* ]]; then
            seen_day="$seen_day$file_date "; daily_kept=$((daily_kept+1)); keep=true; reason="daily"
        fi
        if [ "$weekly_kept" -lt "$RETENTION_WEEKLY" ] && [ -n "$wk" ] && [[ "$seen_week" != *" $wk "* ]]; then
            seen_week="$seen_week$wk "; weekly_kept=$((weekly_kept+1)); keep=true; reason="${reason:+$reason,}weekly"
        fi
        if [ "$monthly_kept" -lt "$RETENTION_MONTHLY" ] && [[ "$seen_month" != *" $mo "* ]]; then
            seen_month="$seen_month$mo "; monthly_kept=$((monthly_kept+1)); keep=true; reason="${reason:+$reason,}monthly"
        fi
        if [ "$yearly_kept" -lt "$RETENTION_YEARLY" ] && [[ "$seen_year" != *" $yr "* ]]; then
            seen_year="$seen_year$yr "; yearly_kept=$((yearly_kept+1)); keep=true; reason="${reason:+$reason,}yearly"
        fi

        if [ "$keep" = true ]; then
            keep_files="$keep_files
$file"
            log_debug "Keep ($reason): $(basename "$file")"
        fi
    done <<< "$sorted"

    # Delete files not in keep list
    local deleted=0
    while read -r file; do
        [ -z "$file" ] && continue
        if ! printf '%s\n' "$keep_files" | grep -Fxq "$file"; then
            rm -f "$file"
            log_debug "Deleted: $(basename "$file")"
            deleted=$((deleted + 1))
        fi
    done <<< "$all_files"

    [ $deleted -gt 0 ] && log_info "GFS cleanup: deleted $deleted file(s)"
    log_debug "Kept: daily=$daily_kept, weekly=$weekly_kept, monthly=$monthly_kept, yearly=$yearly_kept"
}

