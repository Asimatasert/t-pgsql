# ==============================================================================
# METADATA
# ==============================================================================
meta_start() {
    META_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    META_START_EPOCH=$(date +%s)
    META_STATUS="running"
}

meta_write() {
    local dump_file="$1"
    local status="${2:-success}"
    local exit_code="${3:-0}"

    # META_ARTIFACT reports the file that actually exists after this call so the
    # caller can print an accurate DUMP_FILE=... line. Reset it every call.
    META_ARTIFACT=""

    [ "$META_ENABLED" != true ] && return 0
    [ -z "$dump_file" ] && return 0
    [ ! -f "$dump_file" ] && return 0

    local dump_dir=$(dirname "$dump_file")
    local dump_name=$(basename "$dump_file")
    local base_name="${dump_name%.dump}"
    # Build metadata in a UNIQUE temp dir (not a shared dump_dir/metadata.yaml) so
    # concurrent dumps in the same directory don't race on / corrupt each other's
    # metadata. It is added to the tar as "metadata.yaml" via a second -C below.
    local meta_dir; meta_dir=$(mktemp -d); reg_tmp "$meta_dir"
    local meta_file="${meta_dir}/metadata.yaml"
    local tar_file="${dump_dir}/${base_name}.tar.gz"

    local end_time=$(date '+%Y-%m-%d %H:%M:%S')
    local end_epoch=$(date +%s)
    local elapsed_sec=$((end_epoch - META_START_EPOCH))
    local elapsed=$(format_elapsed $elapsed_sec)
    local dump_size=$(ls -lh "$dump_file" 2>/dev/null | awk '{print $5}')

    # Create metadata.yaml
    cat > "$meta_file" << EOF
# t-pgsql metadata
# Generated: ${end_time}

timing:
  started_at: "${META_START_TIME}"
  finished_at: "${end_time}"
  elapsed: "${elapsed}"
  elapsed_seconds: ${elapsed_sec}

source:
  type: "${FROM_TYPE}"
  host: "${FROM_SSH_HOST:-${FROM_DB_HOST}}"
  port: "${FROM_DB_PORT}"
  database: "${FROM_DATABASE//\"/}"
  user: "${FROM_DB_USER//\"/}"

file:
  name: "${dump_name//\"/}"
  size: "${dump_size:-unknown}"
  compression: ${COMPRESS}
  compress_level: ${PG_COMPRESS_LEVEL}

operation:
  command: ${COMMAND}
  status: ${status}
  exit_code: ${exit_code}

environment:
  script_version: "${VERSION}"
  executed_by: $(whoami)
  executed_on: $(hostname)
  working_dir: $(pwd)
EOF

    # Filter bilgisi varsa ekle
    if [ -n "$EXCLUDE_TABLES" ] || [ -n "$EXCLUDE_SCHEMAS" ]; then
        cat >> "$meta_file" << EOF

filter:
  exclude_tables: "${EXCLUDE_TABLES}"
  exclude_schemas: "${EXCLUDE_SCHEMAS}"
  exclude_data: "${EXCLUDE_DATA}"
  only_tables: "${ONLY_TABLES}"
  only_schemas: "${ONLY_SCHEMAS}"
EOF
    fi

    if [[ "$dump_name" == *.dump ]]; then
        # Plain pg_dump archive: wrap dump + metadata into a single tar.gz.
        log_debug "Creating archive: $tar_file"
        local meta_opt=()
        [ -f "$meta_file" ] && meta_opt=(-C "$meta_dir" "metadata.yaml")
        COPYFILE_DISABLE=1 tar -czf "$tar_file" -C "$dump_dir" "$dump_name" "${meta_opt[@]}" 2>/dev/null

        if [ $? -eq 0 ]; then
            # Remove original files
            rm -f "$dump_file"; rm -rf "$meta_dir"
            log_debug "Archive created: $tar_file"
            META_ARTIFACT="$tar_file"

            # Return the tar file path (for use by caller)
            echo "TAR_FILE=$tar_file"
        else
            log_warn "Failed to create archive, keeping separate files"
            META_ARTIFACT="$dump_file"
        fi
    else
        # Externally compressed standalone artifact (.dump.zst/.xz/.bz2): keep it
        # as-is and drop a "${file}.meta" sidecar (read by show_meta). Wrapping it
        # in tar.gz would break restore, which decompresses these files directly.
        mv "$meta_file" "${dump_file}.meta" 2>/dev/null
        META_ARTIFACT="$dump_file"
        log_debug "Metadata sidecar: ${dump_file}.meta"
    fi
}

