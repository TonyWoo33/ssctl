#!/usr/bin/env bash

cmd_monitor(){
  self_check
  local name="" url="" interval=5 count=0 tail=0 nodns=0

  # 先解析所有选项，再确定 name（第一个非连字号参数）
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)       name="$2"; shift 2 ;;
      --url)        url="$2"; shift 2 ;;
      --interval|-i) interval="$2"; shift 2 ;;
      --count|-n)   count="$2"; shift 2 ;;
      --tail|-f|-t) tail=1; shift ;;
      --no-dns)     nodns=1; shift ;;
      --)           shift; break ;;              # 显式结束选项
      -*)
        warn "忽略未知参数：$1"; shift ;;        # 未识别的选项，避免中断
      *)
        # 第一个非选项参数当作 name（仅取一次）
        if [ -z "$name" ]; then name="$1"; shift; else break; fi
        ;;
    esac
  done

  # 解析完毕后，再解析一个可能的 name（例如 '-- name' 之后）
  if [ -z "$name" ] && [ $# -gt 0 ]; then
    name="$1"; shift
  fi

  # name 允许留空 → 用 current
  if [ -z "$name" ]; then
    name="$(resolve_name "")"
  else
    name="$(resolve_name "$name")"
  fi

  # 默认 URL
  if [ "$nodns" -eq 1 ]; then
    url="${url:-http://1.1.1.1}"
  else
    url="${url:-https://www.google.com/generate_204}"
  fi

  local laddr lport unit
  laddr="$(json_get "$name" local_address)"; [ -n "$laddr" ] || laddr="$DEFAULT_LOCAL_ADDR"
  lport="$(json_get "$name" local_port)";   [ -n "$lport" ] || lport="$DEFAULT_LOCAL_PORT"
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

  local ok_cnt=0 total_cnt=0
  local socks_flag="--socks5-hostname"
  [ "$nodns" -eq 1 ] && socks_flag="--socks5"

  printf '%s\n' "MONITOR name=${name} url=${url} interval=${interval}s tail=${tail} dns=$([ "$nodns" -eq 1 ] && echo off || echo on)"
  _hr 80
  printf "%-19s  %-6s  %-6s  %-6s  %-8s  %-6s  %-9s\n" "TIME" "OK" "RTTms" "TTFB" "CONN" "CODE" "SPEED(B/s)"
  _hr 80

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
    printf "%-19s  %-6s  %-6s  %-6s  %-8s  %-6s  %-9s\n" \
      "$(date '+%F %T')" \
      "$printf_ok" \
      "$(to_ms <<<"${t_total:-0}")" \
      "$(to_ms <<<"${t_ttfb:-0}")" \
      "$(to_ms <<<"${t_conn:-0}")" \
      "${code:-000}" \
      "${spd:-0}"

    if (( total_cnt % 5 == 0 )); then
      local rate=$(( ok_cnt*100/total_cnt ))
      printf "%s[✓]%s 成功率：%d%%  （%d/%d）\n" "$C_GREEN" "$C_RESET" "$rate" "$ok_cnt" "$total_cnt"
      _hr 80
    fi

    if [ "$count" -gt 0 ] && [ "$total_cnt" -ge "$count" ]; then
      break
    fi
    sleep "$interval"
  done

  [ -n "$tail_pid" ] && kill "$tail_pid" 2>/dev/null || true
}
