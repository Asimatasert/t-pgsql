# ==============================================================================
# LIST
# ==============================================================================
cmd_list() {
    local norm_dir=$(cd "$OUTPUT_DIR" 2>/dev/null && pwd)
    log_info "Dumps in: $norm_dir"
    echo ""

    [ ! -d "$OUTPUT_DIR" ] && { log_warn "Directory not found"; return 0; }

    printf "%-50s %8s %s\n" "FILE" "SIZE" "DATE"
    printf "%s\n" "$(printf '%.0s-' {1..75})"

    # List .tar.gz, .dump, and compressed dump files
    # Use stat with platform-specific options (Linux: -c, macOS: -f)
    find "$norm_dir" \( -name "*.tar.gz" -o -name "*.dump" -o -name "*.dump.zst" -o -name "*.dump.xz" -o -name "*.dump.bz2" \) -type f -print0 2>/dev/null | \
        xargs -0 -I{} sh -c 'stat -c "%Y %s %n" "$1" 2>/dev/null || stat -f "%m %z %N" "$1" 2>/dev/null' _ {} | \
        sort -rn | \
        while read -r mtime size filepath; do
            local fname=$(basename "$filepath")
            local hsize=$(numfmt --to=iec-i --suffix=B $size 2>/dev/null || echo "${size}B")
            local fdate=$(date -r "$mtime" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$mtime" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
            printf "%-50s %8s %s\n" "$fname" "$hsize" "$fdate"
        done
    echo ""
}

# ==============================================================================
# META (show metadata)
# ==============================================================================
cmd_meta() {
    if [ -z "$FILE" ]; then
        # Show latest (check tar.gz, compressed dumps, then plain dumps)
        local norm_output_dir=$(cd "$OUTPUT_DIR" 2>/dev/null && pwd)
        # Newest across ALL formats by mtime (not tar.gz-first, which showed stale meta).
        FILE=$(ls -t "${norm_output_dir}/"*.tar.gz "${norm_output_dir}/"*.dump.zst \
                     "${norm_output_dir}/"*.dump.xz "${norm_output_dir}/"*.dump.bz2 \
                     "${norm_output_dir}/"*.dump 2>/dev/null | head -1)
    fi

    if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
        log_error "No archive found. Use --file <path>"
        return 1
    fi

    log_info "Metadata: $(basename "$FILE")"
    echo ""
    show_meta "$FILE"
}

# ==============================================================================
# CLEAN
# ==============================================================================
cmd_clean() {
    # Determine which dumps to clean. cleanup_old_dumps keys off the dump base
    # name (${DUMP_NAME:-$FROM_DATABASE}), so we must resolve a base name from
    # one of: a positional db name, --from <connection>, or --dump-name.
    if [ -z "$FROM_DATABASE" ]; then
        if [ -n "$CLEAN_DB" ]; then
            FROM_DATABASE="$CLEAN_DB"
        elif [ -n "$FROM_CONNECTION" ]; then
            parse_connection "$FROM_CONNECTION" "FROM" || { log_error "Invalid source connection: $FROM_CONNECTION"; return 1; }
        elif [ -n "$DUMP_NAME" ]; then
            FROM_DATABASE="$DUMP_NAME"
        fi
    fi

    if [ -z "$FROM_DATABASE" ] && [ -z "$DUMP_NAME" ]; then
        log_error "clean requires a database name, --from <connection>, or --dump-name <name> to determine which dumps to clean"
        log_error "Example: $SCRIPT_NAME clean mydb --keep 5   (or --retention)"
        return 1
    fi

    log_info "Cleaning dumps for: ${DUMP_NAME:-$FROM_DATABASE}"
    [ "$DRY_RUN" = true ] && { log_info "[DRY-RUN] Would clean"; return 0; }
    cleanup_old_dumps
    log_success "Done"
}

