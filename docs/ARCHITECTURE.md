# GlazeVerre 架构

> 本文与代码同步演进；结构性变更先改本文，再改代码（规范 §6.6.1）。
> 每次依据「规范 > MaidKit > 通用最佳实践」顺序做出的裁量，以 ADR 记入文末附录。

## 1. 概述

GlazeVerre 是 iOS 26 原生 SwiftUI 应用：SSH 终端 + 服务器管理 + AI 运维助手。
架构三原则：**非侵入**（100% SSH，无服务端组件）、**手机优先**、**安全默认**
（秘密只进 Keychain；AI 只能提案，执行必须经人审批）。

## 2. 模块结构与依赖方向

```
App/                      # 入口、根 Tab、路由（SwiftUI）
Packages/
  GlassKit/               # Liquid Glass 设计系统：令牌、玻璃组件、动效
  CoreSSH/                # SSH/SFTP 引擎（纯逻辑，无 UI 依赖）
  TerminalKit/            # SwiftTerm 封装、扩展键盘、主题、会话视图
  AIAgent/                # AI 提供商适配、工具注册、Agent 循环、审批
  Persistence/            # SwiftData 模型与 Keychain 封装
```

依赖方向（单向，禁止反向）：

- `App → 各包`
- `TerminalKit / AIAgent → CoreSSH`
- `GlassKit` 不依赖任何业务包
- `CoreSSH`、`AIAgent` 禁止 import SwiftUI/UIKit；公开接口一律 protocol

## 3. 并发与状态模型

- Swift 6 语言模式（严格并发），零数据竞争警告合入；
- SSH 会话与 Agent 循环由 `actor` 封装（P1/P5 落地）；
- 跨模块异步接口使用 async/await 与 `AsyncStream`，禁止回调地狱与全局可变单例；
- UI 状态用 `@Observable` MVVM，业务逻辑不进 View。

## 4. 测试与验证（Validation）

借鉴 MaidKit ARCHITECTURE 的 Validation 纪律：**每阶段退出前必须全绿**。

```sh
swiftlint --quiet && swiftformat --lint .
swift test --package-path Packages/CoreSSH --enable-code-coverage   # 引擎单测（macOS）
xcodebuild test -project GlazeVerre.xcodeproj -scheme GlazeVerre \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -enableCodeCoverage YES
```

CI（`.github/workflows/ci.yml`）在 `macos-26`（Xcode 26，iOS 26 SDK）上执行上述全部命令，
并断言 CoreSSH 与 Persistence 行覆盖率 ≥ 60%（ADR-0005）。
单测底线清单见规范 §6.5.2。

## 5. 生成物纪律

- `GlazeVerre.xcodeproj` 由 XcodeGen 生成，**不入库、不手改**；
- `App/Info.plist` 由 XcodeGen 从 `project.yml` 的 `info:` 块生成，不入库；
- SwiftData 宏展开同理（落地后）。

## 6. 依赖精确版本（ADR-0002）

| 依赖 | 锁定版本 | 用途 |
|---|---|---|
| Citadel | 0.12.1 | SSH/SFTP 客户端 |
| swift-nio-ssh（Wellz26 fork，Citadel 上游要求） | 0.3.4 | NIOSSH 协议栈 |
| swift-nio | 2.81.0 | 事件循环 |
| swift-crypto | 3.12.3 | 密钥类型（Crypto 模块） |

## 7. ADR 附录

| # | 决策（一行） |
|---|---|
| ADR-0001 | 工程文件用 XcodeGen 从 `project.yml` 生成，产物 gitignore，本地与 CI 均先 `xcodegen generate` |
| ADR-0002 | 依赖精确版本（exactVersion）锁定自首次引入生效：P1 锁定上表四个依赖，即「依赖锁定」交付物的落地方式 |
| ADR-0003 | 单测分两处：CoreSSH 引擎测试放包内 `CoreSSHTests`（`swift test`，需 NIO/NIOSSH 类型构造真实校验握手），其余在宿主 App 的 `GlazeVerreTests` / `GlazeVerreUITests`（仅依赖公开 API） |
| ADR-0004 | `maidkit_ref/` 为本地只读精读副本，不入公共仓库（第三方代码再分发的许可风险），在 .gitignore 固定 |
| ADR-0005 | 覆盖率 ≥60% 硬门槛自 P1 起在 CI 启用（CoreSSH 与 Persistence 分别断言）；P0 只采集不设门 |
| ADR-0006 | 颜色令牌直接映射系统语义色（label / secondaryLabel / systemBackground 等），深浅色对比度由系统保证，不自绘调色板 |
| ADR-0007 | 文案走 String Catalog（`App/Resources/Localizable.xcstrings`），首发 zh-Hans + en；代码标识符一律英文 |
| ADR-0008 | 主机密钥指纹：swift-nio-ssh 不公开 key 序列化，指纹经 Mirror 读取 `NIOSSHPublicKey` 内部 backing 提取原始密钥再按 RFC 4253 wire 格式哈希；以真实 `ssh-keygen` 指纹作 Guard 测试钉死内部布局，上游变更时 CI 立即失败并按新布局修复 |
| ADR-0009 | SSH keepalive 以周期性 `true` exec 通道实现（Citadel 0.12 无协议级 keepalive 配置），默认 15s 可配 |
| ADR-0010 | 客户端私钥导入 P1 支持 OpenSSH-ED25519 与 RSA（含口令解密）；ECDSA-P256 客户端密钥解析随 P3 补齐——主机侧 ECDSA-P256/384/521 指纹校验 P1 已支持 |
| ADR-0011 | SSH 连接生命周期以代际标识隔离异步握手、重连与断线回调；断开取消重连，过期连接必须关闭。Shell 打开信号原子保存首个成功或失败结果，避免等待顺序改变错误传播。 |
| ADR-0012 | 只读白名单改为「完整命令名 + 选项级准入」的本地解析：重定向、命令替换、管道、分号一律不放行，精确命令名匹配避免 `lsanything` 之类前缀误判；分类器改为多条规则命中取最高风险等级，避免宽泛 dangerous 规则掩盖 critical；`write_file` 以 `printf '%s' '<内容>'` 传数据，heredoc 分隔符可被内容伪造故弃用 |
