#!/usr/bin/env bash

cmd_list(){
  self_check

  local W_NAME=22 W_RUN=5 W_LPORT=6 W_METH=24 W_ENG=6 W_UNIT=34
  local TOTAL=$((W_NAME+2 + W_RUN+2 + W_LPORT+2 + W_METH+2 + W_ENG+2 + W_UNIT))

  printf '%s' "$C_BOLD"
  printf "%-${W_NAME}s  %-${W_RUN}s  %-${W_LPORT}s  %-${W_METH}s  %-${W_ENG}s  %-${W_UNIT}s\n" \
    "NAME" "RUN" "LPORT" "METH" "ENG" "UNIT"
  printf '%s' "$C_RESET"
  _hr "$TOTAL"

  # Performance enhancement: Get all running units at once
  local running_units
  running_units=$(systemctl --user list-units --no-legend 'sslocal-*.service' 2>/dev/null | awk '$4=="running"{print $1}')

  # Performance enhancement: Read all node data at once
  local node_files=("${NODES_DIR}"/*.json)
  local all_node_data="[]"
  if [ "${#node_files[@]}" -gt 0 ]; then
    all_node_data=$(jq -s 'map({name: (.name // (input_filename | sub(".json$"; "") | sub(".*/"; ""))), lp: (.local_port // "1080"), meth: .method, eng: (.engine // "auto")}) | .[]' "${node_files[@]}")
  fi

  # Loop through nodes and display info
  local has_nodes=0
  for n in $(list_nodes); do
    has_nodes=1
    local node_info
    node_info=$(echo "$all_node_data" | jq --arg n "$n" 'select(.name == $n)')

    local s="${C_DIM}--${C_RESET}"
    local lp meth eng unit

    lp=$(echo "$node_info" | jq -r '.lp')
    meth=$(echo "$node_info" | jq -r '.meth')
    eng=$(echo "$node_info" | jq -r '.eng')
    unit=$(unit_name_for "$n") # unit_name_for still calls jq once, but that is acceptable for now
    
    if printf '%s\n' "$running_units" | grep -Fxq "$unit"; then
      s="${C_GREEN}RUN${C_RESET}"
    fi
    
    case "$(pick_engine "$n")" in # pick_engine still calls jq, acceptable for now
      rust)  eng="${C_CYAN}rust${C_RESET}" ;;
      libev) eng="${C_YELLOW}libev${C_RESET}" ;;
      *)     eng="${C_DIM}?${C_RESET}" ;;
    esac

    local n_c lp_c m_c u_c
    n_c="$(_ellipsis "$n"    "$W_NAME")"
    lp_c="$(_ellipsis "$lp"  "$W_LPORT")"
    m_c="$(_ellipsis "$meth" "$W_METH")"
    u_c="$(_ellipsis "$unit" "$W_UNIT")"

    printf "%-${W_NAME}s  %-${W_RUN}b  %-${W_LPORT}s  %-${W_METH}s  %-${W_ENG}b  %-${W_UNIT}s\n" \
      "$n_c" "$s" "$lp_c" "$m_c" "$eng" "$u_c"
  done

  _hr "$TOTAL"

  if [ "$has_nodes" -eq 0 ]; then
    warn "当前没有任何节点配置。使用：ssctl add <name> ..."
  fi

  if [ -L "${CURRENT_JSON}" ]; then
    local cur; cur="$(basename "$(readlink -f "${CURRENT_JSON}")" .json)"
    printf '%b%s%b%s\n' "${C_CYAN}[✓]${C_RESET} " "当前节点：" "${C_BOLD}" "$cur${C_RESET}"
  else
    printf '%b%s\n' "${C_YELLOW}[!]${C_RESET} " "current 尚未设置（用：ssctl switch <name>）"
  fi

  if run_now="$(current_running_node)"; then
    printf '%b%s%b%s\n' "${C_GREEN}[✓]${C_RESET} " "正在运行：" "${C_BOLD}" "$run_now${C_RESET}"
  else
    printf '%b%s\n' "${C_DIM}[--]${C_RESET} " "当前没有运行中的节点"
  fi
}
