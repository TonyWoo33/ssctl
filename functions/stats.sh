#!/usr/bin/env bash

stats_cache_dir(){
  local dir="${SSCTL_STATS_CACHE_DIR:-${HOME}/.cache/ssctl/stats}" current_umask
  current_umask="$(umask)"
  umask 077
  mkdir -p "$dir" 2>/dev/null || true
  umask "$current_umask"
  printf '%s\n' "$dir"
}

stats_collect_node(){
  local node_json="${1:-}"
  local now_epoch="${2:-0}"
  local stats_cache_dir="${3:-}"
  if [ -z "$node_json" ]; then
    warn "stats_collect_node: 缺少 node_json 参数。"
    return 1
  fi

  local engine
  engine="$(jq -r '.engine // "shadowsocks"' <<<"$node_json")"
  engine="${engine,,}"
  require_safe_identifier "$engine" "engine 字段"

  local app_lib_dir="${APP_LIB_DIR:-}"
  if [ -z "$app_lib_dir" ]; then
    if [ -n "${SSCTL_LIB_DIR:-}" ]; then
      app_lib_dir="${SSCTL_LIB_DIR}/lib"
    else
      local base_dir
      base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null || pwd)"
      app_lib_dir="${base_dir}/lib"
    fi
  fi

  local engine_file="${app_lib_dir}/engines/${engine}.sh"
  if [ ! -f "$engine_file" ]; then
    warn "stats_collect_node: 找不到引擎文件: $engine_file"
    return 1
  fi

  local engine_config_func="engine_${engine}_get_sampler_config"
  if ! declare -f "$engine_config_func" >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    source "$engine_file"
  fi
  if ! declare -f "$engine_config_func" >/dev/null 2>&1; then
    warn "stats_collect_node: 引擎 $engine 未实现 $engine_config_func"
    return 1
  fi

  local sampler_config
  sampler_config="$("$engine_config_func" "$node_json")"

  local sampler_type
  sampler_type="$(printf '%s\n' "$sampler_config" | awk -F= '$1=="SAMPLER_TYPE"{print $2; exit}')"
  sampler_type="${sampler_type,,}"
  if [ -z "$sampler_type" ]; then
    warn "stats_collect_node: 引擎 $engine 未定义 SAMPLER_TYPE"
    return 1
  fi

  local sampler_file="${app_lib_dir}/samplers/${sampler_type}.sh"
  if [ ! -f "$sampler_file" ]; then
    warn "stats_collect_node: 找不到采样器文件: $sampler_file"
    return 1
  fi

  local sampler_func="sampler_${sampler_type}_collect"
  if ! declare -f "$sampler_func" >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    source "$sampler_file"
  fi
  if ! declare -f "$sampler_func" >/dev/null 2>&1; then
    warn "stats_collect_node: 采样器 $sampler_type 未实现 $sampler_func"
    return 1
  fi

  "$sampler_func" "$node_json" "$now_epoch" "$stats_cache_dir" "$sampler_config"
}

stats_run_watch_mode(){
  local args=("$@")
  local monitor_args=("--speed")
  local i=0 arg name_provided=0

  while [ $i -lt ${#args[@]} ]; do
    arg="${args[i]}"
    case "$arg" in
      --watch)
        i=$((i + 1))
        continue
        ;;
      --aggregate)
        warn "--watch 模式不支持 --aggregate，已忽略。"
        i=$((i + 1))
        continue
        ;;
      --filter)
        warn "--watch 模式不支持 --filter，已忽略。"
        if [ $((i + 1)) -lt ${#args[@]} ]; then
          i=$((i + 2))
        else
          i=$((i + 1))
        fi
        continue
        ;;
      --filter=*)
        warn "--watch 模式不支持 --filter，已忽略。"
        i=$((i + 1))
        continue
        ;;
      --interval|--count|--stats-interval|--format|--url|--name)
        monitor_args+=("$arg")
        [ "$arg" = "--name" ] && name_provided=1
        i=$((i + 1))
        if [ $i -lt ${#args[@]} ]; then
          monitor_args+=("${args[i]}")
          [ "$arg" = "--name" ] && name_provided=1
          i=$((i + 1))
        fi
        continue
        ;;
      --interval=*|--count=*|--stats-interval=*|--format=*|--url=*|--name=*)
        monitor_args+=("$arg")
        [[ "$arg" == --name=* ]] && name_provided=1
        i=$((i + 1))
        continue
        ;;
      --json)
        monitor_args+=("--json")
        i=$((i + 1))
        continue
        ;;
      *)
        if [[ "$arg" != -* ]] && [ $name_provided -eq 0 ]; then
          monitor_args+=("--name" "$arg")
          name_provided=1
        else
          monitor_args+=("$arg")
        fi
        i=$((i + 1))
        ;;
    esac
  done

  if [ $name_provided -eq 0 ]; then
    monitor_args+=("--name" "current")
  fi

  cmd_monitor "${monitor_args[@]}"
}

