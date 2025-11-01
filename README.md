# ssctl

`ssctl` 是一个面向桌面与服务器用户的 Shadowsocks 控制平面脚本，基于 user-level systemd 实现节点的增删改查、单实例启动、日志/监控、订阅管理等功能。项目以 Bash 实现，支持 shadowsocks-rust (`sslocal`) 与 shadowsocks-libev (`ss-local`) 双引擎，可快速搭建本地代理环境。

## 功能亮点

- **环境体检与自动安装**：`ssctl doctor` 检测核心依赖（jq、curl、systemctl 等）并可选自动通过系统包管理器安装缺失组件。
- **节点生命周期管理**：新增/导入节点、自动生成 systemd user 单元、单实例启动与切换、防冲突策略。
- **运维工具链**：实时监控链路（`ssctl monitor`）、延迟测试、日志查看与高亮、二维码导出、环境变量快速注入。
- **订阅同步**：解析 `ss://` 链接（含插件参数）并写入本地配置目录，支持批量更新。
- **命令行体验**：内建颜色输出、Bash/Zsh 补全脚本、友好的错误提示。

## 安装与升级

1. 克隆仓库（或下载脚本）：

   ```bash
   git clone https://github.com/TonyWoo33/ssctl.git
   cd ssctl-main
   ```

2. 将 `ssctl` 脚本加入 `PATH`，例如：

   ```bash
   install -m 755 ssctl ~/.local/bin/ssctl
   install -m 644 ssctl-completion.sh ~/.local/share/ssctl/ssctl-completion.sh
   ```

3. 初始化依赖：

   ```bash
   ssctl doctor --install
   ```

   如需先预览将执行的命令，可附加 `--dry-run`。

4. 在 `~/.bashrc` 或 `~/.zshrc` 中启用补全：

   ```bash
   source ~/.local/share/ssctl/ssctl-completion.sh
   ```

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

# 监控链路质量
ssctl monitor hk --interval 3 --tail
```

节点配置位于 `~/.config/shadowsocks-rust/nodes/<name>.json`，可直接编辑后使用 `ssctl show` 检查。

## 常用命令

| 命令 | 说明 |
| --- | --- |
| `ssctl doctor [--install] [--dry-run]` | 检测依赖、systemd 环境，可选自动安装缺失包 |
| `ssctl add <name> ...` | 新建或导入节点；支持 `--from-file`、`--from-clipboard`、手动参数 |
| `ssctl start [name]` | 单实例启动节点，自动更新 `current.json` 并执行连通性探测 |
| `ssctl stop [name]` | 停止节点并移除对应 systemd unit |
| `ssctl list` | 表格列出所有节点及运行状态 |
| `ssctl monitor [name] [...]` | 实时监控链路，支持 DNS/offline 模式和日志跟随 |
| `ssctl sub update [alias]` | 从订阅地址批量导入 `ss://` 链接（含插件参数解析） |
| `ssctl env proxy [name]` | 输出代理环境变量导出命令，配合 `eval` 使用 |

完整参数请查看 `ssctl help`。

## 订阅与节点格式

- 本地节点保存在 `~/.config/shadowsocks-rust/nodes/<name>.json`，权限设置为 `600`。
- 订阅信息保存在 `~/.config/shadowsocks-rust/subscriptions.json`，结构示例：

  ```json
  [
    {"alias": "my-sub", "url": "https://example.com/sub.txt"}
  ]
  ```

- 订阅更新时会解析 `ss://BASE64@host:port#tag?plugin=...`，自动填充 `plugin` 与 `plugin_opts` 字段。

## 补全脚本

- Bash：`source ssctl-completion.sh`
- Zsh：`autoload -U +X compinit && compinit` 后再 `source ssctl-completion.sh`

补全脚本会自动列出本地节点名称、订阅别名，并提供 `doctor`/`sub` 等子命令的选项提示。

## 故障排查

- `systemctl --user` 无法执行：确认系统支持 user-level systemd，执行 `loginctl enable-linger $USER` 并重新登录。
- 自动安装失败：使用 `ssctl doctor --install --dry-run` 查看命令，再根据输出手动安装。
- `ssctl show --qrcode` 报错：确保安装 `qrencode`，可通过 `ssctl doctor --install` 自动补齐。
- 订阅导入乱码：`ssctl` 在解析时会进行 URL 解码及插件参数提取，如仍异常请检查原始链接是否合规。

## 许可

本项目仍沿用原仓库的 License（如未指定，请根据上游协议补充）。
