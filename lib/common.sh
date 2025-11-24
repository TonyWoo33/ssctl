#!/usr/bin/env bash
init_color_defaults(){
  SSCTL_COLOR_DEFAULT=1
  if [ ! -t 1 ]; then SSCTL_COLOR_DEFAULT=0; fi
  if [ -n "${NO_COLOR:-}" ]; then SSCTL_COLOR_DEFAULT=0; fi
  COLOR_FLAG="${SSCTL_COLOR:-${SSNODE_COLOR:-$SSCTL_COLOR_DEFAULT}}"
}

apply_color_palette(){
  if [ "${COLOR_FLAG:-1}" = "0" ]; then
    USE_COLOR=0
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
  else
    USE_COLOR=1
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'

    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_MAGENTA=$'\033[35m'
    C_CYAN=$'\033[36m'
  fi
  export USE_COLOR C_BOLD C_MAGENTA C_CYAN
}

info(){ printf "%s[*]%s %s\n"   "$C_BLUE"  "$C_RESET" "$*" >&2; }
ok(){   printf "%s[✓]%s %s\n"   "$C_GREEN" "$C_RESET" "$*" >&2; }
success(){ ok "$@"; }
warn(){ printf "%s[!]%s %s\n"   "$C_YELLOW" "$C_RESET" "$*" >&2; }
err(){  printf "%s[✗]%s %s\n"   "$C_RED"   "$C_RESET" "$*" >&2; }
error(){ err "$@"; }
die(){  err "$*"; exit 1; }
need_bin(){ command -v "$1" >/dev/null 2>&1 || die "缺少依赖：$1"; }

_ellipsis(){
  local s="$1" w="${2:-20}" len=${#1}
  if (( len > w )); then printf "%s…" "${s:0:$((w-1))}"; else printf "%s" "$s"; fi
}

_hr(){
  local cols="${1:-80}"
  local utf8_flag="${SSCTL_UTF8:-${SSNODE_UTF8:-0}}"
  local use_utf8=0
  if [ "$utf8_flag" = "1" ] && printf '%s' "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" | grep -qi 'utf-8'; then
    use_utf8=1
  fi
  printf '%s' "$C_DIM"
  if [ "$use_utf8" -eq 1 ]; then
    printf '%*s\n' "$cols" '' | tr ' ' '─'
  else
    printf '%*s\n' "$cols" '' | tr ' ' '-'
  fi
  printf '%s' "$C_RESET"
}

ssctl_realpath(){
  local target="$1" must_exist="${2:-0}" resolved=""
  if command -v realpath >/dev/null 2>&1; then
    if [ "$must_exist" -eq 1 ]; then
      resolved="$(realpath "$target" 2>/dev/null || true)"
    else
      resolved="$(realpath -m "$target" 2>/dev/null || true)"
    fi
  fi
  if [ -z "$resolved" ] && command -v readlink >/dev/null 2>&1; then
    resolved="$(readlink -f "$target" 2>/dev/null || true)"
  fi
  if [ -z "$resolved" ]; then
    local py_cmd=""
    if command -v python3 >/dev/null 2>&1; then
      py_cmd="python3"
    elif command -v python >/dev/null 2>&1; then
      py_cmd="python"
    fi
    if [ -n "$py_cmd" ]; then
      resolved="$("$py_cmd" - <<'PY' "$target" "$must_exist" 2>/dev/null
import os, sys
path = sys.argv[1]
must = sys.argv[2] == "1"
if not os.path.isabs(path):
    path = os.path.join(os.getcwd(), path)
if must and not os.path.lexists(path):
    sys.exit(1)
if must:
    print(os.path.realpath(path))
else:
    base = os.path.dirname(path)
    if not os.path.isdir(base):
        sys.exit(1)
    print(os.path.normpath(path))
PY
)" || true
    fi
  fi
  if [ -z "$resolved" ]; then
    if [ "$must_exist" -eq 1 ] && [ ! -e "$target" ] && [ ! -L "$target" ]; then
      return 1
    fi
    local dir
    dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
    resolved="${dir}/$(basename "$target")"
  fi
  printf '%s\n' "$resolved"
}

is_safe_identifier(){
  local value="$1"
  [ -n "$value" ] || return 1
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  case "$value" in
    *..*) return 1 ;;
  esac
  return 0
}

require_safe_identifier(){
  local value="$1" label="${2:-名称}"
  if ! is_safe_identifier "$value"; then
    die "非法${label}：${value}（仅允许 A-Z/a-z/0-9/._- 且不得包含 .. 或 /）"
  fi
}

sanitize_identifier_token(){
  local value="$1"
  value="$(printf '%s' "${value:-}" | tr -c 'A-Za-z0-9._-' '_')"
  value="${value//../_}"
  while [[ "$value" == *__* ]]; do value="${value//__/_}"; done
  while [[ "$value" == _* ]]; do value="${value#_}"; done
  while [[ "$value" == *_ ]]; do value="${value%_}"; done
  while [[ "$value" == .* ]]; do value="${value#.}"; done
  while [[ "$value" == *. ]]; do value="${value%.}"; done
  [ -n "$value" ] || value="node"
  printf '%s\n' "$value"
}

__SSCTL_NODES_REALPATH=""
nodes_dir_realpath(){
  if [ -z "${__SSCTL_NODES_REALPATH:-}" ]; then
    __SSCTL_NODES_REALPATH="$(ssctl_realpath "$NODES_DIR" 1 2>/dev/null || printf '%s' "$NODES_DIR")"
  fi
  printf '%s\n' "$__SSCTL_NODES_REALPATH"
}

ensure_node_path_safe(){
  local candidate="$1"
  local nodes_real lexical_dir resolved=""
  nodes_real="$(nodes_dir_realpath)"
  lexical_dir="$(dirname "$candidate")"
  if [ "$lexical_dir" != "$NODES_DIR" ] && [ "$lexical_dir" != "$nodes_real" ]; then
    die "拒绝非 nodes 目录中的路径：$candidate"
  fi
  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    resolved="$(ssctl_realpath "$candidate" 1 2>/dev/null || true)"
    [ -n "$resolved" ] || die "无法解析节点路径：$candidate"
    case "$resolved" in
      "$nodes_real"|"$nodes_real"/*) ;;
      *) die "检测到节点路径逃逸：$candidate" ;;
    esac
    if [ -L "$candidate" ]; then
      die "拒绝操作符号链接节点文件：$candidate"
    fi
  fi
}
