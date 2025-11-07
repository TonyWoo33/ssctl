#!/usr/bin/env bash

init_dirs(){
  umask 077
  mkdir -p "${NODES_DIR}" "${SYS_DIR}"
  chmod 700 "${CONF_DIR}" "${NODES_DIR}"
}

engine_check(){
  local engine="$1"
  case "$engine" in
    rust)
      [ -x "${BIN_RUST_PATH}" ] || die "找不到 sslocal，请安装 shadowsocks-rust。"
      ;;
    libev)
      [ -x "${BIN_LIBEV_PATH}" ] || die "需要 shadowsocks-libev：未找到 ss-local。"
      ;;
  esac
}

node_json_path(){
  local name="$1"
  require_safe_identifier "$name" "节点名"
  local path="${NODES_DIR}/${name}.json"
  ensure_node_path_safe "$path"
  printf '%s\n' "$path"
}

resolve_name(){
  local name="${1:-}"
  if [ -z "$name" ] || [ "$name" = "current" ]; then
    [ -L "${CURRENT_JSON}" ] || die "当前未设置默认节点：请先 ssctl switch <name>"
    local target_path resolved_name
    target_path="$(readlink -f "${CURRENT_JSON}" 2>/dev/null || true)"
    [ -n "$target_path" ] || die "无法解析 current 指向：${CURRENT_JSON}"
    ensure_node_path_safe "$target_path"
    resolved_name="$(basename "$target_path" .json)"
    require_safe_identifier "$resolved_name" "节点名"
    printf '%s\n' "$resolved_name"
  else
    require_safe_identifier "$name" "节点名"
    printf '%s\n' "$name"
  fi
}

json_get(){
  local name="$1" key="$2"
  local p; p="$(node_json_path "$name")"
  [ -r "$p" ] || die "找不到或无法读取节点 JSON：$p"
  jq -r ".${key} // empty" <"$p"
}

