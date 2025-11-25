# ssctl

`ssctl` 是一个面向桌面与服务器用户的 Shadowsocks 控制平面脚本，基于 user-level systemd 实现节点的增删改查、单实例启动、日志/监控、订阅管理等功能。项目以 Bash 实现，支持 shadowsocks-rust (`sslocal`) 与 shadowsocks-libev (`ss-local`) 双引擎，可快速搭建本地代理环境。

> 当前版本：**v3.2.0**

## 系统要求

- **操作系统**：优先支持 GNU/Linux，要求 Bash ≥ 4、GNU coreutils（`date --iso-8601`）、user-level systemd。其他平台仅做有限验证。
- **速率采样**：`monitor --speed` 与 `ssctl stats` 依赖 Linux 的 `ss`（iproute2）或 macOS 的 `nettop`，缺失时将退化为“只看连通性”模式。
- **探测与 ping**：`monitor --ping` 需要支持 `-W` 选项的 GNU ping（iputils/inetutils）；macOS 用户可通过 `brew install iputils` 或 `brew install inetutils` 获得兼容版本。
- **macOS 提示**：建议安装 `coreutils`（提供 `gdate`）和 `gnu-ping`，但由于缺少 `ss`，速率采样仍不可用，仅能使用基础的节点管理与探测功能。

## 功能亮点

- **环境体检与自动安装**：`ssctl doctor` 检测核心依赖（jq、curl、systemctl 等）并可选自动通过系统包管理器安装缺失组件。
- **节点生命周期管理**：新增/导入节点、自动生成 systemd user 单元、单实例启动与切换、防冲突策略。
- **运维工具链**：实时监控链路（`ssctl monitor` / `ssctl stats --watch`）、上下行速率统计、连通性体检（`probe`）、延迟测试（`latency`）、日志查看与高亮、二维码导出、环境变量快速注入。
- **批量采样性能**：`latency` / `monitor` / `stats` 通过一次性读取节点 JSON 与 systemd 状态，避免在循环中反复调用 `jq` / `systemctl`，几十个节点也能保持流畅。
- **鲁棒探测链路**：所有出网 `curl` 默认携带 `--connect-timeout 5 --max-time 10`，`probe` / `sub` 等命令在弱网环境下不会无限挂起。
- **订阅同步**：解析 `ss://` 链接（含插件参数）并写入本地配置目录，支持批量更新。
- **集中配置+插件**：支持 `~/.config/ssctl/config.json` 调整默认 URL/颜色/体检策略；可在 `functions.d/` 挂载自定义子命令。
- **命令行体验**：内建颜色输出、Bash/Zsh 补全脚本、友好的错误提示。
- **智能化故障转移 (v3.3.0)**：`ssctl switch --best` 会逐个节点发起一次 TCP connect（`/dev/tcp`）并选出 RTT 最低的候选再自动切换；`ssctl monitor` 默认进入多节点 TUI，可启用 `--auto-switch --fail-threshold=N` 在 TUI 中自动切换。

## 安装与升级

1. 克隆仓库（或下载脚本）：

   ```bash
   git clone https://github.com/TonyWoo33/ssctl.git
   cd ssctl-main
   ```

2. 安装可执行脚本与函数库：

   ```bash
   install -d ~/.local/bin ~/.local/share/ssctl
   install -m 755 ssctl ~/.local/bin/ssctl
   cp -r functions lib protocols ~/.local/share/ssctl/
   install -m 644 ssctl-completion.sh ~/.local/share/ssctl/ssctl-completion.sh
   ```

3. 创建默认配置（后续可手动调整）：

   ```bash
   mkdir -p ~/.config/ssctl
   cat <<'EOF' > ~/.config/ssctl/config.json
   {
     "color": "auto",
     "probe": {"url": "https://www.google.com/generate_204"},
     "latency": {"url": "https://www.google.com/generate_204"},
     "monitor": {
       "url": "https://www.google.com/generate_204",
       "interval": 5,
       "no_dns_url": "http://1.1.1.1"
     },
     "doctor": {
       "include_clipboard": true,
       "include_qrencode": true,
       "include_libev": true
     },
     "plugins": {
       "paths": []
     }
   }
   EOF
   ```

4. 初始化依赖：

   ```bash
   ssctl doctor --install
   ```

   如需先预览将执行的命令，可附加 `--dry-run`。
   该命令会一并检测 `ss`/`nettop`、GNU ping 等可选组件，缺失时会提示哪些功能（如 `monitor --speed`）将受限。

