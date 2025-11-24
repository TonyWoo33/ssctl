#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSCTL_BIN="${ROOT_DIR}/ssctl"
export SSCTL_LIB_DIR="${ROOT_DIR}"

# shellcheck disable=SC1090
source "${ROOT_DIR}/tests/test-utils.sh"

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ssctl-integration.XXXX")"
export HOME="${TEST_TMP}/home"
mkdir -p "${HOME}/.config/shadowsocks-rust/nodes"
export NODES_DIR="${HOME}/.config/shadowsocks-rust/nodes"
export CONF_DIR="${HOME}/.config/shadowsocks-rust"
export SYS_DIR="${HOME}/.config/systemd/user"
mkdir -p "${SYS_DIR}"
export __SSCTL_TEST_NODES_DIR="${NODES_DIR}"

TEST_PORT_SS=20800
TEST_PORT_V2RAY_API=20801
TEST_PORT_V2RAY_LOCAL=20802

MOCK_V2RAY_PID=""
ACTIVE_SS_NODE=""

log(){
  printf '[integration] %s\n' "$*" >&2
}

info(){
  printf '[integration][info] %s\n' "$*" >&2
}

die(){
  log "$*"
  exit 1
}

ssctl(){
  command bash "$SSCTL_BIN" "$@"
}

detect_platform(){
  local uname_s
  uname_s="$(uname -s 2>/dev/null || echo unknown)"
  case "$uname_s" in
    Darwin)
      SERVICE_MANAGER="launchd"
      ;;
    Linux)
      if command -v systemctl >/dev/null 2>&1; then
        SERVICE_MANAGER="systemd"
      else
        SERVICE_MANAGER="unknown"
      fi
      ;;
    *)
      SERVICE_MANAGER="unknown"
      ;;
  esac
  log "Running on $(uname -a 2>/dev/null || echo unknown)"
  log "Detected service manager: ${SERVICE_MANAGER}"
  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    if pushd "$ROOT_DIR" >/dev/null 2>&1; then
      export SSCTL_SOURCE_ONLY=1
      # shellcheck disable=SC1090
      source ./ssctl

      # [v3.6.18] 强制所有 'ssctl' 调用都使用本地脚本
      # 这将覆盖任何全局安装的 /usr/local/bin/ssctl 或 PATH 中的旧版本
      TEST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
      PROJECT_ROOT="$TEST_DIR/.."
      LOCAL_SSCTL_BIN="$PROJECT_ROOT/ssctl"

      if [ ! -f "$LOCAL_SSCTL_BIN" ]; then
        echo "[✗] [v3.6.18] 无法在 $LOCAL_SSCTL_BIN 找到本地 ssctl 脚本！" >&2
        exit 1
      fi

      ssctl() {
        command bash "$LOCAL_SSCTL_BIN" "$@"
      }

      echo "[integration] [v3.6.18] 已覆盖 'ssctl' 命令，强制使用: $LOCAL_SSCTL_BIN"

      unset SSCTL_SOURCE_ONLY
      popd >/dev/null 2>&1 || true
    else
      log "无法进入 ROOT_DIR 以 source ssctl"
    fi
  fi
  if [[ "$SERVICE_MANAGER" == "unknown" ]]; then
    log "Unsupported platform for integration test. Skipping."
    exit 0
  fi
}

require_bins(){
  local missing=()
  local bins=("jq" "curl")
  for b in "${bins[@]}"; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Missing required tools: ${missing[*]}"
    exit 1
  fi
}

ensure_mock_binaries(){
  local bin_dir="${TEST_TMP}/bin"
  mkdir -p "$bin_dir"
  export PATH="$bin_dir:$PATH"

  if ! command -v sslocal >/dev/null 2>&1; then
    cat >"${bin_dir}/sslocal" <<'EOF'
#!/usr/bin/env bash
log_file="${HOME}/sslocal-mock.log"
echo "[sslocal-mock] $*" >>"$log_file"
trap '' TERM INT
while true; do sleep 3600; done
EOF
    chmod +x "${bin_dir}/sslocal"
  fi

  if ! command -v v2ray >/dev/null 2>&1; then
    cat >"${bin_dir}/v2ray" <<'EOF'
#!/usr/bin/env bash
log_file="${HOME}/v2ray-mock.log"
echo "[v2ray-mock] $*" >>"$log_file"
trap '' TERM INT
while true; do sleep 3600; done
EOF
    chmod +x "${bin_dir}/v2ray"
  fi
}

