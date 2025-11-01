#!/usr/bin/env bash

cmd_clear(){
  self_check
  info "清理 ssctl 生成的所有 sslocal-*.service（不删除 nodes/ 配置）"
  stop_all_units
  systemctl --user reset-failed || true
  ok "清理完成"
}
