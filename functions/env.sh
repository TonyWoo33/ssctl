#!/usr/bin/env bash

emit_env_proxy(){  # 输出 export 语句，供 eval 使用；$1 = 节点名(可选)
  local name laddr lport
  name="$(resolve_name "${1:-}")"
  laddr="$(json_get "$name" local_address)"; [ -n "$laddr" ] || laddr="$DEFAULT_LOCAL_ADDR"
  lport="$(json_get "$name" local_port)";   [ -n "$lport" ] || lport="$DEFAULT_LOCAL_PORT"

  local proxy_url="socks5h://${laddr}:${lport}"
  cat <<EOF
# Use 'eval "\$(ssctl env proxy${1:+ }$1)"' to apply
export ALL_PROXY="${proxy_url}"
export all_proxy="${proxy_url}"
export http_proxy="${proxy_url}"
export https_proxy="${proxy_url}"
export ftp_proxy="${proxy_url}"
export HTTP_PROXY="${proxy_url}"
export HTTPS_PROXY="${proxy_url}"
export FTP_PROXY="${proxy_url}"
# 如果有内网/直连域名，请把它们加入 NO_PROXY/no_proxy（英文逗号分隔）
# 例：export NO_PROXY="localhost,127.0.0.1,.corp.local"
EOF
}

emit_env_noproxy(){  # 输出 unset 语句，供 eval 使用（关闭代理）
  cat <<'EOF'
# Use 'eval "$(ssctl env noproxy)"' to apply
unset ALL_PROXY all_proxy http_proxy https_proxy ftp_proxy
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY no_proxy
EOF
}

cmd_env(){
  self_check
  case "${1:-proxy}" in
    proxy)
      # ssctl env proxy [name]
      emit_env_proxy "${2:-}"
      ;;
    noproxy|off)
      emit_env_noproxy
      ;;
    *)
      die "用法：ssctl env [proxy [name] | noproxy]"
      ;;
  esac
}
