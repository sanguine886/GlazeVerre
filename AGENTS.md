# AGENTS.md

本文件为在此仓库工作的 AI 代理提供指引。

## 项目概览

GlazeVerre 是一款 iOS 26 原生 SwiftUI 应用:SSH 终端 + 服务器管理 + AI 运维助手,围绕 Apple
的 Liquid Glass 设计语言构建。产品三条原则:**非侵入**(100% SSH,不在服务器安装任何组件)、
**手机优先**、**安全默认**(秘密只进 Keychain;AI 只能提案,未经人工审批绝不执行)。

最低部署目标为 **iOS 26.0**(Liquid Glass 是产品身份,不做降级样式层)。Swift 6 严格并发已开
启,必须保持零警告合入。

唯一需求与规范来源是 [`GlazeVerre-开发提示词.md`](GlazeVerre-开发提示词.md)(仓库根目录,中文)。
出现冲突时以该文件为准。它定义了 P0–P6 阶段计划、设计规范与工程纪律。大型改动前先读它。

文档随代码同步演进:[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)(含 ADR 附录)、
[`docs/SECURITY.md`](docs/SECURITY.md)、[`docs/AI_AGENT.md`](docs/AI_AGENT.md)、
[`docs/TERMINAL.md`](docs/TERMINAL.md)、[`docs/CHANGELOG-phase.md`](docs/CHANGELOG-phase.md)
(每阶段的交付物/验收/遗留风险)。**结构性变更必须先改文档再改代码。** 每次依据「规范 > MaidKit
> 通用最佳实践」顺序做出的裁量,以一行 ADR 追加到 `docs/ARCHITECTURE.md`。

## 常用命令

工具链(CI 强制):`xcodegen`、`swiftlint`、`swiftformat`,用 Homebrew 安装。

```sh
# 生成 Xcode 工程(不入库、不手改)
xcodegen generate

# Lint(两者都必须全绿;CI 按此顺序执行)
swiftformat --lint .
swiftlint --quiet

# 就地格式化(对应 .github/workflows/format.yml 的做法)
swiftformat .

# 包内单测(这些包声明了 macOS platform 正是为了此命令)
swift test --package-path Packages/CoreSSH --enable-code-coverage
swift test --package-path Packages/AIAgent --enable-code-coverage
swift test --package-path Packages/Persistence --enable-code-coverage
swift test --package-path Packages/TerminalKit

# App 单测 + UI 测试(模拟器;CI 在 iPhone 16 Pro 缺失时自动创建)
# -skipPackagePluginValidation 是 CI 实际使用的参数,本地不加会触发包插件校验
xcodebuild test \
  -project GlazeVerre.xcodeproj \
  -scheme GlazeVerre \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -enableCodeCoverage YES \
  -skipPackagePluginValidation

# 未签名真机构建(CI 的 ipa job 用法;模拟器测试不需要)
xcodebuild build -project GlazeVerre.xcodeproj -scheme GlazeVerre \
  -configuration Release -destination 'generic/platform=iOS' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

CI(`.github/workflows/ci.yml`,`macos-26` / Xcode 26)依次执行 lint → xcodegen → 各包
`swift test` → 覆盖率门禁 → iPhone 16 Pro 模拟器 `xcodebuild test` → 未签名真机 IPA 构建。
手动 `workflow_dispatch` 的 `coverage_only` 输入只跑 AIAgent 的 `swift test` + 覆盖率门禁,用于
快速迭代。不要提交 `GlazeVerre.xcodeproj` 或 `App/Info.plist`——两者均为生成物且已被 gitignore
(XcodeGen 工程见 ADR-0001;Info.plist 由 `project.yml` 的 `info:` 块生成,见 ARCHITECTURE.md §5)。

## 架构

```
App/                      入口、根 Tab、功能页、App 服务(SwiftUI)
Packages/
  GlassKit/               Liquid Glass 设计系统:令牌 + 玻璃组件
  CoreSSH/                SSH/SFTP 引擎(纯逻辑,无 UI)
  TerminalKit/            SwiftTerm 封装、扩展键盘、主题、会话视图
  AIAgent/                AI 提供商适配、工具注册、Agent 循环、审批
  Persistence/            SwiftData 模型 + Keychain 封装
