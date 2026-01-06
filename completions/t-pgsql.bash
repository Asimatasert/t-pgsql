# bash completion for t-pgsql

_t_pgsql() {
    local cur prev words cword
    _init_completion || return

    local commands="dump restore clone fetch batch jobs list meta clean version help"

    local opts="
        --from --to
        --password --from-password --to-password
        --password-file --from-password-file --to-password-file
        --config
        --exclude-table --exclude-schema --exclude-data
        --only-table --only-schema
        --compress --compress-level --pg-compress-level
        --output --keep --from-keep
        --from-file --file
        --retention --retention-daily --retention-weekly --retention-monthly --retention-yearly
        --health-check --health-check-after --no-health-check
        --notify --notify-on-error
        --mask --mask-rules --mask-tables
        --stream --stream-buffer
        --sudo --parallel --continue-on-error
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
        --output)
            _filedir -d
            return
            ;;
        --batch)
            # Try to get job names from jobs.yaml
            if [[ -f "jobs.yaml" ]]; then
                local jobs=$(grep -E '^\s+[a-zA-Z0-9_-]+:' jobs.yaml 2>/dev/null | sed 's/://g' | awk '{print $1}')
                COMPREPLY=($(compgen -W "$jobs all" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "all" -- "$cur"))
            fi
            return
            ;;
    esac

    # Jobs subcommands
    if [[ ${words[1]} == "jobs" && $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "list show delete" -- "$cur"))
        return
    fi

    # Default - show options
    if [[ $cur == -* ]]; then
        COMPREPLY=($(compgen -W "$opts" -- "$cur"))
        return
    fi
}

complete -F _t_pgsql t-pgsql
