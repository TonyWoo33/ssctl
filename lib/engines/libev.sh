#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

__ssctl_engine_libev_bootstrap(){
  local engine_dir base_dir
  engine_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  base_dir="$(dirname "$engine_dir")"

  if ! declare -f die >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    . "${base_dir}/common.sh"
  fi
  if ! declare -f engine_shadowsocks_get_service_def >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    . "${engine_dir}/shadowsocks.sh"
  fi
}
__ssctl_engine_libev_bootstrap
unset -f __ssctl_engine_libev_bootstrap

engine_libev_get_service_def(){
  local node_json="${1:?engine_libev_get_service_def 需要 node_json}"
  local patched_json
  patched_json="$(jq -c '. + {engine:"libev"}' <<<"$node_json")"
  engine_shadowsocks_get_service_def "$patched_json"
}

engine_libev_get_sampler_config(){
  local _node_json="${1:-}"
  cat <<'EOF'
SAMPLER_TYPE=procfs
EOF
}
