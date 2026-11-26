# bash completion for t-pgsql

_t_pgsql() {
    local cur prev words cword
    _init_completion || return

    local commands="dump restore clone upgrade fetch batch bot jobs list meta clean doctor explain version help"

    local opts="
        --from --to
        --password --from-password --to-password
        --password-file --from-password-file --to-password-file
        --config
        --exclude-table --exclude-schema --exclude-data
        --only-table --only-schema
        --compress --compress-level --pg-compress-level
        --output --dump-name --keep --from-keep --skip-if-recent
        --from-file --file --yaml
        --retention --retention-daily --retention-weekly --retention-monthly --retention-yearly
        --health-check --health-check-after --no-health-check --health-check-fail
        --notify --notify-on-error --notify-summary
        --mask --mask-rules --mask-tables
        --stream --stream-buffer
        --sudo --globals --pg-bindir --parallel --continue-on-error
        --only-jobs --exclude-jobs --only --exclude
        --save --batch
        --log --log-level
        --verbose --quiet --yes --force --dry-run --no-meta
        --help --version
        -v -q -y -f -h
    "

    # First argument - commands
    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        return
    fi

    # Handle specific options
    case $prev in
        --compress)
            COMPREPLY=($(compgen -W "gzip zstd xz bzip2 none" -- "$cur"))
            return
            ;;
        --log-level)
            COMPREPLY=($(compgen -W "debug info warn error" -- "$cur"))
            return
            ;;
        --compress-level|--pg-compress-level)
            COMPREPLY=($(compgen -W "1 2 3 4 5 6 7 8 9" -- "$cur"))
            return
            ;;
        --password-file|--from-password-file|--to-password-file|--config|--mask-rules|--log|--file|--from-file)
            _filedir
            return
            ;;
        --yaml)
            COMPREPLY=($(compgen -f -X '!*.yaml' -- "$cur"))
            return
            ;;
        --skip-if-recent)
            COMPREPLY=($(compgen -W "today 24h 12h 6h 1d" -- "$cur"))
            return
            ;;
        --output)
            _filedir -d
            return
            ;;
        --batch)
            # Resolve the jobs.yaml next to the installed t-pgsql script
            local script_path jobs_file jobs=""
            script_path=$(command -v t-pgsql 2>/dev/null)
            if [[ -n "$script_path" ]]; then
                # Follow symlink to the real script location
                script_path=$(readlink -f "$script_path" 2>/dev/null || echo "$script_path")
                jobs_file="$(dirname "$script_path")/jobs.yaml"
                if [[ -f "$jobs_file" ]]; then
                    # Only top-level job names: 2-space-indented keys directly
                    # under the "jobs:" section (skip nested fields and other
                    # sections such as "profiles:")
                    jobs=$(awk '/^jobs:[[:space:]]*$/{f=1; next} /^[^[:space:]]/{f=0} f && /^  [a-zA-Z0-9_-]+:/{sub(/:.*/,""); sub(/^  */,""); print}' "$jobs_file" 2>/dev/null)
                fi
            fi
            COMPREPLY=($(compgen -W "$jobs all" -- "$cur"))
            return
            ;;
    esac

    # Jobs subcommands
    if [[ ${words[1]} == "jobs" && $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "list show remove" -- "$cur"))
        return
    fi

    # Default - show options
    if [[ $cur == -* ]]; then
        COMPREPLY=($(compgen -W "$opts" -- "$cur"))
        return
    fi
}

complete -F _t_pgsql t-pgsql
