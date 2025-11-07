#!/usr/bin/env bash

init_dirs(){
  umask 077
  mkdir -p "${NODES_DIR}" "${SYS_DIR}"
  chmod 700 "${CONF_DIR}" "${NODES_DIR}"
}

systemd_user_action(){
  local action="${1:-}"; shift || true
  [ -n "$action" ] || die "systemd_user_action 需要 action 参数"
  local output=""
  if ! output=$(systemctl --user "$action" "$@" 2>&1); then
    error "Systemd 操作 '$action' 失败: $output"
    return 1
  fi
  return 0
}

systemd_user_enable_now(){
  local unit="$1"
  systemd_user_action enable --now "$unit"
}

systemd_user_disable_now(){
  local unit="$1"
  systemd_user_action disable --now "$unit"
}

systemd_user_daemon_reload(){
  systemd_user_action daemon-reload
}

engine_check(){
  local engine="$1" binary_path="${2:-}"
  if [ -z "$binary_path" ]; then
    binary_path="$(engine_binary_path "$engine")"
  fi
  case "$engine" in
    rust)
      [ -x "$binary_path" ] || die "找不到 sslocal，请安装 shadowsocks-rust。"
      ;;
    libev)
      [ -x "$binary_path" ] || die "需要 shadowsocks-libev：未找到 ss-local。"
      ;;
  esac
}

engine_binary_path(){
  local engine="$1" path=""
  case "$engine" in
    rust)
      path="$(command -v "${BIN_RUST}" 2>/dev/null || true)"
      ;;
    libev)
      path="$(command -v "${BIN_LIBEV}" 2>/dev/null || true)"
      ;;
  esac
  printf '%s\n' "$path"
}

declare -Ag __SSCTL_UNIT_STATE_CACHE=()

systemd_cache_unit_states(){
  local pattern="${1:-sslocal-*.service}"
  local snapshot
  snapshot="$(systemctl --user list-units --full --all --plain --no-legend "$pattern" 2>/dev/null || true)"
  __SSCTL_UNIT_STATE_CACHE=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    read -r unit _ active sub _rest <<<"$line"
    [ -n "$unit" ] || continue
    __SSCTL_UNIT_STATE_CACHE["$unit"]="${active:-}:${sub:-}"
  done <<<"$snapshot"
}

systemd_cached_unit_state(){
  local unit="$1"
  printf '%s\n' "${__SSCTL_UNIT_STATE_CACHE[$unit]:-}"
}

systemd_unit_active_cached(){
  local unit="$1"
  local state
  state="$(systemd_cached_unit_state "$unit")"
  case "$state" in
    active:*) return 0 ;;
  esac
  return 1
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

nodes_json_stream(){
  local names=("$@")
  local files=()
  local name path
  if [ ${#names[@]} -eq 0 ]; then
    return 0
  fi
  for name in "${names[@]}"; do
    path="$(node_json_path "$name")"
    [ -r "$path" ] || die "找不到节点 JSON：$path"
    files+=("$path")
  done
  jq -nc '
    def node_name:
      input_filename
      | (split("/") | last)
      | (if endswith(".json") then rtrimstr(".json") else . end);
    inputs | . + {__name: node_name}
  ' "${files[@]}"
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
    systemd_user_disable_now "$u" || true
    rm -f "${SYS_DIR}/${u}" 2>/dev/null || true
    echo " - stopped $u"
  done < <(systemctl --user list-unit-files 'sslocal-*' --no-legend | awk '{print $1}')
  if [ "$any" = 1 ]; then
    systemd_user_daemon_reload || true
  fi
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
  local exec_path; exec_path="$(engine_binary_path "$engine")"
  engine_check "$engine" "$exec_path"
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
  local log_path
  log_path="$(ssctl_default_log_path "$name")"
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
