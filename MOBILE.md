# iPhone control / iPhone 手机控制

[简体中文 README](README.md) · [English README](README.en.md) · [Desktop / 桌面](DESKTOP.md)

## 简体中文

通过 ZeroTier 连接 Windows，在 iPhone 网页上选择已有 Clash / Mihomo 的代理节点。界面与桌面使用同一套深蓝与青绿色设计；电脑端同步显示最近 20 条命令、来源、目标节点和执行结果。

### 安装到已配置的 Windows 网关

需要 Go、已安装的网关、Windows .NET Framework 4.x，以及 Clash 已开启的本机命名管道控制接口。默认管道为 `\\.\pipe\verge-mihomo`；本项目不会修改 Clash 配置。若使用其他管道，通过安装器的 `-Pipe` 参数指定。当前不支持通过远程 HTTP 控制器连接 Clash。

```powershell
& .\scripts\Build-Mobile.ps1
& .\scripts\Build-Desktop.ps1

# 管理员 PowerShell。更新前退出旧桌面界面，停止已有手机控制任务。
& .\scripts\Install-Mobile.ps1 -GatewayRoot C:\ZeroTierGateway
& .\scripts\Install-Desktop.ps1 -GatewayRoot C:\ZeroTierGateway

# 返回普通用户会话运行。
& C:\ZeroTierGateway\bin\zerobridge-desktop.exe
```

安装器从实际 `gateway.json` 读取 Windows / 客户端 ZeroTier 地址和接口编号，默认监听端口 `8787`。只新增专用防火墙规则 `ZeroBridgeMihomoMobile`，范围限定到该程序、ZeroTier 接口、本机地址、端口和配置的客户端地址。不会修改原网关任务、NAT 或上游代理选择。第一次安装生成随机访问密钥；重新安装保留已有密钥。

手机服务任务 `ZeroBridgeMihomoMobile` 与界面任务 `ZeroBridgeMihomoTray` 均在指定用户登录时以普通权限启动。若提升权限使用另一个管理员账户，给两个安装器传入 `-UserId '计算机名\实际用户'`。手机控制需要该用户保持登录、电脑和 Clash 在线；不能把它等同于 SYSTEM 网关的开机自启。关闭桌面界面不会停止手机服务。

### 仅更新已有手机控制与桌面

从包含 v0.3.1 源码的独立目录构建，然后在管理员 PowerShell 执行；任务所属用户须已登录，Clash 及 ZeroTier 应保持在线：

```powershell
& .\scripts\Build-Mobile.ps1
& .\scripts\Build-Desktop.ps1
& .\scripts\Update-Control.ps1 -GatewayRoot C:\ZeroTierGateway
```

更新器先对新程序进行只读 Clash 检查，再备份并核验两个已安装控制程序的 SHA-256，仅停止对应手机与托盘任务以及路径已核验的控制程序。它保留配置、配对二维码、防火墙和任务设置，不停止原网关、不操作 NAT。重启后需读到新的 v0.3.1 在线心跳；失败时尝试恢复旧程序，备份目录仅管理员与 SYSTEM 可访问。自定义任务动作或链接目录会被拒绝。恢复失败时保留备份，按错误说明检查控制任务。

完成后刷新 iPhone Safari 页面，或彻底关闭并重开主屏幕 App，使页面加载新版。已有配对密钥继续可用；只更新控制界面无需关闭手机 Default Route。

### iPhone 配对与使用

1. 手机连接同一 ZeroTier 网络。仅控制节点不需要开启 Enable Default Route；如需手机流量使用此网关，继续遵循原网关配置。
2. 电脑 ZeroBridge 点击「手机控制」。用 iPhone 扫描二维码，通过 Safari 打开，然后点击「连接电脑」。也可手动打开 `http://<Windows-ZeroTier-IP>:8787/` 并输入电脑显示的密钥。
3. Safari「分享 → 添加到主屏幕」。如有「作为网页 App 打开」选项，保持开启。主屏幕 App 如再次要求配对，重新扫码或输入密钥。
4. 在「代理」检查推荐的手动代理组，搜索并选择节点，确认切换。在「记录」查看结果与出站说明；电脑端主面板及手机控制窗口约每 2 秒同步显示。
5. 节点列表显示已有延迟、超时、未测速或测速失败；点击「测本组延迟」更新测量，也可按延迟排序。测速期间仍可查看状态，完成后列表更新。

全局模式默认选择 `GLOBAL`；规则模式根据规则目标与当前嵌套选择推荐手动组，并标明哪些组位于当前模式选中的出站路径中。`GLOBAL` 在规则模式下通常不影响流量，除非规则明确引用它。直连模式下修改代理组不会使流量改为代理。推荐组是根据配置推断的入口，不代表所有请求都使用它；`DIRECT` 规则仍可能直连。自动测速、故障转移和负载均衡组的节点选择只读，嵌套组只在被实际出站路径引用时产生效果。

