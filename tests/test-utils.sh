#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEFAULT_LOCAL_ADDR="127.0.0.1"
export DEFAULT_LOCAL_PORT="1080"

# shellcheck disable=SC1090
. "${ROOT_DIR}/lib/utils.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ssctl-tests.XXXX")"
cleanup(){ rm -rf "$tmp_dir"; }
trap cleanup EXIT

ss_uri="ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTp0ZXN0cGFzczEyMzQ1NkAxMjcuMC4wLjE6ODM4OC?plugin=v2ray;path=%2Fws&plugin-opts=mux=8#demo-node"

plugin=""
plugin_opts=""
fragment=""
ssctl_parse_ss_uri "$ss_uri" method password server port plugin plugin_opts fragment

[[ "$method" == "chacha20-ietf-poly1305" ]]
[[ "$password" == "testpass123456" ]]
[[ "$server" == "127.0.0.1" ]]
[[ "$port" == "8388" ]]
[[ "$fragment" == "demo-node" ]]
[[ "$plugin" == "v2ray" ]]
[[ "$plugin_opts" == "path=/ws"*"mux=8" ]]

output_json="${tmp_dir}/node.json"
ssctl_build_node_json "demo" "$server" "$port" "$method" "$password" "$DEFAULT_LOCAL_ADDR" "$DEFAULT_LOCAL_PORT" "auto" "$plugin" "$plugin_opts" >"$output_json"

name_field="$(jq -r '.name' "$output_json")"
engine_field="$(jq -r '.engine' "$output_json")"
plugin_field="$(jq -r '.plugin' "$output_json")"

[[ "$name_field" == "demo" ]]
[[ "$engine_field" == "auto" ]]
[[ "$plugin_field" == "v2ray" ]]

echo "All util tests passed."
