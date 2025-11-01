#!/usr/bin/env bash

cmd_stop(){
  self_check
  local name; name="$(resolve_name "${1:-}")"
  local unit; unit="$(unit_name_for "$name")"
  if unit_exists "$name"; then
    systemctl --user disable --now "$unit" 2>/dev/null || true
    rm -f "${SYS_DIR}/${unit}" 2>/dev/null || true
    systemctl --user daemon-reload
    ok "已停止: $unit"
  else
    warn "尚未创建 unit：$unit（未启动过或已被 clear 清理）"
  fi
}
