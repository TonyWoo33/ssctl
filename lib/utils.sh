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
    local value_plugin="" value_plugin_opts=""

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
                    value_plugin="${value%%;*}"
                    if [[ "$value" == *";"* ]]; then
                        value_plugin_opts="${value#*;}"
                    fi
                    ;;
                plugin_opts|plugin-opts)
                    if [ -n "$value_plugin_opts" ]; then
                        value_plugin_opts="${value_plugin_opts};${value}"
                    else
                        value_plugin_opts="$value"
                    fi
                    ;;
            esac
        done
    fi

    if [ -n "$out_plugin" ]; then
        printf -v "$out_plugin" '%s' "$value_plugin"
    fi
    if [ -n "$out_plugin_opts" ]; then
        printf -v "$out_plugin_opts" '%s' "$value_plugin_opts"
    fi
}

ssctl_parse_ss_uri(){
    local uri="$1"
    local out_method="$2" out_password="$3" out_server="$4" out_port="$5" out_plugin="$6" out_plugin_opts="$7" out_fragment="$8"
    [[ "$uri" == ss://* ]] || return 1
    local link_body="${uri#ss://}"
    local parsed_fragment=""
    if [[ "$link_body" == *"#"* ]]; then
        parsed_fragment="${link_body#*#}"
    fi
    parsed_fragment="$(url_decode "$parsed_fragment")"

    local without_fragment="${link_body%%#*}"
    local query=""
    if [[ "$without_fragment" == *\?* ]]; then
        query="${without_fragment#*\?}"
    fi
    local core_part="${without_fragment%%\?*}"

    local decoded_cred
    decoded_cred="$(urlsafe_b64_decode "$core_part" || true)"
    if [[ "$decoded_cred" != *@* ]]; then
        decoded_cred="$core_part"
    fi
    decoded_cred="${decoded_cred//$'\r'/}"

    local ss_method ss_password host_port
    ss_method="${decoded_cred%%:*}"
    local rest="${decoded_cred#*:}"
    ss_password="${rest%%@*}"
    host_port="${rest#*@}"
    local ss_server ss_port
    if [[ "$host_port" == \[*\]*:* ]]; then
        ss_server="${host_port%%]*}"
        ss_server="${ss_server#[}"
        ss_port="${host_port##*]:}"
    else
        ss_server="${host_port%%:*}"
        ss_port="${host_port##*:}"
    fi
    [ -n "$ss_method" ] && [ -n "$ss_password" ] && [ -n "$ss_server" ] && [ -n "$ss_port" ] || return 1

    local parsed_plugin="" parsed_plugin_opts=""
    parse_plugin_params "$query" parsed_plugin parsed_plugin_opts

    [ -n "$out_method" ] && printf -v "$out_method" '%s' "$ss_method"
    [ -n "$out_password" ] && printf -v "$out_password" '%s' "$ss_password"
    [ -n "$out_server" ] && printf -v "$out_server" '%s' "$ss_server"
    [ -n "$out_port" ] && printf -v "$out_port" '%s' "$ss_port"
    [ -n "$out_plugin" ] && printf -v "$out_plugin" '%s' "$parsed_plugin"
    [ -n "$out_plugin_opts" ] && printf -v "$out_plugin_opts" '%s' "$parsed_plugin_opts"
    [ -n "$out_fragment" ] && printf -v "$out_fragment" '%s' "$parsed_fragment"
    return 0
}

ssctl_build_node_json(){
    local name="$1" server="$2" port="$3" method="$4" password="$5" laddr="$6" lport="$7"
    local engine="${8:-auto}" plugin="${9:-}" plugin_opts="${10:-}"
    jq -n \
      --arg name "$name" \
      --arg server "$server" \
      --argjson server_port "$port" \
      --arg method "$method" \
      --arg password "$password" \
      --arg laddr "$laddr" \
      --argjson lport "$lport" \
      --arg engine "$engine" \
      --arg plugin "$plugin" \
      --arg plugin_opts "$plugin_opts" \
      '{
         name:$name,
         server:$server,
         server_port:$server_port,
         method:$method,
         password:$password,
         local_address:$laddr,
         local_port:$lport,
         engine:$engine
       }
       + (if ($plugin|length)>0 then {plugin:$plugin} else {} end)
       + (if ($plugin_opts|length)>0 then {plugin_opts:$plugin_opts} else {} end)'
}

ssctl_measure_http(){
    local laddr="$1" lport="$2" url="$3" socks_mode="${4:-hostname}"
    local flag="--socks5-hostname"
    if [ "$socks_mode" = "ip" ]; then
        flag="--socks5"
    fi
    curl -sS -o /dev/null -w '%{time_connect} %{time_starttransfer} %{time_total} %{speed_download} %{http_code}' \
      --connect-timeout 5 --max-time 10 \
      ${flag} "${laddr}:${lport}" \
      "${url}" 2>/dev/null
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
