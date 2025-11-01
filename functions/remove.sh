#!/usr/bin/env bash

cmd_remove(){
  self_check
  local name="$1"; shift || true
  [ -n "$name" ] || die "用法：ssctl remove <name> [--purge] [-y|--yes]"

  local purge=0 yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge) purge=1; shift ;;
      -y|--yes) yes=1; shift ;;
      *) die "未知参数：$1" ;;
    esac
  done

  local unit; unit="$(unit_name_for "$name")"
  local main_json; main_json="$(node_json_path "$name")"
  local libev_json="${NODES_DIR}/_libev_${name}.json"

  # 停止并清理 unit
  if systemctl --user list-unit-files --no-legend "$unit" | awk '{print $1}' | grep -qx "$unit"; then
    systemctl --user disable --now "$unit" 2>/dev/null || true
    rm -f "${SYS_DIR}/${unit}" 2>/dev/null || true
    systemctl --user daemon-reload
    ok "已删除 unit：$unit"
  else
    warn "未发现 unit：$unit（可能未创建或已清理）"
  fi

  # 删除 _libev_ 兼容文件
  if [ -f "$libev_json" ]; then
    rm -f "$libev_json"
    ok "已删除：$libev_json"
  fi

  # 是否删除主配置
  if [ "$purge" -eq 1 ]; then
    if [ "$yes" -ne 1 ]; then
      read -r -p "确认永久删除配置 ${main_json} ? [y/N] " ans
      case "${ans:-N}" in y|Y) ;; *) warn "已取消 purge"; return 0 ;; esac
    fi
    if [ -f "$main_json" ]; then
      rm -f "$main_json"
      ok "已删除：$main_json"
    else
      warn "未找到配置文件：$main_json"
    fi
  else
    info "保留配置文件：$main_json（如需一并删除请使用 --purge）"
  fi

  # 如 current 指向被删节点 → 解除指向
  if [ -L "${CURRENT_JSON}" ]; then
    local cur="$(basename "$(readlink -f "${CURRENT_JSON}")" .json 2>/dev/null || true)"
    if [ "$cur" = "$name" ]; then
      rm -f "${CURRENT_JSON}"
      warn "current 指向已清空（原指向为：$name）"
      # 若还有其他节点，提示用户切换
      local next; next="$(list_nodes | head -n1 || true)"
      [ -n "$next" ] && info "可切换到：ssctl switch $next"
    fi
  fi
}
