#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

if [ -z "${SSCTL_LIB_DIR:-}" ]; then
  SSCTL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

if ! declare -f die >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  . "${SSCTL_LIB_DIR}/lib/common.sh"
fi

service_systemd_unit_dir(){
  printf '%s/systemd/user\n' "${XDG_CONFIG_HOME:-${HOME}/.config}"
}

service_systemd_resolve_realpath(){
  local target="${1:-}"
  [ -n "$target" ] || return 1
  if command -v readlink >/dev/null 2>&1; then
    local resolved=""
    resolved="$(readlink -f "$target" 2>/dev/null || true)"
    if [ -n "$resolved" ]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$target" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
    return 0
  fi
  local dir
  dir="$(cd "$(dirname "$target")" && pwd -P)" || return 1
  printf '%s/%s\n' "$dir" "$(basename "$target")"
}

service_systemd_prepare_enable_target(){
  local requested="${1:-}"
  [ -n "$requested" ] || die "service_systemd_prepare_enable_target 需要 unit 名称或路径"
  local unit_dir; unit_dir="$(service_systemd_unit_dir)"
  local unit_name="" unit_path=""

  if [[ "$requested" == /* ]]; then
    unit_path="$requested"
    unit_name="${requested##*/}"
  else
    unit_name="$requested"
    unit_path="${unit_dir}/${unit_name}"
  fi

  if [ ! -f "$unit_path" ]; then
    error "Unit file 在 enable 之前未在预期路径找到: $unit_path"
    return 1
  fi

  local resolved_path
  resolved_path="$(service_systemd_resolve_realpath "$unit_path" 2>/dev/null || true)"
  if [ -z "$resolved_path" ]; then
    resolved_path="$unit_path"
  fi

  printf '%s:%s\n' "$unit_name" "$resolved_path"
}

service_systemd_user_action(){
  local action="${1:-}"; shift || true
  [ -n "$action" ] || die "service_systemd_user_action 需要 action 参数"
  local output=""
  if ! output=$(systemctl --user "$action" "$@" 2>&1); then
    error "Systemd 操作 '$action' 失败: $output"
    return 1
  fi
  return 0
}

service_systemd_user_enable_now(){
  local unit="${1:-}"
  local explicit_path="${2:-}"
  local prepared
  prepared="$(service_systemd_prepare_enable_target "${explicit_path:-$unit}")" || return 1
  local derived_name="${prepared%%:*}"
  local unit_path="${prepared#*:}"
  local unit_name="${unit:-$derived_name}"

  local default_unit_dir="${HOME}/.config/systemd/user"
  local symlink_path="${default_unit_dir}/${unit_name}"
  rm -f "$symlink_path"

  service_systemd_user_action enable --now "$unit_path"
}

service_systemd_user_enable(){
  local unit="${1:-}"
  local explicit_path="${2:-}"
  local prepared
  prepared="$(service_systemd_prepare_enable_target "${explicit_path:-$unit}")" || return 1
  local derived_name="${prepared%%:*}"
  local unit_path="${prepared#*:}"
  local unit_name="${unit:-$derived_name}"

  # [v3.7.6] 清理默认路径中的陈旧符号链接，避免 enable 时冲突
  local default_unit_dir="${HOME}/.config/systemd/user"
  local symlink_path="${default_unit_dir}/${unit_name}"
  rm -f "$symlink_path"

  service_systemd_user_action enable "$unit_path"
}

service_systemd_user_link_and_enable(){
  local unit_path="${1:-}"
  local unit_name="${2:-}"
  [ -n "$unit_path" ] || die "service_systemd_user_link_and_enable 需要 unit 路径"
  [ -n "$unit_name" ] || die "service_systemd_user_link_and_enable 需要 unit 名称"

  if [ ! -f "$unit_path" ]; then
    error "Unit file 在 link 之前未找到: $unit_path"
    return 1
  fi

  local resolved_path
  resolved_path="$(service_systemd_resolve_realpath "$unit_path" 2>/dev/null || true)"
  [ -n "$resolved_path" ] || resolved_path="$unit_path"

  service_systemd_user_action link "$resolved_path"
  service_systemd_user_action enable "$unit_name"
}

service_systemd_user_disable_now(){
  local unit="$1"
  service_systemd_user_action disable --now "$unit"
}

service_systemd_user_start(){
  local unit="$1"
  service_systemd_user_action start "$unit"
}

service_systemd_user_stop(){
  local unit="$1"
  service_systemd_user_action stop "$unit"
}

service_systemd_user_daemon_reload(){
  service_systemd_user_action daemon-reload
}

service_systemd_user_reload(){
  service_systemd_user_daemon_reload
}

service_systemd_create(){
  local unit_name="${1:?service_systemd_create 需要 unit 名称}"
  local definition="${2:-}"
  local description="ssctl managed service (${unit_name})"
  local exec_start=""
  local restart="on-failure"
  local restart_sec=""
  local envs=()
  local service_opts=()

  while IFS= read -r line; do
    line="${line%%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    [[ "$line" == \#* ]] && continue
    local key="${line%%=*}"
    local value="${line#*=}"
    case "$key" in
      Description) description="$value" ;;
      ExecStart) exec_start="$value" ;;
      Restart) restart="$value" ;;
      RestartSec) restart_sec="$value" ;;
      Environment) envs+=("$value") ;;
      ServiceOption) service_opts+=("$value") ;;
      *)
        service_opts+=("${key}=${value}")
        ;;
    esac
  done <<<"$definition"

  [ -n "$exec_start" ] || die "service_systemd_create: 缺少 ExecStart"

  local unit_content="[Unit]
