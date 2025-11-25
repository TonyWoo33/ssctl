#!/usr/bin/env bash

_ssctl_completions() {
    local cur prev commands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    commands="start stop restart monitor stats latency probe add remove list logs log update doctor sub help version env clear current switch noproxy dashboard keep-alive tui"  

    _ssctl_list_nodes() {
        local node_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ssctl/nodes"
        if [ -d "$node_dir" ]; then
            find "$node_dir" -maxdepth 1 -name "*.json" -printf "%f\n" 2>/dev/null | sed 's/\.json$//'
        fi
    }

    case "${prev}" in
        ssctl)
            COMPREPLY=( $(compgen -W "${commands}" -- ${cur}) )
            return 0
            ;;
        monitor)
            local monitor_opts="--name --interval --count --tail --log --speed --stats-interval --filter --no-dns --ping --format --json --auto-switch --fail-threshold"
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "${monitor_opts}" -- ${cur}) )
            else
                COMPREPLY=( $(compgen -W "$(_ssctl_list_nodes) ${monitor_opts}" -- ${cur}) )
            fi
            return 0
            ;;
        stats)
            local stats_opts="--aggregate --format --watch --interval --json"
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "${stats_opts}" -- ${cur}) )
            else
                COMPREPLY=( $(compgen -W "$(_ssctl_list_nodes) ${stats_opts}" -- ${cur}) )
            fi
            return 0
            ;;
        logs|log)
            local logs_opts="--follow -f --lines --tail -n --filter --since --until --format --raw"
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "${logs_opts}" -- ${cur}) )
            else
                COMPREPLY=( $(compgen -W "$(_ssctl_list_nodes) ${logs_opts}" -- ${cur}) )
            fi
            return 0
            ;;
        probe)
            local probe_opts="--url --json --timeout"
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "${probe_opts}" -- ${cur}) )
            else
                COMPREPLY=( $(compgen -W "$(_ssctl_list_nodes) ${probe_opts}" -- ${cur}) )
            fi
            return 0
            ;;
        start|stop|restart|remove|switch)
            COMPREPLY=( $(compgen -W "$(_ssctl_list_nodes)" -- ${cur}) )
            return 0
            ;;
        add)
            local add_opts="--server --port --method --password --plugin --plugin-opts --engine --from-url --from-clipboard"
            COMPREPLY=( $(compgen -W "${add_opts}" -- ${cur}) )
            return 0
            ;;
        sub)
            local sub_cmds="add list remove update"
            COMPREPLY=( $(compgen -W "${sub_cmds}" -- ${cur}) )
            return 0
            ;;
        keep-alive)
            local ka_opts="--url --interval --max-strikes --stabilization"
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "${ka_opts}" -- ${cur}) )
            fi
            return 0
            ;;
        tui)
            local tui_opts="--help"
            COMPREPLY=( $(compgen -W "${tui_opts}" -- ${cur}) )
            ;;
        *)
            ;;
    esac

    local first_arg="${COMP_WORDS[1]}"
    case "${first_arg}" in
        monitor)
            local monitor_opts="--name --interval --count --tail --log --speed --stats-interval --filter --no-dns --ping --format --json --auto-switch --fail-threshold"
            COMPREPLY=( $(compgen -W "${monitor_opts}" -- ${cur}) )
            ;;
        stats)
            local stats_opts="--aggregate --format --watch --interval --json"
            COMPREPLY=( $(compgen -W "${stats_opts}" -- ${cur}) )
            ;;
        logs|log)
            local logs_opts="--follow -f --lines --tail -n --filter --since --until --format --raw"
            COMPREPLY=( $(compgen -W "${logs_opts}" -- ${cur}) )
            ;;
    esac
}

complete -F _ssctl_completions ssctl
