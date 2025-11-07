#!/usr/bin/env bash

cmd_start(){
  self_check
  local name; name="$(resolve_name "${1:-}")"
  info "为保证单实例，先停止所有已存在的 Shadowsocks 单元…"
  stop_all_units

  write_unit "$name"
  systemctl --user daemon-reload
  systemctl --user enable --now "$(unit_name_for "$name")"
  ok "已启动: $(unit_name_for "$name")"

  # 更新 current 指向
  ln -sfn "$(node_json_path "$name")" "${CURRENT_JSON}"
  ok "已设为当前节点：${name}"

  # 等待端口就绪后再探测，避免“刚起就查”的误报
  if wait_listen "$name" 8; then
    set +e; probe "$name"; local rc=$?; set -e
  else
    warn "服务刚启动，端口尚未监听（可能仍在初始化）"
    warn "可稍后运行：ssctl probe ${name}"
    rc=1
  fi

  return "$rc"
}