Description=${description}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${exec_start}
Restart=${restart}
"

  if [ -n "$restart_sec" ]; then
    unit_content+="RestartSec=${restart_sec}
"
  fi

  local env_entry
  for env_entry in "${envs[@]}"; do
    unit_content+="Environment=${env_entry}
"
  done

  local opt_entry
  for opt_entry in "${service_opts[@]}"; do
    unit_content+="${opt_entry}
"
  done

  unit_content+="
[Install]
WantedBy=default.target
"

  local config_root="${XDG_CONFIG_HOME:-${HOME}/.config}"
  local unit_dir="${config_root}/systemd/user"
  local unit_path="${unit_dir}/${unit_name}"
  if ! mkdir -p "$unit_dir"; then
    warn "无法创建 systemd 目录：$unit_dir"
    return 1
  fi
  if ! printf '%s\n' "$unit_content" > "$unit_path"; then
    warn "无法写入 unit 文件：$unit_path"
    return 1
  fi
  chmod 600 "$unit_path" 2>/dev/null || true

  local resolved_path
  resolved_path="$(service_systemd_resolve_realpath "$unit_path" 2>/dev/null || true)"
  printf '%s\n' "${resolved_path:-$unit_path}"
}

service_systemd_cache_unit_states(){
  local patterns=("$@") unit
  if [ ${#patterns[@]} -eq 0 ]; then
    patterns=('sslocal-*.service' 'v2ray-*.service')
  fi
  local snapshot
  snapshot="$(systemctl --user list-units --full --all --plain --no-legend "${patterns[@]}" 2>/dev/null || true)"
  __SSCTL_UNIT_STATE_CACHE=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    read -r unit _ active sub _rest <<<"$line"
    [ -n "$unit" ] || continue
    __SSCTL_UNIT_STATE_CACHE["$unit"]="${active:-}:${sub:-}"
  done <<<"$snapshot"
}

service_systemd_cached_unit_state(){
  local unit="$1"
  printf '%s\n' "${__SSCTL_UNIT_STATE_CACHE[$unit]:-}"
}

service_systemd_unit_active_cached(){
  local unit="$1"
  local state
  state="$(service_systemd_cached_unit_state "$unit")"
  case "$state" in
    active:*) return 0 ;;
  esac
  return 1
}

service_systemd_unit_exists(){
  local unit="$1"
  systemctl --user list-unit-files --no-legend "$unit" 2>/dev/null | awk '{print $1}' | grep -qx "$unit"
}

service_systemd_current_running_node(){
  local u name=""
  u="$(systemctl --user list-units --no-legend 'sslocal-*.service' 'v2ray-*.service' 2>/dev/null | awk '$4=="running"{print $1}' | head -n1)"
  [ -n "$u" ] || return 1
  case "$u" in
    sslocal-*)
      name="${u#sslocal-}"
      name="${name%.service}"
      name="${name%-*}"
      ;;
    v2ray-*)
      name="${u#v2ray-}"
      name="${name%.service}"
      ;;
  esac
  if [ -n "$name" ] && is_safe_identifier "$name"; then
    printf "%s\n" "$name"
  else
    warn "检测到非法运行节点名称：$name"
    return 1
  fi
}

