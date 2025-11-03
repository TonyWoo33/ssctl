#!/usr/bin/env bash

monitor_number_or_default(){
  local v="$1" default="$2"
  case "$v" in
    ''|"NaN"|"nan"|"inf"|"-inf"|*[!0-9.+-]*) printf '%s\n' "$default" ;;
    *) printf '%s\n' "$v" ;;
  esac
}

monitor_to_ms(){
  awk '{printf "%.0f", ($1*1000)}' 2>/dev/null || echo 0
}

monitor_fetch_logs(){
  local name="$1" source_type="$2" source_value="$3" limit="$4"
  local since_ts="${MONITOR_LOG_SINCE_TS:-0}"
  local entries=()

  if [ "$source_type" = "journal" ]; then
    local journal_cmd=(journalctl --user -u "$source_value" --no-pager -o json -n "$limit")
    if [ "$since_ts" -gt 0 ]; then
      journal_cmd+=(--since "@${since_ts}")
    else
      journal_cmd+=(--since "-5 minutes")
    fi
    mapfile -t entries < <("${journal_cmd[@]}" | ssctl_parse_log_stream journal json "$name")
  else
    mapfile -t entries < <(tail -n "$limit" "$source_value" | ssctl_parse_log_stream file json "$name")
  fi

  local new_entries=()
  local entry ts msg key last_ts="$since_ts"
  local existing=0 max_keys=$(( limit * 5 ))

  for entry in "${entries[@]}"; do
    ts="$(jq -r '(.timestamp_unix // 0)' <<<"$entry")"
    msg="$(jq -r '.message // ""' <<<"$entry")"
    key="${ts}|${msg}"
    existing=0
    local seen_key
    for seen_key in "${MONITOR_LOG_KEYS[@]}"; do
      if [ "$seen_key" = "$key" ]; then
        existing=1
        break
      fi
    done
    if [ $existing -eq 1 ]; then
      continue
    fi
    MONITOR_LOG_KEYS+=("$key")
    new_entries+=("$entry")
    if [ "$ts" -gt "$last_ts" ] 2>/dev/null; then
      last_ts="$ts"
    fi
  done

  if [ ${#MONITOR_LOG_KEYS[@]} -gt "$max_keys" ]; then
    MONITOR_LOG_KEYS=(${MONITOR_LOG_KEYS[@]: -$max_keys})
  fi

  if [ ${#new_entries[@]} -gt 0 ]; then
    local last_entry="${new_entries[-1]}"
    local last_entry_ts="$(jq -r '(.timestamp_unix // 0)' <<<"$last_entry")"
    if [ "$last_entry_ts" -gt 0 ] 2>/dev/null; then
      MONITOR_LOG_SINCE_TS=$(( last_entry_ts + 1 ))
    fi
  fi

  printf '%s\n' "${new_entries[@]}"
}

monitor_render_logs_text(){
  local entries=("$@")
  [ ${#entries[@]} -gt 0 ] || return 0
  printf '--- logs ------------------------------------------------------------\n'
  local item
  for item in "${entries[@]}"; do
    logs_format_text "$item"
  done
}

cmd_monitor(){
  self_check
  ssctl_read_config

  local name="" url="" interval="$DEFAULT_MONITOR_INTERVAL" count=0 tail=0 nodns=0
  local output_format="text" do_ping=0 show_logs=0 show_speed=0 stats_interval="" log_limit=5
  local filter_args=()
  local show_help=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --name)       name="$2"; shift 2 ;;
      --url)        url="$2"; shift 2 ;;
      --interval|-i) interval="$2"; shift 2 ;;
      --count|-n)   count="$2"; shift 2 ;;
      --tail|-f|-t) tail=1; shift ;;
      --log)        show_logs=1; shift ;;
      --speed)      show_speed=1; shift ;;
      --stats-interval) stats_interval="$2"; shift 2 ;;
      --stats-interval=*) stats_interval="${1#*=}"; shift ;;
      --filter)     filter_args+=("$2"); shift 2 ;;
      --filter=*)   filter_args+=("${1#*=}"); shift ;;
      --no-dns)     nodns=1; shift ;;
      --ping)       do_ping=1; shift ;;
      --format)     output_format="$2"; shift 2 ;;
      --format=*)   output_format="${1#*=}"; shift ;;
      --json)       output_format="json"; shift ;;
      -h|--help)    show_help=1; shift ;;
      --)           shift; break ;;
      -* )
        warn "忽略未知参数：$1"; shift ;;
      *)
        if [ -z "$name" ]; then name="$1"; shift; else break; fi ;;
    esac
  done

  if [ "$show_help" -eq 1 ]; then
    cat <<'DOC'
