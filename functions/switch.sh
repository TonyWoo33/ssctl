#!/usr/bin/env bash

cmd_switch(){
  self_check

  local use_best=0 show_help=0
  local positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --best)
        use_best=1; shift ;;
      -h|--help)
        show_help=1; shift ;;
      --)
        shift
        while [ $# -gt 0 ]; do
          positional+=("$1"); shift
        done
        break ;;
      -*)
        warn "忽略未知参数：$1"
        shift ;;
      *)
        positional+=("$1")
        shift ;;
    esac
  done

  if [ "$show_help" -eq 1 ]; then
cat <<'DOC'
用法：
  ssctl switch <name>
  ssctl switch --best
说明：
  - 更新 current.json 指向指定节点，但不会自动启动。
  - --best 会遍历所有节点，通过 ping 选择即时 RTT 最低的节点。
DOC
    return 0
  fi

  local name="${positional[0]:-}" best_latency=""
  if [ "$use_best" -eq 1 ]; then
    [ -z "$name" ] || die "--best 模式下无需指定节点名"
    local best_candidate_name="" best_candidate_latency=""
    info "Testing latencies..."
    if ! switch_pick_best_candidate best_candidate_name best_candidate_latency; then
      return 1
    fi
    name="$best_candidate_name"
    best_latency="$best_candidate_latency"
    info "Winner: ${name}（${best_latency} ms）"
  else
    [ -n "$name" ] || die "用法：ssctl switch <name> 或 ssctl switch --best"
  fi

  require_safe_identifier "$name" "节点名"
  local p; p="$(node_json_path "$name")"
  [ -f "$p" ] || die "不存在节点：$name"
  ln -sfn "$p" "${CURRENT_JSON}"
  if [ "$use_best" -eq 1 ] && [ -n "$best_latency" ]; then
    ok "已切换当前节点：${name}（latency ${best_latency} ms）"
  else
    ok "已切换当前节点：${name}"
  fi
  if [ "$use_best" -eq 1 ]; then
    switch_auto_start_node "$name"
  else
    warn "提示：switch 不会自动启动；请执行：ssctl start"
  fi
}

switch_pick_best_candidate(){
  local out_name_var="${1:-}" out_latency_var="${2:-}"
  [ -n "$out_name_var" ] || die "内部错误：缺少 name 输出引用"
  [ -n "$out_latency_var" ] || die "内部错误：缺少 latency 输出引用"

  local nodes=()
  while read -r node; do
    [ -n "$node" ] || continue
    nodes+=("$node")
  done < <(list_nodes)
  if [ ${#nodes[@]} -eq 0 ]; then
    die "未找到节点"
  fi

  local best_name="" best_latency_value="" best_rank="" success_count=0
  local node_json
  while IFS= read -r node_json || [ -n "$node_json" ]; do
    [ -n "$node_json" ] || continue
    local name server server_port
    name="$(jq -r '.__name' <<<"$node_json")"
    server="$(jq -r '.server // empty' <<<"$node_json")"
    if [[ "$name" == *local* ]]; then
      warn "跳过 local 测试节点：${name}"
      continue
    fi
    if [ -z "$server" ]; then
      warn "节点 ${name} 缺少 server 字段，已跳过"
      continue
    fi
    server_port="$(jq -r '.server_port // .port // empty' <<<"$node_json")"
    if [ -z "$server_port" ] || [ "$server_port" = "null" ]; then
      warn "节点 ${name} 缺少 server_port/port 字段，已跳过"
      continue
    fi

    local latency_display="" latency_rank=""
    if switch_tcp_probe_latency "$server" "$server_port" latency_display latency_rank; then
      success_count=$((success_count + 1))
      printf '  [+] %s: %sms\n' "$name" "$latency_display" >&2
      if [ -z "$best_name" ] || [ "$latency_rank" -lt "$best_rank" ]; then
        best_name="$name"
        best_latency_value="$latency_display"
        best_rank="$latency_rank"
      fi
    else
      printf '  [-] %s: timeout/unreachable\n' "$name" >&2
      warn "节点 ${name} TCP 探测失败"
    fi
  done < <(nodes_json_stream "${nodes[@]}")

  if [ "$success_count" -eq 0 ]; then
    warn "未找到可用节点（ping 全部失败）"
    return 1
  fi
  if [ -z "$best_name" ]; then
    die "No reachable nodes found via ping."
  fi

  printf -v "$out_name_var" '%s' "$best_name"
  printf -v "$out_latency_var" '%s' "$best_latency_value"
  return 0
}

switch_tcp_probe_latency(){
  local server="$1" port="$2" normalized_var="${3:-}" rank_var="${4:-}"
  [ -n "$normalized_var" ] || die "内部错误：缺少 normalized 输出引用"
  [ -n "$rank_var" ] || die "内部错误：缺少 rank 输出引用"
  local start_ts end_ts
  start_ts="$(switch_now_ms)" || return 1
  if timeout 1 bash -c "cat < /dev/null > /dev/tcp/${server}/${port}" >/dev/null 2>&1; then
    end_ts="$(switch_now_ms)" || return 1
    local delta=$((end_ts - start_ts))
    [ "$delta" -ge 0 ] || delta=0
    printf -v "$normalized_var" '%s' "$delta"
    printf -v "$rank_var" '%s' "$delta"
    return 0
  fi
  return 1
}

switch_now_ms(){
  local out=""
  if out="$(date +%s%3N 2>/dev/null)"; then
    printf '%s\n' "$out"
    return 0
  fi
  local epoch=""
  epoch="$(date +%s 2>/dev/null || true)"
  if [ -n "$epoch" ]; then
    printf '%s\n' "$((epoch * 1000))"
    return 0
  fi
  return 1
}

switch_auto_start_node(){
  local node_name="$1"
  if command -v ssctl >/dev/null 2>&1; then
    ssctl start "$node_name"
    return
  fi
  if [ -n "${SSCTL_SELF_PATH:-}" ] && [ -x "${SSCTL_SELF_PATH}" ]; then
    "${SSCTL_SELF_PATH}" start "$node_name"
    return
  fi
  if declare -F cmd_start >/dev/null 2>&1; then
    cmd_start "$node_name"
    return
  fi
  warn "未能自动启动节点：请手动执行 ssctl start ${node_name}"
}
