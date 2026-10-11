# Changelog

[简体中文 README](README.md) · [English README](README.en.md)

## v0.3.2 — 2026-10-11

- 将 TCP / UDP 空闲期限分开：旧配置自动采用 TCP 1800 秒、UDP 沿用原设置（示例 120 秒）；保留 TCP keepalive、半关闭响应及连接上限，避免静默 TCP 两分钟后被主动关闭。
- 每 5 秒重新识别活动 ZeroTier 回包接口，接口丢失期间保留捕获与 guard，恢复后使用当前编号；独立 guard 身份核验不再依赖可能变化的回包接口编号。
- 增加受限 SOCKS/TCP DNS 探测与有进程身份和新鲜度验证的健康心跳。连续 3 次失败降级、2 次成功恢复，不因单次异常重启所有连接或切换节点。
- UDP 收发复用缓冲区，减少每包分配；桌面显示 IPv4 上传/下载 Mbps，日志增加字节、连接失败、上限拒绝与空闲回收计数。
- 手机页面在返回前台、恢复网络或重新显示时取消旧状态读取并刷新，不重发切换或测速命令。
- 新增带备份、哈希核验、版本及健康检查和失败回退的开机网关更新器。
- 保留 PowerShell 7 解析 JSON 时间后的 UTC 类型及偏移，避免健康检查和启动时间误判。

- Separate TCP/UDP idle limits: existing configurations use 1800 seconds for TCP and retain their UDP setting (120 seconds in the example). Preserve keepalive, half-close replies and bounded connections.
- Re-resolve the ZeroTier return interface every 5 seconds; retain capture and guard during outages and use the current index on recovery. Guard identity remains bound to process/start/source/configuration rather than a dynamic return index.
- Add bounded SOCKS/TCP DNS probes and owned, fresh health heartbeats. Three failures mark degraded health and two successes recover, without restarting all flows or changing nodes for a transient failure.
- Reuse UDP buffers; show IPv4 upload/download Mbps and add byte, connection-failure, capacity-rejection and idle-expiration counters.
- Refresh phone state after resume/network restoration without replaying selection or delay commands.
- Add a backed-up, hash-checked gateway updater with versioned health validation and rollback.
- Preserve UTC kinds and offsets after PowerShell 7 JSON parsing to prevent incorrect heartbeat age and startup-time comparisons.

真实本地 TCP 连接空闲 125 秒后仍可继续收发。已部署到验证环境，配置、配对及自启设置保留；用户确认 iPhone 蜂窝连接首次和闲置约三分钟后访问均正常。蜂窝切网和长期外出稳定性仍需实际使用验证。A real local TCP connection remained usable after 125 seconds idle. Deployed with configuration, pairing and autostart settings preserved; the user confirmed cellular access on a physical iPhone both initially and after about three minutes idle. Cellular roaming and long-term outdoor reliability still require real-world observation.

## v0.3.1 — 2026-10-11

- 手机节点列表显示已有延迟，并增加当前组测速与延迟排序；单节点探测使用固定地址、3 秒超时和受限并发，不清除自动组的固定选择。
- 按 Clash 当前模式与实际规则推荐手动代理组；标明不影响当前模式的组，避免规则模式下仅切换 `GLOBAL` 后误以为出口已变化。
- 切换结果核对回读与最终刷新状态；手机和电脑同步显示提交时模式、选择确认与出站说明。已有连接可能保持原节点，选择确认不等于请求出口已验证。
- Display existing node delays and add bounded current-group tests and latency sorting. Individual probes use a fixed address and 3-second timeout without clearing automatic-group fixed choices.
- Recommend a manual group using Clash's current mode and rules; identify groups outside its selected paths so a rule-mode `GLOBAL` change is not mistaken for an effective exit change.
- Reconcile selection readback with final refreshed state. Phone and desktop share command mode, selection confirmation and routing notes. Existing connections may retain their prior node; selection confirmation does not verify a request's exit.

- 增加控制程序更新脚本：备份、哈希核验、新版本心跳检查与失败回退，保留配对和配置；显式按 UTF-8 读取中文状态文件，兼容 Windows PowerShell 5.1。
- Add a control updater with backups, hash checks, versioned heartbeat verification and rollback, preserving pairing and configuration. Read UTF-8 status explicitly so Chinese group names work in Windows PowerShell 5.1.

用户已确认本版本 iPhone 能显示节点延迟，切换选择同步到 Clash。User confirmed delay display and synchronized selections from a physical iPhone.