5. 在 `~/.bashrc` 或 `~/.zshrc` 中启用补全：

   ```bash
   echo 'source ~/.local/share/ssctl/ssctl-completion.sh' >> ~/.bashrc
   source ~/.bashrc
   ```

   若使用 zsh，可改为 `~/.zshrc`。

> **提示**  
> `ssctl` 会使用 `~/.config/shadowsocks-rust/nodes` 作为节点存储目录，并在 `~/.config/systemd/user` 写入 user-level unit 文件。确保系统启用了 user-level systemd (`loginctl enable-linger $USER`)。

## 快速开始

```bash
# 导入节点
ssctl add hk --server 1.2.3.4 --port 8388 --method chacha20-ietf-poly1305 --password secret

# 启动节点（自动停止其他单元、生成 unit、健康检查）
ssctl start hk

# 查看状态与日志
ssctl show --qrcode
ssctl logs -f hk

# 监控链路质量（表格输出走 stderr）
ssctl monitor hk --interval 3 --tail

# 速率统计可与 monitor 同周期滚动
ssctl stats --watch hk --interval 3 --json | jq

# 节点体检 && 延迟探测（JSON/NDJSON 仅写入 stdout）
ssctl probe hk --json | jq
ssctl latency --json | jq
```

节点配置位于 `~/.config/shadowsocks-rust/nodes/<name>.json`，可直接编辑后使用 `ssctl show` 检查。

## 智能化故障转移（v3.3.0）

- `ssctl switch --best` 会遍历所有节点，针对各自服务器发起一次 TCP connect（`/dev/tcp/server/port`），选出 RTT 最低的候选并立即切换且自启该节点，确保链路恢复无需人工干预。
- `ssctl monitor` 现有两种模式：
  - **多节点 TUI（默认）**：不带 `--name` 时进入全屏仪表盘，按 `q` 可退出。`--auto-switch --fail-threshold=N` 会在 TUI 行内标注 `[AUTO X/N]` 并在达到阈值时触发 `ssctl switch --best`。
  - **单节点兼容模式**：带 `--name` 时保留 v3.0 时代的单行 `\r` 刷新输出，适合脚本和单节点调试。
- `ssctl switch <name>` 仍维持“只更新 `current.json` 指向，不自动启动”的行为，便于在无人值守模式下与 `ssctl start` 或自动触发器配合使用。

### Monitor 模式（TUI vs 单节点）

- **TUI (默认)**：执行 `ssctl monitor`（不带 `--name`）时，会并发探测所有节点并使用 `tput` 渲染一个多行仪表盘。支持：
  1. `q` 键随时退出。
  2. `--auto-switch --fail-threshold=N`：在当前活跃节点行尾显示 `[AUTO X/N]`，并在连续 N 次失败后自动执行 `ssctl switch --best`。
  3. `--log`/`--speed`/`--ping` 等选项仍然生效，输出写入 stderr（便于与 JSON 输出并存）。
- **单节点模式**：当 `--name foo`（或传统写法 `ssctl monitor foo`）时，保留 v3.0 的单行 `\r` 刷新行为，便于脚本化或只关注单个节点的场景。

## 输出约定

- **结构化数据**：所有 `--json` / `--format json` / NDJSON（如 `monitor` streaming）均只写入 `stdout`，便于直接通过 `jq`、`tee` 或日志采集器接入。
- **文本/表格**：提示、表格、日志等人类可读内容统一写入 `stderr`，不会干扰上游管道。例如 `ssctl monitor ... >monitor.json` 将只得到 JSON 行。
- **管道示例**：
  ```bash
  ssctl monitor local --count 1 --json | jq '.latency_ms'
  ssctl stats --watch local --interval 2 --json | jq -r '.curl_bytes_per_s'
  ssctl probe local --json --url http://127.0.0.1:8080 | jq '.http.ok'
  ```

## 配置

- **默认路径**：`~/.config/ssctl/config.json`（可通过环境变量 `SSCTL_CONFIG` 或 `--config` 覆盖）。
- **示例配置**：

  ```json
  {
    "color": "auto",
    "monitor": {
      "url": "https://www.google.com/generate_204",
      "no_dns_url": "http://1.1.1.1",
      "interval": 5
    },
    "doctor": {
      "include_clipboard": true,
      "include_qrencode": true,
      "include_libev": true
    },
    "plugins": {
      "paths": ["~/.config/ssctl/functions.d"]
    }
  }
  ```

- 项目根目录提供了 `config.example.json`，可复制到 `~/.config/ssctl/config.json` 再按需调整（例如更换探测 URL 或关闭可选检测）。

