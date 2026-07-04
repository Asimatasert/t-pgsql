# ==============================================================================
# DATA MASKING
# ==============================================================================
apply_masking() {
    local prefix="$1"  # TO connection prefix

    if [ "$MASK" != true ]; then
        return 0
    fi

    log_info "Applying data masking..."

    local type="" host="" port="" user="" password="" database=""

    if [ "$prefix" = "TO" ]; then
        type="$TO_TYPE"
        host="$TO_DB_HOST"
        port="$TO_DB_PORT"
        user="$TO_DB_USER"
        password="$TO_DB_PASSWORD"
        database="$TO_DATABASE"
    fi

    # Run SQL against the target (local/TCP or SSH). $1=sql, $2=extra psql flags.
    # With flags (e.g. -tAq) the SQL is a single query passed via -c. WITHOUT flags
    # it is the masking batch: fed via STDIN so psql executes each statement in its own
    # autocommit transaction — a single bad rule can no longer roll back (silently unmask)
    # all the other, valid masking statements. Uses the caller's connection locals.
    local _MASK_PGPASS=""
    _mask_run() {
        local sql="$1" flags="$2"
        if [ "$type" = "ssh" ]; then
            local pre; pre="$(remote_pgpass_preamble "$user" "$password")"
            if [ -n "$flags" ]; then
                # stdin-free single query: command (with pgpass preamble) via stdin, not argv.
                ssh_exec "$TO_SSH_PORT" "${TO_SSH_USER}@${TO_SSH_HOST}" \
                    "${pre}psql $flags -U $(pq "$user") -h $(pq "$host") -p $(pq "$port") -d $(pq "$database") -c $(pq "$sql")" 2>/dev/null
            else
                # Batch: SQL is piped on ssh stdin (per-statement autocommit), so the command
                # with its pgpass preamble must ride in argv here — transiently visible to `ps`.
                # ON_ERROR_STOP=1 makes psql exit nonzero on a failed masking statement so the
                # caller fails loudly instead of shipping unmasked data as success.
                printf '%s' "$sql" | ssh -p "$TO_SSH_PORT" "${SSH_OPTS[@]}" "${TO_SSH_USER}@${TO_SSH_HOST}" \
                    "${pre}psql -v ON_ERROR_STOP=1 -U $(pq "$user") -h $(pq "$host") -p $(pq "$port") -d $(pq "$database")" 2>/dev/null
            fi
        else
            if [ -n "$flags" ]; then
                PGPASSFILE="$_MASK_PGPASS" psql $flags -U "$user" -h "$host" -p "$port" -d "$database" -c "$sql" 2>/dev/null
            else
                printf '%s' "$sql" | PGPASSFILE="$_MASK_PGPASS" psql -v ON_ERROR_STOP=1 -U "$user" -h "$host" -p "$port" -d "$database" 2>/dev/null
            fi
        fi
    }

    if [ "$type" != "ssh" ]; then
        _MASK_PGPASS="$(make_pgpass_file "$user" "$password")" || { log_error "Masking: credential setup failed"; return 0; }; reg_tmp "$_MASK_PGPASS"
    fi

    local mask_sql=""

    # Explicit rules from a JSON file: {"table.column": "SQL_EXPRESSION", ...}
    # Columns here are named by the user and assumed to exist.
    if [ -n "$MASK_RULES" ] && [ -f "$MASK_RULES" ]; then
        log_debug "Loading mask rules from: $MASK_RULES"
        while IFS=': ' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*[\{\}] ]] && continue
            [[ -z "$key" ]] && continue
            key=$(echo "$key" | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
            value=$(echo "$value" | sed 's/^[[:space:]]*"//; s/"[[:space:]]*,*$//')
            [ -z "$key" ] || [ -z "$value" ] && continue
            # Key is table.column or schema.table.column: the column is the LAST
            # dotted segment; everything before it is the (possibly schema-qualified) table.
            local column="${key##*.}"
            local table="${key%.*}"
            # Quote identifiers: a reserved-word / mixed-case / quoted table or column would
            # otherwise be a syntax error (silently unmasked), or mask the wrong (case-folded)
            # table. $value is a user-supplied SQL expression and is left as-is.
            mask_sql+="UPDATE $(sqlid_table "$table") SET $(sqlid "$column") = $value;"
            log_debug "Mask rule: $table.$column = $value"
        done < "$MASK_RULES"
    fi

    # Auto-mask well-known sensitive columns for --mask-tables. CRITICAL: only
    # emit an UPDATE for a column that actually EXISTS in the table. Blindly
    # updating a missing column (e.g. 'phone') raised an error that rolled back
    # the whole single-transaction batch, so nothing (not even email/password)
    # was masked while the tool still reported success.
    if [ -n "$MASK_TABLES" ]; then
        local in_list="'email','phone','password','password_hash','address','ssn','credit_card'"
        IFS=',' read -ra tables <<< "$MASK_TABLES"
        local table existing found row col schematbl qt
        for table in "${tables[@]}"; do
            table=$(trim "$table")
            [ -z "$table" ] && continue
            # Return each match as schema.table.column so every UPDATE is SCHEMA-QUALIFIED
            # to the exact table the column lives in. A bare name matching the same table in
            # multiple schemas therefore masks EACH one correctly (and never emits a column
            # that a search_path-resolved table lacks, which would abort under ON_ERROR_STOP).
            # Restrict to ordinary/partitioned BASE TABLES the role can actually UPDATE:
            # information_schema.columns also lists VIEWs and read-only relations, and an
            # UPDATE against those aborts the whole batch under ON_ERROR_STOP (and masking a
            # view is pointless — its base table is masked directly).
            existing=$(_mask_run "SELECT c.table_schema || '.' || c.table_name || '.' || c.column_name FROM information_schema.columns c WHERE c.column_name IN ($in_list) AND (c.table_name = '$(sqllit "$table")' OR c.table_schema || '.' || c.table_name = '$(sqllit "$table")') AND EXISTS (SELECT 1 FROM pg_catalog.pg_class rc JOIN pg_catalog.pg_namespace rn ON rn.oid = rc.relnamespace WHERE rc.relname = c.table_name AND rn.nspname = c.table_schema AND rc.relkind IN ('r','p') AND has_table_privilege(rc.oid, 'UPDATE')) ORDER BY 1" "-tAq")
            if [ -z "$existing" ]; then
                log_warn "Masking: table '$table' has no known-sensitive columns (email/phone/password/password_hash/address/ssn/credit_card) — skipped"
                continue
            fi
            found=""
            while IFS= read -r row; do
                [ -z "$row" ] && continue
                col="${row##*.}"           # last segment = column
                schematbl="${row%.*}"      # everything before = schema.table
                qt="$(sqlid_table "$schematbl")"
                case "$col" in
                    email)         mask_sql+="UPDATE $qt SET \"email\" = CONCAT(LEFT(\"email\", 2), '***@***.com') WHERE \"email\" IS NOT NULL;" ;;
                    phone)         mask_sql+="UPDATE $qt SET \"phone\" = '***-***-****' WHERE \"phone\" IS NOT NULL;" ;;
                    password)      mask_sql+="UPDATE $qt SET \"password\" = '********' WHERE \"password\" IS NOT NULL;" ;;
                    password_hash) mask_sql+="UPDATE $qt SET \"password_hash\" = 'MASKED' WHERE \"password_hash\" IS NOT NULL;" ;;
                    address)       mask_sql+="UPDATE $qt SET \"address\" = '[MASKED]' WHERE \"address\" IS NOT NULL;" ;;
                    ssn)           mask_sql+="UPDATE $qt SET \"ssn\" = '***-**-****' WHERE \"ssn\" IS NOT NULL;" ;;
                    credit_card)   mask_sql+="UPDATE $qt SET \"credit_card\" = '****-****-****-****' WHERE \"credit_card\" IS NOT NULL;" ;;
                esac
                found="$found $row"
            done <<< "$existing"
            log_debug "Auto-masking '$table' ->$found"
        done
    fi

    if [ -z "$mask_sql" ]; then
        [ -n "$_MASK_PGPASS" ] && rm -f "$_MASK_PGPASS"
        # --mask was requested but nothing matched (no --mask-tables/--mask-rules, a
        # missing/empty rules file, or no known-sensitive columns). Fail — do NOT ship
        # data the user asked to mask, unmasked, as a success.
        log_error "Masking requested but nothing was masked (check --mask-tables/--mask-rules); refusing to report success"
        return 1
    fi

    local result=0
    _mask_run "$mask_sql" "" >/dev/null 2>&1; result=$?
    [ -n "$_MASK_PGPASS" ] && rm -f "$_MASK_PGPASS"

    if [ $result -eq 0 ]; then
        log_success "Data masking applied"
        return 0
    fi
    # A masking statement failed (ON_ERROR_STOP): fail loudly so the caller does not report
    # a masked backup/restore while the target may still hold UNMASKED sensitive data.
    log_error "Data masking FAILED (a masking statement errored) — target may contain UNMASKED data"
    return 1
}