list_nodes(){
  for f in "${NODES_DIR}"/*.json; do
    [ -e "$f" ] || continue
    base="$(basename "${f%.json}")"
    case "$base" in
      _libev_*) continue ;;
    esac
    if is_safe_identifier "$base"; then
      printf "%s\n" "$base"
    else
      warn "检测到非法节点文件名，已忽略：$base"
    fi
  done
}

unit_name_for(){
  local name="$1"
  local lp; lp="$(json_get "$name" local_port)"; [ -n "$lp" ] || lp="${DEFAULT_LOCAL_PORT}"
  printf "sslocal-%s-%s.service" "$name" "$lp"
}

is_aead_method(){
  case "$1" in
    chacha20-ietf-poly1305|xchacha20-ietf-poly1305|aes-256-gcm|aes-128-gcm) return 0 ;;
    *) return 1 ;;
  esac
}

pick_engine(){
  local name="$1"
  local engine method
  engine="$(json_get "$name" engine | tr '[:upper:]' '[:lower:]')"
  method="$(json_get "$name" method | tr '[:upper:]' '[:lower:]')"
  case "$engine" in
    rust|libev) echo "$engine" ;;
    auto|"")    if is_aead_method "$method"; then echo "rust"; else echo "libev"; fi ;;
    *)          warn "未知 engine=${engine}，按 auto 处理"; if is_aead_method "$method"; then echo "rust"; else echo "libev"; fi ;;
  esac
}

unit_exists(){
  local name="$1" u; u="$(unit_name_for "$name")"
  systemctl --user list-unit-files --no-legend "$u" 2>/dev/null | awk '{print $1}' | grep -qx "$u"
}

current_running_node(){
  local u core name
  u="$(systemctl --user list-units --no-legend 'sslocal-*.service' 2>/dev/null | awk '$4=="running"{print $1}' | head -n1)"
  [ -n "$u" ] || return 1
  core="${u#sslocal-}"
  core="${core%.service}"
  name="${core%-*}"
  if is_safe_identifier "$name"; then
    printf "%s\n" "$name"
  else
    warn "检测到非法运行节点名称：$name"
    return 1
  fi
}

stop_all_units(){
  set +e
  local any=0
  while read -r u; do
    [ -n "$u" ] || continue
    any=1
    systemctl --user disable --now "$u" 2>/dev/null || true
    rm -f "${SYS_DIR}/${u}" 2>/dev/null || true
    echo " - stopped $u"
  done < <(systemctl --user list-unit-files 'sslocal-*' --no-legend | awk '{print $1}')
  [ "$any" = 1 ] && systemctl --user daemon-reload || true
  set -e
}

write_unit(){
  local name="$1"
  ssctl_read_config
  local json_path; json_path="$(node_json_path "$name")"
  [ -r "$json_path" ] || die "找不到节点 JSON：$json_path"
  local unit; unit="$(unit_name_for "$name")"

  local lp; lp="$(json_get "$name" local_port)"; [ -n "$lp" ] || lp="${DEFAULT_LOCAL_PORT}"
  local engine; engine="$(pick_engine "$name")"
  engine_check "$engine"

  local exec_path=""
  case "$engine" in
    rust)  exec_path="${BIN_RUST_PATH}" ;;
    libev) exec_path="${BIN_LIBEV_PATH}" ;;
  esac
  if [ "$engine" = "libev" ] && [ ! -x "$exec_path" ]; then
    die "需要 shadowsocks-libev：未找到 ss-local。请先安装：sudo apt install -y shadowsocks-libev"
  fi

  local run_cfg="${json_path}"
  if [ "$engine" = "libev" ]; then
    run_cfg="${NODES_DIR}/_libev_${name}.json"
    jq -n \
      --argjson server_port "$(jq -r '.server_port' "$json_path")" \
      --arg server       "$(jq -r '.server' "$json_path")" \
      --arg password     "$(jq -r '.password' "$json_path")" \
      --arg method       "$(jq -r '.method' "$json_path")" \
      --arg laddr        "$(jq -r '.local_address // "127.0.0.1"' "$json_path")" \
      --argjson lport    "$(jq -r '.local_port // 1080' "$json_path")" \
      --arg plugin       "$(jq -r '.plugin // empty' "$json_path")" \
      --arg plugin_opts  "$(jq -r '.plugin_opts // empty' "$json_path")" \
      --argjson timeout  "$(jq -r '.timeout // 300' "$json_path")" \
      '{
         server: $server,
         server_port: $server_port,
         password: $password,
         method: $method,
         local_address: $laddr,
         local_port: $lport,
         timeout: $timeout
       }
       + (if ($plugin|length)>0 then {plugin:$plugin} else {} end)
       + (if ($plugin_opts|length)>0 then {plugin_opts:$plugin_opts} else {} end)' \
      > "$run_cfg"
    chmod 600 "$run_cfg"
  fi

  local log_level="${SSCTL_LOG_LEVEL:-info}"
  local log_path="$(ssctl_default_log_path "$name")"
  mkdir -p "$(dirname "$log_path")"
  touch "$log_path"
  chmod 600 "$log_path" 2>/dev/null || true

  cat > "${SYS_DIR}/${unit}" <<EOF
[Unit]
Description=Shadowsocks local client (${name}:${lp}, engine=${engine})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart="${exec_path}" -c "${run_cfg}"
Restart=always
RestartSec=2s
Environment=SSCTL_LOG_LEVEL=${log_level}
Environment=SSCTL_LOG_PATH=${log_path}
Environment=RUST_LOG=${log_level}

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=read-only
UMask=0077
ReadWritePaths=${CONF_DIR}
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

LimitNOFILE=1048576

[Install]
WantedBy=default.target
EOF
  chmod 600 "${SYS_DIR}/${unit}"
  ok "已生成 unit: ${unit}"
}
