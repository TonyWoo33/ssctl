#!/usr/bin/env bash

detect_pkg_manager(){
  local candidates=(apt-get dnf pacman zypper apk brew)
  local pm
  for pm in "${candidates[@]}"; do
    if command -v "$pm" >/dev/null 2>&1; then
      echo "$pm"
      return 0
    fi
  done
  return 1
}

pm_pretty_name(){
  case "$1" in
    apt-get) echo "APT (Debian/Ubuntu)";;
    dnf)     echo "DNF (Fedora/CentOS/RHEL)";;
    pacman)  echo "pacman (Arch/Manjaro)";;
    zypper)  echo "Zypper (openSUSE)";;
    apk)     echo "apk (Alpine)";;
    brew)    echo "Homebrew";;
    *)       echo "$1";;
  esac
}

run_pkg_command(){
  local pm="$1"; shift
  local cmd=("$pm" "$@")
  if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      cmd=(sudo "${cmd[@]}")
    else
      warn "缺少 sudo：请以 root 身份执行或先安装 sudo。命令：${cmd[*]}"
      return 1
    fi
  fi
  info "执行：${cmd[*]}"
  if ! "${cmd[@]}"; then
    warn "包管理器命令失败：${cmd[*]}"
    return 1
  fi
}

pkg_install(){
  local pm
  pm="$(detect_pkg_manager)" || { warn "无法自动识别包管理器，请手动安装依赖。"; return 1; }
  local packages=("$@")
  [ "${#packages[@]}" -gt 0 ] || return 0
  case "$pm" in
    apt-get)
      run_pkg_command "$pm" update || return 1
      run_pkg_command "$pm" install -y "${packages[@]}" || return 1
      ;;
    dnf)
      run_pkg_command "$pm" install -y "${packages[@]}" || return 1
      ;;
    pacman)
      run_pkg_command "$pm" -Sy --noconfirm "${packages[@]}" || return 1
      ;;
    zypper)
      run_pkg_command "$pm" install -y "${packages[@]}" || return 1
      ;;
    apk)
      run_pkg_command "$pm" add "${packages[@]}" || return 1
      ;;
    brew)
      run_pkg_command "$pm" install "${packages[@]}" || return 1
      ;;
    *)
      warn "尚未支持的包管理器：$pm，请手动安装：${packages[*]}"
      return 1
      ;;
  esac
  ok "已尝试通过 $(pm_pretty_name "$pm") 安装：${packages[*]}"
}

package_for_tool(){
  local tool="$1" pm="$2"
  case "$pm" in
    apt-get)
      case "$tool" in
        jq|curl|qrencode|xclip) echo "$tool";;
        wl-paste) echo "wl-clipboard";;
        nc) echo "netcat-openbsd";;
        ss) echo "iproute2";;
        sslocal) echo "shadowsocks-rust";;
        ss-local) echo "shadowsocks-libev";;
      esac
      ;;
    dnf)
      case "$tool" in
        jq|curl|qrencode|xclip) echo "$tool";;
        wl-paste) echo "wl-clipboard";;
        nc) echo "nmap-ncat";;
        ss) echo "iproute";;
        sslocal) echo "shadowsocks-rust";;
        ss-local) echo "shadowsocks-libev";;
      esac
      ;;
    pacman)
      case "$tool" in
        jq|curl|qrencode|xclip) echo "$tool";;
        wl-paste) echo "wl-clipboard";;
        nc) echo "openbsd-netcat";;
        ss) echo "iproute2";;
        sslocal) echo "shadowsocks-rust";;
        ss-local) echo "shadowsocks-libev";;
      esac
      ;;
    zypper)
      case "$tool" in
        jq|curl|qrencode|xclip) echo "$tool";;
        wl-paste) echo "wl-clipboard";;
        nc) echo "netcat-openbsd";;
        ss) echo "iproute2";;
        sslocal) echo "shadowsocks-rust";;
        ss-local) echo "shadowsocks-libev";;
      esac
      ;;
    apk)
      case "$tool" in
        jq|curl|qrencode|xclip) echo "$tool";;
        wl-paste) echo "wl-clipboard";;
        nc) echo "netcat-openbsd";;
        ss) echo "iproute2";;
        sslocal) echo "shadowsocks-rust";;
        ss-local) echo "shadowsocks-libev";;
      esac
      ;;
    brew)
      case "$tool" in
        jq|curl|qrencode|xclip) echo "$tool";;
        wl-paste) echo "wl-clipboard";;
        nc) echo "netcat";;
        sslocal) echo "shadowsocks-rust";;
        ss-local) echo "shadowsocks-libev";;
      esac
      ;;
  esac
}

