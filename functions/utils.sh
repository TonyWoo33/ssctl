#!/usr/bin/env bash

urlsafe_b64_decode(){
    local b64
    b64=$(printf '%s' "$1" | tr -d '\r\n ' | tr -- '-_' '+/')
    # Add padding if needed
    case $(( ${#b64} % 4 )) in
        2) b64+="==" ;;
        3) b64+="=" ;;
    esac
    if printf '%s' "$b64" | base64 -d 2>/dev/null; then
        return 0
    fi
    if printf '%s' "$b64" | openssl base64 -d -A 2>/dev/null; then
        return 0
    fi
    return 1
}

# Helper for URL decoding
url_decode(){
    : "${*//%/\\x}"
    echo -e "${_//+/ }"
}

# Helper for URL encoding
url_encode(){
    local raw="$*"
    printf '%s' "$raw" | jq -sRr @uri
}

# Parse plugin-related query parameters from an ss:// URL query string.
# Usage: parse_plugin_params "query" plugin_var plugin_opts_var
parse_plugin_params(){
    local query="$1" out_plugin="$2" out_plugin_opts="$3"
    local plugin="" plugin_opts=""

    if [ -n "$query" ]; then
        local IFS='&'
        read -ra kv_pairs <<< "$query"
        for kv_pair in "${kv_pairs[@]}"; do
            [ -n "$kv_pair" ] || continue
            local key="${kv_pair%%=*}"
            local value=""
            if [[ "$kv_pair" == *=* ]]; then
                value="${kv_pair#*=}"
            fi
            value="$(url_decode "$value")"
            case "$key" in
                plugin)
                    plugin="${value%%;*}"
                    if [[ "$value" == *";"* ]]; then
                        plugin_opts="${value#*;}"
                    fi
                    ;;
                plugin_opts|plugin-opts)
                    if [ -n "$plugin_opts" ]; then
                        plugin_opts="${plugin_opts};${value}"
                    else
                        plugin_opts="$value"
                    fi
                    ;;
            esac
        done
    fi

    if [ -n "$out_plugin" ]; then
        printf -v "$out_plugin" '%s' "$plugin"
    fi
    if [ -n "$out_plugin_opts" ]; then
        printf -v "$out_plugin_opts" '%s' "$plugin_opts"
    fi
}

# Load key=value pairs from config.env once and expose as environment variables.
# Silently ignore malformed lines so local overrides stay safe.
ssctl_read_config(){
    if [ "${__SSCTL_ENV_LOADED:-0}" = "1" ]; then
        return 0
    fi
    local env_path="${SSCTL_CONFIG_ENV:-${HOME}/.config/ssctl/config.env}"
    if [ -r "$env_path" ]; then
        while IFS= read -r raw_line || [ -n "$raw_line" ]; do
            local line
            line="${raw_line%%#*}"
            line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [ -n "$line" ] || continue
            case "$line" in
                *=*)
                    local key="${line%%=*}"
                    local value="${line#*=}"
                    key="$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                    value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                    if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                        printf -v "$key" '%s' "$value"
                    fi
                    ;;
            esac
        done <"$env_path"
    fi
    __SSCTL_ENV_LOADED=1
}

# Retrieve the main PID for a node or unit. Uses systemd first and falls back to pgrep.
ssctl_unit_pid(){
    local name="$1" unit="$2" pid="" cfg=""
    [ -n "$name" ] || return 1
    if [[ "$name" == *.service ]]; then
        unit="$name"
        name=""
    elif [ -z "$unit" ] && command -v unit_name_for >/dev/null 2>&1; then
        unit="$(unit_name_for "$name")"
    fi

    if [ -n "$unit" ] && command -v systemctl >/dev/null 2>&1; then
        pid="$(systemctl --user show "$unit" -p MainPID --value 2>/dev/null | tr -d ' ' || true)"
        case "$pid" in
            ''|0) pid="" ;;
        esac
    fi

    if [ -n "$pid" ]; then
        printf '%s\n' "$pid"
        return 0
    fi

    if [ -z "$name" ]; then
        return 1
    fi

    if command -v node_json_path >/dev/null 2>&1; then
        cfg="$(node_json_path "$name" 2>/dev/null || true)"
    fi

    local patterns=()
    if [ -n "$cfg" ]; then
        patterns+=("sslocal.*${cfg}" "ss-local.*${cfg}")
    fi
    local port
    if command -v json_get >/dev/null 2>&1; then
        port="$(json_get "$name" local_port 2>/dev/null || true)"
        [ -n "$port" ] || port=""
    fi
    if [ -n "$port" ]; then
        patterns+=("sslocal.*:${port}" "ss-local.*:${port}")
    fi

    if [ ${#patterns[@]} -gt 0 ] && command -v pgrep >/dev/null 2>&1; then
        local pat
        for pat in "${patterns[@]}"; do
            pid="$(pgrep -f "$pat" 2>/dev/null | head -n1 || true)"
            [ -n "$pid" ] && { printf '%s\n' "$pid"; return 0; }
        done
    fi
    return 1
}

# Format bytes per second as integer text.
format_rate(){
    local value="${1:-0}"
    printf '%s' "$value"
}

# Format raw bytes into a human-readable unit (B/KB/MB/GB/TB).
human_bytes(){
    local bytes="${1:-0}" units=(B KB MB GB TB) idx=0
    local value="$bytes"
    while (( value >= 1024 && idx < ${#units[@]}-1 )); do
        value=$(( value / 1024 ))
        idx=$(( idx + 1 ))
    done
    printf '%s %s' "$value" "${units[$idx]}"
}

collect_proc_bytes_linux(){
    local pid="$1" port="$2"
    command -v ss >/dev/null 2>&1 || return 2
    local ss_out=""
    if [ -n "$port" ]; then
        ss_out="$(ss -tinp "( sport = :${port} )" 2>/dev/null || true)"
    else
        ss_out="$(ss -tinp 2>/dev/null || true)"
    fi
    [ -n "$ss_out" ] || return 3
    local result
    result=$(awk -v target_pid="$pid" '
        BEGIN { tx=0; rx=0; capture=0; }
        /users:\(\(/{
            capture=0;
            if (target_pid == "") {
                capture=1;
            } else if ($0 ~ ("pid=" target_pid)) {
                capture=1;
            }
            next
        }
        capture {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^bytes_acked:/) {
                    gsub(/bytes_acked:/, "", $i);
                    gsub(/,/, "", $i);
                    tx += $i + 0;
                } else if ($i ~ /^bytes_received:/) {
                    gsub(/bytes_received:/, "", $i);
                    gsub(/,/, "", $i);
                    rx += $i + 0;
                }
            }
        }
        END { printf "%s %s", tx+0, rx+0 }
    ' <<<"$ss_out") || return 4
    printf '%s\n' "$result"
}

collect_proc_bytes_macos(){
    local pid="$1"
    command -v nettop >/dev/null 2>&1 || return 2
    local sample
    sample="$(nettop -P -L 1 -x -J bytes_in,bytes_out -p "$pid" 2>/dev/null || true)"
    [ -n "$sample" ] || return 3
    local result
    result=$(awk '
        /bytes_in=/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^bytes_in=/) {
                    gsub(/bytes_in=/, "", $i);
                    gsub(/,/, "", $i);
                    rx += $i + 0;
                } else if ($i ~ /^bytes_out=/) {
                    gsub(/bytes_out=/, "", $i);
                    gsub(/,/, "", $i);
                    tx += $i + 0;
                }
            }
        }
        END { printf "%s %s", tx+0, rx+0 }
    ' <<<"$sample") || return 4
    printf '%s\n' "$result"
}

collect_proc_bytes(){
    local pid="$1" port="$2"
    local kernel
    kernel="$(uname -s 2>/dev/null || echo unknown)"
    case "$kernel" in
        Linux)
            collect_proc_bytes_linux "$pid" "$port"
            ;;
        Darwin)
            collect_proc_bytes_macos "$pid"
            ;;
        *)
            return 99
            ;;
    esac
}

