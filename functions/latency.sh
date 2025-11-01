#!/usr/bin/env bash

cmd_latency(){
  self_check
  local url="${1:-$DEFAULT_LATENCY_URL}"
  info "正在测试所有节点的延迟... URL: ${url}"

  local W_NAME=22 W_LATENCY=10
  local TOTAL=$((W_NAME+2 + W_LATENCY))

  printf '%s' "$C_BOLD"
  printf "%-${W_NAME}s  %-${W_LATENCY}s\n" "NAME" "LATENCY (ms)"
  printf '%s' "$C_RESET"
  _hr "$TOTAL"

  local results=""
  for n in $(list_nodes); do
    local laddr lport
    laddr="$(json_get "$n" local_address)"; [ -n "$laddr" ] || laddr="$DEFAULT_LOCAL_ADDR"
    lport="$(json_get "$n" local_port)";   [ -n "$lport" ] || lport="$DEFAULT_LOCAL_PORT"
    
    local latency_s
    latency_s=$(curl -sS -o /dev/null -w '%{time_connect}' --socks5-hostname "${laddr}:${lport}" --connect-timeout 3 "${url}" || echo "9999")
    
    local latency_ms
    latency_ms=$(awk -v s="$latency_s" 'BEGIN { printf "%.0f", s * 1000 }')

    results+="${latency_ms} ${n}\n"
  done

  # Sort and print results
  echo -e "$results" | sort -n | while read -r lat_ms name; do
    if [ "$lat_ms" -ge 3000 ]; then
      printf "%-${W_NAME}s  %s\n" "$(_ellipsis "$name" "$W_NAME")" "${C_RED}TIMEOUT${C_RESET}"
    else
      printf "%-${W_NAME}s  %s\n" "$(_ellipsis "$name" "$W_NAME")" "${lat_ms} ms"
    fi
  done

  _hr "$TOTAL"
}
