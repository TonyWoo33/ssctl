#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

sampler_cache_read(){
  local name="${1:?sampler_cache_read 需要 name}" cache_dir="${2:?sampler_cache_read 需要 cache_dir}"
  local file="${cache_dir}/${name}.cache"
  if [ -r "$file" ]; then
    read -r ts tx rx <"$file" || true
    printf '%s %s %s\n' "${ts:-0}" "${tx:-0}" "${rx:-0}"
    return 0
  fi
  printf '0 0 0\n'
}

sampler_cache_write(){
  local name="${1:?sampler_cache_write 需要 name}" cache_dir="${2:?sampler_cache_write 需要 cache_dir}"
  local epoch="${3:?sampler_cache_write 需要 epoch}" tx="${4:-0}" rx="${5:-0}"
  local file="${cache_dir}/${name}.cache"
  printf '%s %s %s\n' "$epoch" "$tx" "$rx" >"$file"
}

sampler_calc_rates(){
  local name="${1:?sampler_calc_rates 需要 name}"
  local epoch="${2:?sampler_calc_rates 需要 epoch}"
  local cache_dir="${3:?sampler_calc_rates 需要 cache_dir}"
  local tx_bytes="${4:-0}" rx_bytes="${5:-0}"

  local prev_ts prev_tx prev_rx warming=0
  read -r prev_ts prev_tx prev_rx <<<"$(sampler_cache_read "$name" "$cache_dir")"

  sampler_cache_write "$name" "$cache_dir" "$epoch" "$tx_bytes" "$rx_bytes"

  local tx_rate=0 rx_rate=0 total_rate=0
  if [ "$prev_ts" -gt 0 ] && [ "$epoch" -gt "$prev_ts" ] \
     && [ "$tx_bytes" -ge "$prev_tx" ] && [ "$rx_bytes" -ge "$prev_rx" ]; then
    local delta_tx=$(( tx_bytes - prev_tx ))
    local delta_rx=$(( rx_bytes - prev_rx ))
    local delta_t=$(( epoch - prev_ts ))
    [ "$delta_t" -gt 0 ] || delta_t=1
    tx_rate=$(( delta_tx / delta_t ))
    rx_rate=$(( delta_rx / delta_t ))
  else
    warming=1
  fi
  total_rate=$(( tx_rate + rx_rate ))

  printf '%s %s %s %s\n' "$tx_rate" "$rx_rate" "$total_rate" "$warming"
}
