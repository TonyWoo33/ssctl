#!/usr/bin/env bash

draw_at(){
  local row="$1" col="$2" text="$3"
  tput cup "$row" "$col"
  printf "%s" "$text"
}

draw_box(){
  local row="$1" col="$2" width="$3" height="$4" title="$5"
  local horiz i
  horiz=$(printf '%*s' $((width-2)) '' | tr ' ' '-')
  draw_at "$row" "$col" "+${horiz}+"
  for ((i=1;i<height-1;i++)); do
    draw_at $((row+i)) "$col" "|"
    draw_at $((row+i)) $((col+width-1)) "|"
  done
  draw_at $((row+height-1)) "$col" "+${horiz}+"
  if [ -n "$title" ]; then
    draw_at "$row" $((col+2)) "[$title]"
  fi
}

draw_bar(){
  local row="$1" col="$2" width="$3" percent="$4"
  local inner=$((width-2))
  local filled=$(( (percent*inner)/100 ))
  ((filled>inner)) && filled="$inner"
  if [ "$percent" -gt 0 ] && [ "$filled" -le 0 ]; then
    filled=1
  fi
  ((filled<0)) && filled=0
  local filled_part empty_part
  filled_part=$(printf '%*s' "$filled" '' | tr ' ' '#')
  empty_part=$(printf '%*s' $((inner-filled)) '' | tr ' ' ' ')
  draw_at "$row" "$col" "[${filled_part}${empty_part}]"
}

cmd_dashboard(){
  self_check

  local target_name
  target_name="$(resolve_name "${1:-}")"

  local node_json
  if ! node_json="$(nodes_json_stream "$target_name")"; then
    die "无法读取节点配置：$target_name"
  fi
  local unit; unit="$(unit_name_from_json "$node_json")"
  local local_port
  local_port="$(jq -r '.local_port // empty' <<<"$node_json")"
  [ -n "$local_port" ] || local_port="$DEFAULT_LOCAL_PORT"

  ssctl_service_cache_unit_states
  local PID
  PID="$(ssctl_service_get_pid "$target_name" "$unit" "$local_port" 2>/dev/null || true)"
  [ -n "$PID" ] || die "节点 ${target_name} 未运行，请先执行：ssctl start ${target_name}"

  dashboard_iface="$(dashboard_detect_iface)"
  [ -n "$dashboard_iface" ] || die "无法检测网络接口"

  trap 'dashboard_cleanup; exit 0' INT TERM EXIT
  trap 'dashboard_resize_request=1' WINCH
  tput civis
  tput clear

  local prev_rx=0 prev_tx=0 initialized=0 dashboard_resize_request=0 peak_rx=1024
  dashboard_draw_static "$target_name" "$unit"

  while true; do
    if dashboard_poll_input; then
      break
    fi
    if [ "${dashboard_resize_request:-0}" -eq 1 ]; then
      tput clear
      dashboard_draw_static "$target_name" "$unit"
      dashboard_resize_request=0
    fi

    local rx_bytes tx_bytes
    dashboard_read_iface_bytes "$dashboard_iface" rx_bytes tx_bytes
    rx_bytes="${rx_bytes:-0}"
    tx_bytes="${tx_bytes:-0}"

    local rx_rate="0 B/s" tx_rate="0 B/s" activity_pct=0
    if [ "$initialized" -eq 1 ]; then
      local rx_delta=$((rx_bytes - prev_rx))
      local tx_delta=$((tx_bytes - prev_tx))
      ((rx_delta<0)) && rx_delta=0
      ((tx_delta<0)) && tx_delta=0
      if [ "$rx_delta" -gt "$peak_rx" ]; then
        peak_rx="$rx_delta"
      fi
      rx_rate="$(dashboard_format_rate "$rx_delta")"
      tx_rate="$(dashboard_format_rate "$tx_delta")"
      activity_pct="$(dashboard_rate_percent "$rx_delta" "$peak_rx")"
    else
      initialized=1
    fi
    prev_rx="$rx_bytes"
    prev_tx="$tx_bytes"

    local uptime_str="-"
    if [ -n "${PID:-}" ]; then
      local val
      val="$(ps -p "$PID" -o etime= 2>/dev/null | sed 's/^[ \t]*//')"
      [ -n "$val" ] && uptime_str="$val"
    fi
    dashboard_draw_traffic_box "$rx_rate" "$tx_rate" "$activity_pct" "$peak_rx"
    dashboard_draw_status_box "$uptime_str"
    draw_at 2 2 "Uptime: ${uptime_str}            "
    dashboard_draw_logs_box "$unit"

    sleep 1
  done
}

dashboard_cleanup(){
  tput cnorm
  tput clear
}

dashboard_draw_static(){
  local name="$1" unit="$2"
  draw_box 0 0 80 4 "SSCTL DASHBOARD"
  draw_box 5 0 40 6 "Traffic"
  draw_box 5 40 40 6 "Status"
  draw_box 12 0 80 6 "Logs"

  draw_at 1 2 "Node: ${name}"
  draw_at 1 42 "Unit: ${unit}"
  draw_at 2 2 "Uptime: calculating..."
  draw_at 18 2 "[q] Quit    (Ctrl+C 强制退出)"
}

