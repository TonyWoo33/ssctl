#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

__ssctl_engine_hysteria2_bootstrap(){
  local engine_dir base_dir
  engine_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  base_dir="$(dirname "$engine_dir")"

  if ! declare -f die >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    . "${base_dir}/common.sh"
  fi
}
__ssctl_engine_hysteria2_bootstrap
unset -f __ssctl_engine_hysteria2_bootstrap

engine_hysteria2_get_sampler_config(){
  local node_json="${1:?engine_hysteria2_get_sampler_config 需要 node_json}"
  local local_port
  local_port="$(jq -r '.local_port // empty' <<<"$node_json")"
  if [ -z "$local_port" ]; then
    local_port="${DEFAULT_LOCAL_PORT:-1080}"
  fi

  cat <<EOF
SAMPLER_TYPE=procfs
SAMPLER_SOCKS5_PORT=${local_port}
EOF
}

engine_hysteria2_get_service_def(){
  local node_json="${1:?engine_hysteria2_get_service_def 需要 node_json}"

  local name server server_port password local_port up_mbps down_mbps local_address
  local sni peer
  name="$(jq -r '.__name // empty' <<<"$node_json")"
  [ -n "$name" ] || die "engine_hysteria2_get_service_def: 缺少 __name"

  server="$(jq -r '.server // empty' <<<"$node_json")"
  [ -n "$server" ] || die "engine_hysteria2_get_service_def: 节点 ${name} 缺少 server"

  server_port="$(jq -r '.server_port // .port // empty' <<<"$node_json")"
  [ -n "$server_port" ] || die "engine_hysteria2_get_service_def: 节点 ${name} 缺少 server_port"

  password="$(jq -r '.password // .auth // empty' <<<"$node_json")"
  [ -n "$password" ] || die "engine_hysteria2_get_service_def: 节点 ${name} 缺少 password/auth"

  local_port="$(jq -r '.local_port // empty' <<<"$node_json")"
  if [ -z "$local_port" ]; then
    local_port="${DEFAULT_LOCAL_PORT:-1080}"
  fi
  local_address="$(jq -r '.local_address // "127.0.0.1"' <<<"$node_json")"

  up_mbps="$(jq -r '.up_mbps // empty' <<<"$node_json")"
  [ -n "$up_mbps" ] || up_mbps="10"
  down_mbps="$(jq -r '.down_mbps // empty' <<<"$node_json")"
  [ -n "$down_mbps" ] || down_mbps="50"

  sni="$(jq -r '.sni // .server_name // empty' <<<"$node_json")"
  peer="$(jq -r '.peer // empty' <<<"$node_json")"

  local nodes_dir config_path
  nodes_dir="${NODES_DIR:?engine_hysteria2_get_service_def: NODES_DIR 未定义}"
  mkdir -p "$nodes_dir"
  config_path="${nodes_dir}/_hy2_${name}.yaml"

  local server_endpoint="$server"
  if [[ "$server" == *:* ]] && [[ "$server" != \[*] ]]; then
    server_endpoint="[${server}]"
  fi
  server_endpoint="${server_endpoint}:${server_port}"

  cat <<EOF >"$config_path"
server: ${server_endpoint}
auth: ${password}
bandwidth:
  up: ${up_mbps} mbps
  down: ${down_mbps} mbps
socks5:
  listen: ${local_address}:${local_port}
EOF

  if [ -n "$sni" ] || [ -n "$peer" ]; then
    {
      echo "tls:"
      [ -n "$sni" ] && printf '  sni: %s\n' "$sni"
      [ -n "$peer" ] && printf '  peer: %s\n' "$peer"
    } >>"$config_path"
  fi

  chmod 600 "$config_path" 2>/dev/null || true

  local hysteria_bin description exec_start
  hysteria_bin="$(command -v hysteria 2>/dev/null || true)"
  [ -x "$hysteria_bin" ] || die "engine_hysteria2_get_service_def: 未找到 hysteria 客户端，请先安装。"

  description="Hysteria2 client (${name}:${local_port})"
  exec_start="\"${hysteria_bin}\" client -c \"${config_path}\""

  cat <<EOF
Description=${description}
ExecStart=${exec_start}
Restart=always
RestartSec=3s
Environment=SSCTL_NODE=${name}
ServiceOption=NoNewPrivileges=yes
ServiceOption=ProtectSystem=full
ServiceOption=ProtectHome=read-only
ServiceOption=PrivateTmp=yes
ServiceOption=UMask=0077
ServiceOption=ReadWritePaths=${CONF_DIR}
ServiceOption=ReadWritePaths=${nodes_dir}
EOF
}