cmd_stats(){
  self_check
  ssctl_read_config

  local original_args=("$@") arg watch_mode=0
  for arg in "${original_args[@]}"; do
    if [ "$arg" = "--watch" ]; then
      watch_mode=1
      break
    fi
  done
  if [ "$watch_mode" -eq 1 ]; then
    stats_run_watch_mode "${original_args[@]}"
    return $?
  fi

  local interval=2 count=0 aggregate=0 format="text"
  local positional=() filters=()
  local filter_node="" filter_regex=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --interval)
        interval="$2"; shift 2 ;;
      --interval=*)
        interval="${1#*=}"; shift ;;
      --count)
        count="$2"; shift 2 ;;
      --count=*)
        count="${1#*=}"; shift ;;
      --aggregate)
        aggregate=1; shift ;;
      --format)
        format="$2"; shift 2 ;;
      --format=*)
        format="${1#*=}"; shift ;;
      --filter)
        filters+=("$2"); shift 2 ;;
      --filter=*)
        filters+=("${1#*=}"); shift ;;
      -h|--help)
        cat <<'DOC'
用法：ssctl stats [name|all] [--interval S] [--count N] [--aggregate] [--format text|json]
说明：
  - 采集 Shadowsocks 节点的 TX/RX/TOTAL 字节率与累计量。
  - 默认输出 text 表格，配合 --format json 输出结构化数据。
  - --aggregate 会追加 TOTAL 行。
  - --filter 支持 name/node=xxx 或 regex=PATTERN。