setup(){
  detect_platform
  require_bins
  ensure_mock_binaries
}

teardown(){
  if [ -n "${MOCK_V2RAY_PID:-}" ]; then
    if kill -0 "$MOCK_V2RAY_PID" 2>/dev/null; then
      kill "$MOCK_V2RAY_PID" 2>/dev/null || true
    fi
  fi
  if [ -n "${ACTIVE_SS_NODE:-}" ]; then
    ssctl stop "$ACTIVE_SS_NODE" >/dev/null 2>&1 || true
  fi
  ssctl stop test-v2-node >/dev/null 2>&1 || true
  rm -rf "$TEST_TMP"
}
trap teardown EXIT

create_shadowsocks_node(){
  local target_json="${__SSCTL_TEST_NODES_DIR}/test-ss-usa6.json"

  cat <<'EOF' >"$target_json"
{
  "created_at": "2025-10-31T12:09:46.187397",
  "enabled": true,
  "engine": "libev",
  "local_address": "127.0.0.1",
  "local_port": 20800,
  "method": "aes-256-cfb",
  "name": "test-ss-usa6",
  "notes": null,
  "password": "565824",
  "port": 60239,
  "schema_version": 1,
  "server": "usa6.su211.com",
  "tags": [],
  "type": "shadowsocks",
  "udp_timeout": 300,
  "updated_at": "2025-10-31T12:09:46.187407"
}
EOF

  ACTIVE_SS_NODE="test-ss-usa6"
  log "[integration] [v3.7.37] 已写入 usa6 (libev) 节点：${target_json}"
  return 0
}

start_mock_v2ray_api(){
  local port="${1:-$TEST_PORT_V2RAY_API}"
  local script="${TEST_TMP}/mock_v2ray_api.py"
  cat >"$script" <<PY
import socket, threading, sys
HOST = "127.0.0.1"
PORT = int(${port})
RESPONSE = b"HTTP/1.1 200 OK\\r\\nContent-Type: application/json\\r\\n\\r\\n{\\"stat\\":[{\\"value\\":123456},{\\"value\\":789012}]}"

def handle(conn):
    try:
        conn.recv(65535)
        conn.sendall(RESPONSE)
    finally:
        conn.close()

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((HOST, PORT))
s.listen(5)
while True:
    conn, _ = s.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY
  python3 "$script" &
  MOCK_V2RAY_PID=$!
  export MOCK_V2RAY_PORT="$port"
  sleep 0.2
}

create_v2ray_node(){
  local config_path="${TEST_TMP}/v2ray-config.json"
  cat >"$config_path" <<'EOF'
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [],
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  }
}
EOF

  local node_file="${NODES_DIR}/test-v2-node.json"
  cat >"$node_file" <<EOF
{
  "server": "example.com",
  "server_port": 443,
  "password": "integration-pass",
  "method": "chacha20-ietf-poly1305",
  "engine": "v2ray",
  "local_address": "127.0.0.1",
  "local_port": ${TEST_PORT_V2RAY_LOCAL},
  "config_path": "${config_path}",
  "v2ray_stats_tag": "test",
  "sampler_api_port": "${MOCK_V2RAY_PORT:-$TEST_PORT_V2RAY_API}"
}
EOF
}

wait_for_stats(){
  local node="$1"
  local attempts=0
  while [ $attempts -lt 5 ]; do
    if ssctl stats "$node" --format json >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    attempts=$((attempts + 1))
  done
  return 1
}

