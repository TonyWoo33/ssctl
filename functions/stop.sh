#!/usr/bin/env bash

cmd_stop(){
  self_check
  local name; name="$(resolve_name "${1:-}")"
  local node_path; node_path="$(node_json_path "$name")"
  if [ ! -f "$node_path" ]; then
    die "未找到节点配置: $name"
  fi
  local unit; unit="$(unit_name_for "$name")"
  if unit_exists "$name"; then
    ssctl_service_disable_now "$unit"
    rm -f "${SYS_DIR}/${unit}" 2>/dev/null || true
    ssctl_service_reload
    ok "已停止: $unit"
  else
    warn "尚未创建 unit：$unit（未启动过或已被 clear 清理）"
  fi
}
