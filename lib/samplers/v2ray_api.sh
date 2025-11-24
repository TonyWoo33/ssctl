#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

if [ -z "${SSCTL_LIB_DIR:-}" ]; then
  SSCTL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

if ! declare -f die >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  . "${SSCTL_LIB_DIR}/lib/common.sh"
fi

if ! declare -f ssctl_service_is_active >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  . "${SSCTL_LIB_DIR}/lib/service.sh"
fi

sampler_v2ray_api_collect(){
  local node_json="${1:?sampler_v2ray_api_collect 需要 node_json}"
  local epoch="${2:-0}"
  local cache_dir="${3:-}"
  local sampler_config="${4:-}"

  local name
  name="$(jq -r '.__name // empty' <<<"$node_json")"
  [ -n "$name" ] || die "sampler_v2ray_api_collect: 缺少 __name"

  local unit
  unit="$(unit_name_from_json "$node_json")"
  local rtt="-" pid=0 note="" warming=0

  local api_port
  api_port="$(printf '%s\n' "$sampler_config" | awk -F= '$1=="SAMPLER_API_PORT"{print $2; exit}')"
  [ -n "$api_port" ] || api_port="10085"
  local api_addr="127.0.0.1:${api_port}"

  local stats_tag
  stats_tag="$(jq -r '.v2ray_stats_tag // empty' <<<"$node_json")"
  if [ -z "$stats_tag" ]; then
    note="缺少 v2ray_stats_tag"
    echo "$name|0|0|0|0|0|0|$rtt|$pid|0|$note"
    return 0
  fi

  if ! ssctl_service_is_active "$unit"; then
    ssctl_service_cache_unit_states "$unit"
  fi

  if ! ssctl_service_is_active "$unit"; then
    echo "$name|0|0|0|0|0|0|$rtt|$pid|0|V2Ray unit not active"
    return 0
  fi

  pid="$(ssctl_service_get_pid "$name" "$unit" 2>/dev/null || true)"

  local pattern="user>>>${stats_tag}>>>traffic>>>"
  local post_data
  post_data="$(jq -n --arg pattern "$pattern" '{pattern:$pattern, reset:false}')"

  local tmp_body
  tmp_body="$(mktemp)"
  local http_code
  http_code="$(curl --connect-timeout 2 -sS -o "$tmp_body" -w '%{http_code}' -H 'Content-Type: application/json' -X POST "http://${api_addr}/v4/stats/query" -d "$post_data" 2>/dev/null || true)"
  local body
  if [ -s "$tmp_body" ]; then
    body="$(cat "$tmp_body")"
  else
    body=""
  fi
  rm -f "$tmp_body"
  if [ -z "$http_code" ]; then
    http_code="000"
  fi

  if [ "$http_code" != "200" ] || [ -z "$body" ]; then
    note="V2Ray API error ${http_code}"
    echo "$name|0|0|0|0|0|0|$rtt|$pid|0|$note"
    return 0
  fi

  local tx_bytes rx_bytes
  tx_bytes="$(jq -r '.stat[]? | select(.name|test("downlink$")) | .value' <<<"$body" | head -n1)"
  rx_bytes="$(jq -r '.stat[]? | select(.name|test("uplink$")) | .value' <<<"$body" | head -n1)"
  tx_bytes="${tx_bytes:-0}"
  rx_bytes="${rx_bytes:-0}"

  local rate_data
  rate_data="$(sampler_calc_rates "$name" "$epoch" "$cache_dir" "$tx_bytes" "$rx_bytes")"
  read -r tx_rate rx_rate total_rate warming <<<"$rate_data"

  echo "$name|1|$tx_rate|$rx_rate|$total_rate|$tx_bytes|$rx_bytes|$rtt|$pid|$warming|V2Ray API"
}
