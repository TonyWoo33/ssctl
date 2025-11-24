#!/usr/bin/env bash

probe(){
  self_check
  ssctl_read_config

  local output_format="text"
  local url="$DEFAULT_PROBE_URL"
  local name="" target="" show_help=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --name)     name="$2"; shift 2 ;;
      --name=*)   name="${1#*=}"; shift ;;
      --url)      url="$2"; shift 2 ;;
      --url=*)    url="${1#*=}"; shift ;;
      --json)     output_format="json"; shift ;;
      -h|--help)
        show_help=1; shift ;;
      --)
        shift
        if [ $# -gt 0 ] && [ -z "$target" ]; then
          target="$1"; shift
        fi
        while [ $# -gt 0 ]; do
          warn "忽略多余参数：$1"
          shift
        done
        break ;;
      -*)
        warn "忽略未知参数：$1"
        shift ;;
      *)
        if [ -z "$target" ]; then
          target="$1"
        else
          warn "忽略多余参数：$1"
        fi
        shift ;;
    esac
  done

  if [ "$show_help" -eq 1 ]; then
cat <<'DOC'
用法：ssctl probe [name] [--url URL] [--json]
说明：
  - 默认检测 current.json 指向的节点。
  - --url 可覆盖默认探测地址。
  - --json 仅输出结构化 JSON 至 stdout。
