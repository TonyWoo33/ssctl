#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

__ssctl_engine_shadowsocks_bootstrap(){
  local engine_dir base_dir
  engine_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  base_dir="$(dirname "$engine_dir")"

  if ! declare -f die >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    . "${base_dir}/common.sh"
  fi
  if ! declare -f node_json_path >/dev/null 2>&1 || ! declare -f pick_engine >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    . "${base_dir}/service.sh"
  fi
  if ! declare -f ssctl_default_log_path >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    . "${base_dir}/utils.sh"
  fi
}
__ssctl_engine_shadowsocks_bootstrap
unset -f __ssctl_engine_shadowsocks_bootstrap

engine_shadowsocks_get_service_def(){
  local node_json="${1:?engine_shadowsocks_get_service_def 需要 node_json}"

  local name
  name="$(jq -r '.__name // empty' <<<"$node_json")"
  [ -n "$name" ] || die "engine_shadowsocks_get_service_def: 缺少 __name"

  local json_path; json_path="$(node_json_path "$name")"
  local port; port="$(jq -r '.local_port // empty' <<<"$node_json")"
  [ -n "$port" ] || port="$DEFAULT_LOCAL_PORT"

  local engine_variant
  engine_variant="$(pick_engine "$name")"
  local exec_path
  exec_path="$(engine_binary_path "$engine_variant")"
  engine_check "$engine_variant" "$exec_path"

  local run_cfg="$json_path"
  if [ "$engine_variant" = "libev" ]; then
    run_cfg="${NODES_DIR}/_libev_${name}.json"
    local prebuilt_cfg
    prebuilt_cfg="$(jq -c '.__libev_run_config // empty' <<<"$node_json")"
    if [ -n "$prebuilt_cfg" ]; then
      printf '%s\n' "$prebuilt_cfg" > "$run_cfg"
    else
      local remote_port
      remote_port="$(jq -r '.server_port // .port // empty' "$json_path")"
      [ -n "$remote_port" ] || die "节点 ${name} 缺少 server_port/port 字段"
      jq -n \
        --arg server_port "$remote_port" \
        --arg server       "$(jq -r '.server' "$json_path")" \
        --arg password     "$(jq -r '.password' "$json_path")" \
        --arg method       "$(jq -r '.method' "$json_path")" \
        --arg laddr        "$(jq -r '.local_address // "127.0.0.1"' "$json_path")" \
        --argjson lport    "$(jq -r '.local_port // 1080' "$json_path")" \
        --arg plugin       "$(jq -r '.plugin // empty' "$json_path")" \
        --arg plugin_opts  "$(jq -r '.plugin_opts // empty' "$json_path")" \
        --argjson timeout  "$(jq -r '.timeout // 300' "$json_path")" \
        '{
           server: $server,
           server_port: ($server_port|tonumber),
           password: $password,
           method: $method,
           local_address: $laddr,
           local_port: $lport,
           timeout: $timeout
         }
         + (if ($plugin|length)>0 then {plugin:$plugin} else {} end)
         + (if ($plugin_opts|length)>0 then {plugin_opts:$plugin_opts} else {} end)' \
        > "$run_cfg"
    fi
    chmod 600 "$run_cfg"
  elif [ "$engine_variant" = "rust" ]; then
    local remote_port
    remote_port="$(jq -r '.port // .server_port // empty' "$json_path")"
    [ -n "$remote_port" ] || die "节点 ${name} 缺少 server_port/port 字段"
    run_cfg="${NODES_DIR}/_rust_${name}.json"
    jq -n \
      --arg server       "$(jq -r '.server' "$json_path")" \
      --arg server_port  "$remote_port" \
      --arg password     "$(jq -r '.password' "$json_path")" \
      --arg method       "$(jq -r '.method' "$json_path")" \
      --arg laddr        "$(jq -r '.local_address // "127.0.0.1"' "$json_path")" \
      --argjson lport    "$(jq -r '.local_port // 1080' "$json_path")" \
      --arg plugin       "$(jq -r '.plugin // empty' "$json_path")" \
      --arg plugin_opts  "$(jq -r '.plugin_opts // empty' "$json_path")" \
      --argjson timeout  "$(jq -r '.timeout // 300' "$json_path")" \
      '{
         server: $server,
         server_port: ($server_port|tonumber),
         password: $password,
         method: $method,
         local_address: $laddr,
         local_port: $lport,
         timeout: $timeout
       }
       + (if ($plugin|length)>0 then {plugin:$plugin} else {} end)
       + (if ($plugin_opts|length)>0 then {plugin_opts:$plugin_opts} else {} end)' \
      > "$run_cfg"
    chmod 600 "$run_cfg"
  fi

  local log_level="${SSCTL_LOG_LEVEL:-info}"
  local log_path
  log_path="$(ssctl_default_log_path "$name")"
  mkdir -p "$(dirname "$log_path")"
  touch "$log_path"
  chmod 600 "$log_path" 2>/dev/null || true

  local description="Shadowsocks local client (${name}:${port}, engine=${engine_variant})"
  local exec_start="\"${exec_path}\" -c \"${run_cfg}\""

  cat <<EOF
Description=${description}
ExecStart=${exec_start}
Restart=always
RestartSec=2s
Environment=SSCTL_LOG_LEVEL=${log_level}
Environment=SSCTL_LOG_PATH=${log_path}
Environment=RUST_LOG=${log_level}
ServiceOption=NoNewPrivileges=yes
ServiceOption=PrivateTmp=yes
ServiceOption=ProtectSystem=full
ServiceOption=ProtectHome=read-only
ServiceOption=UMask=0077
ServiceOption=ReadWritePaths=${CONF_DIR}
ServiceOption=RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ServiceOption=LimitNOFILE=1048576
EOF
}

engine_shadowsocks_get_sampler_config(){
  local _node_json="${1:-}"
  cat <<'EOF'
SAMPLER_TYPE=procfs
EOF
}
