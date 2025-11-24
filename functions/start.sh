#!/usr/bin/env bash

# shellcheck disable=SC1091
. "${LIB_DIR}/lib/engines/shadowsocks.sh"
# shellcheck disable=SC1091
. "${LIB_DIR}/lib/engines/v2ray.sh"

cmd_start(){
  self_check

  local input_name="${1:-}"
  local target_name; target_name="$(resolve_name "$input_name")"
  local target_json_path; target_json_path="$(node_json_path "$target_name")"
  local node_json
  node_json="$(jq -c --arg name "$target_name" '. + {__name:$name}' "$target_json_path")"
  ssctl_require_node_deps_met "$node_json"

  local engine
  engine="$(jq -r '.engine // "shadowsocks"' <<< "$node_json")"
  engine="${engine,,}"

  local engine_variant
  engine_variant="$(pick_engine "$target_name")"

  if [ "$engine_variant" = "libev" ]; then
    local libev_run_config=""
    if ! libev_run_config="$(jq -c '
      def __ensure_server_port:
        if (.server_port // null) != null then (.server_port | tonumber)
        elif (.port // null) != null then (.port | tonumber)
        else error("missing remote port")
        end;
      def __to_number($v):
        if ($v // null) == null then null
        elif ($v | type) == "number" then $v
        else ($v | tonumber)
        end;
      {
        server: .server,
        server_port: __ensure_server_port,
        password: .password,
        method: .method,
        local_address: (.local_address // "127.0.0.1"),
        local_port: __to_number(.local_port // 1080),
        timeout: __to_number(.timeout // 300)
      }
      + (if ((.plugin // "" ) | length) > 0 then {plugin: .plugin} else {} end)
      + (if ((.plugin_opts // "" ) | length) > 0 then {plugin_opts: .plugin_opts} else {} end)
    ' <<<"$node_json")"; then
      die "节点 ${target_name} 缺少远端端口（port/server_port）"
    fi
    local libev_server_port
    libev_server_port="$(jq -r '.server_port // empty' <<<"$libev_run_config")"
    if [ -z "$libev_server_port" ] || [ "$libev_server_port" = "null" ]; then
      die "节点 ${target_name} 缺少远端端口（port/server_port）"
    fi
    node_json="$(jq -c --argjson cfg "$libev_run_config" '. + {__libev_run_config:$cfg}' <<<"$node_json")"
  fi

  local target_unit service_definition=""
  case "$engine" in
    ""|auto|shadowsocks|rust|libev)
      local port
      port="$(jq -r '.local_port // empty' <<<"$node_json")"
      [ -n "$port" ] || port="$DEFAULT_LOCAL_PORT"
      target_unit="sslocal-${target_name}-${port}.service"
      service_definition="$(engine_shadowsocks_get_service_def "$node_json")"
      ;;
    v2ray)
      target_unit="v2ray-${target_name}.service"
      service_definition="$(engine_v2ray_get_service_def "$node_json")"
      ;;
    *)
      die "不支持的 engine: $engine"
      ;;
  esac

  local unit_file_path=""
  if ! unit_file_path="$(ssctl_service_create "$target_unit" "$service_definition")"; then
    die "服务 [${target_unit}] 创建失败。"
  fi
  if [ -z "$unit_file_path" ]; then
    die "服务 [${target_unit}] 创建成功但未返回 unit 路径。"
  fi
  ok "已生成 unit: ${target_unit}"

  if ! ssctl_service_reload; then
    die "无法重载 systemd daemon"
  fi

  local unit_glob_prefix="${target_unit%%-*}"
  local unit_glob="${unit_glob_prefix}-*.service"
  ssctl_service_cache_unit_states "$unit_glob"
  if ssctl_service_is_active "$target_unit"; then
    success "节点 '${target_name}' 已经处于活动状态。"
    return 0
  fi

  local unit_name
  for unit_name in "${!__SSCTL_UNIT_STATE_CACHE[@]}"; do
    [ -n "$unit_name" ] || continue
    [ "$unit_name" = "$target_unit" ] && continue
    if ssctl_service_is_active "$unit_name"; then
      info "停止其他单元：$unit_name"
      ssctl_service_stop "$unit_name" || warn "停止单元失败：$unit_name"
    fi
  done

  if ! ssctl_service_link_and_enable "$unit_file_path" "$target_unit"; then
    die "无法链接并启用单元：$target_unit"
  fi
  if ! ssctl_service_start "$target_unit"; then
    die "无法启动单元：$target_unit"
  fi
  success "已启动节点: $target_name"

  ln -sfn "$target_json_path" "${CURRENT_JSON}"
  ok "已设为当前节点：${target_name}"

  local rc=0
  if wait_listen "$target_name" 8; then
    set +e; probe "$target_name"; rc=$?; set -e
  else
    warn "服务刚启动，端口尚未监听（可能仍在初始化）"
    warn "可稍后运行：ssctl probe ${target_name}"
    rc=1
  fi

  return "$rc"
}