cmd_doctor(){
  local auto_install=0 dry_run=0
  local include_clipboard="$CONFIG_DOCTOR_INCLUDE_CLIPBOARD"
  local include_qrencode="$CONFIG_DOCTOR_INCLUDE_QRENCODE"
  local include_libev="$CONFIG_DOCTOR_INCLUDE_LIBEV"

  while [ $# -gt 0 ]; do
    case "$1" in
      -i|--install) auto_install=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      --without-clipboard) include_clipboard=0; shift ;;
      --with-clipboard) include_clipboard=1; shift ;;
      --without-qrcode) include_qrencode=0; shift ;;
      --with-qrcode) include_qrencode=1; shift ;;
      --without-libev) include_libev=0; shift ;;
      --with-libev) include_libev=1; shift ;;
      -h|--help)
        cat <<'DOC'
用法：ssctl doctor [--install|-i] [--dry-run] [--without-clipboard] [--without-qrcode] [--without-libev]
说明：
  - 默认仅检测依赖与运行环境。
  - --install           自动尝试安装缺失依赖（需要 sudo 或 root 权限）。
  - --dry-run           与 --install 配合使用时，仅输出将执行的安装命令，不真正执行。
  - --without-clipboard 跳过剪贴板工具 (xclip/wl-paste) 检测。
  - --without-qrcode    跳过 qrencode 检测。
  - --without-libev     跳过 ss-local (libev) 客户端检测。
