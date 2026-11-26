# ==============================================================================
# CONNECTION PARSER
# ==============================================================================
parse_connection() {
    local conn="$1"
    local prefix="$2"

    log_debug "Parsing: $conn -> $prefix"

    if [[ "$conn" == ssh://* ]]; then
        parse_ssh_connection "$conn" "$prefix"
    else
        parse_local_connection "$conn" "$prefix"
    fi
}

parse_local_connection() {
    local conn="$1"
    local prefix="$2"

    local user="postgres"
    local host="localhost"
    local port="5432"
    local db=""

    # Format: user@host[:port]/[db_user@]database
    # Examples:
    #   dbadmin@localhost/test           -> user=dbadmin, db=test
    #   dbadmin@localhost/postgres@test  -> user=postgres, db=test
    #   dbadmin@localhost:5432/test      -> with port
    #   postgres@test                    -> simple format, localhost

    if [[ "$conn" == */* ]]; then
        # Has slash: user@host/database or user@host:port/database
        local db_part="${conn##*/}"
        conn="${conn%/*}"

        # Check if db_part has user@ prefix (db_user@database)
        if [[ "$db_part" == *@* ]]; then
            user="${db_part%%@*}"
            db="${db_part#*@}"
        else
            db="$db_part"
            # user comes from left side of @
            if [[ "$conn" == *@* ]]; then
                user="${conn%%@*}"
            fi
        fi

        # Parse host part: user@host or user@host:port
        if [[ "$conn" == *@* ]]; then
            conn="${conn#*@}"
        fi

        # host:port or just host. Support IPv6 bracket forms [addr]:port and [addr];
        # a bare IPv6 (multiple colons, unbracketed) is ambiguous and is rejected
        # rather than silently blanking the host (which used to dump via the local
        # socket and report success — a silent wrong-target).
        if [[ "$conn" == \[*\]:* ]]; then
            host="${conn%]:*}"; host="${host#\[}"
            port="${conn##*]:}"
        elif [[ "$conn" == \[*\] ]]; then
            host="${conn#\[}"; host="${host%]}"
        elif [[ "$conn" == *:*:* ]]; then
            log_error "IPv6 host must be bracketed, e.g. [${conn%:*}]:${conn##*:} or [${conn}]"
            return 1
        elif [[ "$conn" == *:* ]]; then
            host="${conn%%:*}"
            port="${conn##*:}"
        else
            host="$conn"
        fi
    elif [[ "$conn" == *@* ]]; then
        # Simple format: user@database (localhost assumed)
        user="${conn%%@*}"
        db="${conn#*@}"
        host="localhost"
    else
        # Just database name
        db="$conn"
        host="localhost"
    fi

    [ -z "$db" ] && { log_error "Missing database: $1"; return 1; }

    printf -v "${prefix}_TYPE" '%s' 'local'
    printf -v "${prefix}_DB_USER" '%s' "$user"
    printf -v "${prefix}_DB_HOST" '%s' "$host"
    printf -v "${prefix}_DB_PORT" '%s' "$port"
    printf -v "${prefix}_DATABASE" '%s' "$db"
    # Reset the SSH fields: parsing a LOCAL target must not leave a stale SSH host/user/port
    # from a previously-parsed ssh:// target (which would e.g. defeat the clone source==target
    # guard, or misroute code that inspects ${prefix}_SSH_HOST).
    printf -v "${prefix}_SSH_HOST" '%s' ''
    printf -v "${prefix}_SSH_USER" '%s' ''
    printf -v "${prefix}_SSH_PORT" '%s' ''

    log_debug "$prefix: local $user@$host:$port/$db"
}

parse_ssh_connection() {
    local conn="$1"
    local prefix="$2"

    conn="${conn#ssh://}"

    local ssh_user=""
    local ssh_host=""
    local ssh_port="22"
    local db_user=""
    local db_host="localhost"
    local db_port="5432"
    local db=""

    # Format: ssh_user@ssh_host[:ssh_port]/db_user@db_host[:db_port]/database
    # Examples:
    #   dbadmin@192.0.2.10/postgres@localhost/appdb
    #   dbadmin@192.0.2.10:2222/postgres@localhost:5433/appdb

    # Extract database name (last /)
    if [[ "$conn" == */* ]]; then
        db="${conn##*/}"
        conn="${conn%/*}"
    else
        log_error "Missing database in SSH connection"
        return 1
    fi

    # Check if there's still a / (means db_user@db_host part exists)
    if [[ "$conn" == */* ]]; then
        # Has db connection part
        local db_part="${conn##*/}"
        conn="${conn%/*}"

        # Parse db_part: user@host[:port]
        if [[ "$db_part" == *@* ]]; then
            db_user="${db_part%%@*}"
            local db_host_port="${db_part#*@}"

            if [[ "$db_host_port" == *:* ]]; then
                db_host="${db_host_port%%:*}"
                db_port="${db_host_port##*:}"
            else
                db_host="$db_host_port"
            fi
        else
            # Just host or host:port
            if [[ "$db_part" == *:* ]]; then
                db_host="${db_part%%:*}"
                db_port="${db_part##*:}"
            else
                db_host="$db_part"
            fi
        fi
    fi

    # SSH part: [user@]host[:port]
    if [[ "$conn" == *@* ]]; then
        ssh_user="${conn%%@*}"
        conn="${conn#*@}"
    else
        ssh_user="$(whoami)"
    fi

    if [[ "$conn" == *:* ]]; then
        ssh_host="${conn%%:*}"
        ssh_port="${conn##*:}"
    else
        ssh_host="$conn"
    fi

    # If db_user not specified, use "postgres" as default
    [ -z "$db_user" ] && db_user="postgres"

    printf -v "${prefix}_TYPE" '%s' 'ssh'
    printf -v "${prefix}_SSH_USER" '%s' "$ssh_user"
    printf -v "${prefix}_SSH_HOST" '%s' "$ssh_host"
    printf -v "${prefix}_SSH_PORT" '%s' "$ssh_port"
    printf -v "${prefix}_DB_USER" '%s' "$db_user"
    printf -v "${prefix}_DB_HOST" '%s' "$db_host"
    printf -v "${prefix}_DB_PORT" '%s' "$db_port"
    printf -v "${prefix}_DATABASE" '%s' "$db"

    log_debug "$prefix: ssh $ssh_user@$ssh_host:$ssh_port -> $db_user@$db_host:$db_port/$db"
}

