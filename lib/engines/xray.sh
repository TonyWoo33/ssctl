#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

__ssctl_engine_xray_bootstrap(){
  local engine_dir base_dir
  engine_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  base_dir="$(dirname "$engine_dir")"

  if ! declare -f die >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    . "${base_dir}/common.sh"
  fi
}
__ssctl_engine_xray_bootstrap
unset -f __ssctl_engine_xray_bootstrap

engine_xray_compat_check(){
  if ! command -v xray >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

engine_xray_get_service_def(){
  local node_json="${1:?engine_xray_get_service_def 需要 node_json}"

  local name port config_path description
  name="$(jq -r '.__name // empty' <<<"$node_json")"
  [ -n "$name" ] || die "engine_xray_get_service_def: 缺少 __name"

  port="$(jq -r '.local_port // empty' <<<"$node_json")"
  [ -n "$port" ] || port="${DEFAULT_LOCAL_PORT:-1080}"

  config_path="${NODES_DIR}/_xray_${name}.json"
  description="Xray VLESS client (${name}:${port})"

  cat <<EOF
Description=${description}
ExecStart=xray run -c "${config_path}"
Restart=always
RestartSec=5s
Environment=XRAY_LOCATION_ASSET=${NODES_DIR}
ServiceOption=NoNewPrivileges=yes
ServiceOption=ProtectSystem=full
ServiceOption=ProtectHome=read-only
ServiceOption=PrivateTmp=yes
ServiceOption=ReadWritePaths=${CONF_DIR}
EOF
}

engine_xray_pre_start(){
  local node_json_file="${SSCTL_NODE_JSON:-}"
  local node_name="${SSCTL_NODE_NAME:-}"
  if [ -z "$node_json_file" ] || [ ! -f "$node_json_file" ]; then
    if [ -n "$node_name" ]; then
      node_json_file="${NODES_DIR}/${node_name}.json"
    fi
  fi
  [ -n "$node_json_file" ] && [ -f "$node_json_file" ] || die "engine_xray_pre_start: 无法确定节点配置文件"

  if [ -z "$node_name" ]; then
    node_name="$(jq -r '.__name // empty' "$node_json_file" 2>/dev/null || true)"
  fi
  [ -n "$node_name" ] || node_name="unknown"

  local local_port="${SSCTL_LOCAL_PORT:-${DEFAULT_LOCAL_PORT:-1080}}"
  local config_path="${NODES_DIR}/_xray_${node_name}.json"
  engine_xray_generate_config "$node_json_file" "$config_path" "$local_port"
  echo "Generated Xray config at $config_path"
}

engine_xray_generate_config(){
  local node_json_file="${1:?engine_xray_generate_config 需要 node_json_file}"
  local output_file="${2:?engine_xray_generate_config 需要 output_file}"
  local local_port="${3:-${DEFAULT_LOCAL_PORT:-1080}}"

  local server port uuid flow servername fingerprint public_key short_id
  server="$(jq -r '.server // empty' "$node_json_file")"
  [ -n "$server" ] || die "engine_xray_generate_config: 缺少 server"
  port="$(jq -r '.port // .server_port // empty' "$node_json_file")"
  [ -n "$port" ] || port="443"
  uuid="$(jq -r '.uuid // empty' "$node_json_file")"
  [ -n "$uuid" ] || die "engine_xray_generate_config: 缺少 uuid"
  flow="$(jq -r '.flow // empty' "$node_json_file")"
  servername="$(jq -r '.servername // .server_name // .server // empty' "$node_json_file")"
  fingerprint="$(jq -r '.fingerprint // "chrome"' "$node_json_file")"
  public_key="$(jq -r '.publicKey // .public_key // empty' "$node_json_file")"
  short_id="$(jq -r '.shortId // .short_id // ""' "$node_json_file")"

  jq -n \
    --arg server "$server" \
    --argjson port "$port" \
    --argjson local_port "$local_port" \
    --arg uuid "$uuid" \
    --arg flow "$flow" \
    --arg servername "$servername" \
    --arg fingerprint "$fingerprint" \
    --arg public_key "$public_key" \
    --arg short_id "$short_id" \
    'def maybe_flow($f): if ($f|length)>0 then {flow:$f} else {} end;
      {
        log: {loglevel: "warning"},
        inbounds: [
          {
            port: ($local_port|tonumber),
            listen: "127.0.0.1",
            protocol: "socks",
            settings: {udp: true}
          }
        ],
        outbounds: [
          {
            protocol: "vless",
            settings: {
              vnext: [
                {
                  address: $server,
                  port: ($port|tonumber),
                  users: [
                    ({id: $uuid, encryption: "none"} + maybe_flow($flow))
                  ]
                }
              ]
            },
            streamSettings: {
              network: "tcp",
              security: "reality",
              realitySettings: {
                fingerprint: ($fingerprint // "chrome"),
                serverName: $servername,
                publicKey: $public_key,
                shortId: $short_id
              }
            }
          }
        ]
      }
    ' >"$output_file"
}
