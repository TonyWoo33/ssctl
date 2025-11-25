#!/usr/bin/env bash

init_dirs(){
  umask 077
  mkdir -p "${NODES_DIR}" "${SYS_DIR}"
  chmod 700 "${CONF_DIR}" "${NODES_DIR}"
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
      _libev_*|_rust_*) continue ;;
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

unit_name_from_json(){
  local node_json="${1:?unit_name_from_json 需要 node_json}"
  local name
  name="$(jq -r '.__name // empty' <<<"$node_json")"
  [ -n "$name" ] || die "unit_name_from_json: 缺少 __name"

  local engine port
  engine="$(jq -r '.engine // "shadowsocks"' <<<"$node_json")"
  engine="${engine,,}"
  case "$engine" in
    v2ray)
      printf 'v2ray-%s.service\n' "$name"
      ;;
    ""|auto|shadowsocks|rust|libev)
      port="$(jq -r '.local_port // empty' <<<"$node_json")"
      [ -n "$port" ] || port="$DEFAULT_LOCAL_PORT"
      printf 'sslocal-%s-%s.service\n' "$name" "$port"
      ;;
    *)
      # 非 shadowsocks/v2ray 的其他引擎暂时沿用 shadowsocks 命名规则
      port="$(jq -r '.local_port // empty' <<<"$node_json")"
      [ -n "$port" ] || port="$DEFAULT_LOCAL_PORT"
      printf 'sslocal-%s-%s.service\n' "$name" "$port"
      ;;
  esac
}

unit_name_for(){
  local name="$1"
  local json_path; json_path="$(node_json_path "$name")"
  local node_json
  node_json="$(jq -c --arg n "$name" '. + {__name:$n}' "$json_path")"
  unit_name_from_json "$node_json"
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
    ""|auto|shadowsocks)
      if is_aead_method "$method"; then
        echo "rust"
      else
        echo "libev"
      fi
      ;;
    rust|libev)
      echo "$engine"
      ;;
    v2ray)
      echo "v2ray"
      ;;
    hysteria2)
      echo "hysteria2"
      ;;
    *)
      die "不支持的 engine: $engine"
      ;;
  esac
}

unit_exists(){
  local name="$1"
  local unit; unit="$(unit_name_for "$name")"
  ssctl_service_unit_exists "$unit"
}

current_running_node(){
  ssctl_service_current_running_node
}

stop_all_units(){
  ssctl_service_stop_all_units
}

protocol_load_impl(){
  local protocol="$1"
  require_safe_identifier "$protocol" "协议字段"
  local protocol_file="${SSCTL_LIB_DIR}/protocols/${protocol}.sh"
  [ -f "$protocol_file" ] || die "未找到协议实现：${protocol_file}"
  local fn="protocol_${protocol}_get_unit_name"
  if ! declare -f "$fn" >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    . "$protocol_file"
  fi
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
declare -Ag __SSCTL_SERVICE_IMPL_LOADED=()

__SSCTL_SERVICE_IMPL=""

if [ -z "${APP_LIB_DIR:-}" ]; then
  if [ -n "${SSCTL_LIB_DIR:-}" ]; then
    APP_LIB_DIR="${SSCTL_LIB_DIR}/lib"
  else
    APP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
fi

ssctl_service_detect_impl(){
  local uname_out
  uname_out="$(uname -s 2>/dev/null || echo unknown)"
  case "$uname_out" in
    Darwin) echo "launchd"; return 0 ;;
  esac
  if command -v systemctl >/dev/null 2>&1 && [ -d "/run/user/${UID}/systemd" ]; then
    echo "systemd"
    return 0
  fi
  echo ""
}

ssctl_service_require_impl(){
  if [ -z "${__SSCTL_SERVICE_IMPL:-}" ]; then
    local impl
    impl="$(ssctl_service_detect_impl)"
    [ -n "$impl" ] || die "不支持的服务管理器：仅支持 systemd (Linux) 与 launchd (macOS)。"
    __SSCTL_SERVICE_IMPL="$impl"
  fi

  local impl="${__SSCTL_SERVICE_IMPL}"
  if [ "${__SSCTL_SERVICE_IMPL_LOADED[$impl]:-0}" -eq 0 ]; then
    local impl_file="${APP_LIB_DIR}/services/${impl}.sh"
    [ -f "$impl_file" ] || die "缺少服务管理器实现：${impl_file}"
    # shellcheck disable=SC1090
    . "$impl_file"
    __SSCTL_SERVICE_IMPL_LOADED["$impl"]=1
  fi
}

__ssctl_service_call(){
  local action="$1"; shift
  ssctl_service_require_impl
  local impl="${__SSCTL_SERVICE_IMPL}"
  local func="service_${impl}_${action}"
  if ! declare -f "$func" >/dev/null 2>&1; then
    die "服务实现 ${impl} 缺少函数 ${func}"
  fi
  "$func" "$@"
}

ssctl_service_create(){ __ssctl_service_call create "$@"; }
ssctl_service_reload(){ __ssctl_service_call reload "$@"; }
ssctl_service_cache_unit_states(){ __ssctl_service_call cache_unit_states "$@"; }
ssctl_service_is_active(){ __ssctl_service_call is_active "$@"; }
ssctl_service_start(){ __ssctl_service_call start "$@"; }
ssctl_service_stop(){ __ssctl_service_call stop "$@"; }
ssctl_service_enable(){ __ssctl_service_call enable "$@"; }
ssctl_service_enable_now(){ __ssctl_service_call enable_now "$@"; }
ssctl_service_disable_now(){ __ssctl_service_call disable_now "$@"; }
ssctl_service_link_and_enable(){ __ssctl_service_call link_and_enable "$@"; }
ssctl_service_get_pid(){ __ssctl_service_call get_pid "$@"; }
ssctl_service_unit_exists(){ __ssctl_service_call unit_exists "$@"; }
ssctl_service_current_running_node(){ __ssctl_service_call current_running_node; }
ssctl_service_stop_all_units(){ __ssctl_service_call stop_all_units; }
ssctl_service_reset_failed_units(){ __ssctl_service_call reset_failed_units "$@"; }
ssctl_service_show_status(){ __ssctl_service_call show_status "$@"; }
