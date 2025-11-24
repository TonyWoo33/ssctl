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

service_launchd_plist_dir(){
  printf '%s/Library/LaunchAgents\n' "${HOME}"
}

service_launchd_label_for_unit(){
  local unit="${1:?service_launchd_label_for_unit 需要 unit 名称}"
  printf 'io.ssctl.%s\n' "$unit"
}

service_launchd_unit_from_label(){
  local label="${1:-}"
  label="${label#io.ssctl.}"
  printf '%s\n' "$label"
}

service_launchd_plist_path(){
  local unit="${1:?service_launchd_plist_path 需要 unit 名称}"
  local dir; dir="$(service_launchd_plist_dir)"
  printf '%s/%s.plist\n' "$dir" "$(service_launchd_label_for_unit "$unit")"
}

service_launchd_xml_escape(){
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}

service_launchd_write_plist(){
  local plist_path="${1:?service_launchd_write_plist 需要路径}"
  local content="$2"
  mkdir -p "$(dirname "$plist_path")"
  printf '%s\n' "$content" > "$plist_path"
}

service_launchd_parse_exec(){
  local exec_start="$1"
  local -a argv=()
  eval "argv=($exec_start)"
  if [ "${#argv[@]}" -eq 0 ]; then
    die "launchd: ExecStart 解析失败"
  fi
  (IFS=$'\n'; printf '%s\n' "${argv[@]}")
}

service_launchd_create(){
  local unit="${1:?service_launchd_create 需要 unit 名称}"
  local definition="${2:-}"
  local label; label="$(service_launchd_label_for_unit "$unit")"
  local plist_path; plist_path="$(service_launchd_plist_path "$unit")"

  local description="ssctl service (${unit})"
  local exec_start="" restart="on-failure" restart_sec=""
  local -a envs=() service_opts=()
  local run_at_load="true"
  local keep_alive=""
  local working_dir=""

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
      RunAtLoad) run_at_load="$value" ;;
      KeepAlive) keep_alive="$value" ;;
      WorkingDirectory) working_dir="$value" ;;
      *)
        service_opts+=("${key}=${value}")
        ;;
    esac
  done <<<"$definition"

  local opt_entry
  for opt_entry in "${service_opts[@]}"; do
    local opt_key="${opt_entry%%=*}"
    local opt_val="${opt_entry#*=}"
    case "$opt_key" in
      WorkingDirectory) working_dir="$opt_val" ;;
      RunAtLoad) run_at_load="$opt_val" ;;
      KeepAlive) keep_alive="$opt_val" ;;
    esac
  done

  [ -n "$exec_start" ] || die "launchd: 缺少 ExecStart"

  local program_args=()
  while IFS= read -r arg; do
    program_args+=("$arg")
  done < <(service_launchd_parse_exec "$exec_start")
  [ "${#program_args[@]}" -gt 0 ] || die "launchd: ProgramArguments 为空"

  if [ -z "$keep_alive" ]; then
    if [[ "${restart,,}" = "always" ]]; then
      keep_alive="true"
    else
      keep_alive="false"
    fi
  fi

  local keep_alive_xml
  if [[ "${keep_alive,,}" = "true" ]]; then
    keep_alive_xml="    <key>KeepAlive</key>
    <true/>
"
  else
    keep_alive_xml="    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
"
  fi

  local run_at_load_xml="    <key>RunAtLoad</key>
    <true/>
"
  if [[ "${run_at_load,,}" = "false" ]]; then
    run_at_load_xml="    <key>RunAtLoad</key>
    <false/>
"
  fi

  local env_xml=""
  if [ "${#envs[@]}" -gt 0 ]; then
    env_xml+="    <key>EnvironmentVariables</key>
    <dict>
"
    local env_entry
    for env_entry in "${envs[@]}"; do
      local env_key="${env_entry%%=*}"
      local env_val="${env_entry#*=}"
      env_xml+="        <key>$(service_launchd_xml_escape "$env_key")</key>
        <string>$(service_launchd_xml_escape "$env_val")</string>
"
    done
    env_xml+="    </dict>
"
  fi

  local working_dir_xml=""
  if [ -n "$working_dir" ]; then
    working_dir_xml+="    <key>WorkingDirectory</key>
    <string>$(service_launchd_xml_escape "$working_dir")</string>
"
  fi

  local plist_content='<?xml version="1.0" encoding="UTF-8"?>'
  plist_content+="
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key>
    <string>$(service_launchd_xml_escape "$label")</string>
    <key>ProgramArguments</key>
    <array>
"
  local arg
  for arg in "${program_args[@]}"; do
    plist_content+="        <string>$(service_launchd_xml_escape "$arg")</string>
"
  done
  plist_content+="    </array>
${run_at_load_xml}${keep_alive_xml}${env_xml}${working_dir_xml}"

  if [ -n "$restart_sec" ]; then
    plist_content+="    <key>ThrottleInterval</key>
    <integer>${restart_sec}</integer>
"
  fi

  plist_content+="    <key>SSCTLDescription</key>
    <string>$(service_launchd_xml_escape "$description")</string>
    <key>SSCTLUnit</key>
    <string>$(service_launchd_xml_escape "$unit")</string>
</dict>
</plist>
"

  service_launchd_write_plist "$plist_path" "$plist_content"
  printf '%s\n' "$plist_path"
}

service_launchd_plist_exists(){
  local unit="$1"
  [ -f "$(service_launchd_plist_path "$unit")" ]
}

