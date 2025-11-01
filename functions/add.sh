#!/usr/bin/env bash

. "${SCRIPT_DIR:-.}/functions/utils.sh"

cmd_add(){
  self_check
  local name="$1"; shift || true
  [ -n "$name" ] || die "用法：ssctl add <name> [--from-file FILE | --from-clipboard | --server HOST ...]"

  local from_file="" from_clipboard=0 server="" port="" method="" password="" lport="" engine="" plugin="" plugin_opts=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from-file)    from_file="$2"; shift 2 ;;
      --from-clipboard) from_clipboard=1; shift ;;
      --server)       server="$2"; shift 2 ;;
      --port)         port="$2"; shift 2 ;;
      --method)       method="$2"; shift 2 ;;
      --password)     password="$2"; shift 2 ;;
      --local-port)   lport="$2"; shift 2 ;;
      --engine)       engine="$2"; shift 2 ;;
      --plugin)       plugin="$2"; shift 2 ;;
      --plugin-opts)  plugin_opts="$2"; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done

  local dst; dst="$(node_json_path "$name")"
  [ -e "$dst" ] && die "节点已存在：$name（文件：$dst）"

  if [ -n "$from_file" ]; then
    [ -r "$from_file" ] || die "无法读取 --from-file: $from_file"
    jq . <"$from_file" >"$dst" || die "导入失败：不是合法 JSON？"
    ok "已从文件导入节点：$name"
  elif [ "$from_clipboard" -eq 1 ]; then
    local clipboard_content=""
    if command -v xclip >/dev/null 2>&1; then
        clipboard_content=$(xclip -o -selection clipboard)
    elif command -v wl-paste >/dev/null 2>&1; then
        clipboard_content=$(wl-paste)
    else
        die "需要 xclip (X11) 或 wl-paste (Wayland) 来从剪贴板读取。"
    fi
    
    if [[ "$clipboard_content" == ss://* ]]; then
        local link_body="${clipboard_content#ss://}"
        local without_fragment="${link_body%%#*}"
        local query=""
        if [[ "$without_fragment" == *"\?"* ]]; then
            query="${without_fragment#*\?}"
        fi
        local core_part="${without_fragment%%\?*}"

        local decoded_cred
        decoded_cred="$(urlsafe_b64_decode "$core_part" || true)"
        if [[ "$decoded_cred" != *@* ]]; then
            decoded_cred="$core_part"
        fi
        decoded_cred="${decoded_cred//$'\r'/}"

        local ss_method ss_password ss_server ss_port host_port rest
        ss_method="${decoded_cred%%:*}"
        rest="${decoded_cred#*:}"
        ss_password="${rest%%@*}"
        host_port="${rest#*@}"
        if [[ "$host_port" == \[*\]*:* ]]; then
            ss_server="${host_port%%]*}"
            ss_server="${ss_server#[}"
            ss_port="${host_port##*]:}"
        else
            ss_server="${host_port%%:*}"
            ss_port="${host_port##*:}"
        fi

        local plugin="" plugin_opts=""
        parse_plugin_params "$query" plugin plugin_opts

        jq -n \
          --arg name "$name" \
          --arg server "$ss_server" \
          --argjson server_port "$ss_port" \
          --arg method "$ss_method" \
          --arg password "$ss_password" \
          --arg laddr "$DEFAULT_LOCAL_ADDR" \
          --argjson lport "${lport:-$DEFAULT_LOCAL_PORT}" \
          --arg engine "auto" \
          --arg plugin "$plugin" \
          --arg plugin_opts "$plugin_opts" \
          '{
             name:$name,
             server:$server,
             server_port:$server_port,
             method:$method,
             password:$password,
             local_address:$laddr,
             local_port:$lport,
             engine:$engine
           }
           + (if ($plugin|length)>0 then {plugin:$plugin} else {} end)
           + (if ($plugin_opts|length)>0 then {plugin_opts:$plugin_opts} else {} end)' >"$dst" || warn "写入失败：$dst"
        ok "已从剪贴板导入节点：$name"
    else
        # Assume it is a JSON config
        echo "$clipboard_content" | jq . >"$dst" || die "从剪贴板导入失败：不是合法的JSON或ss://链接"
        ok "已从剪贴板导入JSON配置：$name"
    fi
  else
    [ -n "$server" ]   || die "缺少 --server"
    [ -n "$port" ]     || die "缺少 --port"
    [ -n "$method" ]   || die "缺少 --method"
    [ -n "$password" ] || die "缺少 --password"
    [ -n "$lport" ] || lport="${DEFAULT_LOCAL_PORT}"

    case "${engine,,}" in
      ""|auto|rust|libev) ;;
      *) warn "未知 engine=$engine，已忽略，按 auto 处理"; engine="auto" ;;
    esac

    jq -n \
      --arg name "$name" \
      --arg server "$server" \
      --argjson server_port "$port" \
      --arg method "$method" \
      --arg password "$password" \
      --arg laddr "$DEFAULT_LOCAL_ADDR" \
      --argjson lport "$lport" \
      --arg engine "${engine:-auto}" \
      --arg plugin "$plugin" \
      --arg plugin_opts "$plugin_opts" \
      '{
         name:$name,
         server:$server,
         server_port:$server_port,
         method:$method,
         password:$password,
         local_address:$laddr,
         local_port:$lport,
         engine:$engine
       }
       + (if ($plugin|length)>0 then {plugin:$plugin} else {} end)
       + (if ($plugin_opts|length)>0 then {plugin_opts:$plugin_opts} else {} end)
      ' >"$dst" || die "写入失败：$dst"
    ok "已创建节点：$name"
  fi

  chmod 600 "$dst"
  if [ ! -L "${CURRENT_JSON}" ]; then
    ln -sfn "$dst" "${CURRENT_JSON}"
    ok "已设为当前节点：$name（仅指向，不自动启动）"
    warn "可运行：ssctl start"
  fi
}
