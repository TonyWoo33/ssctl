#!/usr/bin/env bash

cmd_logs(){
  self_check
  local follow=0 lines=200 name=""
  local lines_set=0 output_format="text"
  local positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--follow)
        follow=1
        shift
        ;;
      -n|--lines)
        [ $# -ge 2 ] || die "用法：ssctl logs [-n N] [-f] [name]"
        lines="$2"
        lines_set=1
        shift 2
        ;;
      --json)
        output_format="json"
        shift
        ;;
      --format)
        [ $# -ge 2 ] || die "用法：ssctl logs [--format json|text] [-n N] [-f] [name]"
        output_format="$2"
        shift 2
        ;;
      --format=*)
        output_format="${1#*=}"
        shift
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        die "未知参数：$1"
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [ "${#positional[@]}" -gt 0 ]; then
    name="${positional[0]}"
  fi

  if [ "$follow" -eq 1 ] && [ "$lines_set" -eq 0 ]; then
    lines=50
  fi

  case "$output_format" in
    text|json) ;;
    *) die "未知输出格式：$output_format（支持 text|json）" ;;
  esac

  if [ -n "$name" ]; then
    name="$(resolve_name "$name")"
  else
    name="$(resolve_name "")"
  fi

  local unit; unit="$(unit_name_for "$name")"

  if [ "$follow" -eq 1 ]; then
    # 直接跟随输出（不做着色，以免干扰实时刷新；如需保留可复用之前的 awk 上色）
    if [ "$output_format" = "json" ]; then
      exec journalctl --user -u "$unit" -n "$lines" -f --no-pager -o json
    else
      exec journalctl --user -u "$unit" -n "$lines" -f --no-pager
    fi
  fi

  # 原有逻辑（静态高亮查看）
  local log
  if [ "$output_format" = "json" ]; then
    journalctl --user -u "$unit" -n "$lines" -e --no-pager -o json
    return 0
  fi

  log="$(journalctl --user -u "$unit" -n "$lines" -e --no-pager 2>&1 || true)"
  if [ "$USE_COLOR" -ne 1 ] || [ ! -t 1 ]; then
    printf "%s\n" "$log"
    return 0
  fi
  # ……保留你之前的 awk 高亮逻辑 ……
  awk -v R="$C_RED" -v Y="$C_YELLOW" -v G="$C_GREEN" -v C="$C_CYAN" -v D="$C_DIM" -v B="$C_BOLD" -v Z="$C_RESET" '
    {
      line=$0
      gsub(/(FAILED|failure|exit-code|ERROR|ERR)/,   R"&"Z, line)
      gsub(/(WARN|WARNING)/,                         Y"&"Z, line)
      gsub(/(Started |Running|Listening on)/,        G"&"Z, line)
      gsub(/(INFO)/,                                 C"&"Z, line)
      gsub(/(DEBUG|trace|verbose)/,                  D"&"Z, line)
      gsub(/sslocal|ss-local|v2ray-plugin/, B"&"Z, line)
      print line
    }
  ' <<<"$log"
}