DOC
        return 0
        ;;
      *)
        die "未知参数：$1（使用 ssctl doctor --help 查看用法）"
        ;;
    esac
  done

  init_dirs

  local pm=""
  if pm="$(detect_pkg_manager)"; then
    info "检测到包管理器：$(pm_pretty_name "$pm")"
  else
    warn "未识别到支持的包管理器，自动安装功能将不可用。"
  fi

  local header_width=100
  _hr "$header_width"
  printf "%-18s %-6s %-10s %s\n" "组件" "分类" "状态" "说明"
  _hr "$header_width"

  local doctor_kernel
  doctor_kernel="$(uname -s 2>/dev/null || echo unknown)"

  local missing_required=()
  local missing_optional=()
  local missing_client=()
  local skipped_optional=()
  local skipped_client=()
  local install_candidates=()
  local missing_stats_tool=""

  doctor_category_label(){
    case "$1" in
      required) echo "核心" ;;
      optional) echo "可选" ;;
      client)   echo "客户端" ;;
      *)        echo "$1" ;;
    esac
  }

  doctor_print(){
    local label="$1" tier="$2" status_text="$3" detail="$4"
    printf "%-18s %-6s %-10s %s\n" "$label" "$(doctor_category_label "$tier")" "$status_text" "$detail"
  }

  doctor_check(){
    local tool="$1" label="$2" tier="$3"
    local path
    if path="$(command -v "$tool" 2>/dev/null)"; then
      doctor_print "$label" "$tier" "${C_GREEN}OK${C_RESET}" "$path"
    else
      doctor_print "$label" "$tier" "${C_RED}缺失${C_RESET}" "未找到可执行文件：$tool"
      case "$tier" in
        required) missing_required+=("$tool") ;;
        optional) missing_optional+=("$tool") ;;
        client)   missing_client+=("$tool") ;;
      esac
      if [ -n "$pm" ]; then
        local pkg
        pkg="$(package_for_tool "$tool" "$pm")"
        if [ -n "$pkg" ]; then
          install_candidates+=("$pkg")
        fi
      fi
    fi
  }

  doctor_skip(){
    local label="$1" tier="$2" reason="$3"
    doctor_print "$label" "$tier" "${C_DIM}SKIP${C_RESET}" "$reason"
    case "$tier" in
      optional) skipped_optional+=("$label") ;;
      client)   skipped_client+=("$label") ;;
    esac
  }

  doctor_check jq            "jq"            required
  doctor_check curl          "curl"          required
  doctor_check systemctl     "systemctl"     required

  if [ "$include_qrencode" -eq 1 ]; then
    doctor_check qrencode    "qrencode"      optional
  else
    doctor_skip "qrencode" optional "已跳过（--without-qrcode）"
  fi

  doctor_check nc            "nc"            optional

  if [ "$include_clipboard" -eq 1 ]; then
    doctor_check xclip       "xclip"         optional
    doctor_check wl-paste    "wl-paste"      optional
  else
    doctor_skip "xclip" optional "已跳过（--without-clipboard）"
    doctor_skip "wl-paste" optional "已跳过（--without-clipboard）"
  fi

  case "$doctor_kernel" in
    Linux)
      doctor_check ss "ss (iproute2)" optional
      command -v ss >/dev/null 2>&1 || missing_stats_tool="ss"
      ;;
    Darwin)
      doctor_check nettop "nettop" optional
      command -v nettop >/dev/null 2>&1 || missing_stats_tool="nettop"
      warn "ssctl 面向 GNU/Linux，当前为 macOS：速率采样与 monitor --ping 可能受限。"
      ;;
    *)
      warn "未针对 ${doctor_kernel} 平台进行适配测试，部分功能可能异常。"
      ;;
  esac

  doctor_check sslocal       "shadowsocks-rust" client
  if [ "$include_libev" -eq 1 ]; then
    doctor_check ss-local    "shadowsocks-libev" client
  else
    doctor_skip "ss-local" client "已跳过（--without-libev）"
  fi

  _hr "$header_width"

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user list-unit-files --no-legend >/dev/null 2>&1; then
      ok "systemd --user 已可用。"
    else
      warn "systemd --user 无法访问。可能需要执行：loginctl enable-linger $USER && 重登，或确认系统支持 user-level systemd。"
    fi
  fi

  if [ "${#missing_required[@]}" -eq 0 ]; then
    ok "核心依赖已满足。"
  else
    err "核心依赖缺失：${missing_required[*]}"
  fi

  if [ "${#missing_client[@]}" -eq 0 ]; then
    ok "Shadowsocks 客户端可用。"
  else
    warn "Shadowsocks 客户端缺失：${missing_client[*]}（可任选其一安装）。"
  fi

  if [ "${#missing_optional[@]}" -gt 0 ]; then
    warn "可选工具缺失：${missing_optional[*]}（部分功能将受限）。"
  else
    ok "可选工具齐全。"
  fi

  if [ -n "$missing_stats_tool" ]; then
    warn "缺少 ${missing_stats_tool}，monitor --speed 与 ssctl stats 将无法采样速率。"
  fi

  if [ "${#skipped_optional[@]}" -gt 0 ]; then
    info "已按配置跳过可选组件检测：${skipped_optional[*]}"
  fi
  if [ "${#skipped_client[@]}" -gt 0 ]; then
    info "已按配置跳过客户端检测：${skipped_client[*]}"
  fi

  if ! date --iso-8601=seconds >/dev/null 2>&1; then
    warn "当前系统的 date 不支持 --iso-8601=seconds（需要 GNU coreutils date 或 macOS 的 gdate）。"
  fi
  if command -v ping >/dev/null 2>&1; then
    if ! ping -c1 -W1 127.0.0.1 >/dev/null 2>&1; then
      warn "检测到 ping 不支持 -W 语法，monitor --ping 将不可用（请安装 GNU ping/iputils）。"
    fi
  else
    warn "未找到 ping 命令，monitor --ping 将不可用。"
  fi

  if [ "${#install_candidates[@]}" -gt 0 ]; then
    mapfile -t install_candidates < <(printf '%s\n' "${install_candidates[@]}" | awk 'NF' | sort -u)
    info "建议安装的包：${install_candidates[*]}"
    if [ "$auto_install" -eq 1 ]; then
      if [ "$dry_run" -eq 1 ]; then
        if [ -n "$pm" ]; then
          info "dry-run：将执行的安装命令（未真正执行）："
          printf '  %s %s\n' "$pm" "${install_candidates[*]}"
        else
          warn "dry-run：未能确定包管理器，请手动安装：${install_candidates[*]}"
        fi
      else
        if [ -n "$pm" ]; then
          pkg_install "${install_candidates[@]}" || warn "自动安装部分包失败，请检查上述输出。"
        else
          warn "未能确定包管理器，请手动安装：${install_candidates[*]}"
        fi
      fi
    else
      info "可运行：ssctl doctor --install 进行自动安装（需 sudo/root）。"
    fi
  else
    ok "没有可自动安装的缺失包。"
  fi

  if [ "${#missing_required[@]}" -eq 0 ]; then
    ok "环境检测完成，可执行：ssctl start <节点名>"
  else
    err "请先补齐核心依赖后再继续使用。"
    return 1
  fi
}

ssctl_require_node_deps_met(){
  local node_json="${1:-}"
  [ -n "$node_json" ] || die "(ssctl_require_node_deps_met) 缺少节点 JSON 内容"

  local node_name plugin_name
  node_name="$(jq -r '.__name // .name // empty' <<<"$node_json" 2>/dev/null || true)"
  [ -n "$node_name" ] || node_name="(unknown)"

  plugin_name="$(jq -r '.plugin // ""' <<<"$node_json" 2>/dev/null || true)"
  if [ -z "$plugin_name" ] || [ "$plugin_name" = "null" ]; then
    return 0
  fi

  if ! command -v "$plugin_name" >/dev/null 2>&1; then
    die "Dependency check failed for node '${node_name}': Plugin '${plugin_name}' is specified but not found in \$PATH."
  fi
}