切换影响电脑上共享的 Clash 配置和新建连接，已有连接可能保留原节点。页面不会主动中断全部连接，不改变 Clash 模式、不添加订阅、不重启 Clash。成功表示已回读确认该组的选中节点，并与刷新后的状态一致；出站说明用于区分选择成功与当前模式是否使用该组，不等于已经验证具体请求的出口或节点互联网可达性。电脑端也显示该说明。

测速使用 Mihomo 已有历史值，或对当前组的每个已有成员发起受限的单节点 HTTP 延迟探测。测试地址固定为 `https://www.gstatic.com/generate_204`，每个节点超时为 3 秒，每批最多 256 个成员、16 个并发探测。服务探测阶段使用 70 秒预算，等待正在执行的选择命令等可能延长响应；手机请求超时为 90 秒。它不会执行自动组的整组测速接口，也不会清除自动组的固定选择。延迟是当时访问这一地址的 HTTP 测量值；它不是下载速度、手机到 Windows 的延迟，也不保证其他网站或应用的体验。无法访问测试地址时可能显示超时或失败。

### 访问与记录

- 浏览器只访问 ZeroBridge 的有限接口：读取经过筛选的代理组/模式与延迟、选择手动组已有成员，以及测量组内已有成员。测速地址、超时、数量和并发均由服务限定，不接受任意目标网址。Clash 的完整管理接口不暴露给手机。
- 服务仅监听明确的私有 IPv4 地址；应用还校验来源 IP、Host、Origin 与访问密钥，不信任 `X-Forwarded-For`。本机 ZeroTier 地址也加入白名单，供本机验证。
- 页面为 HTTP，由 ZeroTier 提供隧道加密，没有单独的 HTTPS 层。仅用于受信任的私有网络，不应映射到公网。主屏幕入口是在线网页，不提供离线控制或 Service Worker。
- 二维码含访问密钥；密钥通过 URL fragment 带入，页面读取后移除 fragment。勾选「在这台设备记住连接」会把密钥保存在浏览器 localStorage，否则保存在 sessionStorage。「忘记此设备」只清除当前浏览器凭据，不撤销其他设备。
- 撤销已分享密钥：停止 `ZeroBridgeMihomoMobile` 任务，删除本机 `mobile.json`，重新运行安装器生成新密钥，然后重新配对。先退出并重开桌面配对窗口以加载新二维码。不要删除 `gateway.json`。
- 本机 `mobile.json` 保存密钥和监听配置；`state/mobile/` 保存二维码、状态、日志和最多 20 条近期命令。它们全部被 Git 忽略。重启会恢复近期记录；历史记录有限，不是长期审计数据库。
- 提交命令先保存待处理记录，执行后读取 Clash 当前选择确认。超时、断连或重启导致结果不明时显示「待确认」，请刷新当前选择后再决定是否重试。

卸载手机控制时，停止并删除 `ZeroBridgeMihomoMobile` 任务，删除同名防火墙规则即可停用网络入口；原网关和桌面任务独立保留。

本项目仅提供本地转发与已有代理的控制功能，不提供 VPN、节点、订阅、账号或网络出口服务。见 [DISCLAIMER.md](DISCLAIMER.md)。

## English

Connect iPhone to Windows through ZeroTier and select nodes already configured in Clash / Mihomo. The mobile page shares the desktop's navy and teal design. The desktop shows the last twenty commands, their source, target and result.

### Install on a configured Windows gateway

Requires Go, an existing gateway installation, Windows .NET Framework 4.x and an enabled local Clash named-pipe controller. The default is `\\.\pipe\verge-mihomo`; use the installer's `-Pipe` argument for another local pipe. The project does not modify Clash configuration and does not currently connect to remote HTTP controllers.

```powershell
& .\scripts\Build-Mobile.ps1
& .\scripts\Build-Desktop.ps1

# Administrator PowerShell. Exit the old desktop and stop an existing mobile task before updating.
& .\scripts\Install-Mobile.ps1 -GatewayRoot C:\ZeroTierGateway
& .\scripts\Install-Desktop.ps1 -GatewayRoot C:\ZeroTierGateway

# Run from the ordinary user session.
& C:\ZeroTierGateway\bin\zerobridge-desktop.exe
```

The installer reads the actual addresses and interface index from `gateway.json`, defaults to port `8787`, and adds a dedicated `ZeroBridgeMihomoMobile` firewall rule scoped to the executable, ZeroTier interface, local address, port and configured client. It does not modify the original gateway task, NAT or selected proxy. First installation generates a random token; reinstalling retains it.

`ZeroBridgeMihomoMobile` and `ZeroBridgeMihomoTray` run at user logon with limited privileges. If elevation uses another administrator account, pass `-UserId 'COMPUTER\actual-user'` to both installers. Mobile control requires that user to remain logged on, with the computer and Clash available. It is separate from the SYSTEM gateway boot task. Exiting the desktop does not stop the mobile service.

### Update existing mobile control and desktop only

Build from a separate checkout containing the v0.3.1 source, then run in administrator PowerShell. The tasks' user must be logged on, with Clash and ZeroTier online:

```powershell
& .\scripts\Build-Mobile.ps1
& .\scripts\Build-Desktop.ps1
& .\scripts\Update-Control.ps1 -GatewayRoot C:\ZeroTierGateway
```

The updater runs a read-only Clash check before stopping anything, backs up both installed control binaries, and verifies copied files by SHA-256. It stops only the corresponding mobile/tray tasks and control processes whose executable paths were verified. It preserves configuration, pairing QR, firewall and task settings, leaves the gateway running, and performs no NAT operation. Restart must produce a fresh v0.3.1 online heartbeat; failures trigger an attempt to restore the old binaries. Backups are accessible only to administrators and SYSTEM. Custom task actions and linked directories are rejected. Keep the backups and inspect the control tasks if rollback is incomplete.

After updating, refresh the Safari page or fully close and reopen the Home Screen app to load the new page. Existing pairing credentials remain valid; a control-only update does not require disabling the phone's Default Route.

### Pair and use iPhone

1. Connect to the same ZeroTier network. Proxy control alone does not require Enable Default Route; routing phone traffic through the gateway still requires the original gateway setup.
2. Click Mobile control on the desktop. Scan the QR, open in Safari and tap Connect. Alternatively open `http://<Windows-ZeroTier-IP>:8787/` and enter the displayed key.
3. In Safari choose Share → Add to Home Screen, retaining Open as Web App if offered. If the Home Screen app asks to pair again, scan or enter the key again.
4. Check the recommended manual selector group, search/select a node and confirm. View the result and routing note in History; the desktop summary and command window refresh about every two seconds.
5. The node list shows existing delay, timeout, untested or failed measurements. Tap Test group latency to update the results, or sort by latency. State remains available while measurements run; the list updates on completion.

Global mode defaults to `GLOBAL`. Rule mode recommends a manual group from rule targets and current nested selections, and identifies groups on the current mode's selected outbound paths. `GLOBAL` usually does not affect rule-mode traffic unless a rule explicitly references it. In direct mode, changing a proxy group does not turn direct traffic into proxied traffic. The recommendation is inferred from configuration; not every request uses that group, and `DIRECT` rules can still bypass it. Node selection in automatic latency, fallback and load-balancing groups remains read-only. Nested groups matter only when the selected outbound path references them.

Selections affect the computer's shared Clash configuration and new connections. Existing connections may retain their previous node. The page does not disconnect all connections, change modes, add subscriptions or restart Clash. Success means the group's selection was read back and agreed with the refreshed state. The routing note distinguishes a confirmed selection from whether the current mode uses that group; it does not verify a particular request's exit or the node's Internet connectivity. The desktop displays that note too.

Latency display uses existing Mihomo history or bounded HTTP probes of individual existing members of the current group. The fixed test address is `https://www.gstatic.com/generate_204`, with a 3-second node timeout, at most 256 members and 16 concurrent probes per batch. The service probe phase has a 70-second budget; waiting for a selection already in progress can extend the response. The mobile request timeout is 90 seconds. It does not call the automatic group's whole-group delay endpoint or clear its fixed selection. Delay describes access to this address at that moment; it is not download speed or phone-to-Windows latency and does not guarantee other sites or applications perform similarly. An unreachable test address may produce a timeout or failure.

### Access and records

- The browser uses a limited API for filtered group/mode/delay state, selecting existing manual-group members and testing existing group members. The service fixes the test URL, timeout, count and concurrency; arbitrary destination URLs are not accepted. The complete Clash administration API is not exposed.
- The service binds an explicit private IPv4 address and checks client IP, Host, Origin and access token. It ignores forwarded-IP headers. The local ZeroTier address is also allowed for local verification.
- HTTP is carried inside ZeroTier's encrypted tunnel, without a separate HTTPS layer. Use only on a trusted private network; do not publish the port to the Internet. The Home Screen entry is online-only, without offline control or a Service Worker.
- The pairing QR contains a credential in the URL fragment, which the page removes after reading. Remember this device stores the key in localStorage; otherwise sessionStorage is used. Forget device clears only that browser's credential and does not revoke other devices.
- To revoke shared credentials, stop the `ZeroBridgeMihomoMobile` task, delete local `mobile.json`, rerun the installer and pair again. Reopen the desktop pairing window to reload the QR. Do not delete `gateway.json`.
- Local `mobile.json` contains credentials/listen settings; `state/mobile/` holds the QR, status, logs and up to twenty recent commands. All are ignored by Git. Recent records survive restart but are not a permanent audit database.
- Commands persist a pending record before execution and read back the current selection afterward. Timeouts, disconnections or restarts may leave an unconfirmed result; refresh the current selection before retrying.

To disable mobile control, stop/delete the `ZeroBridgeMihomoMobile` task and remove the firewall rule of the same name. The gateway and desktop tasks remain independent.

This project provides local forwarding and control of an existing proxy only. It supplies no VPN service, nodes, subscriptions, accounts or Internet egress service. See [DISCLAIMER.md](DISCLAIMER.md).
