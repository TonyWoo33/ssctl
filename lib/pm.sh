#!/usr/bin/env bash
set -Eeuo pipefail

if [ -z "${SSCTL_LIB_DIR:-}" ]; then
  SSCTL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

pm_backend_detect(){
  local os_name
  os_name="${SSCTL_MOCK_OS:-$(uname -s 2>/dev/null || echo Linux)}"
  case "$os_name" in
    Darwin) PM_BACKEND="launchd" ;;
    Linux) PM_BACKEND="systemd" ;;
    *) PM_BACKEND="systemd" ;;
  esac
}

pm_backend_load(){
  local backend="${PM_BACKEND:-}"
  case "$backend" in
    launchd)
      # shellcheck disable=SC1090
      . "${SSCTL_LIB_DIR}/lib/services/launchd.sh"
      ;;
    systemd|*)
      PM_BACKEND="systemd"
      # shellcheck disable=SC1090
      . "${SSCTL_LIB_DIR}/lib/services/systemd.sh"
      ;;
  esac
}

pm_backend_init(){
  if [ -z "${PM_BACKEND:-}" ]; then
    pm_backend_detect
  fi
  pm_backend_load
}

pm_backend_init

pm_start_service(){
  case "$PM_BACKEND" in
    launchd) launchd_start_service "$@" ;;
    systemd|*) service_systemd_start "$@" ;;
  esac
}

pm_stop_service(){
  case "$PM_BACKEND" in
    launchd) launchd_stop_service "$@" ;;
    systemd|*) service_systemd_stop "$@" ;;
  esac
}

pm_restart_service(){
  case "$PM_BACKEND" in
    launchd)
      pm_stop_service "$@" || true
      pm_start_service "$@"
      ;;
    systemd|*)
      pm_stop_service "$@" || true
      pm_start_service "$@"
      ;;
  esac
}

pm_is_active(){
  case "$PM_BACKEND" in
    launchd) launchd_is_active "$@" ;;
    systemd|*) service_systemd_is_active "$@" ;;
  esac
}

pm_get_logs(){
  case "$PM_BACKEND" in
    launchd) launchd_get_logs "$@" ;;
    systemd|*) service_systemd_get_logs "$@" ;;
  esac
}

pm_generate_unit(){
  local unit="$1" definition="$2"
  local path=""
  case "$PM_BACKEND" in
    launchd)
      path="$(service_launchd_create "$unit" "$definition")"
      ok "已生成 LaunchAgent: ${unit}"
      ;;
    systemd)
      path="$(service_systemd_create "$unit" "$definition")"
      ok "已生成 unit: ${unit}"
      ;;
    *)
      die "Unsupported PM_BACKEND: $PM_BACKEND. Cannot generate unit."
      ;;
  esac
  printf '%s\n' "$path"
}

pm_daemon_reload(){
  case "$PM_BACKEND" in
    launchd) service_launchd_reload_daemon "$@" ;;
    systemd|*) service_systemd_reload "$@" ;;
  esac
}

pm_cache_unit_states(){
  case "$PM_BACKEND" in
    launchd) service_launchd_cache_unit_states "$@" ;;
    systemd|*) service_systemd_cache_unit_states "$@" ;;
  esac
}

pm_link_and_enable(){
  local unit_path="$1" unit_name="$2"
  case "$PM_BACKEND" in
    launchd) service_launchd_link_and_enable "$unit_path" "$unit_name" ;;
    systemd|*) service_systemd_link_and_enable "$unit_path" "$unit_name" ;;
  esac
}