service_systemd_stop_all_units(){
  local any=0
  local units
  units="$(systemctl --user list-unit-files 'sslocal-*' 'v2ray-*' --no-legend | awk '{print $1}')"

  if [ -n "$units" ]; then
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      any=1
      service_systemd_user_disable_now "$u" || true
      rm -f "${SYS_DIR}/${u}" 2>/dev/null || true
      echo " - stopped $u"
    done <<< "$units"

    if [ "$any" = 1 ]; then
      service_systemd_user_daemon_reload || true
    fi
  fi
}

service_systemd_reset_failed_units(){
  systemctl --user reset-failed || true
}

service_systemd_show_status(){
  local unit="$1"
  systemctl --user status --no-pager "$unit" || true
}

service_systemd_get_pid(){
  local name="$1" unit="$2" provided_port="${3:-}" pid="" cfg=""
  if [[ "$name" == *.service ]]; then
    unit="$name"
    name=""
  elif [ -z "$unit" ] && command -v unit_name_for >/dev/null 2>&1; then
    unit="$(unit_name_for "$name")"
  fi

  if [ -n "$unit" ] && command -v systemctl >/dev/null 2>&1; then
    pid="$(systemctl --user show "$unit" -p MainPID --value 2>/dev/null | tr -d ' ' || true)"
    case "$pid" in
      ''|0) pid="" ;;
    esac
  fi

  if [ -n "$pid" ]; then
    printf '%s\n' "$pid"
    return 0
  fi

  if [ -z "$name" ]; then
    return 1
  fi

  if command -v node_json_path >/dev/null 2>&1; then
    cfg="$(node_json_path "$name" 2>/dev/null || true)"
  fi

  local patterns=()
  if [ -n "$cfg" ]; then
    patterns+=("sslocal.*${cfg}" "ss-local.*${cfg}" "v2ray.*${cfg}")
  fi
  local port="$provided_port"
  if [ -z "$port" ] && command -v json_get >/dev/null 2>&1; then
    port="$(json_get "$name" local_port 2>/dev/null || true)"
    [ -n "$port" ] || port=""
  fi
  if [ -n "$port" ]; then
    patterns+=("sslocal.*:${port}" "ss-local.*:${port}" "v2ray.*:${port}")
  fi

  if [ ${#patterns[@]} -gt 0 ] && command -v pgrep >/dev/null 2>&1; then
    local pat
    for pat in "${patterns[@]}"; do
      pid="$(pgrep -f "$pat" 2>/dev/null | head -n1 || true)"
      [ -n "$pid" ] && { printf '%s\n' "$pid"; return 0; }
    done
  fi

  return 1
}

# Generic interface wrappers
service_systemd_reload(){ service_systemd_user_reload "$@"; }
service_systemd_start(){ service_systemd_user_start "$@"; }
service_systemd_stop(){ service_systemd_user_stop "$@"; }
service_systemd_enable(){ service_systemd_user_enable "$@"; }
service_systemd_enable_now(){ service_systemd_user_enable_now "$@"; }
service_systemd_disable_now(){ service_systemd_user_disable_now "$@"; }
service_systemd_link_and_enable(){ service_systemd_user_link_and_enable "$@"; }
service_systemd_is_active(){ service_systemd_unit_active_cached "$@"; }
