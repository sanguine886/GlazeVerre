# GlazeVerre AI Agent 设计

> 与代码同步演进。安全边界最严格的模块（规范 §4.5 / §4.6）；参照 MaidKit
> `ssh_agent_service.dart` / `agent_run_policy.dart` 的「提案-审批-执行」边界。

## 1. 边界原则

**模型只能提案，永远不能直接执行。** 执行只发生在用户审批通过之后，且始终走
SSH exec 通道；任意时刻提供悬浮「立即中止」kill switch。

## 2. 工具集（对模型暴露的 function）

- `run_command(command, timeout_s)` / `read_file(path)` / `write_file(path, content)` / `list_dir(path)`
- `get_system_info()`（预置缓存）
- `create_snippet(name, script)` / `run_snippet(name, target)`

## 3. 审批策略（P5）

| 策略 | 行为 |
|---|---|
| `alwaysAsk`（默认） | 每次工具调用出审批卡：命令全文、工作目录、影响摘要；批准 / 编辑后批准 / 拒绝 |
| `autoReview` | 模型 `safe_to_run` 声明自动放行只读项，**本地危险命令分类器二次否决**；其余走审批卡 |
| 只读模式 | 白名单只读命令集合（`ls/cat/df/free/ps/…`，按完整命令名精确匹配） |

## 4. 危险命令分类器（P5）

只读许可仅接受本地解析确认的单条命令及明确的只读命令集合；不支持的 shell 语法、重定向、命令替换、管道和可执行程序/写入的工具选项一律不自动放行。模型的 `safe_to_run` 不能替代此检查。多条危险规则同时命中时采用最高风险等级。文件内容使用 POSIX 单引号作为数据传给 `printf '%s'`，保留原始尾换行且不能结束引用并执行命令。

本地规则、不依赖模型。`rm -rf`（含 `/` 或变量）、`mkfs`、`dd`、`shutdown/reboot`、
`chmod -R 777 /`、fork 炸弹、`DROP TABLE/DATABASE`、`> /dev/sd*`、`history -c` 等命中
必须人工确认；高风险要求手动输入命令前 4 字符。词表 ≥ 40 条，fake provider 单测覆盖。

## 5. 上下文与审计（P4/P5）

- 系统提示词注入主机摘要（别名/OS/工作目录/最近 50 行终端环形缓冲）；发送前 UI 预览；
- 审计日志 AES-GCM 本地加密：时间、命令、结果摘要、审批人、策略；可导出/清空。

## 当前状态（P0）

仅交付审批卡视觉组件（`GlassKit/ApprovalCard`，含危险形态红调玻璃）。
策略、分类器、Agent 循环、kill switch、审计随 P4/P5 落地；**安全逻辑不留到「以后补」**。
