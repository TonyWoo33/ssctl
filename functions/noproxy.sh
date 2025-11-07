#!/usr/bin/env bash

cmd_noproxy(){
  self_check
  info "切换为 No Proxy（直连）模式：将停止所有 Shadowsocks 单元"
  stop_all_units
  # 清空 current 指向（表示当前为直连，不绑定任何节点）
  if [ -L "${CURRENT_JSON}" ]; then
    rm -f "${CURRENT_JSON}" || true
    ok "已清空 current 指向（当前为直连模式）"
  fi
  ok "所有代理单元已停止。"
  printf '%s\n' "如需在当前 shell 关闭环境代理，请执行："
  # shellcheck disable=SC2016
  printf '  %s\n' 'eval "$(ssctl env noproxy)"'
}
