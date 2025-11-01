#!/usr/bin/env bash

cmd_metrics(){
  self_check
  local format="json"

  while [ $# -gt 0 ]; do
    case "$1" in
      --format)
        [ $# -ge 2 ] || die "用法：ssctl metrics [--format json|prom]"
        format="$2"
        shift 2
        ;;
      --format=*)
        format="${1#*=}"
        shift
        ;;
      -h|--help)
        cat <<'DOC'
用法：ssctl metrics [--format json|prom]
说明：
  - 默认输出 JSON，包含节点状态、引擎与端口信息。
  - --format prom 输出 Prometheus 兼容指标。
DOC
        return 0
        ;;
      *)
        die "未知参数：$1（使用 ssctl metrics --help 查看用法）"
        ;;
    esac
  done

  case "$format" in
    json|prom) ;;
    *) die "未知输出格式：$format（支持 json|prom）" ;;
  esac

  local timestamp="$(date --iso-8601=seconds)"
  local total=0 active_count=0
  local default_laddr="$DEFAULT_LOCAL_ADDR"

  local nodes_json="" comma=""

  for n in $(list_nodes); do
    total=$((total+1))
    local unit
    unit="$(unit_name_for "$n")"
    local has_unit=0
    local is_active=0
    if unit_exists "$n"; then has_unit=1; fi
    if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
      is_active=1; active_count=$((active_count+1))
    fi

    local engine method local_port local_addr server
    engine="$(pick_engine "$n")"
    method="$(json_get "$n" method)"
    local_port="$(json_get "$n" local_port)"; [ -n "$local_port" ] || local_port="$DEFAULT_LOCAL_PORT"
    local_addr="$(json_get "$n" local_address)"; [ -n "$local_addr" ] || local_addr="$default_laddr"
    server="$(json_get "$n" server)"

    local entry
    entry=$(jq -n \
      --arg name "$n" \
      --arg unit "$unit" \
      --arg engine "$engine" \
      --arg method "$method" \
      --arg server "$server" \
      --arg laddr "$local_addr" \
      --argjson lport "$local_port" \
      --argjson has_unit "$has_unit" \
      --argjson active "$is_active" \
      '{name:$name, unit:$unit, engine:$engine, method:$method, server:$server, local_address:$laddr, local_port:$lport, has_unit:$has_unit, active:$active}'
    )
    nodes_json+="$comma$entry"
    comma="," 
  done

  local nodes_payload="[$nodes_json]"

  if [ "$format" = "json" ]; then
    jq -n \
      --arg time "$timestamp" \
      --argjson total "$total" \
      --argjson active "$active_count" \
      --argjson nodes "$nodes_payload" \
      '{timestamp:$time,total_nodes:$total,active_nodes:$active,nodes:$nodes}'
    return 0
  fi

  prom_escape(){
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//"/\\"}"
    s="${s//$'\n'/}"
    printf '%s' "$s"
  }

  printf "# HELP ssctl_nodes_total Total number of configured ssctl nodes\n"
  printf "# TYPE ssctl_nodes_total gauge\n"
  printf "ssctl_nodes_total %d\n" "$total"
  printf "# HELP ssctl_nodes_active Number of nodes with running systemd units\n"
  printf "# TYPE ssctl_nodes_active gauge\n"
  printf "ssctl_nodes_active %d\n" "$active_count"

  if [ "$nodes_payload" != "[]" ]; then
    printf "# HELP ssctl_node_active Node service status (1=active)\n"
    printf "# TYPE ssctl_node_active gauge\n"
    printf "# HELP ssctl_node_has_unit Whether a systemd unit exists for node\n"
    printf "# TYPE ssctl_node_has_unit gauge\n"
    printf "# HELP ssctl_node_local_port Configured local listening port\n"
    printf "# TYPE ssctl_node_local_port gauge\n"
    printf "# HELP ssctl_node_unit_info Systemd unit metadata\n"
    printf "# TYPE ssctl_node_unit_info gauge\n"

    printf '%s\n' "$nodes_payload" | jq -c '.[]' | while read -r line; do
      local name engine method unit has_unit active lport
      name=$(echo "$line" | jq -r '.name')
      engine=$(echo "$line" | jq -r '.engine')
      method=$(echo "$line" | jq -r '.method')
      unit=$(echo "$line" | jq -r '.unit')
      has_unit=$(echo "$line" | jq -r '.has_unit')
      active=$(echo "$line" | jq -r '.active')
      lport=$(echo "$line" | jq -r '.local_port')

      printf "ssctl_node_active{name=\"%s\",engine=\"%s\",method=\"%s\"} %s\n" \
        "$(prom_escape "$name")" "$(prom_escape "$engine")" "$(prom_escape "$method")" "$active"
      printf "ssctl_node_has_unit{name=\"%s\"} %s\n" "$(prom_escape "$name")" "$has_unit"
      printf "ssctl_node_local_port{name=\"%s\"} %s\n" "$(prom_escape "$name")" "$lport"
      printf "ssctl_node_unit_info{name=\"%s\",unit=\"%s\"} 1\n" "$(prom_escape "$name")" "$(prom_escape "$unit")"
    done
  fi
}
