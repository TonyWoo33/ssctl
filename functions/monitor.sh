#!/usr/bin/env bash

cmd_monitor(){
  self_check
  local name="" url="" interval="$DEFAULT_MONITOR_INTERVAL" count=0 tail=0 nodns=0
  local output_format="text" do_ping=0

  _monitor_number_or_default(){
    local v="$1" default="$2"
    case "$v" in
      ''|"NaN"|"nan"|"inf"|"-inf"|*[!0-9.+-]*) printf '%s\n' "$default" ;;
      *) printf '%s\n' "$v" ;;
    esac
  }

  # 先解析所有选项，再确定 name（第一个非连字号参数）
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)       name="$2"; shift 2 ;;
      --url)        url="$2"; shift 2 ;;
      --interval|-i) interval="$2"; shift 2 ;;
      --count|-n)   count="$2"; shift 2 ;;
      --tail|-f|-t) tail=1; shift ;;
      --no-dns)     nodns=1; shift ;;
      --ping)       do_ping=1; shift ;;
      --format)     output_format="$2"; shift 2 ;;
      --format=*)   output_format="${1#*=}"; shift ;;
      --json)       output_format="json"; shift ;;
      --)           shift; break ;;
      -*)
        warn "忽略未知参数：$1"; shift ;;
      *)
        if [ -z "$name" ]; then name="$1"; shift; else break; fi
        ;;
    esac
  done

  if [ -z "$name" ] && [ $# -gt 0 ]; then
    name="$1"; shift
  fi

  if [ -z "$name" ]; then
    name="$(resolve_name "")"
  else
    name="$(resolve_name "$name")"
  fi

  if [ "$nodns" -eq 1 ]; then
    url="${url:-$DEFAULT_MONITOR_NO_DNS_URL}"
  else
    url="${url:-$DEFAULT_MONITOR_URL}"
  fi

  local laddr lport unit server
  laddr="$(json_get "$name" local_address)"; [ -n "$laddr" ] || laddr="$DEFAULT_LOCAL_ADDR"
  lport="$(json_get "$name" local_port)";   [ -n "$lport" ] || lport="$DEFAULT_LOCAL_PORT"
  server="$(json_get "$name" server)"
  unit="$(unit_name_for "$name")"

  if ! systemctl --user is-active --quiet "$unit"; then
    warn "服务未启动：$unit"
    warn "可先运行：ssctl start ${name}"
    return 1
  fi

  local tail_pid=""
  if [ "$tail" -eq 1 ]; then
    journalctl --user -u "$unit" -n 20 -f --no-pager &
    tail_pid=$!
    info "日志跟随已启动（PID=${tail_pid}）"
  fi
  trap 'rc=$?; [ -n "$tail_pid" ] && kill "$tail_pid" 2>/dev/null || true; exit $rc' INT TERM

  if [ "$do_ping" -eq 1 ] && ! command -v ping >/dev/null 2>&1; then
    warn "未检测到 ping，已跳过 --ping 检测。"
    do_ping=0
  fi

  local ok_cnt=0 total_cnt=0
  local socks_flag="--socks5-hostname"
  [ "$nodns" -eq 1 ] && socks_flag="--socks5"

  if [ "$output_format" = "text" ]; then
    local header_width=96
    printf '%s\n' "MONITOR name=${name} url=${url} interval=${interval}s tail=${tail} dns=$([ "$nodns" -eq 1 ] && echo off || echo on) format=${output_format}"
    _hr "$header_width"
    if [ "$do_ping" -eq 1 ]; then
      printf "%-19s  %-6s  %-6s  %-6s  %-8s  %-6s  %-11s  %-9s\n" "TIME" "OK" "RTTms" "TTFB" "CONN" "CODE" "PINGms" "SPEED(B/s)"
    else
      printf "%-19s  %-6s  %-6s  %-6s  %-8s  %-6s  %-9s\n" "TIME" "OK" "RTTms" "TTFB" "CONN" "CODE" "SPEED(B/s)"
    fi
    _hr "$header_width"
  fi

  while :; do
    total_cnt=$((total_cnt+1))

    local out rc t_conn t_ttfb t_total spd code
    out="$(curl -sS -o /dev/null -w '%{time_connect} %{time_starttransfer} %{time_total} %{speed_download} %{http_code}' \
            --connect-timeout 6 --max-time 10 \
            ${socks_flag} "${laddr}:${lport}" \
            "${url}" 2>/dev/null)" || rc=$? || true
    rc=${rc:-0}

    t_conn="$(awk '{print $1}' <<<"$out")"
    t_ttfb="$(awk '{print $2}' <<<"$out")"
    t_total="$(awk '{print $3}' <<<"$out")"
    spd="$(awk '{print $4}' <<<"$out")"
    code="$(awk '{print $5}' <<<"$out")"

    if [ "$rc" -eq 0 ] && [ -n "$code" ] && [ "$code" != "000" ]; then
      printf_ok="OK"; ok_cnt=$((ok_cnt+1))
    else
      printf_ok="FAIL"
    fi

    to_ms(){ awk '{printf "%.0f", ($1*1000)}' 2>/dev/null || echo 0; }
    local rtt_ms="$(to_ms <<<"${t_total:-0}")"
    local ttfb_ms="$(to_ms <<<"${t_ttfb:-0}")"
    local conn_ms="$(to_ms <<<"${t_conn:-0}")"

    local ping_ms="" ping_ms_value=""
    if [ "$do_ping" -eq 1 ]; then
      local ping_out
      if ping_out=$(ping -c1 -W1 "$server" 2>/dev/null); then
        ping_ms=$(echo "$ping_out" | awk -F'time=' '/time=/{print $2}' | awk '{print $1}')
        ping_ms_value="$(_monitor_number_or_default "$ping_ms" "0")"
      else
        ping_ms="NaN"
        ping_ms_value=""
      fi
    fi

    local speed_val="$(_monitor_number_or_default "$spd" "0")"
    local code_val="$(_monitor_number_or_default "$code" "0")"

    if [ "$output_format" = "json" ]; then
      local ok_flag=0
      [ "$printf_ok" = "OK" ] && ok_flag=1
      jq -n \
        --arg time "$(date --iso-8601=seconds)" \
        --arg name "$name" \
        --arg url "$url" \
        --arg status "$printf_ok" \
        --arg laddr "$laddr" \
        --argjson ok "$ok_flag" \
        --argjson http_code "$code_val" \
        --argjson latency_ms "$rtt_ms" \
        --argjson ttfb_ms "$ttfb_ms" \
        --argjson connect_ms "$conn_ms" \
        --argjson speed_bps "$speed_val" \
        --argjson ping_ms "$([[ -n "$ping_ms_value" ]] && echo "$ping_ms_value" || echo null)" \
        '{time:$time,name:$name,url:$url,status:$status,ok:$ok,http_code:$http_code,latency_ms:$latency_ms,ttfb_ms:$ttfb_ms,connect_ms:$connect_ms,speed_bytes_per_s:$speed_bps,local_address:$laddr} + (if $ping_ms == null then {} else {ping_ms:$ping_ms} end)'
    else
      if [ "$do_ping" -eq 1 ]; then
        printf "%-19s  %-6s  %-6s  %-6s  %-8s  %-6s  %-11s  %-9s\n" \
          "$(date '+%F %T')" \
          "$printf_ok" \
          "$rtt_ms" \
          "$ttfb_ms" \
          "$conn_ms" \
          "${code:-000}" \
          "${ping_ms:-"--"}" \
          "$speed_val"
      else
        printf "%-19s  %-6s  %-6s  %-6s  %-8s  %-6s  %-9s\n" \
          "$(date '+%F %T')" \
          "$printf_ok" \
          "$rtt_ms" \
          "$ttfb_ms" \
          "$conn_ms" \
          "${code:-000}" \
          "$speed_val"
      fi

      if [ "$output_format" = "text" ] && (( total_cnt % 5 == 0 )); then
        local rate=$(( ok_cnt*100/total_cnt ))
        printf "%s[✓]%s 成功率：%d%%  （%d/%d）\n" "$C_GREEN" "$C_RESET" "$rate" "$ok_cnt" "$total_cnt"
        _hr 96
      fi
    fi

    if [ "$count" -gt 0 ] && [ "$total_cnt" -ge "$count" ]; then
      break
    fi
    sleep "$interval"
  done

  [ -n "$tail_pid" ] && kill "$tail_pid" 2>/dev/null || true
}