ssctl_default_log_path(){
    local name="$1"
    printf '%s/logs/%s.log\n' "$CONF_DIR" "$name"
}

resolve_log_source(){
    local name="$1" unit fallback
    if [ -z "$name" ]; then
        return 1
    fi
    unit="$(unit_name_for "$name")"
    if command -v journalctl >/dev/null 2>&1; then
        if journalctl --user -u "$unit" -n 1 --no-pager >/dev/null 2>&1 || journalctl --user -u "$unit" -n 0 --no-pager >/dev/null 2>&1; then
            printf 'journal:%s\n' "$unit"
            return 0
        fi
    fi
    fallback="${SSCTL_LOG_PATH:-$(ssctl_default_log_path "$name")}"
    printf 'file:%s\n' "$fallback"
}

parse_ssr_line(){
    local message="$1"
    local protocol="" action="" target_host="" target_port="" src_host="" src_port="" method=""

    if [[ "$message" =~ ^TCP[[:space:]]+CONNECT[[:space:]]+([^[:space:]]+):([0-9]+)[[:space:]]+from[[:space:]]+([^[:space:]]+):([0-9]+) ]]; then
        protocol="tcp"
        action="connect"
        target_host="${BASH_REMATCH[1]}"
        target_port="${BASH_REMATCH[2]}"
        src_host="${BASH_REMATCH[3]}"
        src_port="${BASH_REMATCH[4]}"
    elif [[ "$message" =~ ^UDP[[:space:]]+ASSOCIATE[[:space:]]+([^[:space:]]+):([0-9]+) ]]; then
        protocol="udp"
        action="associate"
        target_host="${BASH_REMATCH[1]}"
        target_port="${BASH_REMATCH[2]}"
        if [[ "$message" =~ from[[:space:]]+([^[:space:]]+):([0-9]+) ]]; then
            src_host="${BASH_REMATCH[1]}"
            src_port="${BASH_REMATCH[2]}"
        fi
    elif [[ "$message" =~ ^TCP[[:space:]]+FORWARD[[:space:]]+([^[:space:]]+):([0-9]+) ]]; then
        protocol="tcp"
        action="forward"
        target_host="${BASH_REMATCH[1]}"
        target_port="${BASH_REMATCH[2]}"
    fi

    if [[ "$message" =~ method[=:][[:space:]]*([A-Za-z0-9_-]+) ]]; then
        method="${BASH_REMATCH[1]}"
    fi

    jq -n \
        --arg protocol "$protocol" \
        --arg action "$action" \
        --arg target_host "$target_host" \
        --arg target_port "$target_port" \
        --arg source_host "$src_host" \
        --arg source_port "$src_port" \
        --arg method "$method" \
        '{
            protocol: (if ($protocol|length) > 0 then $protocol else null end),
            action: (if ($action|length) > 0 then $action else null end),
            target_host: (if ($target_host|length) > 0 then $target_host else null end),
            target_port: (if ($target_port|length) > 0 then ($target_port|tonumber) else null end),
            source_host: (if ($source_host|length) > 0 then $source_host else null end),
            source_port: (if ($source_port|length) > 0 then ($source_port|tonumber) else null end),
            method: (if ($method|length) > 0 then $method else null end)
        }'
}
