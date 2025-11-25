#!/usr/bin/env bash

cmd_keep_alive(){
  self_check

  local interval="${1:-60}" max_strikes="${2:-3}" target_url="${DEFAULT_LATENCY_URL:-$DEFAULT_PROBE_URL}" stabilization=10

  local strikes=0
  printf '[*] Keep-alive monitor started (Interval: %ss, Max Strikes: %s)\n' "$interval" "$max_strikes"

  while true; do
    local current_name="" current_port=""
    if ! current_name="$(keep_alive_current_node_name)"; then
      warn "没有运行中的节点，${interval}s 后重试"
      sleep "$interval"
      continue
    fi
    if ! current_port="$(keep_alive_resolve_port "$current_name")"; then
      warn "无法解析节点 ${current_name} 端口，${interval}s 后重试"
      sleep "$interval"
      continue
    fi

    if keep_alive_probe "$current_port" "$target_url"; then
      if [ "$strikes" -gt 0 ]; then
        printf '[*] Recovery: %s connectivity restored\n' "$current_name"
      fi
      strikes=0
    else
      strikes=$((strikes + 1))
      printf '[!] Check failed (%s/%s) for node %s\n' "$strikes" "$max_strikes" "$current_name"
      if [ "$strikes" -ge "$max_strikes" ]; then
        printf '[!] Node deemed dead after %s strikes. Switching...\n' "$max_strikes"
        if cmd_switch --best; then
          printf '[*] Switch complete. Waiting %ss for stabilization...\n' "$stabilization"
          sleep "$stabilization"
        else
          printf '[!] Recovery failed (no nodes reachable?). Retrying in %ss...\n' "$interval"
        fi
        strikes=0
        sleep "$interval"
        continue
      fi
    fi

    sleep "$interval"
  done
}

keep_alive_current_node_name(){
  local running
  running="$(current_running_node 2>/dev/null || true)"
  if [ -n "$running" ]; then
    printf '%s\n' "$running"
    return 0
  fi
  if [ -L "${CURRENT_JSON}" ]; then
    local target
    target="$(readlink -f "${CURRENT_JSON}" 2>/dev/null || true)"
    if [ -n "$target" ] && [ -f "$target" ]; then
      basename "$target" .json
      return 0
    fi
  fi
  return 1
}

keep_alive_resolve_port(){
  local name="$1"
  local node_json port
  if ! node_json="$(nodes_json_stream "$name" 2>/dev/null || true)" || [ -z "$node_json" ]; then
    return 1
  fi
  port="$(jq -r '.local_port // empty' <<<"$node_json")"
  [ -n "$port" ] || port="$DEFAULT_LOCAL_PORT"
  printf '%s\n' "$port"
}

keep_alive_probe(){
  local port="$1" url="$2"
  curl -sS --max-time 10 --connect-timeout 5 -x "socks5h://127.0.0.1:${port}" "$url" -o /dev/null >/dev/null 2>&1
}
