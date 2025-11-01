#!/usr/bin/env bash

cmd_show(){
  self_check

  local show_qrcode=0
  if [ "${2:-}" = "--qrcode" ] || [ "${1:-}" = "--qrcode" ]; then
    show_qrcode=1
  fi

  # —— 自动自愈：有运行中的节点时，若 current 指向不同，自动纠正 —— 
  if run_now="$(current_running_node)"; then
    if [ -L "${CURRENT_JSON}" ]; then
      cur_now="$(basename "$(readlink -f "${CURRENT_JSON}")" .json 2>/dev/null || true)"
    else
      cur_now=""
    fi
    if [ "${cur_now}" != "${run_now}" ]; then
      ln -sfn "$(node_json_path "${run_now}")" "${CURRENT_JSON}"
      ok "已将 current 指向运行中的节点：${run_now}"
    fi
  fi

  local target name arg="${1:-}"
  if [ "$arg" = "--qrcode" ]; then arg=""; fi # arg is not the name if it is --qrcode

  if name="$(current_running_node)"; then
    target="$name"
  else
    target="$(resolve_name "${arg}")"
  fi

  if [ "$show_qrcode" -eq 1 ]; then
    need_bin qrencode
    local json_path; json_path="$(node_json_path "$target")"
    local method password server port tag
    method=$(jq -r '.method' "$json_path")
    password=$(jq -r '.password' "$json_path")
    server=$(jq -r '.server' "$json_path")
    port=$(jq -r '.server_port' "$json_path")
    tag=$(url_encode "$target")

    local creds_b64
    creds_b64=$(echo -n "${method}:${password}" | base64 | tr -d '\n')
    local ss_link="ss://${creds_b64}@${server}:${port}#${tag}"
    
    info "节点 \"$target\" 的分享链接 (二维码):"
    qrencode -t ANSIUTF8 "$ss_link"
    echo "链接: $ss_link"
  else
    local path; path="$(node_json_path "$target")"
    jq . <"$path" || true
    echo

    local unit; unit="$(unit_name_for "$target")"
    if systemctl --user is-active --quiet "$unit"; then
      systemctl --user status --no-pager "$unit" || true
    else
      if unit_exists "$target"; then
        warn "服务未启动：$unit"
      else
        warn "尚未创建 unit：$unit（未启动过或已被 clear 清理）"
      fi
    fi

    if name="$(current_running_node)"; then
      ok "正在运行的节点：$name"
    else
      warn "当前没有运行中的节点"
    fi
    if [ -L "${CURRENT_JSON}" ]; then
      ok "current 指向：$(basename "$(readlink -f "${CURRENT_JSON}")" .json)"
    else
      warn "current 尚未设置（可用：ssctl switch <name>）"
    fi
  fi
}