DOC
        return 0
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -* )
        die "未知参数：$1"
        ;;
      *)
        positional+=("$1"); shift ;;
    esac
  done

  for item in "${filters[@]}"; do
    case "$item" in
      name=*|node=*) filter_node="${item#*=}" ;;
      regex=*) filter_regex="${item#*=}" ;;
      *) warn "忽略未知 filter：$item" ;;
    esac
  done

  case "$format" in
    text|json) ;;
    *) die "未知输出格式：$format" ;;
  esac

  local target="" nodes=()
  if [ ${#positional[@]} -gt 0 ]; then
    target="${positional[0]}"
  fi

  if [ -z "$target" ]; then
    target="$(resolve_name "")"
  fi

  if [ "$target" = "all" ]; then
    while read -r node; do
      [ -n "$node" ] || continue
      nodes+=("$node")
    done < <(list_nodes)
  else
    nodes+=("$(resolve_name "$target")")
  fi

  if [ ${#nodes[@]} -eq 0 ]; then
    die "未找到节点"
  fi

  local filtered=()
  local node
  for node in "${nodes[@]}"; do
    if [ -n "$filter_node" ] && [[ "$node" != *"$filter_node"* ]]; then
      continue
    fi
    if [ -n "$filter_regex" ] && ! printf '%s\n' "$node" | grep -Eq "$filter_regex"; then
      continue
    fi
    filtered+=("$node")
  done

  nodes=("${filtered[@]}")
  if [ ${#nodes[@]} -eq 0 ]; then
    die "filter 结果为空"
  fi

  local node_configs=()
  if ! mapfile -t node_configs < <(nodes_json_stream "${nodes[@]}"); then
    die "无法读取节点配置"
  fi
  if [ ${#node_configs[@]} -eq 0 ]; then
    die "未能加载任何节点配置"
  fi

  if [ "${SSCTL_MONITOR_STATS_ENABLED:-true}" = "false" ]; then
    warn "配置禁用 stats 采集（SSCTL_MONITOR_STATS_ENABLED=false），仍继续执行。"
  fi

  local cache_dir
  cache_dir="$(stats_cache_dir)"

  local header_printed=0
  local iteration=0
  while :; do
    iteration=$((iteration + 1))
    local timestamp epoch
    timestamp="$(date '+%F %T')"
    epoch="$(date +%s)"

    local rows=() row aggregate_tx_rate=0 aggregate_rx_rate=0 aggregate_total_rate=0
    local aggregate_tx_total=0 aggregate_rx_total=0 warming_any=0
    local node_result_jsons=()

    ssctl_service_cache_unit_states

    local node_json
    for node_json in "${node_configs[@]}"; do
      row="$(stats_collect_node "$node_json" "$epoch" "$cache_dir")"
      rows+=("$row")
      IFS='|' read -r name valid tx_rate rx_rate total_rate tx_total rx_total rtt pid warming note <<<"$row"
      if [ "$valid" = "1" ]; then
        aggregate_tx_rate=$(( aggregate_tx_rate + tx_rate ))
        aggregate_rx_rate=$(( aggregate_rx_rate + rx_rate ))
        aggregate_total_rate=$(( aggregate_total_rate + total_rate ))
        aggregate_tx_total=$(( aggregate_tx_total + tx_total ))
        aggregate_rx_total=$(( aggregate_rx_total + rx_total ))
      fi
      if [ "$warming" = "1" ]; then
        warming_any=1
      fi

      if [ "$format" = "json" ]; then
        node_result_jsons+=("$(jq -c -n \
          --arg name "$name" \
          --arg pid "$pid" \
          --arg note "$note" \
          --arg rtt "$rtt" \
          --argjson tx_rate "${tx_rate:-0}" \
          --argjson rx_rate "${rx_rate:-0}" \
          --argjson total_rate "${total_rate:-0}" \
          --argjson tx_total "${tx_total:-0}" \
          --argjson rx_total "${rx_total:-0}" \
          --argjson valid "${valid:-0}" \
          --argjson warming "${warming:-0}" \
          '{name:$name,
            pid:(try ($pid|tonumber) catch null),
            tx_bytes_per_second:$tx_rate,
            rx_bytes_per_second:$rx_rate,
            total_bytes_per_second:$total_rate,
            tx_total_bytes:$tx_total,
            rx_total_bytes:$rx_total,
            rtt_ms:(if $rtt == "-" then null else (try ($rtt|tonumber) catch null) end),
            valid:($valid==1),
            warming_up:($warming==1)} 
           | (if ($note|length) > 0 then . + {note:$note} else . end)' )")
      fi
    done

    if [ "$format" = "text" ]; then
      if [ $header_printed -eq 0 ]; then
        printf '%-19s  %-12s  %10s  %10s  %11s  %12s  %12s  %8s\n' \
          "TIME" "NODE" "TX(B/s)" "RX(B/s)" "TOTAL(B/s)" "TX_TOTAL" "RX_TOTAL" "PID" >&2
        (_hr 100) >&2
        header_printed=1
      fi
      for row in "${rows[@]}"; do
        IFS='|' read -r name valid tx_rate rx_rate total_rate tx_total rx_total rtt pid warming note <<<"$row"
        printf '%-19s  %-12s  %10s  %10s  %11s  %12s  %12s  %8s\n' \
          "$timestamp" "$name" "$(format_rate "$tx_rate")" "$(format_rate "$rx_rate")" \
          "$(format_rate "$total_rate")" "$(human_bytes "$tx_total")" "$(human_bytes "$rx_total")" "${pid:-0}" >&2
        if [ -n "$note" ]; then
          printf '    note: %s\n' "$note" >&2
        fi
      done
      if [ $aggregate -eq 1 ]; then
        printf '%-19s  %-12s  %10s  %10s  %11s  %12s  %12s  %8s\n' \
          "$timestamp" "TOTAL" "$(format_rate "$aggregate_tx_rate")" "$(format_rate "$aggregate_rx_rate")" \
          "$(format_rate "$aggregate_total_rate")" "$(human_bytes "$aggregate_tx_total")" \
          "$(human_bytes "$aggregate_rx_total")" "-" >&2
      fi
      if [ $warming_any -eq 1 ]; then
        printf '    warming up: 需要至少两次采样才能计算速率。\n' >&2
      fi
      if [ "$count" -eq 0 ] || [ $iteration -lt "$count" ]; then
        printf '\n' >&2
      fi
    else
      local nodes_payload aggregate_obj="null"
      if [ ${#node_result_jsons[@]} -gt 0 ]; then
        nodes_payload="$(printf '%s\n' "${node_result_jsons[@]}" | jq -c -s '.')"
      else
        nodes_payload='[]'
      fi
      if [ $aggregate -eq 1 ]; then
        aggregate_obj="$(jq -c -n \
          --arg name "TOTAL" \
          --argjson tx_rate "$aggregate_tx_rate" \
          --argjson rx_rate "$aggregate_rx_rate" \
          --argjson total_rate "$aggregate_total_rate" \
          --argjson tx_total "$aggregate_tx_total" \
          --argjson rx_total "$aggregate_rx_total" \
          '{name:$name,aggregate:true,tx_bytes_per_second:$tx_rate,rx_bytes_per_second:$rx_rate,total_bytes_per_second:$total_rate,tx_total_bytes:$tx_total,rx_total_bytes:$rx_total}')"
      fi
      jq -c -n \
        --arg time "$timestamp" \
        --argjson interval "$interval" \
        --argjson aggregate "$aggregate_obj" \
        --argjson nodes "$nodes_payload" \
        '{time:$time,interval_seconds:$interval,nodes:$nodes} + (if $aggregate == null then {} else {aggregate:$aggregate} end)'
    fi

    if [ "$count" -gt 0 ] && [ $iteration -ge "$count" ]; then
      break
    fi
    sleep "$interval"
  done
}
