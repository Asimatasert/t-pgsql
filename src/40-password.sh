# ==============================================================================
# PASSWORD HANDLER
# ==============================================================================
get_password() {
    local prefix="$1"
    local index="${2:-0}"  # Optional index for multiple targets
    local pass=""

    # 1. Direct parameter
    if [ "$prefix" = "FROM" ] && [ -n "$FROM_PASSWORD" ]; then
        pass="$FROM_PASSWORD"
    elif [ "$prefix" = "TO" ] && [ -n "$TO_PASSWORD" ]; then
        pass="$TO_PASSWORD"
    elif [ -n "$PASSWORD" ]; then
        pass="$PASSWORD"
    fi

    # 2. Environment variable
    if [ -z "$pass" ]; then
        if [ "$prefix" = "FROM" ] && [ -n "$T_PGSQL_FROM_PASSWORD" ]; then
            pass="$T_PGSQL_FROM_PASSWORD"
        elif [ "$prefix" = "TO" ] && [ -n "$T_PGSQL_TO_PASSWORD" ]; then
            pass="$T_PGSQL_TO_PASSWORD"
        elif [ -n "$T_PGSQL_PASSWORD" ]; then
            pass="$T_PGSQL_PASSWORD"
        fi
    fi

    # 3. Password file
    if [ -z "$pass" ]; then
        local pf=""
        if [ "$prefix" = "FROM" ] && [ -n "$FROM_PASSWORD_FILE" ]; then
            pf="$FROM_PASSWORD_FILE"
        elif [ "$prefix" = "TO" ] && [ ${#TO_PASSWORD_FILES[@]} -gt 0 ]; then
            # One file applies to all targets; multiple files map per-target by index.
            # If there are multiple files but fewer than targets, an out-of-range target
            # gets NO file (not target 0's) — reusing another target's credential is wrong.
            if [ ${#TO_PASSWORD_FILES[@]} -eq 1 ]; then
                pf="${TO_PASSWORD_FILES[0]}"
            else
                pf="${TO_PASSWORD_FILES[$index]}"
            fi
        elif [ -n "$PASSWORD_FILE" ]; then
            pf="$PASSWORD_FILE"
        fi

        if [ -n "$pf" ]; then
            if [ ! -f "$pf" ]; then
                # A password file was explicitly requested but is missing — fail loudly
                # instead of silently proceeding with no password.
                log_error "Password file not found: $pf"
                return 1
            fi
            # Strip CR and LF so a Windows/CRLF-saved file doesn't leave a trailing \r
            # embedded in the password.
            pass=$(cat "$pf" | tr -d '\r\n')
            log_debug "Password from file: $pf"
        fi
    fi

    # 4. Interactive prompt
    if [ -z "$pass" ] && [ -t 0 ] && [ "$YES" != true ]; then
        read -s -p "$prefix password: " pass
        echo ""
    fi

    # Sudo mode doesn't need password for FROM
    if [ -z "$pass" ] && [ "$prefix" = "FROM" ] && [ "$SUDO" = true ]; then
        log_debug "Sudo mode: skipping FROM password"
        printf -v "${prefix}_DB_PASSWORD" '%s' ''
        return 0
    fi

    if [ -z "$pass" ]; then
        log_error "No password for $prefix"
        return 1
    fi

    printf -v "${prefix}_DB_PASSWORD" '%s' "$pass"
}