meta_update_target() {
    local tar_file="$1"
    local restore_status="${2:-success}"
    local restore_elapsed="${3:-0}"

    [ "$META_ENABLED" != true ] && return 0
    [ -z "$tar_file" ] && return 0
    [ ! -f "$tar_file" ] && return 0

    local temp_dir=$(mktemp -d)
    [ -z "$temp_dir" ] && { log_error "mktemp failed"; return 0; }

    # Extract everything from tar
    tar -xzf "$tar_file" -C "$temp_dir" 2>/dev/null || { rm -rf "$temp_dir"; return 0; }

    # Find the dump file (ignore macOS AppleDouble ._ sidecars, which sort first).
    local dump_name=$(ls "$temp_dir"/*.dump 2>/dev/null | grep -vE '/\._' | head -1 | xargs basename 2>/dev/null)
    [ -z "$dump_name" ] && { rm -rf "$temp_dir"; return 0; }

    # Create metadata.yaml if it doesn't exist
    if [ ! -f "$temp_dir/metadata.yaml" ]; then
        cat > "$temp_dir/metadata.yaml" << EOF
# t-pgsql metadata (generated during restore)
timing:
  restored_at: "$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    fi

    # Append target and restore info to metadata
    cat >> "$temp_dir/metadata.yaml" << EOF

target:
  type: ${TO_TYPE}
  host: ${TO_SSH_HOST:-${TO_DB_HOST}}
  port: ${TO_DB_PORT}
  database: ${TO_DATABASE}
  user: ${TO_DB_USER}

restore:
  status: ${restore_status}
  elapsed: "$(format_elapsed $restore_elapsed)"
  total_elapsed: "$(format_elapsed $(($(date +%s) - META_START_EPOCH)))"
EOF

    # Recreate tar with updated metadata. Write to a SIDE FILE and atomically replace the
    # original only on success — a failed re-tar (disk full, etc.) must not truncate/corrupt
    # the only backup archive, which the old in-place rewrite could do right before the temp
    # copy was deleted.
    local tar_args=("$dump_name")
    [ -f "$temp_dir/metadata.yaml" ] && tar_args+=("metadata.yaml")
    local new_tar="${tar_file}.tpgtmp.$$"
    if (cd "$temp_dir" && COPYFILE_DISABLE=1 tar -czf "$new_tar" "${tar_args[@]}" 2>/dev/null) && [ -s "$new_tar" ]; then
        mv -f "$new_tar" "$tar_file"
        log_debug "Metadata updated with target info"
    else
        rm -f "$new_tar"
        log_warn "Metadata re-archive failed; leaving the original dump archive intact"
    fi

    rm -rf "$temp_dir"
}

# Extract dump from tar archive, returns path to extracted dump.
# The member name comes from the (possibly untrusted) archive, so it is validated
# against path traversal BEFORE extraction: a member like '../../tmp/evil.dump' or an
# absolute path could otherwise write outside extract_dir when restoring a crafted archive.
extract_dump() {
    local file="$1"
    local extract_dir="${2:-$(mktemp -d)}"
    [ -z "$extract_dir" ] && { log_error "mktemp failed"; return 1; }

    if [[ "$file" == *.tar.gz ]]; then
        # Skip macOS AppleDouble sidecars (._name): an archive that passed through macOS
        # (with xattrs, e.g. com.apple.provenance) carries a "._<dump>.dump" entry that would
        # otherwise be picked ahead of the real dump and fail the restore.
        local dump_name=$(tar -tzf "$file" 2>/dev/null | grep -E '\.dump$' | grep -vE '(^|/)\._' | head -1)
        if [ -n "$dump_name" ]; then
            # Reject absolute paths and any '..' component; require a plain relative name.
            case "$dump_name" in
                /*|*/../*|../*|*/..|..) log_error "Unsafe archive member (path traversal), refusing to extract: $dump_name"; return 1 ;;
            esac
            tar -xzf "$file" -C "$extract_dir" "$dump_name" 2>/dev/null
            # Confirm the extracted file really landed inside extract_dir (defends against
            # symlink/edge cases the name check might miss on non-GNU tar).
            local out="${extract_dir}/${dump_name}" real base
            real=$(cd "$(dirname "$out")" 2>/dev/null && pwd -P)/$(basename "$out")
            base=$(cd "$extract_dir" 2>/dev/null && pwd -P)
            if [ -z "$real" ] || [ -z "$base" ] || [ "${real#"$base"/}" = "$real" ]; then
                log_error "Extracted dump escaped the temp directory, refusing: $dump_name"
                return 1
            fi
            echo "$out"
        fi
    elif [[ "$file" == *.dump ]]; then
        echo "$file"
    fi
}

