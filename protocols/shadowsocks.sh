#!/usr/bin/env bash
set -Eeuo pipefail

protocol_shadowsocks_get_unit_name(){
  local node_json="$1"
  local name port
  name="$(jq -r '.__name' <<<"$node_json")"
  [ -n "$name" ] || die "protocol_shadowsocks_get_unit_name: 缺少 __name"
  port="$(jq -r '.local_port // empty' <<<"$node_json")"
  [ -n "$port" ] || port="$DEFAULT_LOCAL_PORT"
  printf "sslocal-%s-%s.service\n" "$name" "$port"
}

protocol_shadowsocks_generate_unit_content(){
  local node_json="$1"
  local name
  name="$(jq -r '.__name' <<<"$node_json")"
  [ -n "$name" ] || die "protocol_shadowsocks_generate_unit_content: 缺少 __name"

  local json_path; json_path="$(node_json_path "$name")"
  local unit_name; unit_name="$(protocol_shadowsocks_get_unit_name "$node_json")"
  local port; port="$(jq -r '.local_port // empty' <<<"$node_json")"; [ -n "$port" ] || port="$DEFAULT_LOCAL_PORT"

  local engine; engine="$(pick_engine "$name")"
  local exec_path; exec_path="$(engine_binary_path "$engine")"
  engine_check "$engine" "$exec_path"
  if [ "$engine" = "libev" ] && [ ! -x "$exec_path" ]; then
    die "需要 shadowsocks-libev：未找到 ss-local。请先安装：sudo apt install -y shadowsocks-libev"
  fi

  local run_cfg="$json_path"
  if [ "$engine" = "libev" ]; then
    run_cfg="${NODES_DIR}/_libev_${name}.json"
    jq -n \
      --argjson server_port "$(jq -r '.server_port' "$json_path")" \
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
         server_port: $server_port,
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

  cat <<EOF
[Unit]
Description=Shadowsocks local client (${name}:${port}, engine=${engine})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart="${exec_path}" -c "${run_cfg}"
Restart=always
RestartSec=2s
Environment=SSCTL_LOG_LEVEL=${log_level}
Environment=SSCTL_LOG_PATH=${log_path}
Environment=RUST_LOG=${log_level}

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=read-only
UMask=0077
ReadWritePaths=${CONF_DIR}
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

LimitNOFILE=1048576

[Install]
WantedBy=default.target
EOF
}