用法：ssctl monitor [name] [--interval S] [--count N] [--log] [--speed]
                  [--stats-interval S] [--tail] [--filter key=value]
                  [--format text|json] [--ping] [--no-dns]
说明：
  --log            捕获 CONNECT/UDP 目标，可配合 target/ip/port/method/protocol/regex 过滤。
  --speed          输出 Shadowsocks 进程的 TX/RX/TOTAL(B/s) 与累计量；可用 --stats-interval 单独控制采样周期。
  --tail           循环刷新输出；默认每 interval 秒采样。
  --format json    输出结构化字段，包含日志数组与速率细节。
  --no-dns         使用 --socks5 与裸 IP 仅测链路连通性。
DOC
    return 0
  fi

  if [ -z "$name" ] && [ $# -gt 0 ]; then
    name="$1"; shift
  fi

  case "$output_format" in
    text|json) ;;
    *) die "未知输出格式：$output_format" ;;
  esac

  if [ -z "$name" ]; then
    name="$(resolve_name "")"
  else
    name="$(resolve_name "$name")"
  fi

  if [ "$show_logs" -eq 0 ] && [ "$tail" -eq 1 ]; then
    show_logs=1
  fi

  if [ -z "$stats_interval" ]; then
    stats_interval="$interval"
  fi

  if [ "$tail" -eq 1 ] && [ "$show_logs" -eq 1 ]; then
    log_limit=10
  fi

  if [ "$show_logs" -eq 1 ] && [ "${SSCTL_MONITOR_LOG_ENABLED:-true}" = "false" ]; then
    warn "配置禁用日志捕获（SSCTL_MONITOR_LOG_ENABLED=false），已跳过 --log。"
    show_logs=0
  fi

  if [ "$show_speed" -eq 1 ] && [ "${SSCTL_MONITOR_STATS_ENABLED:-true}" = "false" ]; then
    warn "配置禁用速率采样（SSCTL_MONITOR_STATS_ENABLED=false），已跳过 --speed。"
    show_speed=0
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

  if ! systemctl --user is-active --quiet "$unit" 2>/dev/null; then
    if [ "$output_format" = "json" ]; then
      jq -n --arg name "$name" --arg unit "$unit" '{error:"unit_inactive",name:$name,unit:$unit}'
    else
      warn "服务未启动：$unit"
      warn "可先运行：ssctl start ${name}"
    fi
    return 1
  fi

  if [ "$do_ping" -eq 1 ] && ! command -v ping >/dev/null 2>&1; then
    warn "未检测到 ping，已跳过 --ping 检测。"
    do_ping=0
  fi

  local stats_cache_dir=""
  if [ "$show_speed" -eq 1 ]; then
    stats_cache_dir="$(stats_cache_dir)"
  fi

  local log_filter_target="" log_filter_ip="" log_filter_port="" log_filter_method="" log_filter_protocol="" log_filter_regex=""
  local f
  for f in "${filter_args[@]}"; do
    case "$f" in
      target=*) log_filter_target="${f#*=}" ;;
      ip=*) log_filter_ip="${f#*=}" ;;
      port=*) log_filter_port="${f#*=}" ;;
      method=*) log_filter_method="${f#*=}" ;;
      protocol=*) log_filter_protocol="${f#*=}" ;;
      regex=*) log_filter_regex="${f#*=}" ;;
      *) warn "忽略未知 filter：$f" ;;
    esac
  done

  local log_source_type="" log_source_value=""
  if [ "$show_logs" -eq 1 ]; then
    local source_info
    source_info="$(resolve_log_source "$name" 2>/dev/null || true)"
    if [ -z "$source_info" ]; then
      source_info="file:$(ssctl_default_log_path "$name")"
    fi
    log_source_type="${source_info%%:*}"
    log_source_value="${source_info#*:}"
    if [ "$log_source_type" = "file" ]; then
      mkdir -p "$(dirname "$log_source_value")"
      [ -e "$log_source_value" ] || touch "$log_source_value"
    fi
    export LOG_FILTER_TARGET="${log_filter_target:-}"
    export LOG_FILTER_IP="${log_filter_ip:-}"
    export LOG_FILTER_PORT="${log_filter_port:-}"
    export LOG_FILTER_METHOD="${log_filter_method:-}"
    export LOG_FILTER_PROTOCOL="${log_filter_protocol:-}"
    export LOG_FILTER_REGEX="${log_filter_regex:-}"
  fi

  local ok_cnt=0 total_cnt=0
  local socks_flag="--socks5-hostname"
  [ "$nodns" -eq 1 ] && socks_flag="--socks5"

  local header_width=96
  if [ "$show_speed" -eq 1 ]; then
    header_width=140
  fi

  if [ "$output_format" = "text" ]; then
    local speed_flag="off" log_flag="off" dns_flag="on"
    [ "$show_speed" -eq 1 ] && speed_flag="on"
    [ "$show_logs" -eq 1 ] && log_flag="on"
    [ "$nodns" -eq 1 ] && dns_flag="off"
    printf 'MONITOR name=%s url=%s interval=%ss speed=%s log=%s dns=%s format=%s\n' \
      "$name" "$url" "$interval" "$speed_flag" "$log_flag" "$dns_flag" "$output_format"
    _hr "$header_width"
    if [ "$do_ping" -eq 1 ] && [ "$show_speed" -eq 1 ]; then
      printf "%-19s  %-6s  %-6s  %-6s  %-8s  %-6s  %-8s  %-9s  %-9s  %-9s  %-9s  %-12s  %-12s\n" \
        "TIME" "OK" "RTTms" "TTFB" "CONN" "CODE" "PINGms" "CURL(B/s)" "TX(B/s)" "RX(B/s)" "TOTAL(B/s)" "TX_TOTAL" "RX_TOTAL"
    elif [ "$show_speed" -eq 1 ]; then
      printf "%-19s  %-6s  %-6s  %-6s  %-8s  %-6s  %-9s  %-9s  %-9s  %-9s  %-12s  %-12s\n" \
        "TIME" "OK" "RTTms" "TTFB" "CONN" "CODE" "CURL(B/s)" "TX(B/s)" "RX(B/s)" "TOTAL(B/s)" "TX_TOTAL" "RX_TOTAL"
    elif [ "$do_ping" -eq 1 ]; then
      printf "%-19s  %-6s  %-6s  %-6s  %-8s  %-6s  %-11s  %-9s\n" "TIME" "OK" "RTTms" "TTFB" "CONN" "CODE" "PINGms" "SPEED(B/s)"
    else
      printf "%-19s  %-6s  %-6s  %-6s  %-8s  %-6s  %-9s\n" "TIME" "OK" "RTTms" "TTFB" "CONN" "CODE" "SPEED(B/s)"
    fi
    _hr "$header_width"
  fi

  local last_stats_epoch=0 last_stats_entry="" stats_row=""
  MONITOR_LOG_SINCE_TS=0
  MONITOR_LOG_KEYS=()

  while :; do
    total_cnt=$(( total_cnt + 1 ))

    local out="" rc=0 t_conn="0" t_ttfb="0" t_total="0" spd="0" code="0"
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

    local printf_ok="FAIL"
    if [ "$rc" -eq 0 ] && [ -n "$code" ] && [ "$code" != "000" ]; then
      printf_ok="OK"
      ok_cnt=$(( ok_cnt + 1 ))
    fi

    local rtt_ms ttfb_ms conn_ms
    rtt_ms="$(monitor_to_ms <<<"${t_total:-0}")"
    ttfb_ms="$(monitor_to_ms <<<"${t_ttfb:-0}")"
    conn_ms="$(monitor_to_ms <<<"${t_conn:-0}")"

    local ping_ms="" ping_ms_value=""
    if [ "$do_ping" -eq 1 ]; then
      local ping_out
      if ping_out=$(ping -c1 -W1 "$server" 2>/dev/null); then
        ping_ms=$(echo "$ping_out" | awk -F'time=' '/time=/{print $2}' | awk '{print $1}')
        ping_ms_value="$(monitor_number_or_default "$ping_ms" "0")"
      else
        ping_ms="NaN"
        ping_ms_value=""
      fi
    fi

    local speed_val="$(monitor_number_or_default "$spd" "0")"
    local code_val="$(monitor_number_or_default "$code" "0")"

    local stats_valid=0 stats_tx_rate=0 stats_rx_rate=0 stats_total_rate=0 stats_tx_total=0 stats_rx_total=0 stats_note="" stats_warming=0
    if [ "$show_speed" -eq 1 ]; then
      local now_epoch="$(date +%s)"
      if [ "$last_stats_epoch" -eq 0 ] || [ $(( now_epoch - last_stats_epoch )) -ge "$stats_interval" ]; then
        last_stats_entry="$(stats_collect_node "$name" "$now_epoch" "$stats_cache_dir")"
        last_stats_epoch="$now_epoch"
      fi
      if [ -n "$last_stats_entry" ]; then
        IFS='|' read -r _ stats_valid stats_tx_rate stats_rx_rate stats_total_rate stats_tx_total stats_rx_total _ _ stats_warming stats_note <<<"$last_stats_entry"
      fi
    fi

    local logs_json="[]" text_logs=()
    if [ "$show_logs" -eq 1 ]; then
      mapfile -t text_logs < <(monitor_fetch_logs "$name" "$log_source_type" "$log_source_value" "$log_limit")
      if [ ${#text_logs[@]} -gt 0 ]; then
        logs_json="$(printf '%s\n' "${text_logs[@]}" | jq -s '.')"
      else
        logs_json='[]'
      fi
    fi

    if [ "$output_format" = "json" ]; then
      local stats_json='null'
      if [ "$show_speed" -eq 1 ] && [ -n "$last_stats_entry" ]; then
        local stats_valid_num=0
        [ "$stats_valid" = "1" ] && stats_valid_num=1
        local stats_warming_num=0
        [ "$stats_warming" = "1" ] && stats_warming_num=1
        local stats_tx_rate_num="$(monitor_number_or_default "$stats_tx_rate" "0")"
        local stats_rx_rate_num="$(monitor_number_or_default "$stats_rx_rate" "0")"
        local stats_total_rate_num="$(monitor_number_or_default "$stats_total_rate" "0")"
        local stats_tx_total_num="$(monitor_number_or_default "$stats_tx_total" "0")"
        local stats_rx_total_num="$(monitor_number_or_default "$stats_rx_total" "0")"
        stats_json="$(jq -n \
          --argjson valid "$stats_valid_num" \
          --argjson tx_rate "$stats_tx_rate_num" \
          --argjson rx_rate "$stats_rx_rate_num" \
          --argjson total_rate "$stats_total_rate_num" \
          --argjson tx_total "$stats_tx_total_num" \
          --argjson rx_total "$stats_rx_total_num" \
          --argjson warming "$stats_warming_num" \
          --arg note "$stats_note" \
          '{valid:($valid==1),tx_bytes_per_second:$tx_rate,rx_bytes_per_second:$rx_rate,total_bytes_per_second:$total_rate,tx_total_bytes:$tx_total,rx_total_bytes:$rx_total,warming_up:($warming==1)} | if ($note|length)>0 then . + {note:$note} else . end')"
      fi

      local timestamp_iso="$(date --iso-8601=seconds)"
      local ok_flag=0
      [ "$printf_ok" = "OK" ] && ok_flag=1
      local http_code_num=0
      if [[ "$code_val" =~ ^[0-9]+$ ]]; then
        http_code_num=$((10#$code_val))
      fi
      local rtt_ms_num="$(monitor_number_or_default "$rtt_ms" "0")"
      local ttfb_ms_num="$(monitor_number_or_default "$ttfb_ms" "0")"
      local conn_ms_num="$(monitor_number_or_default "$conn_ms" "0")"
      local curl_rate_num="$(monitor_number_or_default "$speed_val" "0")"
      local ping_ms_json="null"
      if [ -n "$ping_ms_value" ]; then
        ping_ms_json="$(monitor_number_or_default "$ping_ms_value" "0")"
      fi

      jq -n \
        --arg time "$timestamp_iso" \
        --arg name "$name" \
        --arg url "$url" \
        --arg status "$printf_ok" \
        --arg laddr "$laddr" \
        --argjson ok_flag "$ok_flag" \
        --argjson http_code "$http_code_num" \
        --argjson latency_ms "$rtt_ms_num" \
        --argjson ttfb_ms "$ttfb_ms_num" \
        --argjson connect_ms "$conn_ms_num" \
        --argjson curl_bps "$curl_rate_num" \
        --argjson ping_ms "$ping_ms_json" \
        --argjson stats "$stats_json" \
        --argjson logs "$logs_json" \
        '{time:$time,name:$name,url:$url,status:$status,ok:($ok_flag==1),http_code:$http_code,latency_ms:$latency_ms,ttfb_ms:$ttfb_ms,connect_ms:$connect_ms,curl_bytes_per_s:$curl_bps,local_address:$laddr}
         | (if $ping_ms == null then . else . + {ping_ms:$ping_ms} end)
         | (if $stats == null then . else . + {stats:$stats} end)
         | (if ($logs|length)>0 then . + {logs:$logs} else . end)'
    else
      if [ "$do_ping" -eq 1 ] && [ "$show_speed" -eq 1 ]; then
        printf "%-19s  %-6s  %-6s  %-6s  %-8s  %-6s  %-8s  %-9s  %-9s  %-9s  %-9s  %-12s  %-12s\n" \
          "$(date '+%F %T')" \
          "$printf_ok" \
          "$rtt_ms" \
          "$ttfb_ms" \
          "$conn_ms" \
          "${code:-000}" \
          "${ping_ms:-"--"}" \
          "$speed_val" \
          "$(format_rate "$stats_tx_rate")" \
          "$(format_rate "$stats_rx_rate")" \
          "$(format_rate "$stats_total_rate")" \
          "$(human_bytes "$stats_tx_total")" \
          "$(human_bytes "$stats_rx_total")"
      elif [ "$show_speed" -eq 1 ]; then
        printf "%-19s  %-6s  %-6s  %-6s  %-8s  %-6s  %-9s  %-9s  %-9s  %-9s  %-12s  %-12s\n" \
          "$(date '+%F %T')" \
          "$printf_ok" \
          "$rtt_ms" \
          "$ttfb_ms" \
          "$conn_ms" \
          "${code:-000}" \
          "$speed_val" \
          "$(format_rate "$stats_tx_rate")" \
          "$(format_rate "$stats_rx_rate")" \
          "$(format_rate "$stats_total_rate")" \
          "$(human_bytes "$stats_tx_total")" \
          "$(human_bytes "$stats_rx_total")"
      elif [ "$do_ping" -eq 1 ]; then
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

      if [ "$show_speed" -eq 1 ]; then
        if [ "$stats_warming" = "1" ]; then
          printf '    stats: warming up（等待下一次采样以计算速率）\n'
        fi
        if [ -n "$stats_note" ]; then
          printf '    stats: %s\n' "$stats_note"
        fi
      fi

      if [ "$show_logs" -eq 1 ] && [ ${#text_logs[@]} -gt 0 ]; then
        monitor_render_logs_text "${text_logs[@]}"
      fi

      if (( total_cnt % 5 == 0 )); then
        local rate=$(( ok_cnt*100/total_cnt ))
        printf "%s[✓]%s 成功率：%d%%  （%d/%d）\n" "$C_GREEN" "$C_RESET" "$rate" "$ok_cnt" "$total_cnt"
        _hr "$header_width"
      fi
    fi

    if [ "$count" -gt 0 ] && [ "$total_cnt" -ge "$count" ]; then
      break
    fi
    sleep "$interval"
  done

  if [ "$show_logs" -eq 1 ]; then
    unset LOG_FILTER_TARGET LOG_FILTER_IP LOG_FILTER_PORT LOG_FILTER_METHOD LOG_FILTER_PROTOCOL LOG_FILTER_REGEX
  fi
}