test_shadowsocks_procfs(){
  log "[CASE] Plain SS (usa6) + Procfs"
  if ! create_shadowsocks_node; then
    log "[CASE SKIPPED] Shadowsocks + Procfs（无可用真实节点）"
    return 0
  fi
  local node="${ACTIVE_SS_NODE}"
  local start_rc=0
  if ! ssctl start "$node"; then
    start_rc=$?
  fi
  if [ "$start_rc" -ne 0 ]; then
    die "ssctl start ${node} 失败"
  fi
  wait_for_stats "$node"
  local output
  output="$(ssctl stats "$node" --format json)"
  echo "$output" | jq -e --arg node "$node" '.name == $node' >/dev/null
  echo "$output" | jq -e '.valid == true' >/dev/null
  if ! ssctl probe "$node"; then
    die "ssctl probe ${node} (真实节点) 失败"
  fi
  ssctl stop "$node"
  ACTIVE_SS_NODE=""
  log "[CASE PASSED] Shadowsocks + Procfs (节点: ${node})"
}

create_plugin_shadowsocks_node(){
  local target_json="${__SSCTL_TEST_NODES_DIR}/test-ss-freeglobal.json"

  cat <<'EOF' >"$target_json"
{
  "created_at": "2025-11-01T14:45:24.147602",
  "enabled": true,
  "engine": "rust",
  "local_address": "127.0.0.1",
  "local_port": 20802,
  "method": "chacha20-ietf-poly1305",
  "name": "test-ss-freeglobal",
  "notes": null,
  "password": "fd16a8048abdda9e2a9bae81c763dc30",
  "plugin": "v2ray-plugin",
  "plugin_opts": "tls;host=freeglobal.cn;path=/ws123;mode=websocket;loglevel=none",
  "port": 443,
  "schema_version": 1,
  "server": "freeglobal.cn",
  "tags": [],
  "type": "shadowsocks",
  "udp_timeout": 300,
  "updated_at": "2025-11-01T14:45:24.147611"
}
EOF

  ACTIVE_SS_NODE="test-ss-freeglobal"
  log "[integration] [v3.7.29] 已写入插件节点：${target_json}"
  return 0
}

test_shadowsocks_plugin(){
  log "[CASE] Plugin SS (freeglobal) + Procfs"
  if ! create_plugin_shadowsocks_node; then
    log "[CASE SKIPPED] Plugin SS（节点生成失败）"
    return 0
  fi
  local node="${ACTIVE_SS_NODE}"
  local start_rc=0
  if ! ssctl start "$node"; then
    start_rc=$?
  fi
  local generated_unit_file="${HOME}/.config/systemd/user/sslocal-test-ss-freeglobal-20802.service"
  if [ "$start_rc" -ne 0 ]; then
    die "ssctl start ${node} 失败"
  fi
  wait_for_stats "$node"
  local output
  output="$(ssctl stats "$node" --format json)"
  echo "$output" | jq -e --arg node "$node" '.name == $node' >/dev/null
  echo "$output" | jq -e '.valid == true' >/dev/null
  if ! ssctl probe "$node"; then
    die "ssctl probe ${node} (插件节点) 失败"
  fi
  ssctl stop "$node"
  ACTIVE_SS_NODE=""
  log "[CASE PASSED] Plugin SS + Procfs (节点: ${node})"
}

test_v2ray_sampler(){
  log "[CASE] V2Ray + V2Ray API"
  start_mock_v2ray_api "$TEST_PORT_V2RAY_API"
  create_v2ray_node
  ssctl start test-v2-node
  wait_for_stats test-v2-node
  local output
  output="$(ssctl stats test-v2-node --format json)"
  echo "$output" | jq -e '.name == "test-v2-node"' >/dev/null
  echo "$output" | jq -e '.valid == true' >/dev/null
  if echo "$output" | jq -e '.note | contains("Mock")' >/dev/null 2>&1; then
    log "Warning: sampler note still references Mock data."
  fi
  ssctl stop test-v2-node
  log "[CASE PASSED] V2Ray + V2Ray API"
}

main(){
  setup
  test_shadowsocks_procfs
  test_shadowsocks_plugin
  test_v2ray_sampler
  log "All integration cases passed."
}

main "$@"
