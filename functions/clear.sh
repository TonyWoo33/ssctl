#!/usr/bin/env bash

cmd_clear(){
  self_check
  info "清理 ssctl 生成的所有 sslocal-*/v2ray-*.service（不删除 nodes/ 配置）"
  stop_all_units
  ssctl_service_reset_failed_units
  ok "清理完成"
}