- 修复 Windows 重启后 ZeroTier 网卡编号变化导致网关预检失败：启动时按配置的 ZeroTier 地址与客户端子网重新识别活动网卡；不存在或匹配多个时拒绝启动。
- 手机控制安装器也按 ZeroTier 地址识别网卡，避免重新安装时依赖过期编号。
- Resolve the active ZeroTier interface by its configured Windows/client addresses at gateway startup, so Windows interface-index changes across reboots no longer prevent startup. Missing or ambiguous matches fail safely.
- The mobile installer likewise finds the current ZeroTier adapter by address rather than a stale interface index.

## v0.3.0 — 2026-09-20

v0.2.0 的本地桌面预览与手机控制一起发布；没有单独发布 v0.2.0 标签。
The local v0.2.0 desktop preview ships in this release; no separate v0.2.0 tag was published.

- 增加与桌面同款设计的 iPhone 网页控制台：扫码配对、代理组/节点搜索与切换、主屏幕入口、操作记录。
- 通过本机命名管道控制已有 Clash；新增 HTTP 服务仅绑定配置的私有 IPv4，使用客户端地址白名单、访问密钥、Host/Origin 校验及范围受限的防火墙规则。
- 电脑端实时显示命令和结果；成功必须回读确认 Clash 当前选择。失败或结果不明时不会误报成功，不提供完整 Clash 管理接口。
- Added an iPhone web controller matching the desktop design: QR pairing, group/node search and selection, Home Screen entry and command history.
- Controls existing Clash through a local named pipe. The optional HTTP service binds a configured private IPv4 address and uses client allowlisting, access tokens, Host/Origin checks and a scoped firewall rule.
- Desktop command synchronization verifies successful changes by reading Clash's current selection. Unconfirmed operations stay visibly unconfirmed; the full Clash administration API is not exposed.

用户已确认 iPhone 实机可控制节点切换。User confirmed successful control from a physical iPhone.

- 增加独立中英文 Windows 界面、系统托盘、包速率与活动连接图表、日志入口、启停确认，以及用户登录自启安装器。
- 界面以普通权限运行，不新增网络监听；启停沿用管理员管理脚本。关闭/退出界面不停止网关。
- Added a bilingual Windows dashboard, notification-area icon, packet/connection charts, logs, confirmed Start/Stop controls and a user-logon installer.
- The UI runs without elevation or a network listener; explicit management actions use the existing elevated scripts. Closing or exiting the UI leaves the gateway running.

- 项目更名为 **ZeroBridge Mihomo**，仓库与 Go 模块路径同步调整。
- 完善中英文 README、双语开机自启文档，以及“不提供 VPN 或代理服务”的功能范围声明。
- Renamed the project to **ZeroBridge Mihomo**, including repository and Go module paths.
- Added complete Chinese/English READMEs, bilingual autostart guides and an explicit statement that the project provides no VPN or proxy service.

## v0.1.0 — 2026-09-20

首个实验性预发布版本，尚不承诺接口兼容性或长期稳定性。

- WinDivert NETWORK_FORWARD 捕获指定客户端的 IPv4 转发流量。
- 进程内 TCP/IP 栈转换 TCP/UDP 为本机 Mihomo SOCKS5 连接，无 TUN 网卡。
- DNS 转发改写、TCP 重传、IPv4 分片、连接数和空闲超时限制。
- 独立 guard、启动预检、NAT 备份及恢复脚本。
- 可选 SYSTEM 开机任务、High 优先级与代理进程恢复。
- 示例配置、运行库下载与校验、协议测试和运维说明。

已验证本地协议测试、Windows 网关、手机蜂窝 IPv4 出口与视频，以及计划任务的进程恢复。IPv6 代理、持久防泄漏、真实重启验收与长期稳定性不在本版本保证范围内。

发布源码，不附带真实配置、日志、恢复备份、编译产物或第三方驱动二进制。

### English

First experimental prerelease; API compatibility and long-term reliability are not guaranteed.

- Capture one configured client's IPv4 forwarding traffic with WinDivert NETWORK_FORWARD.
- Convert TCP/UDP through an in-process TCP/IP stack to existing local Mihomo SOCKS5, without a TUN adapter.
- DNS rewriting, TCP retransmission, IPv4 fragmentation, flow limits and idle timeouts.
- Independent guard, startup checks, and NAT backup/restoration scripts.
- Optional SYSTEM startup task, High priority and proxy-process recovery.
- Example configuration, verified runtime download, protocol tests and operational documentation.

Local protocol tests, Windows forwarding, cellular IPv4 exit/video and scheduled-task process recovery were verified. IPv6 proxying, persistent leak prevention, actual reboot acceptance and long-term stability are not guaranteed. The source release excludes real configurations, logs, recovery backups, build outputs and third-party driver binaries. This project provides local forwarding only; it does not operate or supply VPN or proxy services.
