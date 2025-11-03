#!/usr/bin/env bash
# Bash/Zsh completion for ssctl

__ssctl_node_candidates(){
    local dir="${HOME}/.config/shadowsocks-rust/nodes"
    local entries=()
    if [ -d "$dir" ]; then
        while IFS= read -r file; do
            local base="${file##*/}"
            base="${base%.json}"
            case "$base" in
                _libev_*) continue ;;
            esac
            entries+=("$base")
        done < <(find "$dir" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | sort)
    fi
    printf '%s\n' "${entries[@]}"
}

__ssctl_sub_aliases(){
    local file="${HOME}/.config/shadowsocks-rust/subscriptions.json"
    if [ -r "$file" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.[].alias' "$file" 2>/dev/null
    fi
}

_ssctl_completions(){
    local cur prev cmd
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    local commands="add remove start stop switch list show monitor stats logs clear env noproxy latency test sub doctor probe check help metrics"
    local global_opts="--config --color --no-color --help --version"

    if [ "$prev" = "--config" ]; then
        COMPREPLY=($(compgen -f -- "$cur"))
        return
    fi

    if [ "$prev" = "--color" ]; then
        COMPREPLY=($(compgen -W "auto on off" -- "$cur"))
        return
    fi

    cmd=""
    local i=1
    while [ $i -lt ${#COMP_WORDS[@]} ]; do
        local word="${COMP_WORDS[$i]}"
        case "$word" in
            --config)
                i=$((i+2))
                continue
                ;;
            --color)
                i=$((i+2))
                continue
                ;;
            --color=*|--no-color|-h|--help|-v|--version)
                i=$((i+1))
                continue
                ;;
            --)
                if [ $i -lt $(( ${#COMP_WORDS[@]} - 1 )) ]; then
                    cmd="${COMP_WORDS[$((i+1))]}"
                fi
                break
                ;;
            -* )
                i=$((i+1))
                continue
                ;;
            *)
                cmd="$word"
                break
                ;;
        esac
    done

    if [ -z "$cmd" ]; then
        COMPREPLY=($(compgen -W "$commands $global_opts" -- "$cur"))
        return
    fi

    case "$cmd" in
        add)
            ;;
        remove|start|stop|switch|show|monitor|stats|logs|probe|check)
            COMPREPLY=($(compgen -W "$(__ssctl_node_candidates)" -- "$cur"))
            return
            ;;
        env)
            if [ "$COMP_CWORD" -eq 2 ]; then
                COMPREPLY=($(compgen -W "proxy noproxy off" -- "$cur"))
                return
            elif [ "$COMP_CWORD" -eq 3 ] && [[ "${COMP_WORDS[2]}" == "proxy" ]]; then
                COMPREPLY=($(compgen -W "$(__ssctl_node_candidates)" -- "$cur"))
                return
            fi
            ;;
        sub)
            if [ "$COMP_CWORD" -eq 2 ]; then
                COMPREPLY=($(compgen -W "add list remove update" -- "$cur"))
                return
            fi
            case "${COMP_WORDS[2]}" in
                remove|update)
                    COMPREPLY=($(compgen -W "$(__ssctl_sub_aliases)" -- "$cur"))
                    return
                    ;;
            esac
            ;;
        doctor)
            COMPREPLY=($(compgen -W "--install --dry-run --without-clipboard --with-clipboard --without-qrcode --with-qrcode --without-libev --with-libev -i -h --help" -- "$cur"))
            return
            ;;
        monitor)
            COMPREPLY=($(compgen -W "--url --interval --count --tail --no-dns --ping --format --json" -- "$cur"))
            return
            ;;
        stats)
            COMPREPLY=($(compgen -W "--interval --count --aggregate --format --filter" -- "$cur"))
            return
            ;;
        logs)
            COMPREPLY=($(compgen -W "--format --json -f --follow -n --lines --since --until --filter --raw" -- "$cur"))
            return
            ;;
        metrics)
            COMPREPLY=($(compgen -W "--format -h --help" -- "$cur"))
            return
            ;;
    esac

    COMPREPLY=()
}

if [ -n "${BASH_VERSION:-}" ]; then
    complete -F _ssctl_completions ssctl
elif [ -n "${ZSH_VERSION:-}" ]; then
    autoload -U +X compinit && compinit
    autoload -U +X bashcompinit && bashcompinit
    complete -F _ssctl_completions ssctl
fi
