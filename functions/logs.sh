#!/usr/bin/env bash

logs_priority_to_level(){
  case "$1" in
    0) echo "emerg" ;;
    1) echo "alert" ;;
    2) echo "crit" ;;
    3) echo "err" ;;
    4) echo "warn" ;;
    5) echo "notice" ;;
    6|""|"null") echo "info" ;;
    7) echo "debug" ;;
    *) echo "info" ;;
  esac
}

logs_parse_journal_line(){
  local node="$1" line="$2"
  local base message priority pid realtime_raw seconds micros timestamp="" level seconds_json="null"

  base="$(jq -c --arg node "$node" '{node:$node,message:(.MESSAGE//""),priority:(.PRIORITY//"6"),realtime:(.__REALTIME_TIMESTAMP//._SOURCE_REALTIME_TIMESTAMP//null),pid:(._PID//null)}' <<<"$line" 2>/dev/null || true)"
  [ -n "$base" ] || return 1

  message="$(jq -r '.message' <<<"$base")"
  priority="$(jq -r '.priority' <<<"$base")"
  pid="$(jq -r '.pid // ""' <<<"$base")"
  realtime_raw="$(jq -r '.realtime // ""' <<<"$base")"

  if [ -n "$realtime_raw" ] && [[ "$realtime_raw" =~ ^[0-9]+$ ]]; then
    seconds=$(( realtime_raw / 1000000 ))
    micros=$(( realtime_raw % 1000000 ))
    if date -d "@$seconds" '+%F %T' >/dev/null 2>&1; then
      timestamp="$(date -d "@$seconds" '+%F %T')"
    elif date -r "$seconds" '+%F %T' >/dev/null 2>&1; then
      timestamp="$(date -r "$seconds" '+%F %T')"
    else
      timestamp="$seconds"
    fi
    if [ -n "$timestamp" ] && [ "$micros" -gt 0 ]; then
      timestamp="$timestamp.$(printf '%06d' "$micros")"
    fi
    seconds_json="$seconds"
  fi

  level="$(logs_priority_to_level "$priority")"
  base="$(jq -c \
    --arg node "$node" \
    --arg msg "$message" \
    --arg time "$timestamp" \
    --arg level "$level" \
    --arg priority "$priority" \
    --arg pid "$pid" \
    --argjson unix "${seconds_json:-null}" \
    '{node:$node,time:(if ($time|length)>0 then $time else null end),level:$level,priority:(if ($priority|test("^[0-9]+$")) then ($priority|tonumber) else null end),message:$msg,pid:(if ($pid|length)>0 then ($pid|tonumber) else null end),timestamp_unix:$unix}'
  )"

  local enrich
  enrich="$(parse_ssr_line "$message")"
  printf '[%s,%s]\n' "$base" "$enrich" | jq -c '
    reduce .[] as $item ({}; 
      reduce ($item|to_entries[]) as $kv (.;
        if $kv.value == null then . else .[$kv.key] = $kv.value end))'
}

logs_parse_file_line(){
  local node="$1" line="$2" timestamp="" rest="$line"
  if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[T[:space:]][0-9:.+-]+)[[:space:]]+(.*)$ ]]; then
    timestamp="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"
  fi
  local base enrich
  base="$(jq -c \
    --arg node "$node" \
    --arg time "$timestamp" \
    --arg msg "$rest" \
    '{node:$node,time:(if ($time|length)>0 then $time else null end),level:"info",priority:null,message:$msg,pid:null,timestamp_unix:null}'
  )"
  enrich="$(parse_ssr_line "$rest")"
  printf '[%s,%s]\n' "$base" "$enrich" | jq -c '
    reduce .[] as $item ({}; 
      reduce ($item|to_entries[]) as $kv (.;
        if $kv.value == null then . else .[$kv.key] = $kv.value end))'
}

