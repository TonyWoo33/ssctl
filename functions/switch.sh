#!/usr/bin/env bash

cmd_switch(){
  self_check
  local name="${1:-}"; [ -n "$name" ] || die "用法：ssctl switch <name>"
  local p; p="$(node_json_path "$name")"
  [ -f "$p" ] || die "不存在节点：$name"
  ln -sfn "$p" "${CURRENT_JSON}"
  ok "已切换当前节点：${name}"
  warn "提示：switch 不会自动启动；请执行：ssctl start"
}
