#!/usr/bin/env bash

cmd_current(){
  self_check

  local running=""
  if running="$(current_running_node 2>/dev/null || true)" && [ -n "$running" ]; then
    printf 'Current node: %s\n' "$running"
    return 0
  fi

  local preferred=""
  if [ -L "${CURRENT_JSON}" ]; then
    local target
    target="$(readlink -f "${CURRENT_JSON}" 2>/dev/null || true)"
    if [ -n "$target" ] && [ -f "$target" ]; then
      preferred="$(basename "$target" .json)"
    fi
  fi

  if [ -n "$preferred" ]; then
    printf 'No node is active (preferred: %s)\n' "$preferred"
  else
    printf 'No node is active\n'
  fi
  return 1
}