logs_entry_matches(){
  local entry="$1" value
  if [ -n "${LOG_FILTER_TARGET:-}" ]; then
    value="$(jq -r '.target_host // ""' <<<"$entry")"
    [[ "$value" == *"${LOG_FILTER_TARGET}"* ]] || return 1
  fi
  if [ -n "${LOG_FILTER_IP:-}" ]; then
    value="$(jq -r '.source_host // .target_host // ""' <<<"$entry")"
    [[ "$value" == *"${LOG_FILTER_IP}"* ]] || return 1
  fi
  if [ -n "${LOG_FILTER_PORT:-}" ]; then
    local tport="$(jq -r '(.target_port|tostring) // ""' <<<"$entry")"
    local sport="$(jq -r '(.source_port|tostring) // ""' <<<"$entry")"
    if [ "$tport" != "${LOG_FILTER_PORT}" ] && [ "$sport" != "${LOG_FILTER_PORT}" ]; then
      return 1
    fi
  fi
  if [ -n "${LOG_FILTER_METHOD:-}" ]; then
    value="$(jq -r '.method // ""' <<<"$entry")"
    [[ "$value" == *"${LOG_FILTER_METHOD}"* ]] || return 1
  fi
  if [ -n "${LOG_FILTER_PROTOCOL:-}" ]; then
    value="$(jq -r '.protocol // ""' <<<"$entry")"
    [[ "$value" =~ ^${LOG_FILTER_PROTOCOL}$ ]] || return 1
  fi
  if [ -n "${LOG_FILTER_REGEX:-}" ]; then
    value="$(jq -r '.message // ""' <<<"$entry")"
    printf '%s\n' "$value" | grep -Eq "${LOG_FILTER_REGEX}" || return 1
  fi
  return 0
}

logs_format_text(){
  local entry="$1"
  local time level node message protocol target_host target_port source_host source_port method
  time="$(jq -r '(.time // "-")' <<<"$entry")"
  level="$(jq -r '(.level // "info")' <<<"$entry")"
  node="$(jq -r '(.node // "-")' <<<"$entry")"
  message="$(jq -r '(.message // "")' <<<"$entry")"
  protocol="$(jq -r '(.protocol // "")' <<<"$entry")"
  target_host="$(jq -r '(.target_host // "")' <<<"$entry")"
  target_port="$(jq -r '((.target_port // empty)|tostring)' <<<"$entry")"
  source_host="$(jq -r '(.source_host // "")' <<<"$entry")"
  source_port="$(jq -r '((.source_port // empty)|tostring)' <<<"$entry")"
  method="$(jq -r '(.method // "")' <<<"$entry")"

  local extras=()
  [ -n "$protocol" ] && extras+=("proto=${protocol}")
  if [ -n "$target_host" ]; then
    if [ -n "$target_port" ]; then
      extras+=("target=${target_host}:${target_port}")
    else
      extras+=("target=${target_host}")
    fi
  fi
  if [ -n "$source_host" ]; then
    if [ -n "$source_port" ]; then
      extras+=("src=${source_host}:${source_port}")
    else
      extras+=("src=${source_host}")
    fi
  fi
  [ -n "$method" ] && extras+=("method=${method}")

  local extra_suffix=""
  if [ ${#extras[@]} -gt 0 ]; then
    extra_suffix=" [${extras[*]}]"
  fi

  printf '%s %-5s (%s) %s%s\n' "$time" "$level" "$node" "$message" "$extra_suffix"
}

ssctl_parse_log_stream(){
  local source="$1" format="$2" name="$3"
  local line entry
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$source" in
      journal)
        entry="$(logs_parse_journal_line "$name" "$line" 2>/dev/null || true)"
        ;;
      file)
        entry="$(logs_parse_file_line "$name" "$line" 2>/dev/null || true)"
        ;;
      *) entry="" ;;
    esac
    [ -n "$entry" ] || continue
    if ! logs_entry_matches "$entry"; then
      continue
    fi
    if [ "$format" = "json" ]; then
      printf '%s\n' "$entry"
    else
      logs_format_text "$entry"
    fi
  done
}

cmd_logs(){
  self_check
  ssctl_read_config

  local follow=0 lines=200 lines_set=0 format="text" raw=0
  local name="" since="" until="" filter_args=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--follow)
        follow=1; shift ;;
      -n|--lines)
        lines="$2"; lines_set=1; shift 2 ;;
      --lines=*)
        lines="${1#*=}"; lines_set=1; shift ;;
      --since)
        since="$2"; shift 2 ;;
      --since=*)
        since="${1#*=}"; shift ;;
      --until)
        until="$2"; shift 2 ;;
      --until=*)
        until="${1#*=}"; shift ;;
      --filter)
        filter_args+=("$2"); shift 2 ;;
      --filter=*)
        filter_args+=("${1#*=}"); shift ;;
      --format)
        format="$2"; shift 2 ;;
      --format=*)
        format="${1#*=}"; shift ;;
      --json)
        format="json"; shift ;;
      --raw)
        raw=1; shift ;;
      -h|--help)
        cat <<'DOC'
