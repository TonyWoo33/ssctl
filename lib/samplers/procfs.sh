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

sampler_procfs_collect(){
  local node_json="${1:?sampler_procfs_collect 需要 node_json}"
  local epoch="${2:-0}"
  local cache_dir="${3:-}"
  local _sampler_config="${4:-}"

  local name lport unit pid metrics rc note="" valid=0 warming=0
  local tx_bytes=0 rx_bytes=0 tx_rate=0 rx_rate=0 total_rate=0 rtt="-"

  name="$(jq -r '.__name' <<<"$node_json")"
  lport="$(jq -r '.local_port // empty' <<<"$node_json")"; [ -n "$lport" ] || lport="$DEFAULT_LOCAL_PORT"
  unit="$(unit_name_from_json "$node_json")"

  pid=""
  local unit_active=0
  if ssctl_service_is_active "$unit"; then
    unit_active=1
  fi
  pid="$(ssctl_service_get_pid "$name" "$unit" "$lport" 2>/dev/null || true)"
  if [ "$unit_active" -eq 0 ] && [ -n "$pid" ]; then
    unit_active=1
  fi
  if [ "$unit_active" -eq 0 ] || [ -z "$pid" ]; then
    note="unit inactive或PID不可用"
    echo "$name|0|0|0|0|0|0|$rtt|${pid:-0}|0|$note"
    return 0
  fi

  metrics="$(collect_proc_bytes "$pid" "$lport" 2>/dev/null)"
  rc=$?
  if [ $rc -ne 0 ]; then
    if [ $rc -eq 3 ]; then
      note="当前无活跃连接"
      tx_bytes="$prev_tx"
      rx_bytes="$prev_rx"
    else
      case $rc in
        2) note="缺少 ss/nettop 支持" ;;
        4) note="解析网络统计失败" ;;
        99) note="当前平台不支持采样" ;;
        *) note="采样失败 (code=$rc)" ;;
      esac
      echo "$name|0|0|0|0|0|0|$rtt|$pid|0|$note"
      return 0
    fi
  fi

  if [ $rc -eq 0 ]; then
    read -r tx_bytes rx_bytes <<<"$metrics"
  fi
  tx_bytes="${tx_bytes:-0}"
  rx_bytes="${rx_bytes:-0}"

  local rate_data
  rate_data="$(sampler_calc_rates "$name" "$epoch" "$cache_dir" "$tx_bytes" "$rx_bytes")"
  read -r tx_rate rx_rate total_rate warming <<<"$rate_data"
  valid=1
  echo "$name|$valid|$tx_rate|$rx_rate|$total_rate|$tx_bytes|$rx_bytes|$rtt|$pid|$warming|$note"
}
