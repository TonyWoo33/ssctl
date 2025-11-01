#!/usr/bin/env bash

. "${SCRIPT_DIR:-.}/functions/utils.sh"

SUB_CONF="${CONF_DIR}/subscriptions.json"

# Initialize subscription file if it doesn't exist
init_sub_conf(){
  if [ ! -f "$SUB_CONF" ]; then
    echo "[]" > "$SUB_CONF"
    chmod 600 "$SUB_CONF"
  fi
}


cmd_sub(){
  self_check
  init_sub_conf

  local sub_cmd="${1:-list}"; shift || true

  case "$sub_cmd" in
    add)
      # Usage: ssctl sub add <alias> <url>
      local alias="$1" url="$2"
      [ -n "$alias" ] || die "用法: ssctl sub add <alias> <url>"
      [ -n "$url" ] || die "用法: ssctl sub add <alias> <url>"
      
      if jq -e --arg alias "$alias" '.[] | select(.alias == $alias)' < "$SUB_CONF" > /dev/null; then
        die "订阅别名已存在: $alias"
      fi

      jq '[.[] | select(.alias != "'"$alias"'")] + [{alias: "'"$alias"'", url: "'"$url"'"}]' < "$SUB_CONF" > "${SUB_CONF}.tmp" && mv "${SUB_CONF}.tmp" "$SUB_CONF"
      ok "已添加订阅: $alias"
      ;;
    list)
      info "所有订阅:"
      jq -r '.[] | " - \(.alias): \(.url)"' < "$SUB_CONF"
      ;;
    remove)
      local alias="$1"
      [ -n "$alias" ] || die "用法: ssctl sub remove <alias>"
      jq 'map(select(.alias != "'"$alias"'"))' < "$SUB_CONF" > "${SUB_CONF}.tmp" && mv "${SUB_CONF}.tmp" "$SUB_CONF"
      ok "已移除订阅: $alias"
      ;;
    update)
      local force=0
      local target_alias="all"

      while [ $# -gt 0 ]; do
        case "$1" in
          --force|-f)
            force=1
            shift
            ;;
          --)
            shift
            if [ $# -gt 0 ]; then
              [ "$target_alias" = "all" ] || die "重复指定目标: $1"
              target_alias="$1"
              shift
            fi
            [ $# -eq 0 ] || die "未知多余参数: $1 (用法: ssctl sub update [--force] [别名|all])"
            break
            ;;
          -*)
            die "未知参数: $1 (用法: ssctl sub update [--force] [别名|all])"
            ;;
          *)
            [ "$target_alias" = "all" ] || die "重复指定目标: $1"
            target_alias="$1"
            shift
            ;;
        esac
      done

      info "正在更新订阅... (目标: ${target_alias}; 覆盖模式: $([ "$force" -eq 1 ] && echo "强制" || echo "保留现有"))"

      local subs_to_update
      if [ "$target_alias" = "all" ]; then
        subs_to_update=$(jq -c '.[]' < "$SUB_CONF")
      else
        subs_to_update=$(jq -c --arg alias "$target_alias" '.[] | select(.alias == $alias)' < "$SUB_CONF")
      fi

      if [ -z "$subs_to_update" ]; then
        die "找不到要更新的订阅: $target_alias"
      fi

      echo "$subs_to_update" | while read -r sub_json; do
        local alias url
        alias=$(echo "$sub_json" | jq -r .alias)
        url=$(echo "$sub_json" | jq -r .url)

        info "正在处理订阅: $alias"
        local encoded_list
        encoded_list=$(curl -sS --max-time 20 "$url" || { warn "下载失败: $alias ($url)"; continue; })

        local decoded_list
        decoded_list=$(urlsafe_b64_decode "$encoded_list")

        if [ -z "$decoded_list" ]; then
          warn "解码失败或订阅为空: $alias"
          continue
        fi

        echo "$decoded_list" | while read -r line; do
          if [[ "$line" == ss://* ]]; then
            local link_body="${line#ss://}"
            local fragment=""
            if [[ "$link_body" == *"#"* ]]; then
              fragment="${link_body#*#}"
            fi
            fragment="$(url_decode "$fragment")"

            local without_fragment="${link_body%%#*}"
            local query=""
            if [[ "$without_fragment" == *\?* ]]; then
              query="${without_fragment#*\?}"
            fi
            local core_part="${without_fragment%%\?*}"

            local decoded_cred
            decoded_cred="$(urlsafe_b64_decode "$core_part" || true)"
            if [[ "$decoded_cred" != *@* ]]; then
              decoded_cred="$core_part"
            fi
            decoded_cred="${decoded_cred//$'\r'/}"

            local method="${decoded_cred%%:*}"
            local rest="${decoded_cred#*:}"
            local password_part="${rest%%@*}"
            local host_port="${rest#*@}"
            local server port
            if [[ "$host_port" == \[*\]*:* ]]; then
              server="${host_port%%]*}"
              server="${server#[}"
              port="${host_port##*]:}"
            else
              server="${host_port%%:*}"
              port="${host_port##*:}"
            fi
            local password="$password_part"

            local plugin="" plugin_opts=""
            if [ -n "$query" ]; then
              local IFS='&'
              read -ra kv_pairs <<< "$query"
              for kv_pair in "${kv_pairs[@]}"; do
                [ -n "$kv_pair" ] || continue
                local key="${kv_pair%%=*}"
                local value=""
                if [[ "$kv_pair" == *=* ]]; then
                  value="${kv_pair#*=}"
                fi
                value="$(url_decode "$value")"
                case "$key" in
                  plugin)
                    plugin="${value%%;*}"
                    if [[ "$value" == *";"* ]]; then
                      plugin_opts="${value#*;}"
                    fi
                    ;;
                  plugin_opts|plugin-opts)
                    if [ -n "$plugin_opts" ]; then
                      plugin_opts="${plugin_opts};${value}"
                    else
                      plugin_opts="$value"
                    fi
                    ;;
                esac
              done
            fi

            local node_suffix="$fragment"
            if [ -z "$node_suffix" ]; then
              node_suffix="${server}-${port}"
            fi
            local node_name="${alias}_${node_suffix}"

            info "正在添加/更新节点: $node_name"
            # Directly use the logic from cmd_add to create the JSON
            local dst dst_dir tmp_file
            dst="$(node_json_path "$node_name")"
            dst_dir="$(dirname "$dst")"
            tmp_file="$(mktemp "${dst_dir}/.subnode.XXXXXX" 2>/dev/null)" || {
              warn "无法创建临时文件，跳过: $node_name"
              continue
            }

            if ! jq -n \
              --arg name "$node_name" \
              --arg server "$server" \
              --argjson server_port "$port" \
              --arg method "$method" \
              --arg password "$password" \
              --arg laddr "$DEFAULT_LOCAL_ADDR" \
              --argjson lport "$DEFAULT_LOCAL_PORT" \
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
               + (if ($plugin_opts|length)>0 then {plugin_opts:$plugin_opts} else {} end)
              ' >"$tmp_file"; then
              warn "写入失败：$dst"
              rm -f "$tmp_file"
              continue
            fi

            chmod 600 "$tmp_file"

            if [ -e "$dst" ]; then
              if [ "$force" -ne 1 ]; then
                warn "节点已存在，使用 --force 可覆盖: $node_name"
                rm -f "$tmp_file"
                continue
              fi

              local backup
              backup="${dst}.bak.$(date +%Y%m%d%H%M%S)"
              if cp "$dst" "$backup"; then
                info "已备份旧节点到: $backup"
              else
                warn "备份失败，跳过覆盖: $node_name"
                rm -f "$tmp_file"
                continue
              fi
            fi

            if mv "$tmp_file" "$dst"; then
              chmod 600 "$dst"
              ok "节点已同步: $node_name"
            else
              warn "无法替换节点：$node_name"
              rm -f "$tmp_file"
              continue
            fi
          fi
        done
        ok "订阅处理完毕: $alias"
      done
      ;;
    *)
      die "未知订阅命令: $sub_cmd. 可用命令: add, list, remove, update"
      ;;
  esac
}