用法：ssctl log [name] [--follow] [--lines N] [--filter key=value]
                [--since TS] [--until TS] [--format text|json] [--raw]
说明：
  - 支持 target/ip/port/method/protocol/regex 过滤。
  - --follow/-f  跟随输出；默认读取最近 200 行，可用 --lines 调整。
  - --raw        直接输出原始 journald/文件日志，不做解析。
  - --format json 输出结构化字段，包含 protocol/target/source 等信息。
DOC
        return 0
        ;;
      --)
        shift
        [ $# -gt 0 ] && name="$1"
        break
        ;;
      -* )
        die "未知参数：$1"
        ;;
      *)
        name="$1"; shift ;;
    esac
  done

  if [ "$follow" -eq 1 ] && [ "$lines_set" -eq 0 ]; then
    lines=50
  fi

  case "$format" in
    text|json) ;;
    *) die "未知输出格式：$format" ;;
  esac

  if [ -n "$name" ]; then
    name="$(resolve_name "$name")"
  else
    name="$(resolve_name "")"
  fi

  local source_info source_type source_value
  source_info="$(resolve_log_source "$name" 2>/dev/null || true)"
  if [ -z "$source_info" ]; then
    warn "无法确定日志来源，默认使用文件日志。"
    source_info="file:$(ssctl_default_log_path "$name")"
  fi
  source_type="${source_info%%:*}"
  source_value="${source_info#*:}"

  local filter target regex ip port method protocol
  for filter in "${filter_args[@]}"; do
    case "$filter" in
      target=*) target="${filter#*=}" ;;
      ip=*) ip="${filter#*=}" ;;
      port=*) port="${filter#*=}" ;;
      method=*) method="${filter#*=}" ;;
      protocol=*) protocol="${filter#*=}" ;;
      regex=*) regex="${filter#*=}" ;;
      *) warn "忽略未知 filter：$filter" ;;
    esac
  done

  if [ "$source_type" = "file" ]; then
    mkdir -p "$(dirname "$source_value")"
    if [ ! -e "$source_value" ]; then
      touch "$source_value"
    fi
    if [ -n "$since" ] || [ -n "$until" ]; then
      warn "文件日志暂不支持 --since/--until，已忽略。"
    fi
  fi

  local cmd=()

  if [ "$raw" -eq 1 ]; then
    if [ "$source_type" = "journal" ]; then
      cmd=(journalctl --user -u "$source_value" --no-pager -n "$lines")
      [ -n "$since" ] && cmd+=(--since "$since")
      [ -n "$until" ] && cmd+=(--until "$until")
      [ "$follow" -eq 1 ] && cmd+=(-f)
      exec "${cmd[@]}"
    else
      if [ "$follow" -eq 1 ]; then
        exec tail -n "$lines" -F "$source_value"
      else
        exec tail -n "$lines" "$source_value"
      fi
    fi
    return
  fi

  export LOG_FILTER_TARGET="${target:-}"
  export LOG_FILTER_IP="${ip:-}"
  export LOG_FILTER_PORT="${port:-}"
  export LOG_FILTER_METHOD="${method:-}"
  export LOG_FILTER_PROTOCOL="${protocol:-}"
  export LOG_FILTER_REGEX="${regex:-}"

  local rc=0
  if [ "$source_type" = "journal" ]; then
    cmd=(journalctl --user -u "$source_value" --no-pager -o json -n "$lines")
    [ -n "$since" ] && cmd+=(--since "$since")
    [ -n "$until" ] && cmd+=(--until "$until")
    [ "$follow" -eq 1 ] && cmd+=(-f)
    "${cmd[@]}" | ssctl_parse_log_stream journal "$format" "$name"
    rc=${PIPESTATUS[1]}
  else
    if [ "$follow" -eq 1 ]; then
      tail -n "$lines" -F "$source_value" | ssctl_parse_log_stream file "$format" "$name"
      rc=${PIPESTATUS[1]}
    else
      tail -n "$lines" "$source_value" | ssctl_parse_log_stream file "$format" "$name"
      rc=${PIPESTATUS[1]}
    fi
  fi

  unset LOG_FILTER_TARGET LOG_FILTER_IP LOG_FILTER_PORT LOG_FILTER_METHOD LOG_FILTER_PROTOCOL LOG_FILTER_REGEX
  return $rc
}

# Wrapper for log alias.
cmd_log(){
  cmd_logs "$@"
}
