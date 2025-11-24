#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

__ssctl_engine_v2ray_bootstrap(){
  local engine_dir base_dir
  engine_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  base_dir="$(dirname "$engine_dir")"

  if ! declare -f die >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    . "${base_dir}/common.sh"
  fi
  if ! declare -f ssctl_service_is_active >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    . "${base_dir}/service.sh"
  fi
}
__ssctl_engine_v2ray_bootstrap
unset -f __ssctl_engine_v2ray_bootstrap

engine_v2ray_get_service_def(){
  local node_json="${1:?engine_v2ray_get_service_def 需要 node_json}"

  local name config_path
  name="$(jq -r '.__name // empty' <<<"$node_json")"
  [ -n "$name" ] || die "engine_v2ray_get_service_def: 缺少 __name"
  config_path="$(jq -r '.config_path // empty' <<<"$node_json")"
  [ -n "$config_path" ] || die "engine_v2ray_get_service_def: 缺少 config_path"

  local description="V2Ray service (${name})"

  cat <<EOF
Description=${description}
ExecStart=v2ray run -c "${config_path}"
Restart=on-failure
RestartSec=3s
Environment=SSCTL_NODE=${name}
ServiceOption=NoNewPrivileges=yes
ServiceOption=ProtectSystem=full
ServiceOption=ProtectHome=read-only
ServiceOption=PrivateTmp=yes
ServiceOption=ReadWritePaths=${CONF_DIR}
EOF
}

engine_v2ray_get_sampler_config(){
  local node_json="${1:?engine_v2ray_get_sampler_config 需要 node_json}"
  local api_port
  api_port="$(jq -r '.sampler_api_port // "10085"' <<<"$node_json")"
  cat <<EOF
SAMPLER_TYPE=v2ray_api
SAMPLER_API_PORT=${api_port}
EOF
}
