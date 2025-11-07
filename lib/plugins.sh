#!/usr/bin/env bash

expand_path(){
  case "$1" in
    "") return 1 ;;
    ~) printf '%s\n' "$HOME" ;;
    ~/*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

load_plugins(){
  local unique_dirs=()
  local seen=""
  add_dir(){
    local raw="$1" resolved
    [ -n "$raw" ] || return 0
    resolved=$(expand_path "$raw" 2>/dev/null || true)
    [ -n "$resolved" ] || return 0
    [ -d "$resolved" ] || return 0
    case " $seen " in
      *" $resolved "*) return 0 ;;
    esac
    seen="$seen $resolved"
    unique_dirs+=("$resolved")
  }

  for dir in "${LIB_DIR}/functions.d"; do
    add_dir "$dir"
  done
  add_dir "${HOME}/.config/ssctl/functions.d"

  if [ -n "${SSCTL_PLUGIN_DIRS:-}" ]; then
    local IFS=':'
    for dir in $SSCTL_PLUGIN_DIRS; do
      add_dir "$dir"
    done
  fi

  if [ "${#CONFIG_PLUGIN_PATHS[@]}" -gt 0 ]; then
    for dir in "${CONFIG_PLUGIN_PATHS[@]}"; do
      add_dir "$dir"
    done
  fi

  for dir in "${unique_dirs[@]}"; do
    for file in "$dir"/*.sh; do
      [ -e "$file" ] || continue
      # shellcheck disable=SC1090
      . "$file"
    done
  done
}
