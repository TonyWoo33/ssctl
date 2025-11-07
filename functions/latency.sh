#!/usr/bin/env bash

cmd_latency(){
  self_check
  ssctl_read_config

  local url="$DEFAULT_LATENCY_URL"
  local output_format="text"
  local show_help=0
  local positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --url)    url="$2"; shift 2 ;;
      --url=*)  url="${1#*=}"; shift ;;
      --json)   output_format="json"; shift ;;
      -h|--help)
        show_help=1; shift ;;
      --)
        shift
        while [ $# -gt 0 ]; do
          positional+=("$1")
          shift
        done
        break ;;
      -*)
        warn "忽略未知参数：$1"
        shift ;;
      *)
        positional+=("$1")
        shift ;;
    esac
  done

  if [ "$show_help" -eq 1 ]; then
cat <<'DOC'
用法：ssctl latency [--url URL] [--json]
说明：
  - 对所有已配置节点发起一次 TCP CONNECT，估算握手延迟。
  - 默认使用配置文件中的 latency.url，可用 --url 覆盖。
  - --json 输出结构化结果，仅写入 stdout。
DOC
    return 0
  fi

  if [ ${#positional[@]} -gt 0 ]; then
    url="${positional[0]}"
  fi
  url="${url:-$DEFAULT_LATENCY_URL}"

  local nodes=()
  while read -r node; do
    [ -n "$node" ] || continue
    nodes+=("$node")
  done < <(list_nodes)

  if [ ${#nodes[@]} -eq 0 ]; then
    die "未找到节点"
  fi

  local names=() latencies=() ok_flags=() errors=()
  local node
  for node in "${nodes[@]}"; do
    local laddr lport unit unit_active=0 unit_pid=""
    laddr="$(json_get "$node" local_address)"; [ -n "$laddr" ] || laddr="$DEFAULT_LOCAL_ADDR"
    lport="$(json_get "$node" local_port)";   [ -n "$lport" ] || lport="$DEFAULT_LOCAL_PORT"
    unit="$(unit_name_for "$node")"

    if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
      unit_active=1
    else
      unit_pid="$(ssctl_unit_pid "$node" "$unit" 2>/dev/null || true)"
      [ -n "$unit_pid" ] && unit_active=1
    fi

    local latency_val="null" ok_flag=0 error=""
    if [ "$unit_active" -eq 1 ]; then
      local latency_s="" curl_rc=0
      local timing_out
      timing_out="$(ssctl_measure_http "$laddr" "$lport" "$url" "hostname")" || curl_rc=$?
      latency_s="$(printf '%s\n' "$timing_out" | awk '{print $1}')"
      if [ "$curl_rc" -eq 0 ] && [ -n "$latency_s" ]; then
        latency_val="$(awk -v s="$latency_s" 'BEGIN{printf "%.0f", s*1000}' 2>/dev/null || echo 0)"
        ok_flag=1
      else
        error="timeout"
      fi
    else
      error="unit_inactive"
    fi

    names+=("$node")
    latencies+=("$latency_val")
    ok_flags+=("$ok_flag")
    errors+=("$error")
  done

  if [ "$output_format" = "text" ]; then
    local W_NAME=22 W_LATENCY=14
    local TOTAL=$((W_NAME + 2 + W_LATENCY))
    printf '%s' "$C_BOLD" >&2
    printf "%-${W_NAME}s  %-${W_LATENCY}s\n" "NAME" "LATENCY (ms)" >&2
    printf '%s' "$C_RESET" >&2
    (_hr "$TOTAL") >&2
    local idx
    for idx in "${!names[@]}"; do
      local name="${names[$idx]}"
      local latency="${latencies[$idx]}"
      local ok="${ok_flags[$idx]}"
      local err="${errors[$idx]}"
      if [ "$ok" -eq 1 ]; then
        printf "%-${W_NAME}s  %s\n" "$(_ellipsis "$name" "$W_NAME")" "${latency} ms" >&2
      else
        local msg="TIMEOUT"
        [ "$err" = "unit_inactive" ] && msg="INACTIVE"
        printf "%-${W_NAME}s  %s\n" "$(_ellipsis "$name" "$W_NAME")" "${C_RED}${msg}${C_RESET}" >&2
      fi
    done
    (_hr "$TOTAL") >&2
    return 0
  fi

  local entries=() payload='[]'
  local idx
  for idx in "${!names[@]}"; do
    local name="${names[$idx]}"
    local latency="${latencies[$idx]}"
    local ok="${ok_flags[$idx]}"
    local err="${errors[$idx]}"
    if [ "$ok" -eq 1 ]; then
      entries+=("$(jq -c -n \
        --arg name "$name" \
        --argjson latency "$latency" \
        '{name:$name,ok:true,latency_ms:$latency}')")
    else
      entries+=("$(jq -c -n \
        --arg name "$name" \
        --arg err "$err" \
        '{name:$name,ok:false,latency_ms:null,error:(if ($err|length)>0 then $err else "unknown" end)}')")
    fi
  done
  if [ ${#entries[@]} -gt 0 ]; then
    payload="$(printf '%s\n' "${entries[@]}" | jq -c -s '.')"
  fi
  jq -c -n \
    --arg url "$url" \
    --arg time "$(date --iso-8601=seconds)" \
    --argjson results "$payload" \
    '{time:$time,url:$url,results:$results}'
}
