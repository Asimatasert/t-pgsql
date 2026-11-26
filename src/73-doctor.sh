# ==============================================================================
# DOCTOR — environment & backup-health checks
# ==============================================================================
# Local, read-only diagnostics: required/optional tools, output dir + free disk,
# per-database backup freshness, newest-archive readability, and the jobs file.
# With --from/--to it also tests connectivity. Exits non-zero if a problem is found.

DOCTOR_WARN=0
DOCTOR_FAIL=0
_dok_ok()   { echo -e "  ${GREEN}\xE2\x9C\x93${NC} $1"; }
_dok_warn() { echo -e "  ${YELLOW}!${NC} $1"; DOCTOR_WARN=$((DOCTOR_WARN+1)); }
_dok_fail() { echo -e "  ${RED}\xE2\x9C\x97${NC} $1"; DOCTOR_FAIL=$((DOCTOR_FAIL+1)); }
_dok_note() { echo -e "    ${CYAN}\xE2\x86\xB3${NC} $1"; }
_dok_head() { echo; echo -e "${BOLD}$1${NC}"; }

# Cross-platform file mtime (GNU stat -c, then BSD stat -f).
_dok_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# Human-friendly age from a number of seconds.
_dok_age() {
    local s=$1
    if [ "$s" -lt 3600 ]; then echo "$((s/60))m"
    elif [ "$s" -lt 86400 ]; then echo "$((s/3600))h $(((s%3600)/60))m"
    else echo "$((s/86400))d $(((s%86400)/3600))h"; fi
}

