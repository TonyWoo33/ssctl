#!/usr/bin/env bash

probe(){
  local name; name="$(resolve_name "${1:-}")"
  local url="${2:-$DEFAULT_PROBE_URL}"

  local laddr lport unit
  laddr="$(json_get "$name" local_address)"; [ -n "$laddr" ] || laddr="$DEFAULT_LOCAL_ADDR"
  lport="$(json_get "$name" local_port)";   [ -n "$lport" ] || lport="$DEFAULT_LOCAL_PORT"
  unit="$(unit_name_for "$name")"

  info "节点: ${name}  本地代理: ${laddr}:${lport}"

  if ! systemctl --user is-active --quiet "$unit"; then
    warn "服务未启动：$unit"
    warn "提示：先执行 ssctl start${1:+ }$name"
    return 1
  fi

  if command -v nc >/dev/null 2>&1; then
    if ! nc -z "$laddr" "$lport" -w 2; then
      warn "端口未监听：${laddr}:${lport}"
      return 1
    fi
  else
    if ! (exec 3<>/dev/tcp/${laddr}/${lport}) 2>/dev/null; then
      warn "端口未监听：${laddr}:${lport}"
      return 1
    fi
    exec 3>&-
  fi

  info "STEP A: 代理+DNS 访问 ${url}"
  if curl -sS -I --connect-timeout 6 --max-time 10 --socks5-hostname "${laddr}:${lport}" "${url}" -o /dev/null; then
    ok "HTTP 探测（带 DNS）: 连通"
  else
    rc=$?
    warn "HTTP 探测失败，curl 码: ${rc}"
    info "STEP B: 仅链路 http://1.1.1.1"
    if curl -sS -I --connect-timeout 6 --max-time 10 --socks5 "${laddr}:${lport}" "http://1.1.1.1" -o /dev/null; then
      warn "链路可用但域名失败 → rust 可在 JSON 用 dns；libev 使用系统 DNS"
    else
      warn "链路不可用 → 查看：journalctl --user -u ${unit} -e --no-pager"
    fi
    return 1
  fi

  local ip country
  ip="$(curl -sS --connect-timeout 4 --max-time 6 --socks5-hostname "${laddr}:${lport}" https://ifconfig.me || true)"
  country="$(curl -sS --connect-timeout 4 --max-time 6 --socks5-hostname "${laddr}:${lport}" https://ipinfo.io/country || true)"
  [ -n "$ip" ] && ok "出口 IP: ${ip}"
  [ -n "$country" ] && ok "国家/地区: ${country}"
}
