#!/usr/bin/env bash

CONFIG_PATH_DEFAULT="${HOME}/.config/ssctl/config.json"
CONFIG_DEFAULT_JSON='{
  "color": "auto",
  "probe": {"url": "https://www.google.com/generate_204"},
  "latency": {"url": "https://www.google.com/generate_204"},
  "monitor": {
    "url": "https://www.google.com/generate_204",
    "interval": 5,
    "no_dns_url": "http://1.1.1.1"
  },
  "doctor": {
    "include_clipboard": true,
    "include_qrencode": true,
    "include_libev": true
  },
  "plugins": {
    "paths": []
  }
}'

CONFIG_PATH=""
CONFIG_DATA=""
CONFIG_COLOR_MODE=""
CONFIG_PLUGIN_PATHS=()
CONFIG_DOCTOR_INCLUDE_CLIPBOARD=1
CONFIG_DOCTOR_INCLUDE_QRENCODE=1
CONFIG_DOCTOR_INCLUDE_LIBEV=1

load_config(){
  local specified_path="${1:-}"
  local path=""
  if [ -n "$specified_path" ]; then
    path="$specified_path"
  elif [ -n "${SSCTL_CONFIG:-}" ]; then
    path="${SSCTL_CONFIG}"
  else
    path="${CONFIG_PATH_DEFAULT}"
  fi
  CONFIG_PATH="$path"

  if ! command -v jq >/dev/null 2>&1; then
    CONFIG_DATA="$CONFIG_DEFAULT_JSON"
    return 0
  fi

  if [ -f "$path" ]; then
    if ! CONFIG_DATA="$(jq -s '.[0] * (.[1] // {})' <(printf '%s' "$CONFIG_DEFAULT_JSON") "$path" 2>/dev/null)"; then
      warn "配置文件解析失败：$path，已回退默认配置。"
      CONFIG_DATA="$CONFIG_DEFAULT_JSON"
    fi
  else
    CONFIG_DATA="$CONFIG_DEFAULT_JSON"
  fi

  CONFIG_COLOR_MODE="$(printf '%s' "$CONFIG_DATA" | jq -r '.color // empty')"
  DEFAULT_PROBE_URL="$(printf '%s' "$CONFIG_DATA" | jq -r '.probe.url')"
  DEFAULT_LATENCY_URL="$(printf '%s' "$CONFIG_DATA" | jq -r '.latency.url')"
  DEFAULT_MONITOR_URL="$(printf '%s' "$CONFIG_DATA" | jq -r '.monitor.url')"
  DEFAULT_MONITOR_INTERVAL="$(printf '%s' "$CONFIG_DATA" | jq -r '.monitor.interval')"
  DEFAULT_MONITOR_NO_DNS_URL="$(printf '%s' "$CONFIG_DATA" | jq -r '.monitor.no_dns_url')"
  CONFIG_DOCTOR_INCLUDE_CLIPBOARD="$(printf '%s' "$CONFIG_DATA" | jq -r 'if .doctor.include_clipboard then 1 else 0 end')"
  CONFIG_DOCTOR_INCLUDE_QRENCODE="$(printf '%s' "$CONFIG_DATA" | jq -r 'if .doctor.include_qrencode then 1 else 0 end')"
  CONFIG_DOCTOR_INCLUDE_LIBEV="$(printf '%s' "$CONFIG_DATA" | jq -r 'if .doctor.include_libev then 1 else 0 end')"

  CONFIG_PLUGIN_PATHS=()
  if mapfile -t CONFIG_PLUGIN_PATHS < <(printf '%s' "$CONFIG_DATA" | jq -r '.plugins.paths[]?' 2>/dev/null); then
    true
  else
    CONFIG_PLUGIN_PATHS=()
  fi
}

apply_config_color(){
  local mode="${1:-}"
  if [ -z "$mode" ] || [ "$mode" = "auto" ]; then
    COLOR_FLAG="${SSCTL_COLOR:-${SSNODE_COLOR:-$SSCTL_COLOR_DEFAULT}}"
  else
    case "$mode" in
      on|true|1) COLOR_FLAG=1 ;;
      off|false|0) COLOR_FLAG=0 ;;
      *)
        warn "未知 color 配置：$mode（支持 auto/on/off）"
        COLOR_FLAG="${SSCTL_COLOR:-${SSNODE_COLOR:-$SSCTL_COLOR_DEFAULT}}"
        ;;
    esac
  fi
  apply_color_palette
}

__SSCTL_ENV_LOADED=0
ssctl_read_config(){
  if [ "${__SSCTL_ENV_LOADED:-0}" = "1" ]; then
    return 0
  fi
  local env_path="${SSCTL_CONFIG_ENV:-${HOME}/.config/ssctl/config.env}"
  if [ -r "$env_path" ]; then
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
      local line
      line="${raw_line%%#*}"
      line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [ -n "$line" ] || continue
      case "$line" in
        *=*)
          local key="${line%%=*}"
          local value="${line#*=}"
          key="$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
          value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
          if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            printf -v "$key" '%s' "$value"
          fi
          ;;
      esac
    done <"$env_path"
  fi
  __SSCTL_ENV_LOADED=1
}
