# ChatGPT(Codex) 在两种代理模式下不可用 + 模式无法直切 —— 排查结论与后续计划

状态：A 组（根因修复）已实现，并在本机以 `/Applications` 里的 1.2.3/9 构建实测通过；
B 组（UDP / 无 SNI 流 / 退出健壮性）未实现，方案见 §6。

排查日期：2026-11-20。环境：macOS 27.2.1、Xcode 27.1、SSH 服务器
`root@59.136.225.99:2222`（韩国，**无 IPv6**）、本机系统 DNS 为路由器 `192.168.1.1`。

## 1. 问题描述

用户可观察到的四个现象，全部发生在同一天、同一网络：

1. **ChatGPT 桌面端（实际签名为 `com.openai.codex`）在两种模式下都不可用**：界面一直停在
   「正在连接中」。Global Proxy 和 Per-App Routing 都一样；用户回忆「以前 Global 模式是可用的」。
2. **代理模式无法直接切换**：Global → Per-App、Per-App → Global 都失败，必须先切到
   Local Proxy Only 再切过去。
3. **无法把 ChatGPT.app 加进 App Routing 列表**：选完应用后列表里没有它（只有 Claude）。
4. 界面报 `App routing extension could not be enabled · App containing System Extension to be
   activated must be in /Applications`。

复现条件：本机 DNS 被污染（见 R1），隧道服务器没有 IPv6（见 R2），并且 App 从 `/Applications`
之外启动时必然触发 R6。

## 2. 调查结论（按根因编号）

### R1 本机 DNS 被污染，且这是所有失败的上游

| 名称 | 本机解析 | 服务器侧解析（真实） |
|---|---|---|
| `chatgpt.com` A | `210.209.84.142` | `172.64.155.209` / `104.18.32.47` |
| `chatgpt.com` AAAA | `2a03:2880:f10e:83:face:b00c:0:25de`（Facebook 段） | — |
| `api.openai.com` | `104.244.46.211` / `31.13.76.65` 等（Twitter / Facebook 段） | `118.193.202.219` 段可达 |
| `api.anthropic.com` | `160.79.104.10`（**未污染**） | `160.79.104.10` |

对照实验（隧道建在备用端口，避免干扰 App）：

- `curl --socks5-hostname 127.0.0.1:11080 https://chatgpt.com/` → **200**（远端 DNS）
- `curl --socks5 127.0.0.1:11080 https://chatgpt.com/` → **连接被 proxy 关闭**（本地 DNS，用污染 IP）
- 经由内置 Privoxy（`forward-socks5`，转发主机名）→ chatgpt.com **200**、api.openai.com 401

结论：**只要主机名被带到隧道另一端解析就能通；一旦按本机解析出的 IP 去连就必失败。**
`api.anthropic.com` 没被污染，这解释了「Claude 大体可用、ChatGPT 完全不可用」的差异。

### R2 服务器没有 IPv6

`ip -6 addr show scope global` 为空。凡是 IPv6 目标（真实 IPv6、或被污染的 AAAA），
`tunnel.log` 都会出现 `[ssh] channel N: open failed: connect failed: open failed`。
`ip6.istatmenus.app`（IPv6-only）是最干净的样本，与污染无关也照样失败。

### R3 Global 模式只设置了系统 SOCKS，Chromium/Electron 会本地解析

- macOS 系统 SOCKS 对 **CFNetwork** 应用是传递主机名的：`ssh -v` 日志里能看到
  `direct-tcpip: ... for chatgpt.com port 443`，`nscurl` 走系统代理拿到 200。Safari 属于这一类。
- **Chromium / Electron** 走系统 SOCKS 时按本地解析（等价于 `curl --socks5`），把污染后的 IP
  交给代理。Codex 桌面端是 Electron（日志里有 `electron-message-handler` / `rendererWebContentsId`），
  Chrome 与「ChatGPT for Chrome」扩展宿主同理。
- 因此旧版 Global 模式对浏览器类应用是坏的：只有 SOCKS，没有能携带主机名的 HTTP 代理。

