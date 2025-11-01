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
    cmd="${COMP_WORDS[1]}"

    local commands="add remove start stop switch list show monitor logs clear env noproxy latency test sub doctor probe check help"

    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        return
    fi

    case "$cmd" in
        add)
            # no completion for options yet
            ;;
        remove|start|stop|switch|show|monitor|logs|probe|check)
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
            COMPREPLY=($(compgen -W "--install --dry-run -i -h --help" -- "$cur"))
            return
            ;;
    esac
}

if [ -n "${BASH_VERSION:-}" ]; then
    complete -F _ssctl_completions ssctl
elif [ -n "${ZSH_VERSION:-}" ]; then
    autoload -U +X compinit && compinit
    autoload -U +X bashcompinit && bashcompinit
    complete -F _ssctl_completions ssctl
fi