DOC
    return 0
  fi

  if [ -z "$name" ]; then
    name="${target:-}"
  fi
  name="$(resolve_name "${name:-}")"
  url="${url:-$DEFAULT_PROBE_URL}"

  local node_json
  node_json="$(jq -c --arg name "$name" '. + {__name:$name}' "$(node_json_path "$name")")"
  ssctl_require_node_deps_met "$node_json"

  local laddr lport unit
  laddr="$(json_get "$name" local_address)"; [ -n "$laddr" ] || laddr="$DEFAULT_LOCAL_ADDR"
  lport="$(json_get "$name" local_port)";   [ -n "$lport" ] || lport="$DEFAULT_LOCAL_PORT"
  unit="$(unit_name_for "$name")"

  local unit_active=0 unit_pid=""
  ssctl_service_cache_unit_states "$unit"
  if ssctl_service_is_active "$unit"; then
    unit_active=1
  else
    unit_pid="$(ssctl_service_get_pid "$name" "$unit" "$lport" 2>/dev/null || true)"
    if [ -n "$unit_pid" ]; then
      unit_active=1
    fi
  fi

  if [ "$output_format" = "text" ]; then
    info "节点: ${name}  本地代理: ${laddr}:${lport}"
  fi

  if [ "$unit_active" -ne 1 ]; then
    if [ "$output_format" = "json" ]; then
      jq -c -n --arg name "$name" --arg unit "$unit" \
        '{name:$name,unit:$unit,error:"unit_inactive"}'
    else
      warn "服务未启动：$unit"
      warn "提示：先执行 ssctl start ${name}"
    fi
    return 1
  fi

  local port_ok=0
  if command -v nc >/dev/null 2>&1; then
    if nc -z "$laddr" "$lport" -w 2 2>/dev/null; then
      port_ok=1
    fi
  else
    if (exec 3<>/dev/tcp/"${laddr}"/"${lport}") 2>/dev/null; then
      port_ok=1
      exec 3>&-
    fi
  fi

  if [ "$output_format" = "text" ]; then
    if [ "$port_ok" -eq 1 ]; then
      ok "端口监听正常：${laddr}:${lport}"
    else
      warn "端口未监听：${laddr}:${lport}"
    fi
  fi

  if [ "$port_ok" -ne 1 ]; then
    if [ "$output_format" = "json" ]; then
      jq -c -n \
        --arg name "$name" \
        --arg unit "$unit" \
        --arg laddr "$laddr" \
        --argjson lport "$lport" \
        '{name:$name,unit:$unit,local_address:$laddr,local_port:$lport,port_ok:false,error:"port_unreachable"}'
    fi
    return 1
  fi

  if [ "$output_format" = "text" ]; then
    info "STEP A: 代理+DNS 访问 ${url}"
  fi

  local http_metrics="" http_curl_rc=0 http_code="000" http_time="0"
  http_metrics="$(ssctl_measure_http "$laddr" "$lport" "$url" "hostname" 2>/dev/null)" || http_curl_rc=$?
  http_code="$(printf '%s\n' "$http_metrics" | awk '{print $5}')"
  http_time="$(printf '%s\n' "$http_metrics" | awk '{print $3}')"
  local http_latency_ms
  http_latency_ms="$(awk -v s="${http_time:-0}" 'BEGIN{printf "%.0f", s*1000}' 2>/dev/null || echo 0)"

  local http_ok=0
  if [ "$http_curl_rc" -eq 0 ] && [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
    http_ok=1
    if [ "$output_format" = "text" ]; then
      ok "HTTP 探测（带 DNS）: 连通 (code=${http_code})"
    fi
  else
    if [ "$output_format" = "text" ]; then
      warn "HTTP 探测失败，curl 码: ${http_curl_rc}"
    fi
  fi

  local link_attempted=0 link_ok=0 link_curl_rc=0
  if [ "$http_ok" -ne 1 ]; then
    link_attempted=1
    if [ "$output_format" = "text" ]; then
      info "STEP B: 仅链路 http://1.1.1.1"
    fi
    curl -sS -I --connect-timeout 5 --max-time 10 \
      --socks5 "${laddr}:${lport}" \
      "http://1.1.1.1" -o /dev/null 2>/dev/null || link_curl_rc=$?
    if [ "$link_curl_rc" -eq 0 ]; then
      link_ok=1
      if [ "$output_format" = "text" ]; then
        warn "链路可用但域名失败 → rust 可在 JSON 用 dns；libev 使用系统 DNS"
      fi
    else
      if [ "$output_format" = "text" ]; then
        warn "链路不可用 → 查看：journalctl --user -u ${unit} -e --no-pager"
      fi
    fi
  fi

  local ip="" country=""
  if [ "$http_ok" -eq 1 ]; then
    ip="$(curl -sS --connect-timeout 5 --max-time 10 --socks5-hostname "${laddr}:${lport}" "${PROBE_IP_LOOKUP_URL}" 2>/dev/null || true)"
    country="$(curl -sS --connect-timeout 5 --max-time 10 --socks5-hostname "${laddr}:${lport}" "${PROBE_COUNTRY_LOOKUP_URL}" 2>/dev/null || true)"
    if [ "$output_format" = "text" ]; then
      [ -n "$ip" ] && ok "出口 IP: ${ip}"
      [ -n "$country" ] && ok "国家/地区: ${country}"
    fi
  fi

  if [ "$output_format" = "json" ]; then
    jq -c -n \
      --arg name "$name" \
      --arg unit "$unit" \
      --arg laddr "$laddr" \
      --arg url "$url" \
      --argjson lport "$lport" \
      --argjson port_ok "$port_ok" \
      --arg http_code "${http_code:-000}" \
      --argjson http_curl_rc "$http_curl_rc" \
      --argjson http_latency_ms "$http_latency_ms" \
      --argjson http_ok "$http_ok" \
      --argjson link_attempted "$link_attempted" \
      --argjson link_ok "$link_ok" \
      --argjson link_curl_rc "$link_curl_rc" \
      --arg ip "$ip" \
      --arg country "$country" \
      '{
         name:$name,
         unit:$unit,
         local_address:$laddr,
         local_port:$lport,
         url:$url,
         port_ok:($port_ok==1),
         http:{
           ok:($http_ok==1),
           curl_exit:$http_curl_rc,
           http_code:(try ($http_code|tonumber) catch 0),
           latency_ms:$http_latency_ms
         },
         link_only:{
           attempted:($link_attempted==1),
           ok:($link_ok==1),
           curl_exit:$link_curl_rc
         },
         ip:(if ($ip|length)>0 then $ip else null end),
         country:(if ($country|length)>0 then $country else null end)
       }'
  fi

  if [ "$http_ok" -eq 1 ]; then
    return 0
  fi
  return 1
}