### R4 SNI 嗅探遇到 ECH/GREASE 就提前放弃（扩展侧）

`RoutingSniffer.parse` 见到扩展类型 `0xfe0d` 立即返回 `.echOrGrease`，连同一条 ClientHello 里的
明文 SNI 一起丢掉，于是该流只能按应用自己解析出的（污染）IP 去连。

证据：用户截图里的统计行 `TLS names 0 · ECH/GREASE 7` —— 7 个样本全部命中提前放弃分支。

### R5 中继的两个硬失败会掐断进行中的连接

- `RoutingTCPRelay.start()` 先连 SOCKS、成功后才 `open` 应用的连接。中间隔着回环连接
  + 两次 SSH 往返，Electron 并发开连接时客户端已经放弃 → `Could not open the application connection`。
- `readClient()` 里 `data.count <= 64 KiB` 的硬校验：单次回调超过 64 KiB 是合法的，
  原实现直接 `finish`，报 `Application data exceeded the relay buffer`，把正在传输的 HTTP/2 连接打断。

这两条在统计上表现为「同一秒内一条 Proxy、一条 Blocked，每秒重复」，也就是用户看到的死循环。

### R6 系统扩展只能从 `/Applications` 里的 App 激活

从 DerivedData 启动的 Debug 构建必然失败：`App containing System Extension to be activated must
be in /Applications`。这是现象 2 与现象 4 的直接原因（在去掉代码里的硬拦截之后仍然切不过去）。

### R7 扩展更新依赖 `CFBundleVersion`

排查中一度出现「代码改了但行为没变」：`systemextensionsctl list` 显示已激活的始终是
`1.2.3/8`，而新构建的 App/扩展版本号也仍是 `1.2.3/8`，macOS 认为没有新版本，**不替换已装扩展**。
把 `CURRENT_PROJECT_VERSION` 提到 9 后新扩展（新 UUID）立即生效。

> 发版约束：**每次发版必须 bump `CFBundleVersion`**，否则老用户机器上的扩展不会更新，
> 只有 App 主体（界面）在变。

### R8 Add App 的可用性问题

- `NSOpenPanel.begin`（modeless）在 `LSUIElement` App 里可能落在主窗口后面、且不成为 key window，
  表现为点不动、滚不动。背景自动化下也无法可靠操作它。
- 选中应用后只生成编辑区草稿，必须再点 **Apply Rules** 才写入规则；列表计数仍是「1 app」，
  看起来就是「添加不上」。签名识别本身没问题（离线跑 `AppRoutingController.inspectApp`：
  `ChatGPT.app → 2DC432GLL2/com.openai.codex`，11 个 helper，0.68 s）。

## 3. A 组：已完成并验证的修复

| # | 改动 | 文件 | 对应根因 |
|---|---|---|---|
| A1 | 嗅探器不再因 `0xfe0d` 放弃：记下继续扫，有明文 SNI 就用；只有完整 ClientHello 无 SNI 才报 `.echOrGrease` | `TunnelProxyRoutingExtension/RoutingSniffer.swift` | R4 |
| A2 | Global 模式同时设置 SOCKS(1080) + HTTP/HTTPS(8118 Privoxy)；关闭时按归属逐个还原；新增 `ownedSystemHttpProxyPort`；启动补偿也检查 web proxy | `TunnelProxy/Controllers/TunnelController.swift` | R3 |
| A3 | 去掉 Global ↔ Per-App 的硬拦截，改为「先拆旧的、再起新的」，失败逐步回滚 | 同上（`chooseProxyMode`） | 现象 2 |
| A4 | 激活扩展前检查是否在 `/Applications`，并把系统那条英文错误映射成可操作的提示（含中文文案）；状态行允许换行 | `TunnelProxy/Controllers/AppRoutingController.swift`、`Views/AppRoutingView.swift`、两份 `AppRouting.strings` | R6 |
| A5 | Add App 改成 sheet；选中后**立即入库**（不再只留草稿） | `TunnelProxy/Views/AppRoutingView.swift` | R8 |
| A6 | 中继先 `open` 应用连接再拨号；删掉单次读 64 KiB 的硬失败 | `TunnelProxyRoutingExtension/RoutingTCPRelay.swift` | R5 |
| A7 | 嗅探器用例拆分（ECH+SNI → hostname，ECH 无 SNI → echOrGrease） | `tests/RoutingRelayChecks.swift` | R4 |
| A8 | 文档：README 新增 Proxy modes 一节；`plan/app-routing-dns-poisoning-fix.md` 记录本次修订 | `README.md`、`plan/…` | — |

