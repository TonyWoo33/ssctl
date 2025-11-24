#!/usr/bin/env bash

cmd_switch(){
  self_check

  local use_best=0 latency_url="" show_help=0
  local positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --best)
        use_best=1; shift ;;
      --url)
        [ $# -ge 2 ] || die "--url 需要一个参数"
        latency_url="$2"; shift 2 ;;
      --url=*)
        latency_url="${1#*=}"; shift ;;
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
  ssctl switch --best [--url URL]
说明：
  - 更新 current.json 指向指定节点，但不会自动启动。
  - --best 会调用 latency --json，选择延迟最低且 ok:true 的节点。
  - --url 仅在 --best 模式下生效，用于覆盖 latency 采样 URL。
DOC
    return 0
  fi

  if [ "$use_best" -eq 0 ] && [ -n "$latency_url" ]; then
    die "--url 仅可与 --best 一起使用"
  fi

  local name="${positional[0]:-}" best_latency=""
  if [ "$use_best" -eq 1 ]; then
    [ -z "$name" ] || die "--best 模式下无需指定节点名"
    local best_candidate_name="" best_candidate_latency=""
    if ! switch_pick_best_candidate "$latency_url" best_candidate_name best_candidate_latency; then
      return 1
    fi
    name="$best_candidate_name"
    best_latency="$best_candidate_latency"
    info "自动选择节点：${name}（${best_latency} ms）"
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
  local latency_url="$1" out_name_var="${2:-}" out_latency_var="${3:-}"
  [ -n "$out_name_var" ] || die "内部错误：缺少 name 输出引用"
  [ -n "$out_latency_var" ] || die "内部错误：缺少 latency 输出引用"

  local payload=""
  payload="$(switch_fetch_latency_payload "$latency_url")"
  local best_json=""
  if ! best_json="$(jq -er '
    .results
    | map(select((.ok == true)
                 and (.latency_ms | type == "number")
                 and (.latency_ms > 0)))
    | if length == 0 then error("no candidates") else sort_by(.latency_ms) | .[0] end
  ' <<<"$payload" 2>/dev/null)"; then
    die "未找到可用节点（latency 结果均为 INACTIVE/timeout）"
    return 1
  fi

  local best_name="" best_latency=""
  best_name="$(jq -r '.name' <<<"$best_json")"
  best_latency="$(jq -r '.latency_ms' <<<"$best_json")"
  printf -v "$out_name_var" '%s' "$best_name"
  printf -v "$out_latency_var" '%s' "$best_latency"
  return 0
}

switch_fetch_latency_payload(){
  local latency_url="$1"
  local latency_args=(--json)
  if [ -n "$latency_url" ]; then
    latency_args+=("--url" "$latency_url")
  fi

  if declare -F cmd_latency >/dev/null 2>&1; then
    cmd_latency "${latency_args[@]}"
    return
  fi
  if [ -n "${SSCTL_SELF_PATH:-}" ] && [ -x "${SSCTL_SELF_PATH}" ]; then
    "${SSCTL_SELF_PATH}" latency "${latency_args[@]}"
    return
  fi
  if command -v ssctl >/dev/null 2>&1; then
    ssctl latency "${latency_args[@]}"
    return
  fi
  die "未找到 latency 命令（请确保 ssctl 在 PATH 或已加载 cmd_latency）"
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