```

依赖方向单向,禁止反向:

- `App → 各包`
- `TerminalKit / AIAgent → CoreSSH`
- `GlassKit` 不依赖任何业务包
- `CoreSSH`、`AIAgent` 禁止 `import SwiftUI`/`UIKit`;公开接口一律 protocol,
  UI 依赖抽象,测试可注入替身。

状态模型:SSH 会话与 Agent 循环由 `actor` 封装;跨模块异步一律 `async/await` + `AsyncStream`
(禁止回调地狱,禁止全局可变单例);UI 状态用 `@Observable` MVVM,业务逻辑位于
`App/Services/*`,不写进 View。

### App 目录

- `App/GlazeVerreApp.swift` —— `@main`;通过私有的 `AppModelContainer` 构建**唯一**一个 SwiftData
  `ModelContainer`,覆盖五个模型(`HostRecord`、`SnippetRecord`、`AIProviderRecord`、
  `ChatSessionRecord`、`AuditRecord`),构造各 manager,并用 `.environment(...)` +
  `.modelContainer(...)` 注入。
- `App/Services/` —— 编排/manager(`HostManager`、`SnippetManager`、`AIProviderManager`、
  `ChatManager`、`AuditManager`、`AgentRunner`、metrics)。业务逻辑在此。
- `App/Features/<Area>/` —— 按 Tab 区域分组的 SwiftUI 视图(Servers、Terminal、SFTP、
  Assistant、Settings、Snippets)。
- `App/Root/RootTabView.swift` —— 四个根 Tab:Servers / Terminal / Assistant / Settings。
- `App/Resources/Localizable.xcstrings` —— String Catalog。

### 关键包类型

- `AIAgent`:`AIChatStreaming` 协议 + 三套适配器(`OpenAICompatibleAdapter`、
  `AnthropicAdapter`、`GeminiAdapter`),经 `AIProviderAdapterFactory` 创建;`AgentLoop`(一个
  `@MainActor` class)驱动「提案 → 审批 → 执行 → tool result 续接」;`AgentToolRegistry`
  持有七个内置工具及其 JSON Schema;`ApprovalDecider` 实现三种策略;
  `DangerousCommandClassifier` 是纯函数式规则引擎(多规则命中取最高风险等级);
  `ReadOnlyCommandPolicy` 负责只读白名单的命令名精确匹配与 shell 语法解析;`AgentCancellationToken`
  即 kill switch;`AuditLogging`/`InMemoryAuditLog` 记录每次工具调用。
- `CoreSSH`:`SSHSession` actor(连接 / exec / PTY shell / keepalive / 指数退避重连 /
  状态流),`CitadelTransport`,TOFU `KnownHostsStore` + `TOFUHostKeyValidator`,
  `HostKeyFingerprint`,`SFTP`。
- `Persistence`:SwiftData store(`HostStore`、`SnippetStore`、`AIProviderStore`、
  `ChatSessionStore`、`AuditStore`),各自暴露 `makeContainer` 供内存测试;记录只持不透明的
  Keychain 引用,绝不存秘密本体。
- `TerminalKit`:`TerminalSession`、`KeyboardLayout`、`TerminalTheme`、`TerminalFontSpec`、
  `SessionTabsModel`、`TmuxDetector`。
- `GlassKit`:`GlassSpacing` 间距令牌,`GlassPalette`/`GlassTypography` 两个文件里的
  `Color`/`Font` 扩展(如 `Color.glassBackground`、`Font.glassMono`),以及 `GlassCard` /
  `GlassButton` / `GlassBar` / `ApprovalCard` 组件。仅 iOS,且**没有测试 target**。

## 约定与陷阱

**容易踩的 lint 规则**(`.swiftlint.yml`):行长 120 警告 / 160 报错;文件 > 300 行警告 /
> 500 报错,类型 > 300 警告 / > 400 报错;`force_cast` 与 `force_try` 为**报错**;多行列表
**必须**带尾逗号;标识符最小长度 2(所以设计令牌 `xs`/`sm`/… 合法)。`.swiftformat` 固定
4 空格缩进与 Swift 6.0。

**命名与风格**:代码标识符、注释、类型名一律**英文**;只有面向用户的文案做本地化。命名遵循
朴素 Swift 风格(`@Observable` manager、protocol 优先的公开接口)。错误建模为显式 enum 并遵循
`LocalizedError`(如 `SSHError`、`AgentError`、`AIProviderError`)。

**本地化**:面向用户的字符串走 String Catalog(`App/Resources/Localizable.xcstrings`),键用
点号命名空间(`tab.servers`、`approval.approve`、`agent.thinking`),同时提供 `en` 与
`zh-Hans`。不要在 View 里硬编码展示字符串;用 `Text("key")` / `String(localized: "key")`。

**秘密**:密码、私钥、passphrase、AI API Key **只进** `KeychainStore`,属性
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`。绝不允许进 SwiftData、`UserDefaults` 或日志。
SwiftData 记录只持不透明的 `secretRef`/`apiKeyRef` 字符串;`HostRecordTests` 断言秘密值不会
出现在任何记录属性中。

**日志**:统一用 `os.Logger`。App 层 subsystem 用 `com.glazeverre.GlazeVerre`;注意 AIAgent
的三个适配器仍是改名前的 `com.glazeterm.AIAgent`(历史遗留,新增日志请用前者)。任何含密钥、主机地址或
命令内容的字段必须标 `privacy: .private`。主机名/IP 绝不发给 AI 模型,只发别名(规范 §6.4.2)。

**可观测性陷阱**:`HostManager.hosts` 是存储型 `@Observable` 属性,从 store 刷新,而非计算属性
`try? store.all()`。计算属性不注册依赖,其他 Tab 的视图会漏掉别处新增的主机直到重启 App。为
manager 状态请遵循此模式。

**SwiftData + `@Query` 陷阱**:使用 `@Query` 的视图不能依赖合成的 `init()`;需显式声明
`init()` 并赋值 `_hosts = Query(...)` / `_manager = Environment(...)`
(参见 `App/Features/Servers/ServersView.swift`)。

**AI 安全模型**(不得削弱):模型只能**提案**;任何策略下执行都必须经人工审批。
`DangerousCommandClassifier` 是本地、纯函数式规则引擎,多条规则命中时取**最高风险等级**
(避免宽泛 dangerous 规则掩盖 critical);模型的 `safe_to_run` 不能绕过它。**编辑后**的命令在运行前会被
重新分类,因此变危险的编辑会退回人工复核。kill switch 取消在途 provider 请求并拆除池化的 SSH
会话。此处任何改动都需要测试证明「无任何策略组合可绕过危险命令人工确认」。

只读白名单(`ReadOnlyCommandPolicy`)按**完整命令名精确匹配**并解析 shell 语法:重定向、命令替换、
管道、分号一律不放行;`env`/`command`/`awk` 等「参数即程序」的命令不在白名单内。

**工具路由**:App 自有工具(`create_snippet`、`run_snippet`)不会带 SSH executor 广播给模型;
`AgentRunner` 只注册有真实 executor 的工具,因此模型绝不会提出最终落到 `unknownToolCall` 的
调用。`shellCommand(for:...)` 是唯一把抽象工具渲染成实际 shell 文本的地方,分类器与 executor
看到的完全一致;路径使用 POSIX 单引号封装。

**生成物**:`GlazeVerre.xcodeproj`、`App/Info.plist` 与 SwiftData 宏展开一律为生成物——不要手改。

**依赖**:第三方依赖在各包 `Package.swift` 中以 `exact:` 精确锁定(ADR-0002:Citadel 0.12.1、
Wellz26 swift-nio-ssh 0.3.4、swift-nio 2.81.0、swift-crypto 3.12.3、SwiftTerm 1.20.0)。
升级 SwiftTerm 须跑全量终端回归。新增依赖须满足 MIT/Apache/BSD 许可证兼容、上游活跃、无分析
SDK,并在 PR 中说明理由。

**`maidkit_ref/`** 是 MaidKit 项目的本地只读精读副本,故意 gitignore(第三方代码,许可安全:
不再分发)。不要 import 或提交它。

**提交/PR**:Conventional Commits;一个阶段或一个功能一个 PR,摘要含改动概要、自测记录、规范
核对项。每阶段结束在 `docs/CHANGELOG-phase.md` 追加一条记录。

## 测试

- 包内逻辑用各包的 `swift test`;App 层用 iPhone 16 Pro 模拟器上的 `xcodebuild test`。
- **覆盖率门禁**:CoreSSH、AIAgent、Persistence 各自必须 ≥ 60% 行覆盖率(ADR-0005 仅点名
  CoreSSH 与 Persistence,AIAgent 由 CI 同样设门)。AIAgent 与 Persistence 用
  `swift test --enable-code-coverage` + `llvm-cov`;CoreSSH 同理。
- 单测底线(规范 §6.5.2):CoreSSH 连接/known-hosts/重连;AIAgent 审批策略/危险命令分类器/
  工具回路;Persistence 秘密隔离断言。
- 用替身而非真实网络:`FakeChatProvider`、`FakeHostSession`、`CapturingToolExecutor`
  (AIAgent),以及 `FakeHTTPStreamingTransport` / `NeverFailingTransport`(适配器测试),
  它们位于测试 target 内。Persistence 测试用内存 SwiftData 容器
  (`makeContainer(inMemory: true)`)。
- UI 测试依赖稳定的 accessibility identifier。根屏标志元素形如 `screen.<area>.<element>`
  (`screen.servers.add`、`screen.terminal.heading`、`screen.assistant.heading`、
  `screen.settings.heading`),其余元素 ID 无统一前缀(如 `host.field.name`、`settings.fontSize`、
  `sftp.row.<name>`、`host.card.<uuid>`);重构视图时保留它们。`RootTabsSmokeTests` 断言四个根 Tab 均能切换屏幕。