验证结果：

- `bash tests/run-routing-checks.sh --relay`：解析器用例 + 7 个 loopback 中继场景全部 PASS。
- `xcodebuild -target TunnelProxyRoutingExtension`：BUILD SUCCEEDED。
  App target 在项目 shell 里需要 `OTHER_SWIFT_FLAGS=-disable-sandbox`（嵌套沙箱导致宏插件起不来），
  Xcode 里 ⌘R 不需要。
- 实机（`/Applications` 里的 1.2.3/**9**）：
  - 模式切换：Global ↔ Per-App 双向直切成功（含已连接状态）；`scutil --proxy` 在 Global 下
    SOCKS 1080 + HTTP/HTTPS 8118 三项全开，切到 Per-App 后三项全关。
  - 嗅探：`TLS names 44 · ECH/GREASE 0`（修前 `TLS names 0 · ECH/GREASE 7`）。
  - ChatGPT 规则：`ChatGPT`（`com.openai.codex`）进入列表，计数 2 apps。
  - 隧道侧实时记录：`chatgpt.com → Proxy`（多条）、`sdmntprsouthcentralus.oaiusercontent.com → Proxy`。
  - Codex 日志：`20:42:42 … episode_finished outcome=recovered`，此后 2 分钟无
    `rendezvous unavailable`（修复前重试到 `connectionAttempt=33`）。

## 4. B 组：未完成 / 遗留

按影响排序：

1. **UDP 一律不可用**：DNS(53) 与 QUIC(443) 被扩展直接关闭（`UDP cannot use the SSH tunnel`）。
   后果：QUIC 回退 TCP（慢但不致命）；应用自带的解析器（DoH、硬编码公共 DNS）失效后回退系统 DNS，
   而系统 DNS 返回污染答案 → 又变成第 2 项的流。**固定重连回路（Codex 的 pubsub / rendezvous）
   只要有一环恒失败就会按 18s→37s 指数退避一直重试，UI 永远停在「正在连接中」。**
2. **无 SNI 的纯 IP 流仍失败**：`199.16.156.38`、`2a03:2880:…:face:b00c`、`2607:6bc0::10` 等，
   拿到的是污染 IP 或 IPv6，服务器连不上 → `Blocked`。
3. **域名列表策略不做嗅探**：`Proxy Listed Domains` / `Direct Listed Domains` 下，IP-only 流仍按 IP
   判定（`app-routing-implementation.md` §2.2 的既定行为）。
4. **退出偶发失败**：Per-App 模式下 `prepareToQuit` 有时因 `appRouting.disable()` 返回 false 而放弃
   退出，表现为「点了退出没反应」，并留下孤儿 `ssh`/`privoxy`。
5. **残留 privoxy 会卡住 connect**：孤儿 privoxy 占着 8118 时，`reclaimPorts()` 期间的 `isBusy`
   使主界面所有按钮变灰且无提示（本次排查中实际踩到）。
6. **`/Library/SystemExtensions` 堆积 5 个待卸载副本**（`waiting to uninstall on reboot`），需重启清理。

## 5. 影响面（不修 B 组的后果）

| 流类型 | 现状 | 不修的后果 |
|---|---|---|
| TLS + 有 SNI | Proxy，正常 | — |
| UDP/53（应用自带 DNS） | Blocked | 解析回退系统 DNS → 污染答案 → 第 2 类 |
| UDP/443（QUIC） | Blocked | 回退 TCP，稍慢；固定重连回路可能反复失败 |
| TCP 到污染 IP / IPv6（无 SNI） | Blocked | 目标不可达，重试 |

结论：A 组让「TLS + SNI」这条主路径通了，Codex 可用；但**只要应用依赖自带 DNS，
它就会周期性地退回污染 IP**，表现为时好时坏。

## 6. 建议的下一步：让被路由的应用用隧道的 DNS

目标：被路由的应用拿到的 DNS 答案来自隧道另一端，从根本上消除「污染 IP + 无 SNI」这一类流。

范围：

- 仅对 **Proxy All** 的应用、**外部** UDP:53 做处理；`isLocal` 的 DNS（路由器）继续直连。
- 在扩展内解析查询，经 `ssh -D` 用 **TCP DNS** 转发（服务器侧解析），把响应按原查询的
  transaction id 回填成 UDP 响应给应用。
- 缓存（TTL 内）+ 并发合并 + 3–5 s 超时；**任何失败都回退**到「不干预，让系统 DNS 走 Direct」，
  绝不因为我们的 DNS 实现把解析彻底弄坏。
- 暂不做：DoH/DoT 的识别与改写、UDP 443（QUIC）代理、split-DNS 与 VPN 场景的特殊处理。

需要先确认的前置问题：

1. `NETransparentProxyNetworkSettings` 对端口 53 的规则限制（SDK 注释要求 DNS 走「目标域名规则」），
   以及实际能拿到哪些 UDP:53 流、能否归属到具体应用。
2. TCP DNS 的目标解析器选择：固定公共解析器（经隧道）还是服务器系统解析器。
3. 与现有「UDP 一律 Blocked」规则的替换边界（哪些策略下放行）。

验证：

- 现有 `tests/` 的 loopback fixture 增加：DNS 报文构造/解析、截断与重试、超时回退、缓存命中、
  并发同一域名的合并。
- 实机：把 `chatgpt.com` 在系统 DNS 上人为指向错误 IP，确认被路由应用仍能连通；
  断开隧道后确认回退路径可用。
- 回归：Claude 桌面端、Codex 桌面端、Chrome（Proxy All）、`directAll` 应用、本地/LAN 目标。

保守替代方案（工作量小、风险低）：只做「校验 + 覆盖」——对应用的 UDP:53 查询照常放行，
同时用隧道异步解析同一域名；仅当两者答案不一致且隧道答案可用时，才在**后续**查询上返回隧道答案。
实施难度低，但生效有延迟。

## 7. 复现与验证清单（命令）

```bash
# 1) why: 本机 DNS 是否被污染
dig +short chatgpt.com A; dig +short chatgpt.com AAAA
ssh -p 2222 -i ~/.ssh/home.pem root@59.136.225.99 'getent ahostsv4 chatgpt.com | head -2'

# 2) 远端 DNS vs 本地 DNS（订阅模式不同，结果不同）
curl -sS --max-time 20 --socks5-hostname 127.0.0.1:1080 -o /dev/null -w "%{http_code}\n" https://chatgpt.com/
curl -sS --max-time 20 --socks5          127.0.0.1:1080 -o /dev/null -w "%{http_code}\n" https://chatgpt.com/

# 3) Global 模式是否三项都设上
scutil --proxy

# 4) 已激活的扩展版本（改代码后必须变）
systemextensionsctl list | grep tunnelproxy

# 5) 中继/嗅探回归
bash tests/run-routing-checks.sh --relay
```

发版前检查（对应 R7）：

```bash
/usr/libexec/PlistBuddy -c "Print CFBundleVersion" /Applications/TunnelProxy.app/Contents/Info.plist
```

## 8. 本次排查中被替换的本机文件

- `/Applications/TunnelProxy.app` 现为 Debug 构建 **1.2.3 build 9**（Apple Development 签名）；
  原 1.2.4（Developer ID）备份在 `build/installed-backup-1.2.4-20261120-201421/TunnelProxy.app`，
  回滚方式：`cp -R build/installed-backup-1.2.4-20261120-201421/TunnelProxy.app /Applications/`。
- 应用规则已写入 `Claude` + `ChatGPT` 两条（均为 Proxy All，UserDefaults `appRoutingRules`）。