# Show metadata from tar archive
show_meta() {
    local file="$1"

    if [[ "$file" == *.tar.gz ]]; then
        tar -xzf "$file" -O metadata.yaml 2>/dev/null || {
            log_error "No metadata found (not a valid t-pgsql archive): $file"
            return 1
        }
    elif [[ -f "${file}.meta" ]]; then
        cat "${file}.meta"
    else
        log_error "No metadata for: $file (not a .tar.gz archive and no .meta sidecar)"
        return 1
    fi
}

format_elapsed() {
    local sec=$1
    local min=$((sec / 60))
    local hrs=$((min / 60))
    sec=$((sec % 60))
    min=$((min % 60))

    if [ $hrs -gt 0 ]; then
        printf "%dh %dm %ds" $hrs $min $sec
    elif [ $min -gt 0 ]; then
        printf "%dm %ds" $min $sec
    else
        printf "%ds" $sec
    fi
}

# List dump files belonging to EXACTLY one base name, newest first.
# The shell glob "${base}_*" also matches a prefix-overlapping db (e.g. base
# "prod" would grab "prod_v2_...").  Anchor the result with a regex so only
# files named base + "_" + YYYYMMDD + "_" + HHMMSS + a known extension survive.
# Usage: list_dumps_for_base "dir" "base"
list_dumps_for_base() {
    local dir="$1"
    local base="$2"
    # Escape regex metacharacters in the base so it is matched literally.
    local esc_base
    esc_base=$(printf '%s' "$base" | sed 's/[][\.^$*+?(){}|/]/\\&/g')
    local re="/${esc_base}_[0-9]{8}_[0-9]{6}(_[0-9]+)?\.(tar\.gz|dump\.zst|dump\.xz|dump\.bz2|dump)\$"
    { ls -t "$dir"/"${base}"_*.tar.gz \
           "$dir"/"${base}"_*.dump.zst \
           "$dir"/"${base}"_*.dump.xz \
           "$dir"/"${base}"_*.dump.bz2 \
           "$dir"/"${base}"_*.dump 2>/dev/null; } | grep -E "$re"
}

# Check if recent dump exists (skip_if_recent feature)
# Returns 0 if should skip, 1 if should proceed
check_skip_recent() {
    [ -z "$SKIP_IF_RECENT" ] && return 1  # No skip configured, proceed

    local dump_base_name="${DUMP_NAME:-$FROM_DATABASE}"
    local latest=$(list_dumps_for_base "$OUTPUT_DIR" "$dump_base_name" | head -1)
    [ -z "$latest" ] && return 1  # No existing dump, proceed

    # Get file modification time (macOS uses -f, Linux uses -c)
    local file_epoch
    file_epoch=$(stat -c %Y "$latest" 2>/dev/null) || file_epoch=$(stat -f %m "$latest" 2>/dev/null)
    [[ ! "$file_epoch" =~ ^[0-9]+$ ]] && return 1

    local now_epoch=$(date +%s)
    local diff_sec=$((now_epoch - file_epoch))

    # Parse timeframe
    local skip_sec=0
    case "$SKIP_IF_RECENT" in
        today)
            # Check if file was created today
            local file_date=$(date -r "$file_epoch" +%Y%m%d 2>/dev/null || date -d "@$file_epoch" +%Y%m%d 2>/dev/null)
            local today_date=$(date +%Y%m%d)
            if [ "$file_date" = "$today_date" ]; then
                log_info "Skipping: dump already exists today ($(basename "$latest"))"
                return 0
            fi
            return 1
            ;;
        *h|*m|*d|*)
            # Extract the numeric part and its unit multiplier. Validate BEFORE any
            # arithmetic: a garbage value like "24hr"/"1.5h"/"5x" used to hit a bash
            # arithmetic error and ABORT the whole backup (a missed backup). Now we
            # warn and proceed with the backup instead of skipping.
            local _num _mult=3600
            case "$SKIP_IF_RECENT" in
                *h) _num="${SKIP_IF_RECENT%h}"; _mult=3600 ;;
                *m) _num="${SKIP_IF_RECENT%m}"; _mult=60 ;;
                *d) _num="${SKIP_IF_RECENT%d}"; _mult=86400 ;;
                *)  _num="$SKIP_IF_RECENT"; _mult=3600 ;;
            esac
            if ! [[ "$_num" =~ ^[0-9]+$ ]]; then
                log_warn "Invalid --skip-if-recent '$SKIP_IF_RECENT' (use e.g. 24h, 30m, 2d, today); proceeding with backup"
                return 1
            fi
            skip_sec=$(( _num * _mult ))
            ;;
    esac

    if [ $diff_sec -lt $skip_sec ]; then
        local age=$(format_elapsed $diff_sec)
        log_info "Skipping: recent dump exists ($age ago, threshold: $SKIP_IF_RECENT)"
        return 0
    fi

    return 1
}