service_launchd_bootstrap(){
  local plist_path="$1"
  if command -v launchctl >/dev/null 2>&1; then
    launchctl bootstrap "gui/${UID}" "$plist_path" >/dev/null 2>&1 \
      || launchctl load -w "$plist_path" >/dev/null 2>&1
  fi
}

service_launchd_bootout(){
  local plist_path="$1"
  if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/${UID}" "$plist_path" >/dev/null 2>&1 \
      || launchctl unload -w "$plist_path" >/dev/null 2>&1 || true
  fi
}

service_launchd_reload(){
  service_launchd_stop "$@"
  service_launchd_start "$@"
}

service_launchd_start(){
  local unit="${1:?service_launchd_start 需要 unit 名称}"
  local plist_path; plist_path="$(service_launchd_plist_path "$unit")"
  [ -f "$plist_path" ] || die "launchd: 未找到 plist：$plist_path"
  service_launchd_bootstrap "$plist_path"
}

service_launchd_stop(){
  local unit="${1:?service_launchd_stop 需要 unit 名称}"
  local plist_path; plist_path="$(service_launchd_plist_path "$unit")"
  [ -f "$plist_path" ] || return 0
  service_launchd_bootout "$plist_path"
}

service_launchd_enable(){ service_launchd_start "$@"; }
service_launchd_enable_now(){ service_launchd_start "$@"; }
service_launchd_disable_now(){ service_launchd_stop "$@"; }
service_launchd_link_and_enable(){
  local _unit_path="${1:-}"
  local unit_name="${2:-}"
  [ -n "$unit_name" ] || die "launchd: 需要 unit 名称以 enable"
  service_launchd_enable "$unit_name"
}

service_launchd_is_active(){
  local unit="${1:?service_launchd_is_active 需要 unit 名称}"
  if service_launchd_get_pid "$unit" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

service_launchd_parse_list_output(){
  local label="$1"
  launchctl list "$label" 2>/dev/null || true
}

service_launchd_get_pid(){
  local unit="${1:?service_launchd_get_pid 需要 unit 名称}"
  local label; label="$(service_launchd_label_for_unit "$unit")"
  local output
  output="$(service_launchd_parse_list_output "$label")"
  [ -n "$output" ] || return 1
  local pid
  pid="$(printf '%s\n' "$output" | awk -F'= ' '/"PID"/{gsub(/[^0-9]/,"",$2); if($2!=""){print $2; exit}}')"
  if [ -z "$pid" ]; then
    pid="$(printf '%s\n' "$output" | awk '{if(NF==3 && $3=="'"$label"'"){print $1; exit}}')"
  fi
  if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ]; then
    printf '%s\n' "$pid"
    return 0
  fi
  return 1
}

service_launchd_cache_unit_states(){
  local _pattern="${1:-}"
  __SSCTL_UNIT_STATE_CACHE=()
  local plist_dir; plist_dir="$(service_launchd_plist_dir)"
  local prev_nullglob; prev_nullglob="$(shopt -p nullglob || true)"
  shopt -s nullglob
  local plist
  for plist in "${plist_dir}"/io.ssctl.*.plist; do
    [ -f "$plist" ] || continue
    local filename="${plist##*/}"
    local label="${filename%.plist}"
    local unit; unit="$(service_launchd_unit_from_label "$label")"
    local state="inactive:"
    if service_launchd_is_active "$unit"; then
      local pid
      pid="$(service_launchd_get_pid "$unit" 2>/dev/null || true)"
      state="active:${pid:-}"
    fi
    __SSCTL_UNIT_STATE_CACHE["$unit"]="$state"
  done
  if [ -n "$prev_nullglob" ]; then
    eval "$prev_nullglob"
  else
    shopt -u nullglob
  fi
}

service_launchd_unit_exists(){
  local unit="$1"
  service_launchd_plist_exists "$unit"
}

service_launchd_current_running_node(){
  service_launchd_cache_unit_states
  local unit state
  for unit in "${!__SSCTL_UNIT_STATE_CACHE[@]}"; do
    state="${__SSCTL_UNIT_STATE_CACHE[$unit]}"
    case "$unit" in
      sslocal-*.service)
        if [[ "$state" == active:* ]]; then
          local core="${unit#sslocal-}"
          core="${core%.service}"
          local name="${core%-*}"
          if is_safe_identifier "$name"; then
            printf '%s\n' "$name"
            return 0
          fi
        fi
        ;;
    esac
  done
  return 1
}

service_launchd_stop_all_units(){
  local plist_dir; plist_dir="$(service_launchd_plist_dir)"
  local prev_nullglob; prev_nullglob="$(shopt -p nullglob || true)"
  shopt -s nullglob
  local plist
  for plist in "${plist_dir}"/io.ssctl.*.plist; do
    [ -f "$plist" ] || continue
    service_launchd_bootout "$plist"
    rm -f "$plist"
  done
  if [ -n "$prev_nullglob" ]; then
    eval "$prev_nullglob"
  else
    shopt -u nullglob
  fi
}

service_launchd_reset_failed_units(){
  return 0
}

service_launchd_show_status(){
  local unit="${1:?service_launchd_show_status 需要 unit 名称}"
  local label; label="$(service_launchd_label_for_unit "$unit")"
  launchctl print "gui/${UID}/${label}" 2>/dev/null || launchctl list "$label" || true
}