dashboard_poll_input(){
  local key=""
  if read -rsn1 -t 0.05 key; then
    case "$key" in
      q|Q) return 0 ;;
    esac
  fi
  return 1
}

dashboard_detect_iface(){
  local ifname
  ifname="$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1);exit}}}')"
  [ -n "$ifname" ] || ifname="$(ip route show default 2>/dev/null | awk '/dev/{print $5;exit}')"
  [ -n "$ifname" ] || ifname="eth0"
  printf '%s\n' "$ifname"
}

dashboard_read_iface_bytes(){
  local iface="$1" rx_var="$2" tx_var="$3"
  local rx_path="/sys/class/net/${iface}/statistics/rx_bytes"
  local tx_path="/sys/class/net/${iface}/statistics/tx_bytes"
  local rx=0 tx=0
  [ -r "$rx_path" ] && rx="$(cat "$rx_path" 2>/dev/null || echo 0)"
  [ -r "$tx_path" ] && tx="$(cat "$tx_path" 2>/dev/null || echo 0)"
  printf -v "$rx_var" '%s' "${rx:-0}"
  printf -v "$tx_var" '%s' "${tx:-0}"
}

dashboard_format_rate(){
  local bytes="${1:-0}"
  local units=("B/s" "KB/s" "MB/s" "GB/s")
  local value="$bytes" idx=0
  while [ "$value" -ge 1024 ] && [ "$idx" -lt 3 ]; do
    value=$((value / 1024))
    idx=$((idx+1))
  done
  printf '%s %s' "$value" "${units[$idx]}"
}

dashboard_rate_percent(){
  local bytes="${1:-0}" peak="${2:-1024}"
  [ "$peak" -gt 0 ] || peak=1024
  local pct=$((bytes * 100 / peak))
  ((pct>100)) && pct=100
  if [ "$bytes" -gt 0 ] && [ "$pct" -eq 0 ]; then
    pct=5
  fi
  printf '%s' "$pct"
}

dashboard_draw_traffic_box(){
  local rx="$1" tx="$2" pct="$3" peak="$4"
  draw_at 6 2 "RX: ${rx}            "
  draw_at 7 2 "TX: ${tx}            "
  draw_at 8 2 "Activity:"
  draw_bar 8 12 20 "$pct"
  draw_at 9 12 "$(printf '(Peak: %s)' "$(dashboard_format_rate "$peak")")"
}

dashboard_draw_status_box(){
  local uptime_str="$1"
  local conn_count latency
  conn_count="$(dashboard_conn_count)"
  latency="$(dashboard_probe_latency)"
  draw_at 6 42 "Connections: ${conn_count}      "
  draw_at 7 42 "Latency(8.8.8.8): ${latency} ms      "
  draw_at 8 42 "Proc Uptime: ${uptime_str}          "
}

dashboard_conn_count(){
  if command -v ss >/dev/null 2>&1; then
    ss -tun state established 2>/dev/null | tail -n +2 | wc -l | tr -d ' '
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tun 2>/dev/null | awk '$6=="ESTABLISHED"' | wc -l | tr -d ' '
  else
    echo "N/A"
  fi
}

dashboard_probe_latency(){
  local start end delta
  start=$(date +%s%3N)
  if timeout 1 bash -c "cat < /dev/null > /dev/tcp/8.8.8.8/53" >/dev/null 2>&1; then
    end=$(date +%s%3N)
    delta=$((end-start))
    printf '%s' "$delta"
  else
    echo "timeout"
  fi
}

dashboard_draw_logs_box(){
  local unit="$1"
  local recent_logs="" historic_log=""
  if command -v journalctl >/dev/null 2>&1; then
    recent_logs="$(journalctl --user -u "$unit" --no-pager -o cat --since '30 seconds ago' -n 5 2>/dev/null || true)"
    historic_log="$(journalctl --user -u "$unit" --no-pager -o cat -n 1 2>/dev/null | tail -n1 || true)"
  fi
  local row=13
  if [ -z "$recent_logs" ]; then
    draw_at "$row" 2 "✅ No recent events (traffic is healthy & quiet).                        "
    row=$((row+1))
    draw_at "$row" 2 "   Scanner heartbeat: $(date +%H:%M:%S)                                  "
    row=$((row+1))
    draw_at "$row" 2 "   -------------------------------------------------                      "
    row=$((row+1))
    draw_at "$row" 2 "   Last known event:                                                     "
    row=$((row+1))
    if [ -n "$historic_log" ]; then
      draw_at "$row" 4 "$(printf '%-70s' "$historic_log")"
    else
      draw_at "$row" 4 "(no historic logs)"
    fi
    row=$((row+1))
  else
    while IFS= read -r line; do
      draw_at "$row" 2 "$(printf '%-75s' "$line")"
      row=$((row+1))
      [ "$row" -gt 16 ] && break
    done <<<"$recent_logs"
  fi
  while [ "$row" -le 16 ]; do
    draw_at "$row" 2 "$(printf '%-75s' ' ')"
    row=$((row+1))
  done
}