- 支持字段：
  - `color`: `auto`/`on`/`off` 控制颜色输出。
  - `monitor`: 控制默认探测 URL、无 DNS 模式 URL、间隔。
  - `probe` / `latency`: 设置默认的探测 URL。
  - `doctor.*`: 决定是否检测剪贴板、二维码、libev 客户端。
  - `plugins.paths`: 追加插件脚本目录（见下节）。

## 插件扩展

- **加载顺序**：
  1. 安装目录下的 `${SSCTL_LIB_DIR}/functions.d/*.sh`
  2. 用户目录 `~/.config/ssctl/functions.d/*.sh`
  3. `SSCTL_PLUGIN_DIRS`（使用 `:` 分隔多个路径）
  4. 配置文件中 `plugins.paths`
- 每个插件脚本 `source` 后可定义形如 `cmd_xyz()` 的子命令，或扩展工具函数。
- 适用于定制探测逻辑（如替换 `curl`）、集成第三方 API、批量运维脚本等。

### 环境变量

| 变量 | 作用 |
| --- | --- |
| `SSCTL_CONFIG` / `SSCTL_CONFIG_ENV` | 覆盖主配置 JSON 以及 `config.env` 路径 |
| `SSCTL_LIB_DIR` / `SSCTL_PLUGIN_DIRS` | 调整函数库与附加插件目录（`:` 分隔） |
| `SSCTL_COLOR` / `NO_COLOR` / `SSCTL_UTF8` | 强制颜色开关以及是否使用 UTF-8 线条 |
| `SSCTL_MONITOR_LOG_ENABLED` / `SSCTL_MONITOR_STATS_ENABLED` | 设为 `false` 可禁用 `monitor --log` 或 `monitor --speed` |
| `SSCTL_STATS_CACHE_DIR` | 指定 `ssctl stats` 的缓存目录 |
| `SSCTL_PROBE_IP_URL` / `SSCTL_PROBE_COUNTRY_URL` | 自定义 `probe` 命令查询出口 IP 与国家的接口 |

## 常用命令

| 命令 | 说明 |
| --- | --- |
| `ssctl doctor [--install] [--without-clipboard] [...]` | 检测依赖、systemd 环境，可选自动安装或跳过部分可选依赖 |
| `ssctl add <name> ...` | 新建或导入节点；支持 `--from-file`、`--from-clipboard`、手动参数 |
| `ssctl start [name]` | 单实例启动节点，自动更新 `current.json` 并执行连通性探测 |
| `ssctl switch <name> \| --best` | `<name>` 仅切换 `current.json` 指向；`--best` 逐个节点执行 TCP connect（`/dev/tcp/server/port`）采样，选出 RTT 最低的候选并自动启动 |
| `ssctl stop [name]` | 停止节点并移除对应 systemd unit |
| `ssctl list` | 表格列出所有节点及运行状态 |
| `ssctl monitor [name] [--interval S] [--tail] [--log] [--speed] [--json] [--auto-switch] [--fail-threshold=N]` | 实时监控链路质量：不带 `--name` 时进入多节点 TUI（并发探测、`tput` 渲染、支持 `q` 退出、TUI 中显示 `--auto-switch` 计数并触发 `switch --best`）；带 `--name` 时保留单节点单行 `\r` 刷新模式；`--speed` 依赖 `ss`/`nettop`，`--ping` 需 GNU ping |
| `ssctl dashboard [name]` | 全屏 ASCII TUI 仪表盘：显示系统级 RX/TX、Session Peak 自适应 Activity Bar、连接计数/延迟、Hybrid Logs（30s Heartbeat + 历史事件）；按 `q` 退出 |
| `ssctl log [name] [--follow] [--filter key=value] [--format json]` | 解析 CONNECT/UDP 目标，支持 target/ip/port/method/protocol/regex 过滤与 JSON 输出 |
| `ssctl stats [name\|all] [--aggregate] [--format json] [--watch]` | 采集节点实时 TX/RX/TOTAL(B/s) 与累计量，依赖 `ss`/`nettop`；`--watch` 等价于 `monitor --speed` |
| `ssctl probe\|journal [name] [--url URL] [--json]` | 快速体检：校验端口监听、SOCKS5 HTTP 连通性、链路探测（仅链路/带 DNS），支持 JSON 输出 |
| `ssctl latency [--url URL] [--json]` | 对全部节点发起一次 TCP 握手测量，返回排序列表或 JSON 结果 |
| `ssctl metrics [--format prom]` | 导出节点指标，支持 JSON / Prometheus |
| `ssctl sub update [alias]` | 从订阅地址批量导入 `ss://` 链接（含插件参数解析） |
| `ssctl journal [name]` | 查看 systemd 日志 (同 logs 命令) |
| `ssctl clear` | 清理所有 ssctl 生成的内容（保留 nodes/） |
| `ssctl noproxy` | 停止所有代理单元并切换为直连模式 |
| `ssctl env proxy [name]` | 输出代理环境变量导出命令，配合 `eval` 使用 |
| `ssctl keep-alive [--interval S] [--max-strikes N] [--url URL]` | 守护式连通性检测：通过 SOCKS5 访问指定 URL，连续失败自动执行 `switch --best`（含自适应等待/心跳日志） |

