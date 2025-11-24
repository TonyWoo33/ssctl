#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${ROOT_DIR}/tests/test-utils.sh"
set -Eeuo pipefail

# shellcheck disable=SC1091
source "${ROOT_DIR}/functions/switch.sh"

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ssctl-switch-best.XXXX")"
trap 'rm -rf "$TEST_TMP_DIR"' EXIT

export CURRENT_JSON="${TEST_TMP_DIR}/current.json"
NODES_DIR="${TEST_TMP_DIR}/nodes"
mkdir -p "$NODES_DIR"

MOCK_LATENCY_JSON=""
MOCK_START_CALLED_WITH=""
MOCK_DIE_MSG=""
MOCK_SUCCESS_MSG=""

ssctl(){
  local sub="${1:-}"
  shift || true
  case "$sub" in
    latency)
      printf '%s\n' "${MOCK_LATENCY_JSON:-}"
      ;;
    start)
      MOCK_START_CALLED_WITH="${1:-}"
      ;;
    *)
      printf 'mock ssctl 未实现命令：%s\n' "$sub" >&2
      ;;
  esac
}

cmd_latency(){
  ssctl latency "$@"
}

cmd_start(){
  ssctl start "$@"
}

self_check(){ :; }
require_safe_identifier(){ :; }

node_json_path(){
  local name="$1"
  printf '%s/%s.json\n' "$NODES_DIR" "$name"
}

die(){
  MOCK_DIE_MSG="$*"
  return 1
}

success(){
  MOCK_SUCCESS_MSG="$*"
}

ok(){
  success "$@"
}

warn(){ :; }
info(){ :; }

reset_mocks(){
  MOCK_LATENCY_JSON=""
  MOCK_START_CALLED_WITH=""
  MOCK_DIE_MSG=""
  MOCK_SUCCESS_MSG=""
}

create_node(){
  local name="$1"
  mkdir -p "$NODES_DIR"
  printf '{"__name":"%s"}\n' "$name" >"$(node_json_path "$name")"
}

test_happy_path(){
  reset_mocks
  create_node "A"; create_node "B"; create_node "C"
  MOCK_LATENCY_JSON='{"results":[{"name":"A","ok":true,"latency_ms":100},{"name":"B","ok":true,"latency_ms":50},{"name":"C","ok":true,"latency_ms":200}]}'
  cmd_switch --best
  [[ "$MOCK_START_CALLED_WITH" == "B" ]]
  [[ -z "${MOCK_DIE_MSG}" ]]
}

test_filter_inactive(){
  reset_mocks
  create_node "A"; create_node "B"
  MOCK_LATENCY_JSON='{"results":[{"name":"A","ok":false,"latency_ms":50},{"name":"B","ok":true,"latency_ms":100}]}'
  cmd_switch --best
  [[ "$MOCK_START_CALLED_WITH" == "B" ]]
  [[ -z "${MOCK_DIE_MSG}" ]]
}

test_filter_timeout(){
  reset_mocks
  create_node "A"; create_node "B"
  MOCK_LATENCY_JSON='{"results":[{"name":"A","ok":true,"latency_ms":0},{"name":"B","ok":true,"latency_ms":100}]}'
  cmd_switch --best
  [[ "$MOCK_START_CALLED_WITH" == "B" ]]
  [[ -z "${MOCK_DIE_MSG}" ]]
}

test_all_fail(){
  reset_mocks
  MOCK_LATENCY_JSON='{"results":[{"name":"A","ok":false,"latency_ms":null},{"name":"B","ok":true,"latency_ms":0}]}'
  if cmd_switch --best; then
    echo "预期失败，但命令成功" >&2
    exit 1
  fi
  [[ -z "${MOCK_START_CALLED_WITH}" ]]
  [[ "${MOCK_DIE_MSG}" == *"未找到可用节点"* ]]
}

run_tests(){
  test_happy_path
  test_filter_inactive
  test_filter_timeout
  test_all_fail
  echo "switch --best tests passed."
}

run_tests