# Distinct dump base names present in the output directory.
_dok_bases() {
    ls -1 "$OUTPUT_DIR"/*.tar.gz "$OUTPUT_DIR"/*.dump "$OUTPUT_DIR"/*.dump.zst \
          "$OUTPUT_DIR"/*.dump.xz "$OUTPUT_DIR"/*.dump.bz2 2>/dev/null \
        | while IFS= read -r f; do basename "$f"; done \
        | sed -E 's/_[0-9]{8}_[0-9]{6}(_[0-9]+)?\.(tar\.gz|dump\.zst|dump\.xz|dump\.bz2|dump)$//' \
        | sort -u
}

_dok_tool() {
    local name="$1" req="$2" why="$3"
    if command -v "$name" >/dev/null 2>&1; then
        _dok_ok "$name"
    elif [ "$req" = "req" ]; then
        _dok_fail "$name not found (required)"
    else
        _dok_warn "$name not found — ${why:-optional}"
    fi
}

cmd_doctor() {
    DOCTOR_WARN=0; DOCTOR_FAIL=0
    echo -e "${BOLD}t-pgsql doctor${NC} — environment & backup health"

    # ---- Toolchain --------------------------------------------------------
    _dok_head "Toolchain"
    _dok_tool pg_dump    req
    _dok_tool pg_restore req
    _dok_tool psql       req
    _dok_tool createdb   req
    _dok_tool dropdb     req
    _dok_tool pg_dumpall opt "needed for --globals / upgrade"
    _dok_tool ssh        opt "needed for ssh:// connections"
    _dok_tool scp        opt "needed for SSH transfers"
    _dok_tool pv         opt "needed for --stream buffering / --bwlimit"
    _dok_tool zstd       opt "needed for --compress zstd"
    _dok_tool xz         opt "needed for --compress xz"
    _dok_tool bzip2      opt "needed for --compress bzip2"
    _dok_tool curl       opt "needed for notifications / bot"
    _dok_tool python3    opt "improves the Telegram bot update parsing"

    # ---- Storage ----------------------------------------------------------
    _dok_head "Backup storage"
    if [ -d "$OUTPUT_DIR" ]; then
        _dok_ok "output directory: $OUTPUT_DIR"
        [ -w "$OUTPUT_DIR" ] || _dok_warn "output directory is not writable"
        local dfline avail usep availh
        dfline=$(df -Pk "$OUTPUT_DIR" 2>/dev/null | awk 'NR==2{print $4","$5}')
        if [ -n "$dfline" ]; then
            avail=${dfline%,*}; usep=${dfline#*,}; usep=${usep%\%}
            availh=$(awk -v k="$avail" 'BEGIN{ if(k>1048576) printf "%.1f GB", k/1048576; else printf "%.0f MB", k/1024 }')
            if   [ "${usep:-0}" -ge 90 ]; then _dok_fail "disk ${usep}% used — only ${availh} free"
            elif [ "${usep:-0}" -ge 85 ]; then _dok_warn "disk ${usep}% used — ${availh} free"
            else _dok_ok "disk ${usep}% used — ${availh} free"; fi
        fi
    else
        _dok_note "output directory does not exist yet: $OUTPUT_DIR (created on first dump)"
    fi

    # ---- Freshness --------------------------------------------------------
    _dok_head "Backup freshness"
    local bases; bases=$(_dok_bases)
    if [ -z "$bases" ]; then
        _dok_note "no dumps found in $OUTPUT_DIR"
    else
        local now base newest mt age count
        now=$(date +%s)
        while IFS= read -r base; do
            [ -z "$base" ] && continue
            newest=$(list_dumps_for_base "$OUTPUT_DIR" "$base" | head -1)
            [ -z "$newest" ] && continue
            mt=$(_dok_mtime "$newest"); [ -z "$mt" ] && continue
            age=$((now - mt))
            count=$(list_dumps_for_base "$OUTPUT_DIR" "$base" | wc -l | tr -d ' ')
            if [ "$age" -ge 172800 ]; then
                _dok_warn "$base — newest dump is $(_dok_age "$age") old (${count} kept)"
            else
                _dok_ok "$base — newest $(_dok_age "$age") ago (${count} kept)"
            fi
        done <<< "$bases"
    fi

    # ---- Integrity (newest archive per base) ------------------------------
    if [ -n "$bases" ]; then
        _dok_head "Archive integrity (newest per database)"
        local newest bn
        while IFS= read -r base; do
            [ -z "$base" ] && continue
            newest=$(list_dumps_for_base "$OUTPUT_DIR" "$base" | head -1)
            [ -z "$newest" ] && continue
            bn=$(basename "$newest")
            case "$newest" in
                *.tar.gz)
                    if tar -tzf "$newest" 2>/dev/null | head -1 | grep -q .; then _dok_ok "$bn — readable archive"
                    else _dok_fail "$bn — unreadable tar.gz"; fi ;;
                *.dump)
                    if command -v pg_restore >/dev/null 2>&1 && pg_restore -l "$newest" >/dev/null 2>&1; then _dok_ok "$bn — valid dump archive"
                    else _dok_warn "$bn — could not validate (pg_restore)"; fi ;;
                *.dump.zst)
                    if command -v zstd >/dev/null 2>&1 && zstd -l "$newest" >/dev/null 2>&1; then _dok_ok "$bn — valid zstd"
                    else _dok_warn "$bn — could not validate (zstd)"; fi ;;
                *.dump.xz)
                    if command -v xz >/dev/null 2>&1 && xz -l "$newest" >/dev/null 2>&1; then _dok_ok "$bn — valid xz"
                    else _dok_warn "$bn — could not validate (xz)"; fi ;;
                *)
                    if [ -s "$newest" ]; then _dok_ok "$bn — present"; else _dok_fail "$bn — empty file"; fi ;;
            esac
        done <<< "$bases"
    fi

    # ---- Jobs configuration ----------------------------------------------
    _dok_head "Jobs configuration"
    if [ -f "$JOBS_FILE" ]; then
        local jc
        jc=$(awk '/^jobs:/{f=1;next} /^[a-zA-Z]/{if($0!~/^jobs:/)f=0} f&&/^  [a-zA-Z0-9_-]+:/{c++} END{print c+0}' "$JOBS_FILE")
        _dok_ok "jobs file: $JOBS_FILE (${jc} job(s))"
        local pf exp
        while IFS= read -r pf; do
            [ -z "$pf" ] && continue
            exp="${pf/#\~/$HOME}"
            [ -f "$exp" ] || _dok_warn "job password file not found: $pf"
        done < <(grep -hoE 'password_file:[[:space:]]*"?[^"]+' "$JOBS_FILE" 2>/dev/null | sed -E 's/.*password_file:[[:space:]]*"?//')
    else
        _dok_note "no jobs file at $JOBS_FILE (optional)"
    fi

    # ---- Connections (only if a connection was supplied) ------------------
    if [ -n "$FROM_CONNECTION" ] || [ "${#TO_CONNECTIONS[@]}" -gt 0 ]; then
        _dok_head "Connections"
        if [ -n "$FROM_CONNECTION" ]; then
            if parse_connection "$FROM_CONNECTION" "FROM"; then
                get_password "FROM"
                if health_check "FROM" "Source" >/dev/null 2>&1; then _dok_ok "source reachable: $FROM_CONNECTION"
                else _dok_fail "source NOT reachable: $FROM_CONNECTION"; fi
            else _dok_fail "invalid source connection: $FROM_CONNECTION"; fi
        fi
        local i=0 conn
        for conn in "${TO_CONNECTIONS[@]}"; do
            if parse_connection "$conn" "TO"; then
                get_password "TO" "$i"
                if health_check "TO" "Target" >/dev/null 2>&1; then _dok_ok "target reachable: $conn"
                else _dok_fail "target NOT reachable: $conn"; fi
            else _dok_fail "invalid target connection: $conn"; fi
            i=$((i+1))
        done
    fi

    # ---- Summary ----------------------------------------------------------
    echo
    if [ "$DOCTOR_FAIL" -gt 0 ]; then
        echo -e "${RED}\xE2\x9C\x97 ${DOCTOR_FAIL} problem(s), ${DOCTOR_WARN} warning(s)${NC}"
        return 1
    elif [ "$DOCTOR_WARN" -gt 0 ]; then
        echo -e "${YELLOW}! ${DOCTOR_WARN} warning(s), no blocking problems${NC}"
        return 0
    else
        echo -e "${GREEN}\xE2\x9C\x93 all checks passed${NC}"
        return 0
    fi
}