完整参数请查看 `ssctl help`。

### 📊 Visual Dashboard (`ssctl dashboard`)

- **全屏 ASCII 布局**：标题、Traffic/Status/Logs 三大区域，使用 `tput` 绝对定位，`q` 键随时退出。
- **系统级流量**：读取默认出口网卡 `/sys/class/net/*/statistics/*`，Session Peak 自适应 Activity Bar，低速也能看到跳动；同时显示 RX/TX 速率（人类可读格式）。
- **连接健康**：展示当前 ESTABLISHED 数量、对 8.8.8.8 的 TCP latency，和节点进程 uptime。
- **Hybrid Logs**：实时读取最近 30s 日志，若静默成功则显示心跳时间并附带最后一次历史事件，避免“空白”误判；启用 `"verbose": true` 可看到更多成功/失败细节。

### 🤖 Automation Suite

- `ssctl keep-alive [interval] [max_strikes]`：守护式连通性检测（默认 60s/3 次），连续失败自动执行 `switch --best`，实时输出失败/恢复日志。
- `ssctl sub update [alias|all] [--force]`：批量刷新订阅，自动解码 Base64/SIP002 并生成节点配置；失败不影响其他订阅。
- `ssctl switch --best`：基于实时 TCP connect 延迟自动择优节点，配合 `keep-alive` 或 `monitor --auto-switch` 实现智能路由。

### 🧩 Plugin Architecture (v3.6.0)

- `start.sh` 与 `monitor.sh` 通过 `engine_${name}_*` 接口动态加载引擎（shadowsocks/libev/v2ray…），主逻辑不再硬编码协议。
- 新协议（如 Hysteria、Tuic）只需在 `lib/engines/*.sh` 中实现 `get_service_def` / `get_sampler_config` 即可即插即用。

## 订阅与节点格式

- 本地节点保存在 `~/.config/shadowsocks-rust/nodes/<name>.json`，权限设置为 `600`。
- 订阅信息保存在 `~/.config/shadowsocks-rust/subscriptions.json`，结构示例：

  ```json
  [
    {"alias": "my-sub", "url": "https://example.com/sub.txt"}
  ]
  ```

- 订阅更新时会解析 `ss://BASE64@host:port#tag?plugin=...`，自动填充 `plugin` 与 `plugin_opts` 字段。
- `ssctl probe` 在 HTTP 测试通过后会额外访问 `ifconfig.me` 与 `ipinfo.io/country` 来展示出口 IP/国家，可通过设置 `SSCTL_PROBE_IP_URL`、`SSCTL_PROBE_COUNTRY_URL` 或修改配置文件来替换/关闭这些外部请求。

## 补全脚本

- Bash：`source ssctl-completion.sh`
- Zsh：`autoload -U +X compinit && compinit` 后再 `source ssctl-completion.sh`

补全脚本会自动列出本地节点名称、订阅别名，并提供 `doctor`/`sub` 等子命令的选项提示。

## 故障排查

- `systemctl --user` 无法执行：确认系统支持 user-level systemd，执行 `loginctl enable-linger $USER` 并重新登录。
- 自动安装失败：使用 `ssctl doctor --install --dry-run` 查看命令，再根据输出手动安装。
- `ssctl show --qrcode` 报错：确保安装 `qrencode`，可通过 `ssctl doctor --install` 自动补齐。
- 订阅导入乱码：`ssctl` 在解析时会进行 URL 解码及插件参数提取，如仍异常请检查原始链接是否合规。

## 测试

开发者可以在仓库根目录执行 `bash tests/test-utils.sh`，用来快速验证 `ssctl_parse_ss_uri`、`ssctl_build_node_json` 等关键工具函数不会回归。CI 将在每次推送时运行相同脚本并执行 `shellcheck`。

## 许可

本项目根据 MIT 许可证 (The MIT License) 授权。详情请见 `LICENSE` 文件。
