# Pi / Reasonix / opencode 代码架构与 Code Search 探索

> 本文基于 `/opt/pi-mono`、`/opt/reasonix` 与 `/opt/opencode` 的实际源码，以及 `/opt/my_db` 的 code search 索引。
> 所有结论标注为 `[static]`（静态索引/源码）；未做运行时 build/断点验证。

---

## 0. 索引与缓存

| 项目 | 源码 | 缓存 | Chunks | Call graph keys |
|---|---|---|---|---|
| Pi | `/opt/pi-mono` | `/opt/code_caches/pi-mono_cache` | 17,099 | 6,518 |
| Reasonix | `/opt/reasonix` | `/opt/code_caches/reasonix_cache` | 109,141 | 16,968 |
| opencode | `/opt/opencode` | `/opt/code_caches/opencode_cache` | 12,418 | 3,370 |

KV 命名空间：

- `/code/pi-mono`
- `/code/reasonix`（symbols 234,338 / callers 18,193 / callees 28,048）
- `/code/opencode`（TypeScript monorepo；`cache_import` 前 `context/symbol` 不可用）

索引命令：

```bash
cd /opt/my_db
./analyze_nodejs_repo.sh /opt/pi-mono  /code/pi-mono  --jobs 4
./analyze_nodejs_repo.sh /opt/reasonix /code/reasonix --jobs 4
./analyze_nodejs_repo.sh /opt/opencode /code/opencode --jobs 4
```

> Reasonix 源码是 **Go**；`npx reasonix` 只是分发包装。`analyze_nodejs_repo.sh` 的 TypeScript 插件只影响 TS 文件，Go 文件走 ctags + 默认解析。

---

## 1. Pi 的源码架构（TypeScript monorepo）

### 1.1 仓库结构

```
pi-mono/
├── packages/
│   ├── agent/            # 模型无关的 agent 循环（核心）
│   ├── ai/               # provider/model catalog/auth/streaming
│   ├── coding-agent/     # 产品层：CLI、工具、会话、模式、扩展
│   ├── tui/              # 终端 UI 框架
│   ├── schema/ mcp/ telemetry/ durable/ env/ evals/ chord/ codemode/
│   └── ...
└── apps/p2/              # 另一个前端应用
```

### 1.2 核心链路 `[static]`

```
packages/coding-agent/src/cli/args.ts: parseArgs
  → modes/interactive/interactive-mode.ts (InteractiveModeOptions)
    → packages/agent/src/agent.ts: Agent
      → agent-loop.ts: runAgentLoop (111)
        → runLoop (172)
          → streamAssistantResponse (390)   # 调 provider
          → executeToolCalls (518)
            → executeToolCallsSequential (540) / executeToolCallsParallel (596)
              → runToolCall (821)
```

关键符号与文件：

| 能力 | 源码 |
|---|---|
| CLI 参数 | `packages/coding-agent/src/cli/args.ts: parseArgs` |
| 交互模式 | `packages/coding-agent/src/modes/interactive/interactive-mode.ts` |
| Agent 类 | `packages/agent/src/agent.ts: class Agent` |
| Agent 循环 | `packages/agent/src/agent-loop.ts: runAgentLoop / runLoop` |
| 流式响应 | `agent-loop.ts: streamAssistantResponse` |
| 工具执行 | `agent-loop.ts: executeToolCalls / runToolCall` |
| 工具定义 | `packages/coding-agent/src/core/tools/*`（bash/read/write/edit/grep/find/ls/powershell） |
| Provider | `packages/ai/src/models.ts`、`packages/ai/src/providers/*`、`streamSimple` |
| 会话树 | `packages/coding-agent/src/core/session-manager.ts`（`createBranchedSession:1643`、`_persist:1173`、`appendCompaction:1272`） |
| Fork | `packages/coding-agent/src/core/agent-session-runtime.ts: fork:262` |
| TUI | `packages/tui/src/tui.ts`（`Component:117`、`handleTerminalInput:1087`）、`tui-alt-screen.ts: doRender` |
| 扩展/MCP | `packages/coding-agent/src/core/extensions/loader.ts`（`loadExtension`、`registerMcpServer`） |

### 1.3 设计特点

- **agent 核心与 provider 解耦**：`Agent` 通过 `StreamFn` 调模型，DeepSeek 只是 provider 之一。
- **工具是带钩子的对象**：`AgentTool` 支持 `beforeToolCall/afterToolCall`，执行模式 `sequential | parallel`。
- **会话是树**：`fork` → `createBranchedSession`，支持分支/回溯。
- **TUI 独立包**：`packages/tui` 可单独复用，包含 layout、editor、keybindings、alt-screen。
- **扩展机制**：MCP、codemode、tool-search 在 `core/extensions` + `extensions/*`。

---

## 2. Reasonix 的源码架构（Go）

### 2.1 分层

```
cmd/reasonix/main.go          # 入口；blank import 注册 provider + builtin tools
internal/
├── frontend/                 # cli / tui / acp / serve / remotehost / termrender
├── contract/                 # 稳定接口：provider / tool / event / config / preset
├── assembly/boot/            # 配置驱动装配
├── runtime/agent/            # Agent = Provider + Tool Registry + Session
├── session/control/          # turnOrchestrator / approvals / ask / admission
├── tools/builtin/            # bash / jobs / fetchchain / websearch / script
├── state/                    # sessionstore / checkpoint / memory / instruction
├── safety/                   # permission / sandbox / evidence
├── ext/                      # hooks / extension dispatch / MCP
├── model/                    # anthropic / gemini / openai / responses / billing
└── base/                     # fs/net/proc/shellparse/workspace 等
```

### 2.2 启动与装配 `[static]`

```
cmd/reasonix/main.go
  → cli.RunWithBuildInfo            internal/frontend/cli/cli.go:49
    → assembly/boot                 # config → provider / tools / preset / browser
    → session/control.Controller
```

`cmd/reasonix/main.go` 通过 blank import 注册内置实现：

```go
_ "reasonix/internal/model/anthropic"
_ "reasonix/internal/model/gemini"
_ "reasonix/internal/model/openai"
_ "reasonix/internal/model/responses"
_ "reasonix/internal/tools/builtin"
```

### 2.3 Turn / Agent 链路 `[static]`

```
Controller.Send / RunTurn
  → session/control/turn_entry.go: runTurnLoop:50
    → turn_orchestrator.go: runTurnLoop:466
      → runTurnLoopWithPreparedTurn:473
        → runtime/agent/sampling_request.go: streamProviderRequest:30
          → contract/provider/provider.go: Provider.Stream:542
        → tools/builtin.*（tool.RegisterBuiltin:338）
        → safety/permission.Gate.approve:610
        → state/sessionstore（checkpoint / transcript）
```

`ctx.py` 取到的真实调用关系：

```
control.turnOrchestrator::runTurnLoopWithPreparedTurn
  callers(1): control.turnOrchestrator::runTurnLoop
  callees(16): armAwaitResume / noticeUserGate / stopGoal / continueGoal /
               runOrchestratedTurn / withVisionRouting / ...
```

### 2.4 关键子系统

| 子系统 | 源码 | 说明 |
|---|---|---|
| Provider 契约 | `internal/contract/provider/provider.go` + 同目录 `retry/context_overflow/argument_normalization/schema_*/output_budget/projection` | 重试、上下文溢出、参数修复、schema 校验、输出预算、投影 |
| Agent 运行时 | `internal/runtime/agent/agent.go`、`sampling_request.go`、`compact.go`、`cache_shape.go` | 驱动模型/工具/会话；`MaxToolOutputBytes = 32KB`；压缩与缓存 |
| Turn 控制 | `internal/session/control/turn_entry.go`、`turn_orchestrator.go`、`approval*.go`、`ask*.go` | turn 循环、审批、ask、admission、goal/subagent |
| 工具 | `internal/tools/builtin/`（`bash.go` 等） | bash 跨平台/后台 job/安全拦截；jobs/fetchchain/websearch |
| 状态 | `internal/state/sessionstore/`、`checkpoint/`、`memory/` | 会话持久化、检查点、记忆 |
| 安全 | `internal/safety/permission/`、`sandbox/`、`evidence/` | 权限门、沙箱、证据 |
| 扩展/MCP | `internal/ext/extension/` | dispatcher、MCPBackend.Call |
| 前端 | `internal/frontend/cli|tui|acp|serve|remotehost` | 多形态前端 |
| 装配 | `internal/assembly/boot/` | 配置驱动的 provider/tool/preset 装配 |
| 修复 | `internal/platform/repair/` | 事务式 repair/undo |

### 2.5 设计特点

- **配置驱动**：provider/tool 从 config 解析，不硬编码；内置实现通过 blank import 注册。
- **Provider 契约很厚**：Go 项目里最成熟的部分，覆盖真实 API 差异与失败模式。
- **安全/审批是一等公民**：turn 控制和 permission/sandbox 占大量代码。
- **工具层非常重**：bash 的跨平台、后台任务、删除拦截、PowerShell 等。
- **多前端**：CLI/TUI/ACP/serve/remotehost，核心不绑定终端。

---

## 3. 对比

| 维度 | Pi | Reasonix | opencode |
|---|---|---|---|
| 语言 | TypeScript | Go | TS/Go 等 |
| 规模 | 17k chunks | 109k chunks | 产品级 |
| 核心循环 | `packages/agent`，薄且通用 | runtime/agent + control，分层厚 | 产品化 |
| Provider | 多 provider，StreamFn 抽象 | 厚契约（重试/归一化/overflow/cache） | 多 provider |
| 工具 | 独立 tools 目录 + 钩子 | builtin 大量平台/安全处理 | 内建工具 |
| 会话 | 树/分支 | sessionstore + checkpoint + memory | 产品化 |
| 安全 | 工具钩子 | permission/sandbox/evidence | 权限系统 |
| TUI | 独立 tui 包 | 独立 tui/termrender | 内建 |
| 适合 lite | ★★★★（抄骨架） | ★★（抄概念） | ★（抄行为） |

---

## 4. 对 lite 的取舍

**照 Pi 的骨架**

```
lite/
├── agent/        纯循环：messages → model → tool calls → messages
├── provider/     DeepSeek（OpenAI-compatible streaming）
├── tools/        bash / read / write / edit（先四个）
├── session/      线性 JSONL（后续再做树/分支）
├── tui/          终端 UI（复用 /opt/my_db 的 TUI 经验）
└── config        key/model/cwd
```

**只从 Reasonix 借概念**

- tool-call 参数归一化/修复；
- 上下文溢出 → 压缩；
- 单次工具输出上限（32KB）；
- 前缀稳定（system prompt + tool schema 固定，消息只追加）以命中 DeepSeek 缓存；
- approval/sandbox 先不做，但保留 hook 位置。

**从 opencode 抄行为（不抄体量）**

opencode 是成熟产品，架构不适合照搬；只借可验证的具体交互与工具语义：

- `tool/read.ts` 的图片 → attachments（文本带行号、二进制拒绝），见 §8.28；
- diff viewer 的 split/unified 双模式、`MIN_SPLIT_WIDTH`、hunk 跳转、单文件模式，见 §8.12；
- `session_input` 的待处理 prompt 队列语义，见 §8.19；
- `session_context_epoch` 的上下文裁剪/digest 思路（简化版），见 §8.20；
- `acp/permission` 的 once / always / reject 三态，见 §8.25。

**不要抄**

- 多前端、MCP、subagent、goal、checkpoint 这些产品化体系；
- 大量平台特化（Windows/PowerShell/repair）。

---

## 5. Code Search 探索流程

### 5.1 前置检查

```bash
cd /opt/my_db
./ai_code_search.sh check /opt/code_caches/pi-mono_cache pi-mono
./ai_code_search.sh check /opt/code_caches/reasonix_cache reasonix
```

必须看到：chunks、向量、HNSW 新于 .bin、call_graph、dataflow、KV 已导入。

### 5.2 索引/重建

```bash
# 首次/全量（索引任务必须串行）
./analyze_nodejs_repo.sh /opt/pi-mono  /code/pi-mono  --jobs 4
./analyze_nodejs_repo.sh /opt/reasonix /code/reasonix --jobs 4
```

Go 调用图修复后，可只重建 call graph + KV：

```bash
./tools/call_graph /opt/code_caches/reasonix_cache
./tools/cache_import /opt/code_caches/reasonix_cache /code/reasonix --cache-dir /memory
```

### 5.3 Phase 1：架构扫描（语义搜索）

```bash
C=/opt/code_caches/pi-mono_cache
for q in "CLI entry point main command" \
         "terminal UI render input keyboard" \
         "session tree branch fork" \
         "agent loop messages turn"; do
  ./ai_code_search.sh search "$C" "$q" 4
done
```

真实命中示例（Pi）：

- `parseArgs` → `packages/coding-agent/src/cli/args.ts:72`
- `handleTerminalInput` → `packages/tui/src/tui.ts:1087`
- `runAgentLoop` → `packages/agent/src/agent-loop.ts:111`
- `createBranchedSession` → `packages/coding-agent/src/core/session-manager.ts:1643`

Reasonix：

```bash
C=/opt/code_caches/reasonix_cache
for q in "boot assembly config providers tools" \
         "provider interface stream request" \
         "approval policy sandbox permission" \
         "session store checkpoint replay"; do
  ./ai_code_search.sh search "$C" "$q" 4
done
```

命中示例：

- `provider.Provider::Stream` → `internal/contract/provider/provider.go:542`
- `agent.Agent::streamProviderRequest` → `internal/runtime/agent/sampling_request.go:30`
- `permission.Gate::approve` → `internal/safety/permission/permission.go:610`
- `tool.RegisterBuiltin` → `internal/contract/tool/tool.go:338`

### 5.4 Phase 2：符号上下文（callers/callees）

```bash
./tools/ctx.py /code/pi-mono runAgentLoop handleTerminalInput \
  createBranchedSession --max 10

./tools/ctx.py /code/reasonix \
  'control.turnOrchestrator::runTurnLoopWithPreparedTurn' \
  'control.Controller::runTurnLoop' --max 10
```

或单符号：

```bash
./tools/cache_query 'control.turnOrchestrator::runTurnLoopWithPreparedTurn' \
  --repo /code/reasonix --type context --brief
```

注意：Go 符号是 `pkg::Func` 命名空间，裸名查不到；用完整名。

### 5.5 Phase 3：数据流/细节

```bash
./ai_code_search.sh dataflow /opt/code_caches/pi-mono_cache messages
./ai_code_search.sh search  /opt/code_caches/pi-mono_cache "tool call arguments parse" 5 --rich
./ai_code_search.sh snippet /opt/code_caches/reasonix_cache ./my_agent.go 5
```

### 5.6 已知限制

- **Go 调用图**：已修复 `code_indexer` 的 Go body 提取、`call_graph` 的 `func` kind、作用域解析与 UTF-8 输出；跨包/跨类型接口调用仍可能落到裸名或缺失。
- **符号命名**：Go 是 `pkg::Func`，C++ 是 `Class::method`；查询用完整名。
- **word_freq.json 缺失**：两个缓存都有 warning，TF-IDF 重排受限；语义搜索不受影响。
- **静态证据**：callgraph/dataflow 不等于运行时多态/接口分派真相。

### 5.7 本次探索的实际结果

- Pi：`runAgentLoop` callers `agentLoop/runPromptMessages`，callees `getDefaultStreamFn/runLoop/declareToolChanges/emit`。
- Reasonix：`runTurnLoopWithPreparedTurn` callers `runTurnLoop`，callees `armAwaitResume/noticeUserGate/stopGoal/continueGoal/runOrchestratedTurn/...`。
- Reasonix Go：索引 101,565 个 Go chunks；修复后 call graph 从 1,224 键（仅 JS）提升到 16,968 键，含 72,569 个函数、44,920 个函数体。

### 5.8 范例：逐个项目探索同一功能（工具审批）

顺序：**一个项目 → 定位 → 关系 → 读源码 → 下一个项目**，最后才横向列表。
不要一开始就跨项目聚合，否则只拿到一锅混合排名，看不出各自在哪个抽象层解决。

#### ① Pi

```bash
cd /opt/my_db
# 第一轮：用「行为」描述，命中全是 UI 层，方向不对
./ai_code_search.sh search /opt/code_caches/pi-mono_cache \
  "tool approval permission confirm user prompt" 5
#   -> promptConfirm / grantNotice / showExtensionConfirm（终端交互，不是策略）

# 第二轮：换成「机制」描述，直接命中扩展点
./ai_code_search.sh search /opt/code_caches/pi-mono_cache \
  "beforeToolCall block tool execution deny result" 5
#   [1] BeforeToolCallResult   0.92  packages/agent/src/types.ts:66
#   [2] _beforeToolCall        0.87  packages/coding-agent/src/core/agent-session.ts:678

./tools/cache_query '_beforeToolCall' --repo /code/pi-mono --type context --brief
#   callers(2): _installAgentToolHooks, _executeNestedToolCall
#   callees(2): emitToolCall, hasHandlers
```

- `types.ts:66` `BeforeToolCallResult { block?, reason?, terminate? }`
- `agent-loop.ts:738` 返回 `block` 时**不执行工具**，直接
  `createErrorToolResult(reason ?? "Tool execution was blocked")` 作为 `immediate` 结果返回
- `extensions/runner.ts:1256` `emitToolCall` 遍历 handler，**命中第一个 `block:true` 就短路**；
  handler 可原地改 `event.input` 改参数

**结论**：Pi **没有内置规则引擎**，审批完全下放给扩展；核心只给「可阻断钩子 + 可改参数」。
`_isAllowedTool`（`:1581`）是 `--tools` 白名单，不是审批。

#### ② Reasonix

```bash
./ai_code_search.sh search /opt/code_caches/reasonix_cache \
  "permission policy decide mode rules allow deny ask" 6
#   [1] Policy::allowedOnlyByMode 1.00  internal/safety/permission/origin_ctx.go:34
#   [2] TestPolicyModeAllow       1.00  permission_test.go:200   （单测，跳过）
#   [5] Policy::Decide            0.89  internal/safety/permission/permission.go:148
```

- `permission.go:107` `Policy{Mode, Allow, Ask, Deny, SessionAllow, AllowDynamicBash, ReadOnly, AskOnOrigin}`
- `:282` `DecideSubjects`：多 subject 逐个判定，**任一 Deny 即 Deny，任一 Ask 则 Ask**
- `:170` `DecideSubject` 优先级：
  `ReadOnly 姿态 > bash 专项 > 浏览器凭据 > computer >`
  **`deny > SessionAllow > ask > allow > readOnly→Allow > subjectRequiresHuman→Ask > Mode`**
- 规则语法 `internal/contract/permrule`：`Tool` / `Tool(glob)` / `Tool=literal`
- `verdict.go:72` `Gate.Check` = `Gate.Verdict`；`remember=true` 时把 **ToolName 整体**
  追加进 `Policy.Allow`（"always allow" 是工具级，不是命令级）
- `:569` `Approver == nil` 时走 `unattendedAsk`：无人值守按允许，但 `ReadOnly`/`AskOnOrigin` 改拒
- bash 两跳：`BashCommandIsReadOnly` 可把非只读**升级成只读**（免审批）；
  `gitReadPrograms` 可把"只读"git 命令**降级回非只读**（仓库配置会跑程序）

**结论**：规则求值（纯函数 Policy）与「问人」（Approver 接口）彻底分离，粒度 = 工具 + subject glob。

#### ③ opencode

```bash
./ai_code_search.sh search /opt/code_caches/opencode_cache \
  "permission ruleset evaluate tool call allow deny ask" 6
#   [2] PermissionDecision 0.78  app/src/session/requests/permission-machine.ts:5 （UI 状态机）
#   [5] PermissionRuleset  0.78  client/src/promise/generated/types.ts:1088     （生成类型）
```

前 6 名都在 UI / 生成代码里，策略本体按文件定位：
`grep -n "export" /opt/opencode/packages/core/src/permission.ts`

- `permission.ts:94` 求值只有一个函数：

  ```ts
  evaluate(action, resource, ...rulesets) =
    rulesets.flat().findLast(r => Wildcard.match(action, r.action)
                               && Wildcard.match(resource, r.resource))
    ?? { action, resource: "*", effect: "ask" }      // 默认 ask
  ```

  **`findLast` → 后写的覆盖先写的**；`Wildcard` 支持 `*`/`?`（`util/wildcard.ts`）
- `:176` `denied()` 先用配置规则短路：任一 resource 为 `deny` 即拒，saved 翻不掉
- `:187` `all = [...rules, ...savedRules()]`，saved 在后 → 可覆盖配置的 `ask`
- `:256` `assert()`：`deny → BlockedError`；`allow → 过`；`ask → pending + Deferred.await`。
  带反馈拒绝 → `CorrectedError`（模型继续）；纯拒 → `DeclinedError` 用 `Effect.die` 打穿
- `:306` `reply()`：`reject` 连带拒绝同 session 所有 pending；
  `always` 时 `saved.add({projectID, action, resources: save})` 落库（项目级）
- `:63` `Unattended`：无人值守时 ask 转 deny
- `shell.ts:127` 调用侧传 `resources` 与 `save`；`save` 是**前缀通配**
  （`shell/parse.ts:229` 取前几个词拼 `"git status *"`）

**结论**：`(action, resource)` 二元组 + glob 规则表，默认 `ask`；持久化授权项目级、粒度是命令前缀。

#### 横向对比

| 维度 | Pi | Reasonix | opencode |
|---|---|---|---|
| 内置策略 | 无，全靠扩展 | `Policy` 纯函数 | `evaluate()` + ruleset |
| 挂点 | `beforeToolCall` 钩子 | `Gate.Check/Verdict` | `Permission.assert/ask` |
| 判定键 | 工具名 + args（自定义） | 工具名 + **subject** glob | **action + resource** glob |
| 优先级 | 扩展自定义 | deny > sessionAllow > ask > allow > readOnly > Mode | 配置 deny 短路 → 其余 `findLast` |
| 默认动作 | 无 → 执行 | writer 回落 `Mode`（默认 ask） | 无匹配 → `ask` |
| 记住范围 | 扩展自定义 | 进程内 `SessionAllow` + 落配置 | 项目级 DB，粒度=命令前缀 |
| 拒绝语义 | 文本塞回 tool result | `Verdict.Reason` 喂模型 | `CorrectedError` 继续 / `DeclinedError` 终止 |
| 无人值守 | 不阻塞 | `Approver=nil` → 允许 | `Unattended` → deny |
| 只读姿态 | 无 | `ReadOnly` 硬拒写；bash 可动态升降级 | 无独立姿态 |

**对 lite 的启示**：`lua/core/approval.lua` 现在是 `decide(tool)`，**只有工具名没有参数**，
「允许 bash」等于放行所有 bash 命令。三家一致的解法是**把审批键扩成「动作 + 目标」**：

- `decide(tool, args)`，对 `bash` 取命令前缀作为 subject（对齐 opencode 的 `save`）
- `allow[tool]` → `allow[rule]`，写成 `bash(git status *)`（对齐 Reasonix 的 permrule）
- 保持「deny 优先 + 无匹配回落 mode」，不要引入 opencode 的 `findLast` 覆盖语义

---

## 6. 证据分级

- 本文所有源码位置、调用关系均来自 code search 索引，标记 `[static]`。
- 未验证运行时行为（build、交互、模型请求、工具执行）。
- 需要 `[verified]` 时：实际 build + 运行 + 断点/日志确认。

---

## 7. lite 上下文记忆实现（已落地）

> 目标：补上“所有 agent 都没有的上下文记忆”。核心用 C，暴露给 LuaJIT FFI，其余 Lua。

### 7.1 分层

```
/opt/my_db KV cache (C, mmap 零拷贝)
  └── lite/src/cache/*.c + src/storage/mmap.c
        └── build/liblite_cache.so
              └── lua/ffi/cache.lua        (FFI)
                    └── lua/core/memory.lua (命名空间/TTL/召回)
                          ├── core/agent.lua (自动注入 + 写入 turn)
                          └── core/tools.lua (remember / recall 工具)
```

### 7.2 C 引擎（复制并独立构建）

- 源码：`src/cache/cache.c`、`hash_index.c`、`sorted_array.c`、`skip_list.c`、`namespace.c`、`search.c`、`iter.c`、`tag_index.c`、`index_persistence.c`、`vector_index.c`、`hnsw.c`；`src/storage/mmap.c`；`src/utils/metrics.c`。
- 头文件：`include/cache.h`、`cache_internal.h`、`cache_index.h`、`cache_hnsw.h`、`mydb.h`、`mydb_internal.h`、`metrics.h`。
- 构建：`CMakeLists.txt` → `build/liblite_cache.so`（OpenMP）。
- 能力：`cache_open/close/sync`、get/set/del/exists、namespace、prefix/range/regex/fuzzy/tag 搜索、TTL/LRU/compact。
- 日志：默认安静，`LITE_CACHE_VERBOSE=1` 才输出。

### 7.3 FFI

`lua/ffi/cache.lua` 直接声明 `cache_*`，提供：

```lua
local C = require("ffi.cache")
local h = assert(C.open(dir, 100*1024*1024))
C.set(h, "/agent/knowledge/cpp", '{"c":"move semantics","tags":["cpp"]}', 0)
print(C.get(h, "/agent/knowledge/cpp"))
for _, r in ipairs(C.search_prefix(h, "/agent/knowledge/", {max_results=10})) do
  print(r.key, r.value, r.score)
end
C.close(h)
```

### 7.4 Lua 记忆层

`lua/core/memory.lua`：

- 存储位置：**当前目录**的 `mem.bin` + `mem.idx`（mmap 载入；约 30 秒 `sync` 一次）。
- 命名空间：
  - `/agent/knowledge/*`：长期事实（permanent）
  - `/agent/working/*`：工作记忆（5 分钟）
  - `/agent/session/<id>/turn/<n>`：对话轮次（1 小时）
- 方法：`remember_fact / remember_working / remember_turn / recall / context / stats`。
- `recall(query)`：前缀扫描 + 标签搜索 + 词命中评分；返回 `{key,data,text,score}`。
- `context(query)`：格式化成注入给模型的小块文本。

### 7.5 Agent 接入

> 以下描述以 P1 压缩（§8.30）与缓存修复（§8.31）之后的实现为准；
> 早期"最近 2 轮 + 8k 字符"的说法已作废。

- 上下文窗口：由 `lua/core/compact.lua` 的三段结构决定（固定前缀 / digest / 近期尾巴），
  预算来自 `config.context_chars`（默认 64000），尾巴的 user 轮数上限来自
  `config.context_turns`（默认 16，是**上限**不是固定值）。更早的轮次不留在 prompt，
  只留在 `mem.bin`。
- 每次请求前：`memory:context(recall_query, {limit=8, max_chars=2400})` 搜索并按预算组装，
  **追加到消息列表最末尾**（末尾放 `system` 消息 DeepSeek 接受），不写入会话。
- 注入只在每个用户轮的**第一次**请求发生（`inject_context`），工具循环的后续请求不重复注入
  —— 重复注入会让前缀整体位移，下一轮命中率 71% vs 追加末尾 97%（§8.31 实测）。
- 同时 emit `memory` 事件（命中 items），TUI 状态栏显示 `mem:<总数> hit:<本轮命中>`。
- 回答完成后：`memory:remember_turn(session_id, turn, user, answer, tools)`。
- 工具新增：
  - `remember {key,content,tags}` → `/agent/knowledge/*`
  - `recall {query,limit}` → 返回命中记忆
- 这样既保留 DeepSeek 前缀缓存（历史消息只追加），又给模型当前相关记忆。

### 7.6 验证

- `./tools/test.sh`：461 项单测（`tools/auto_unit.lua`），含 KV 持久化、recall、agent 注入、
  上下文窗口裁剪/压缩预算、缓存前缀稳定性、remember/recall 工具。
- 打包：`dist/lite-linux-x64.tar.gz` 含 `build/liblite_cache.so`；包内 `core.memory` 可用。
- 手动验证：在项目目录运行 `lite --recall "关键词"`，会使用该目录的 `mem.bin`。
- 真实 DeepSeek 请求验证见 §8.30/§8.31（命中率、cache hit/miss 均为真实 API 实测）。

---

## 8. TUI 技术方案（已确定）

### 8.1 定位

TUI 只是 frontend：`core/*` 继续通过 `context` 事件驱动；TUI 订阅事件、提交输入，不反向依赖。渲染层自己写，不引入 ncurses/notcurses，用 LuaJIT FFI + ANSI + 自建 cell buffer。

### 8.2 模块

```
lua/tui/
├── screen.lua       cell buffer / 宽字符 / 行 diff / snapshot
├── terminal.lua     termios raw / ioctl size / ANSI / alt-screen
├── input.lua        键序列解析（方向键 / Ctrl / 粘贴 / UTF-8）
├── composer.lua     多行输入 / 历史 / Ctrl+C·D·L
├── transcript.lua   消息块 / 工具输出折叠 / 流式追加 / 滚动
├── status.lua       model / turn / cwd / memory 命中数
├── mouse.lua        左键拖选状态机（begin/update/copy）
├── clipboard.lua    剪贴板写入（xclip → wl-copy → xsel → pbcopy → OSC 52）
└── tui.lua          布局 + 事件循环 + 提交
```

### 8.3 虚拟屏幕（核心）

`screen.lua` 用二维 cell 数组渲染：

```lua
cell = { ch = "字", fg = 0, bg = 0, attr = 0 }
```

- 宽字符（CJK）占 2 列；换行、截断、滚动都在虚拟屏幕完成。
- 真实终端和测试/截图共用同一份渲染结果。
- 提供 `snapshot_text()` / `snapshot_html()`，AI 可直接读取，无需真实终端。
- 行级 diff：只重绘变化行，降低闪烁和 I/O。

### 8.4 终端适配

- termios FFI：`tcgetattr/tcsetattr` 进入 raw（`-icanon -echo min 1 time 0`），退出恢复。
- `ioctl(TIOCGWINSZ)` 取尺寸；窗口变化可定时轮询（简单）或 self-pipe + SIGWINCH（后续）。
- ANSI：alt-screen、隐藏/显示光标、清行、光标定位、256/truecolor。
- 退出/异常必须恢复终端状态。

### 8.5 输入

- `input.lua` 解析字节流：方向键、PageUp/Down、Home/End、Ctrl+字母、粘贴、UTF-8。
- 鼠标：SGR 序列 `ESC[<b;x;yM|m` → `{key="mouse", action, button, x, y}`；
  `action ∈ press/drag/release`，`code>=64` 视为滚轮；X10 旧编码一并归一。
  终端侧开 `?1002h`（按下+拖拽）+ `?1006h`（SGR 坐标）。
- `composer.lua`：单/多行输入、历史、光标移动、kill 行。
- 键位建议：
  - Enter 提交；Ctrl+J 换行；Ctrl+C 取消/清空；Ctrl+D 退出（空输入时）。
  - PgUp/PgDn 滚动 transcript；Ctrl+L 重绘。
  - 后续加 Tab 补全、Ctrl+R 历史搜索。

### 8.6 Transcript / Status

- block 类型：`user / assistant / tool / error / info`。
- 工具输出默认折叠（显示首行 + 行数），Enter 展开。
- assistant 流式追加；滚动时保持视图锚点。
- 状态栏：model、turn、cwd、记忆命中数、当前工具。
- 记忆块不直接铺在 transcript，只在状态栏提示“memory: N”。

### 8.7 异步 Agent / HTTP（关键改造）

现在 `http.lua` 是阻塞 `curl_easy_perform`，TUI 期间无法响应输入。改为：

```
curl_multi_init / add_handle / multi_perform / multi_info_read / remove_handle
```

- `http.lua` 提供 `start/post_stream` 返回 handle；`poll(timeout_ms)` 推进并分发 SSE。
- `agent.lua` 改成状态机（或协程）：`idle / streaming / tool / done`；TUI 每个 tick 推进。
- TUI 主循环：poll stdin + curl_multi + 定时器（记忆 flush、状态刷新），合并重绘。
- 支持流式中滚动、Ctrl+C 取消（`curl_multi_remove_handle`）。

实现细节（`[verified]`）：

- **不使用 Lua FFI 写回调**：`curl_multi` 请求用 libcurl 默认写回调写入 `tmpfile()`，每个 `poll` 后 `fflush + ftell + fread` 读取增量，再在普通 Lua 栈上调 `on_data`。这样避免 JIT 下从 C 回调进入 Lua 偶发 `PANIC ... (bad callback)`。
- 单活动请求：`http.request` 拒绝并发请求；完成后 `finish_req` 关闭 tmpfile。
- agent 用协程：`provider.stream_async` yield `{kind="http", req}`，TUI poll 完成后 resume。
- `tool_start` / `tool_result` 触发立即重绘；状态栏显示 `tool:<name>`。工具执行仍是同步的，`bash` 运行期间 TUI 不刷新（后续可做异步工具）。

### 8.8 事件流

```
input → agent:submit(text)
agent → ctx:emit("delta"/"tool_start"/"tool_result"/"assistant"/"error")
TUI  → 订阅事件，更新 block / status / screen
memory → 请求前 recall、回答后 remember；TUI 只显示命中数
```

### 8.9 测试与可观测

- 纯逻辑单测（`auto_unit.lua`）：宽字符、input、composer、transcript、status、整屏快照、diff 解析/布局/虚拟化。
- `tools/tui_smoke.sh`：tmux 120x30 + 临时 git 仓库，验证初始界面/状态栏/diff split-unified；使用假 key，不访问网络。
- 失败时保存 `artifacts/<timestamp>/tui.smoke/screen.txt`；`tools/test.sh` 已包含该步骤。
- 真实终端（raw/ANSI/输入）由 `tui_smoke` 覆盖；后续可再加 `--snapshot` 文本/HTML 导出。

### 8.10 分阶段

1. **P0 渲染核心**：`screen` + `composer` + `transcript` + 虚拟屏幕单测。
2. **P1 真实终端**：termios / ANSI / alt-screen / 输入；`--once` 保持。
3. **P2 异步流式**：curl_multi + agent 状态机；流式滚动/取消。
4. **P3 交互完善**：历史、工具展开、记忆命中、`state` 自动化。
5. **P4 可观测**：虚拟屏幕截图/HTML 接入 artifacts 与回归。

### 8.11 待定决策

- 颜色：256 色优先，truecolor 可选。
- 是否支持鼠标滚动 / 选择复制。
- 工具审批 UI（当前全自动，后续按 Reasonix 风格加 ask 覆盖层）。
- 多行提交键：Ctrl+J 还是 Shift+Enter（终端差异）。
- 取消语义：Ctrl+C 一次取消当前请求，空输入时二次退出。

### 8.12 diff 视图（已实现）

参考实现（code search，`[static]`）：

- Pi：`packages/coding-agent/src/modes/interactive/components/diff.ts:87 renderDiff`，unified + 词级 `renderIntraLineDiff` + Tab→空格。
- opencode：`packages/tui/src/feature-plugins/system/diff-viewer.tsx`，`MIN_SPLIT_WIDTH=100`、`DiffRenderable view=split|unified`、虚拟化 `scrollbox`、文件树、hunk 跳转、单文件模式；TUI 基于 OpenTUI 原生渲染器。

lite 实现（纯 ANSI，CPU 虚拟化）：

```
lua/tui/diff.lua         parse / pair / intraline（词级 LCS，1:1 才做，超限回退前后缀）
lua/tui/diff_layout.lua  unified/split 逻辑行 + wrap 高度 + 前缀和；只渲染可视行
lua/tui/diff_view.lua    全屏 pager：滚动 / hunk / split 切换 / 单文件
lua/tui/loop.lua         Ctrl+G 执行 git diff；工具输出含 diff --git 时也可打开
```

- split 宽度阈值 100；窄屏强制 unified。
- 大文件：只存逻辑行 + 每行高度前缀和；滚动二分定位首行，仅 wrap 可见窗口。
- GPU：进程内不做；终端负责光栅化（kitty/alacritty/wezterm 等）。
- `edit` 工具成功后返回单 hunk unified diff（3 行上下文）；TUI 中 <=40 行自动展开，`Ctrl+G` 可进 pager。

### 8.13 serve / attach（已实现）

参考：opencode / Reasonix 都有 serve / attach 前端（第 1/2 节 `[static]`）。lite 用最小 TCP JSON Lines 实现：

- `lite serve --port 8765 [--host 127.0.0.1]`：headless 运行 ctx/tools/agent/memory。
  - 事件广播：`user / delta / assistant / tool_start / tool_result / error / status / turn_start / turn_end / memory / state`。
  - 新客户端：`hello` → `replay`（最多 500 条）→ `state`；之后实时广播。
  - 命令：`submit / cancel / state / ping / diff`；submit 忙时排队。
  - 每轮结束 `memory:sync()` 并广播最新 `state`（mem 计数）。
- `lite attach --port 8765`：复用 `tui/*`，本地不跑 agent；把 submit/cancel/diff 发给服务端并渲染远程事件。
  - `--tmux`：用 `tmux new-window` 新开 attach 窗口。
  - `Ctrl+G` 请求服务端 cwd 的 `git diff`。
- 安全：默认只绑 `127.0.0.1`，无鉴权，不要暴露公网。
- 测试：`tools/serve_smoke.sh`（TCP probe + tmux attach + diff 转发）。

### 8.14 prompt 与记忆召回（已实现）

参考实现（code search，`[static]`）：

- Pi：`packages/coding-agent/src/core/system-prompt.ts:128 buildSystemPromptSections`，preamble + `<tools>/<rules>/<project_context>/<cwd>`；`renderProjectContext:79` 注入项目指令。
- Reasonix：`internal/session/control/prefix.go:11 SystemPrompt` + `ToolSchemas:22` 作为缓存前缀；`internal/runtime/agent/context_manager.go:93 prepareOnce` 做上下文维护；`internal/contract/tool/recall.go:5 RecallRequest` 用 query/positions 召回折叠上下文。

lite 实现：

- `lua/core/prompt.lua`：结构化 sections（`preamble/tools/rules/memory/project_context/cwd`）。
  - 项目指令自动加载 `AGENTS.md` / `CLAUDE.md` / `.lite/instructions.md`；`LITE_INSTRUCTIONS_FILE` 覆盖，`/dev/null` 禁用，默认截断 4000 字符。
  - 工具列表从 `tools:schemas()` 生成，避免与 schema 脱节。
- 记忆召回：ASCII 词 + 中文 bigram；短追问拼接上一轮 user；`<retrieved_memory>` 块标注“可能过期、按需使用”，并提示 `recall`。
- 稳定前缀：system + tool schema 固定；memory 块动态插入最近 user 之前，旧轮次只从 memory 召回。
- Agent 的 `window_messages(reserve)` 会扣除 memory 块预算，避免 prompt 超限。
- TUI/serve 共用同一套 prompt/recall；`mem:N hit:H` 可见。

### 8.15 todo list（已实现）

- `context.lua`：`session.todos`；`core/todos.lua` 负责 normalize/校验（`pending / in_progress / completed / cancelled`，最多 50 条）。
- `todo` 工具：一次提交完整列表；更新 `ctx.session.todos`，emit `todos`，并持久化到 `/agent/working/todos`（TTL long）。
- Prompt：todo 是工具/主机状态，不自动注入；当前 user 请求优先，旧任务不能借 todo 劫持本轮。
- TUI：状态栏 `todo:done/total`，`Ctrl+T` 全屏列表；serve 广播 `todos`，attach 同步显示。
- 测试：normalize/持久化/tool/状态栏/TodoView，以及旧 todo 不进入 prompt 的回归；tmux TUI 与 serve/attach 冒烟均断言 `todo:1/2` 和列表内容。

### 8.16 定时唤醒（已实现）

- `lua/core/scheduler.lua`：`every / task / max_runs / can / submit`；状态持久化到 `/agent/working/wake`（runs / last_run / last_answer）。
- `serve --wake <秒> --task <prompt>`（或 `--task-file` / `.lite/wake.md`）；仅当 `not busy and #queue == 0` 时触发。
- 唤醒 prompt 包含任务与上次结果，要求无人值守完成；每轮结束把 assistant 返回值写回 scheduler。
- 广播 `wake` 事件给 attach；状态包含 `wake.runs/every/next_run/task`。
- 安全：无人值守 + bash 自动执行风险高，应先补工具审批/沙箱后再长期运行。

### 8.17 TUI 核心补全（已实现）

对照 Pi `packages/tui/src/components/*`（markdown/editor/select-list/scroll-view/help）与 opencode `feature-plugins`（diff/which-key）：

- **Markdown**：`lua/tui/markdown.lua`；标题/列表/引用/代码块/行内 code/bold/italic/link；transcript 的 assistant 块走 Markdown，按宽度 wrap 并保留 segment 样式。
- **Help / which-key**：`lua/tui/help_view.lua`，`?` 打开；TUI/attach 均支持。
- **Tab 补全**：`lua/tui/complete.lua` + composer `replace_token`；按当前 token 列目录、唯一命中直接补全，多命中补公共前缀。
- **会话恢复**：`Session.from_memory(memory, cwd, 5)` —— 只从当前目录 `mem.bin` 的 KV
  （`/agent/index/cwd/<hash>/<id>` + `/msg/<seq>`）取最近会话；全局 JSONL 不参与。
- 测试：Markdown/help/complete/session 单测；tmux 实际验证恢复、Markdown、help、`src/ma` → `src/main.lua`。
- 尚未做：鼠标/选择复制、终端图片协议、全文搜索浮层、Session picker。

### 8.18 会话存储：KV cache（不引入 SQLite）

opencode 用 SQLite（`[static]`：`packages/core/src/session/sql.ts` 的 `session/message/part/todo/session_message/session_input`，`projector.ts:193` 事件投影）。lite 使用自建 KV cache：

- 结构：`/agent/session/<id>/meta`、`/agent/index/cwd/<hash>/<id>`、`/agent/session/<id>/msg/<seq>`（完整消息）、`/agent/session/<id>/turn/<n>`（摘要）、`/agent/session/<id>/todos`（session 级 todo）。
- 引擎：hash + sorted array/skiplist + tag/vector；`mem.bin` `MAP_SHARED` mmap，`mem.idx` 只读 mmap；`cache_get/prefix` 返回指针，C 层零拷贝，Lua 解码 JSON 时才复制。
- `Session:append` 双写 JSONL + KV `/msg/<seq>`；`/session` 优先读 msg 精确重建（含 tool_calls/tool result），turn 摘要兜底。
- `list_sessions(cwd)` 走 cwd 索引前缀搜索；选择后重建 messages + `max_turn`，JSONL 仅兜底。
- `remember_turn` 更新 meta（updated/title/turns）与 cwd 索引；meta 永久，消息/turn/todo 用 long TTL。
- todo 按 session_id 隔离，切换会话时重新载入。
- 验证：178 单测 + tmux「仅 KV、无 JSONL」自动恢复与 `/session` 切换。

### 8.19 session input / replay（已实现）

- 对齐 opencode `session_input`：待处理 prompt 存 `/agent/session/<id>/input/<seq>`（text/ts），`core/inputs.lua` 提供 add/load/remove。
- `serve` 启动时从 KV 恢复队列（push 回放 user 事件），`start_next` 取走后删除；重启不丢排队 prompt。
- `serve` 启动时把恢复的 messages 以 `user/assistant/tool_result` 事件写入 replay；attach 连接即看到历史。
- `state` 增加 `queued` 计数。
- 验证：180 单测 + serve smoke（hello/replay/state/ping/diff + todo）。

### 8.20 上下文 digest 与 AI 自我迭代

- 对齐 opencode `session_context_epoch`（简化）：`window_messages` 返回被裁掉的 dropped messages；`request_messages` 把它们压成 `<session_context>` digest 存 `/agent/session/<id>/context`，并按 digest 预算二次裁剪；细节仍由 `recall` 提供。
- AI 友好：`--once --json` 结构化事件、`--check/--recall/state/sessions --json`、`--tui --snapshot` 整屏快照、`artifacts/`、tmux 快照、`mem.bin` 跨迭代记忆、`AGENTS.md`/`design.md` + code search 规范。
- 自我迭代循环：读 AGENTS/design → code search 参考 → 改代码 → `build.sh/test.sh` → `--once`/`--tui --snapshot`/`state --json` 观察 → 记忆写入下一轮。
- 验证：186 单测 + CLI（snapshot/state/sessions）+ TUI/serve 冒烟。

### 8.21 thinking / reasoning（已实现）

- Provider 请求：`thinking = {type="enabled"}` + `reasoning_effort`；开关来自 `LITE_THINKING` / `DEEPSEEK_THINKING`、`LITE_REASONING_EFFORT` / `DEEPSEEK_REASONING_EFFORT`，TUI/serve 支持 `--thinking` / `--reasoning-effort`。
- SSE：`delta.reasoning_content` → `reasoning` 事件；`content` 仍可能为 null，已守卫。
- Agent：`ctx:emit("reasoning", text)`；不把 reasoning 写回 messages（避免污染后续请求）。
- TUI：灰色 `…` 思考块，assistant 内容开始时自动结束；serve/attach 广播并显示；`--once --json` 输出 `{"type":"reasoning"}`。
- 验证：190 单测；真实 API 收到 72 条 reasoning 事件；tmux 显示 `… Simple: 9.9 > 9.11...`。

### 8.22 性能与一致性优化

- `mem.lock`：写进程 `flock(LOCK_EX|LOCK_NB)` 独占，防止 TUI/serve 多写覆盖；`--recall/state/sessions` 只读不加锁，可在运行中诊断。
- `Session:append` 维护 `meta.messages`；`session_messages` 用 `search_range` 取尾部窗口，避免 `max_results=0` 全量扫描。
- transcript `build_lines` 增加签名缓存：空闲滚动不重建；流式/折叠/换行变化自动失效。
- 验证：196 单测 + CLI/TUI/serve 冒烟；TUI 运行时 `state --json` 可正常读取。

### 8.23 重试与优雅退出

- HTTP 重试：`LITE_MAX_RETRIES`（默认 2）；429 / 5xx / 网络错误重试。
  - 阻塞 `--once`：指数退避（0.5s/1s）。
  - 协程 TUI/serve：重新发起 `M.start` 并 yield 新请求；一旦已输出 delta/reasoning 则不再重试，避免重复内容。
- serve 优雅退出：`core/signal.lua` 用 `sigprocmask + signalfd` 把 SIGINT/SIGTERM 变成 poll fd；收到后停止 loop，关闭 clients/server/multi，`memory:close()` 同步落盘。
- 验证：201 单测；serve smoke 发送 SIGTERM 并确认进程退出。

### 8.24 bash 沙箱与路径越界防护

参考 Reasonix `internal/safety/sandbox`（bwrap、write roots、network、fail closed）与 `internal/safety/permission`（deny > ask > allow）。

- `lua/core/sandbox.lua`：`bwrap --die-with-parent --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --bind <cwd> <cwd> --chdir <cwd>`；`LITE_SANDBOX_NET=0` 时加 `--unshare-net`。
- 启用：`LITE_SANDBOX=1` / `--sandbox`；bwrap 缺失时 **fail closed**，不会退回无沙箱执行。
- 文件工具 `resolve` 增加 `realpath -m` 二次校验，阻止 workspace 内 symlink 指向外部。
- 测试：206 单测；沙箱内写 workspace 成功、写外部失败；symlink 越界被拒。

### 8.25 工具审批（已实现）

参考 Reasonix `permission.Policy::Decide`（deny > ask > allow）与 opencode `acp/permission`（once / always / reject）。

- `core/approval.lua`：`auto|ask|deny`；read/recall/remember/todo 直接 allow；session allow 持久化到 `/agent/session/<id>/approvals`。
- Agent：tool 执行前 `decide`；`ask` 时协程 `yield {kind="approval", name, args}`。
- TUI：`ApprovalView` 覆盖层，`y` once / `a` always / `n`/Esc reject；非交互 `--once` 遇到 ask 直接拒绝。
- serve/attach：广播 `approval`，客户端回 `{"type":"approval","id",decision}`；60s 超时自动 reject；`cancel` 也 reject。
- 验证：217 单测；真实 TUI `--approval ask` 弹层 → `y` → 执行 bash → done。

### 8.26 异步 bash（已实现）

- `core/proc.lua`：后台 `bash -c {command} > tmp 2>&1`，退出码写 status 文件；主循环非阻塞 poll 增量输出。
- Agent：async 模式下 `bash` 走 `tools:start_bash`，`yield {kind="proc", proc}`；其余工具同步。
- TUI/serve：每 tick `proc:poll()`；完成后 resume agent。`Ctrl+C` / `cancel` 调 `proc:cancel()`（SIGKILL）并回填 `[cancelled]`。
- 仍受审批/沙箱约束：先 approval，再启动 proc。
- 验证：225 单测；真实 TUI `sleep 8` 显示 `tool:bash` 不冻结，Ctrl+C 后输出 `[cancelled]` 并继续回复。

### 8.27 UTF-8 清洗与调试日志

- 400 `invalid unicode code point` 根因：KV 记忆/工具输出可能混入非法 UTF-8 或 surrogate；cjson 原样编码后被 DeepSeek 拒绝。
- `lua/core/text.lua`：请求前清洗所有 `content` 与 `tool_calls.arguments/name`，非法字节替换为 U+FFFD；保持 JSON 有效。
- `lua/core/debug.lua` + `LITE_DEBUG_LOG` / `--debug-log PATH`：JSONL 记录 `request`（消息数/字节/修复数）与 `response`（status/rc/error）。
- 验证：向 KV 写入含 `\xff` 的 fact，触发 `utf8_repaired=1`，真实请求成功；232 单测。

### 8.28 read 图片 / 目录（对齐 opencode）

参考 opencode `packages/opencode/src/tool/read.ts`：图片/PDF 通过 attachments 返回，文本带行号。

- 文本：1-based 行号，默认 2000 行/50KB，单行 2000 字符；目录列出条目（子目录带 `/`）；二进制拒绝。
- 图片：按 magic 识别 JPEG/PNG/GIF/WebP，最大 20MB；`Tools:read` 设置 `pending_attachment`，返回 `Image read successfully: path`。
- Agent：工具结果后追加 **user** 消息 `[{type=text},{type=image_url,url=data:...;base64,...}]`；图片只能放 user，避免 DeepSeek 400。
- 图片 base64 不写 KV（1MB value 限制），JSONL/工具结果保留路径；TUI/serve 发 `image` 事件。
- 验证：真实 API 读取红色 PNG，只回复 `red`；240 单测。

### 8.29 省 token：向 Pi / Reasonix / opencode 对齐

三家参考实现（`/opt/pi-mono`、`/opt/reasonix`、`/opt/opencode`）的减 token 手段高度一致，分四层：

| 层 | 作用点 | 省的是 |
|---|---|---|
| ① 单次工具输出硬上限 | 进 prompt 前 | 单步突增 |
| ② 追加式 prompt（前缀稳定） | 请求组装 | DeepSeek 命中价 ≈ miss 的 1/10 |
| ③ 低频压缩（cache-reset 点） | 超阈值时一次 | 长期线性增长 |
| ④ 用真实 usage 校准估算 | 全局 | 估算漂移导致误压或爆窗 |

关键事实（`[verified]`，走 agents 的 code search 通道读源码）：

- **Pi** `core/compaction/compaction.ts`：`reserveTokens=16384`、`keepRecentTokens=20000`、`backgroundTokens=32768`；
  触发即 `tokens > window - reserve`；`findCutPoint` 从最新往前累加、切点避开 tool result；
  后台在 `blocking - 32768` 就提前写摘要；送摘要的对话逐条截到 2000 字符。
- **Reasonix** `runtime/agent/compact.go`：压缩是"低频 cache-reset 点"，产物 = 稳定前缀（system + 首条 user，≤1500 tokens 且 ≤15% 窗口）+ 一段结构化 digest（Standing facts / Goal / Decisions / Files / Commands / Errors / Pending）+ 近期原文尾巴（`clamp(window×10%, 32K, 96K)`，边界回退避开 tool result）；
  `keepUserTurns` 给用户原话单独预算（窗口 5%，下限 1024）；`foldEconomics` 收益 < 100 tokens 不调 summarizer；`tokPerChar` 用上轮 usage 反推 chars→tokens。
- **opencode** `core/session/compaction.ts`：`RESERVE_MIN=16000`/`RESERVE_SHARE=0.15` 的余量是为了"整段照发、复用缓存"，而不是更早压缩；`PRECOMPUTE_LEAD=60000`；`TRANSCRIPT_LEVELS` 渐进降级（整段 → 截 tool output → 抹 output + 截 input → 只留 user → 省略，从最老的 exchange 开始降级，最新的永不丢）。

lite 的差距与本轮已落地（P0）：

| # | 原状 | 现在 |
|---|---|---|
| 1 | `provider.lua` 不解析 `usage`，命中率不可观测 | 请求带 `stream_options.include_usage`；usage chunk 的 `choices` 是空数组，**必须在 choices 判断之前处理**；`context:add_usage` 累积，TUI 状态栏 `cache:N%`，`--once --json` 发 `usage` 事件 |
| 2 | `tools.lua` 只留头部（30KB） | `truncate_mid` 头 2/3 + 尾 1/3 + marker；bash 独立 32KB 档；TUI 异步 bash 的 proc 输出原本**完全不过限**，现在也裁 |
| 3 | `context_chars` 默认 8000（≈2k tokens） | 64000 |
| 4 | `context_turns` 文档写 2、config 默认 16 | 文档订正为 16（代码行为未变，是否降到 2 待定） |

实测（`[verified]`，真实 API）：新进程首轮 `hit 2688 / prompt 4206`（63.9%，system + tool schema 是固定前缀，DeepSeek 按前缀跨进程命中）；同轮工具返回后第二次请求 `hit 3840 / prompt 4395`（87.4%），累积 75.9%，**真正新增的 miss 只有 555 tokens**。说明 append-only 前缀本身是生效的。

### 8.30 P1：低频压缩（已落地）

`lua/core/compact.lua` + `agent.lua` 的接入点。核心判断抄 Reasonix：
**压缩是低频 cache-reset 点，不是每轮裁剪**。

三段结构：

| 段 | 内容 | 约束 |
|---|---|---|
| 稳定前缀 | system + 首条 user turn | 首条钉住上限 `min(budget×5%, 6000)`，且硬性 ≤ budget/8（这段每次请求都付费） |
| digest | 一段结构化摘要 | 固定小标题、禁止编造、硬性字数上限 `clamp(budget×10%, 800, 6000)` |
| 近期尾巴 | 最近原文 | `budget×10%`，夹在 `[min(8000, avail/3), 24000]`，且 ≤ trigger/2；边界回退避开 `role=="tool"`；`context_turns` 是尾巴的 user 轮数**上限** |

关键实现决定（每条都对应一个踩过的坑）：

- **`avail = budget - 固定前缀`**：system prompt 有 4.7k 字符，若把它算进可分配预算，尾巴和用户原话会把窗口挤爆。子预算全部基于 `avail`。
- **地板值必须按预算夹住**：`tail_min=8000` 这种绝对地板在 9k 预算下会吃掉整个窗口，压完还超阈值 → 每轮都压。Reasonix 同一处注释：*Smaller synthetic windows drop the 32K floor so the tail cannot alone exceed the window.*
- **最新一条无条件进尾巴**：丢掉最新消息等于丢掉"刚才发生了什么"，任何摘要都补不回来。
- **`min_recent_keep` 的溢出要封顶**：允许尾巴略超预算，但溢出量 ≤ budget/2，否则两条 6KB 工具结果就能吃光窗口。
- **迟滞（rearm）**：`rearm = 折叠后规模 + max(2×min_fold, budget×10%)`。没有它，折叠后基座仍贴着触发线 → 下一条消息又触发 → 每轮压一次。**rearm 必须把固定前缀算进去**，否则迟滞失效（这是变异测试 M1 抓到的）。
- **检查点验收**：摘要 > 2×cap 就拒绝；折叠后规模 >= 折叠前也拒绝。宁可这次不压，也不要留一个"看起来压过了"的假结果。
- **摘要请求不带 tools / 不带 thinking**：摘要用不到工具定义，带上只是白付 schema token，而且它本来就不和主对话共享缓存前缀。
- **上一次 digest 要显式合并**：lite 的 digest 存 KV（不在 transcript 里），不会被自动卷进折叠区。不合并就会每压一次丢一段历史（对应 opencode 的 `[previous compaction][transcript]` 拼法）。
- **无 KV 时的内存兜底**：状态一丢 baseline 归零，下次请求会把整段历史重新摘一遍 —— 每次请求多花一次摘要调用。
- **尾巴逐级缩小重试**（opencode `SHRINK_STEPS` 思路）：`1 → 0.5 → 0.25`，把"没东西可折"和"失败"区分开，并在 reason 里报出试过的倍数。
- **硬上限只做物理兜底**（`budget×2`）：触发它说明压缩救不回来，此时丢最老消息并在块里写明可用 `recall` 找回。这是边界，不是策略。

`window_messages` 已删除（它每轮从最老整段切，前缀整体位移，缓存全废）。

实测（`[verified]`，真实 API）：

- 合成 91 条消息、budget 20000：折叠区 34197 字符 → 视图 91 条/44k 字符降到 14 条/12222 字符；摘要 5 秒；基线 79；再调一次不重复压。
- 带 KV：`baseline=53` 落盘，重建 agent 后能读回并继续保持低频。
- TUI 真实终端（budget 9000，三次 6KB 工具输出）：`compact: prompt 13434 -> 7059 chars (folded 7306 into a 931-char digest; baseline 6, 0 user turns kept, 0 dropped)`。
- 摘要质量：模型在有 `Pending & next step` 时明确写 "Unknown — no user turn is present in this segment"，说明"禁止编造"生效。

回归测试：`tools/auto_unit.lua` 385 项。六个变异全部被抓：
去掉无条件保留最新条 / 去掉摘要长度验收 / 去掉摘要长度提示词 / rearm 漏固定前缀 /
去掉 tail 的 tool 对齐 / 去掉地板值夹取。

### 8.31 缓存杀手：动态块插在会话中间（已修）

P1 落地后仍观察到命中率只有 38~48%。排查发现**不是压缩的问题，也不是 DeepSeek 的问题**，
而是 prompt 组装把每轮都变的块插在了会话中间。

根因：`request_messages` 把召回块（`<retrieved_memory>`）和 todo 块插在「最后一条 user 之前」。
工具循环里"最后一条 user"始终是本轮开头那个问题，于是每一轮都把它插到 system 后面 ——
后面所有消息整体位移，前缀缓存从插入点往后全部失效，只剩 `system + tools` 那段（约 4k tokens）
还能命中。这正好解释了实测中反复出现的 `hit = 4096`。

两处修正：

1. **每个用户轮只注入一次**（`iter == 1`）：同一轮后续工具请求复用同一前缀，不再重复注入。
   模型早就见过这些内容，重复注入既打断缓存又白花 token。
2. **块追加到最末尾**，不再插在中间：末尾放 system 消息 DeepSeek 接受（已验证）。

受控对比（真实 API，同一底座消息，只改块的位置）：

| 位置 | 首轮命中 | 下一轮命中 |
|---|---|---|
| 插在最后一条 user 之前 | 95% | **71%** |
| 追加到最末尾 | 95% | **97%** |

端到端（同一 prompt、同样 7 次请求、budget 64000）：

| | hit | miss（计费） | 命中率 |
|---|---|---|---|
| 改前 | 34304 | 37126 | 48.0% |
| 改后 | 55296 | **10529** | **84.0%** |

**计费 miss tokens 减少 72%**。DeepSeek 命中价约为 miss 的 1/10，折算后相当于这条链路的
有效成本降到原来的 ~35%。

这条比压缩的收益大得多，而且它一直是隐性成本：只要走工具循环就会踩到。

回归测试（`tools/auto_unit.lua`）：
- `agent memory block goes last, not mid-conversation`
- `prefix stability: messages never shift between tool rounds`
- `prefix stability: recall block not re-injected in tool rounds`

变异验证：把块改回插在 user 之前 → 3 项 FAIL；每轮重新注入 → 1 项 FAIL。

### 8.32 P2：硬上限、预算地板与 token 校准（已落地）

P1 的压缩在小预算下有两条退化路径，加上一条估算漂移，这轮一起修掉。

**① 硬上限会连 digest 一起丢掉（真 bug）**

`hard_window` 原来只保留 `msgs[1]` 再加一条"历史被丢弃"的提示。但 `view_messages()`
的输出是 `[system, 摘要块, ...历史]`，摘要块在 `msgs[2]` —— 于是压缩失败走硬上限时，
**上一次好不容易压出来的摘要被一起扔掉**。实测 budget 9000 时 `prompt 8195 → 1231`：
历史清空、摘要也没了，模型只能从头再来，比不压缩更差。

修法：先量出前导固定段（system + 紧随其后的 digest 块），只丢中间的历史，并在提示里
写明丢了几条、可用 `recall` 找回。返回 `(msgs, trimmed, dropped)`，事件里带丢弃条数。

**② 预算小于固定前缀时必然退化**

压缩的可分配预算 = 预算 − 固定前缀。system prompt 本身就有 4~5k 字符，预算设成 9000
时只剩 4k 可分配，连"折叠区 + 尾巴"的最小值都不够 → 每次都是 `nothing to fold` →
一路滑到硬上限。这不是用户的错，是配置不自洽。

修法：`compactor()` 里把预算抬到固定前缀的 3 倍（够放摘要 + 尾巴 + 可折叠区），并发一条
`reason="budget raised"` 的事件说明实际生效值。默认 64000 不受影响（4.7k×3 = 14.1k）。

**③ 字符预算是估算，会漂**

没有本地 tokenizer，纯按"3.5 字符/token"估会在中英混排、含图片占位、含 JSON 参数时偏很多。
Reasonix 的 `tokPerChar` 做法：用上一轮真实 `usage.prompt_tokens` 反推真实比例。

落地 `Compact.tok_per_char(prev, chars, tokens)`：首次观测直接用，之后指数平滑（0.7/0.3），
离谱值（≤0 或 >2）直接丢弃。`agent:tok_per_char()` / `agent:estimate_tokens()` 暴露给
状态栏和探针。实测校准精度：

```
估算 6360 tokens  vs  真实 prompt_tokens 6495   （误差 2%）
tok_per_char = 0.3452（实测 0.3563）
```

状态栏新增 `ctx:N%`（占触发线的百分比，≥60% 才显示，避免噪声）。

实测（`[verified]`，真实 API）：

| 场景 | 改前 | 改后 |
|---|---|---|
| budget 9000 三次 18KB 工具输出 | `hard ceiling` → `prompt 8195 → 1231`（历史清空） | `budget raised` + 无硬上限，`prompt 4400 → 9611` 正常增长 |
| TUI budget 9000 三次 6KB 工具输出 | 同上退化 | `compact: prompt 13092 → 8392 chars（6281 折成 1581 字符摘要）`，状态栏 `cache:57% ctx:66%` |

**④ 顺带修正一个度量口径（已落地）**

`cache_ratio`（命中/总 prompt）会被"每轮新增的工具输出"稀释：一次 9KB 工具结果
≈ 2.6k tokens，全部按 miss 计价，命中率自然掉到 50%。真正该看的是
**"可复用前缀里命中了多少"**，即 `hit / min(上一轮 prompt, 本轮 prompt)`。

落地：

- `context.lua`：`add_usage` 里同时算第二种口径，累积到 `usage.prefix_hit/prefix_denom`，
  并写进 `usage.last.reuse`（单轮）/ `prefix_ratio()`（会话级）。分母取上一轮与本轮
  prompt 的较小值 —— 只有这一段是"两轮都存在、本该被缓存"的部分；`hit` 超过分母时夹住，
  避免 provider 乱报导致 >100%。
- 告警：`reuse < 0.5` 且分母 ≥ 1500 tokens 时发 `prefix_drop` 事件（一轮最多一次，
  否则一次 agent 循环里每条请求都会刷）。1500 的地板是为了让短 prompt 不误报 ——
  几百 token 的请求本来就没有可复用前缀。
- 状态栏：`cache:79% reuse:94%` 并排显示。读法：cache 低而 reuse 高 = 正常（新增内容
  按 miss 计价）；两个都低 = 前缀真坏了（system/tools 抖动、压缩动了前缀）。
- `--once --json`：`usage` 事件带 `reuse`（单轮）+ `prefix_ratio`（会话），
  `prefix_drop` 单独一个事件类型。

实测（`[verified]`，真实 API，一次含工具调用的请求链 3.9k prompt）：

```
cache_ratio 0.799   reuse 0.936   requests 2
```

同一份 usage 下两种口径差 14 个点，正是"第二轮新增的 252 miss tokens"造成的稀释。

回归测试：`tools/auto_unit.lua` 从 390 增至 424 项。新增覆盖：预算地板（抬起 + 上报 +
不再触发硬上限 + 历史保留）、硬上限保留 digest 与 system、`tok_per_char` 首观测/平滑/
离谱值丢弃、`estimate_tokens` 用校准、状态栏 `ctx:%` 阈值、前缀命中率（无上一轮时为 nil /
夹住 >100% / 告警阈值 / 一轮一次 / 短 prompt 不告警 / 状态栏 `reuse:%` 与两轮前不显示）。
变异验证：硬上限只留 `msgs[1]` → FAIL；去掉预算地板 → 4 项 FAIL；
去掉平滑 → FAIL；去掉离谱值保护 → FAIL；`estimate_tokens` 忽略校准 → FAIL；
分母改成 `max()` → FAIL；去掉 `prefix_warned_turn` → FAIL。

### 8.33 仍然待办（P2 剩余）

1. 渐进降级（opencode `TRANSCRIPT_LEVELS`）：只有"折叠"和"丢最老"两档，
   缺中间档（截 tool output → 抹 output + 截 input → 只留 user 文本）。
2. 提前压缩（Pi `backgroundTokens=32768`）：后台在触发线之下就开始写摘要，
   到线时已经写好。需要后台任务，serve/wake 里做更自然。
3. `cache_shape` 诊断：hash(system + tools) 变了就打 notice，直接解释 miss 原因。
4. ~~观测：把 `cache_ratio` 与 `ctx%` 的逐轮曲线记进 KV，`lite state` 能看趋势；
   并改用"可复用前缀命中率"作为告警口径（见 §8.32 ④）。~~
   **命中率口径部分已实现**（`reuse`/`prefix_ratio`/`prefix_drop` 告警/状态栏 `reuse:%`，
   见 §8.32 ④）；**逐轮曲线落 KV、`lite state` 看趋势仍未做**。
5. ~~单条消息本身超预算时（一个 18KB 工具结果 > 可分配预算），只能放着不管，
   等它自然触发硬上限。~~ **已实现**：`Compact:msg_cap()` = 触发线的 1/4，
   并有绝对地板 2000 字符（`msg_ratio=0.25` / `msg_min=2000`）。只截
   `role == "tool"` 的消息 —— assistant 的 `tool_calls` 是配对结构（截了会
   400），user 原话是约束（截了就找不回来），system 与首条 user 钉住不动。
   截中间：留头 2/3 + 尾 1/3（开头是命令在干什么，结尾是报错/结论），中间插
   `... [N chars truncated: ... re-run the command narrower ...] ...`。
   **clip 不落 KV**：cap 只由 budget 决定，`M:clips(msgs)` 是纯函数，
   `view_messages` 每轮重算 → 同一条消息的裁剪结果稳定，前缀缓存照样命中；
   原文始终留在 transcript/KV 里（`M.clip_message` 复制出新表，不改原消息）。
6. 触发线仍是字符口径。有了 `tok_per_char` 校准后，可以改成 token 口径
   （例如 `LITE_CONTEXT_TOKENS`），和模型真实窗口直接对齐 ——
   参考实现（Pi 16k reserve / Reasonix 90% / opencode 85%）都是按 token 算的。

### 8.34 鼠标拖选 + 复制（transcript 文本选择）

终端原生选择在有鼠标上报（`?1002h`）时会被吃掉，所以拖选必须自己实现。
分三层，各自只管一件事：

**选区（`screen.lua`）** —— 状态只存在屏幕层，`Screen.sel = {y0,x0,y1,x1}`，
坐标是 1-based 的屏幕列/行：

- `set_selection(y0,x0,y1,x1)`：接受任意方向（`y1<y0` 或同行 `x1<x0` 才交换端点），
  统一成"先上后下、行内先左后右"。改 `sel` 后清 `self.prev`，强制整屏重绘。
- `clear_selection()` / `has_selection()`：释放、以及给 overlay 判断用。
- `resize` 直接丢掉 `sel` —— 尺寸一变，行列坐标就没有意义了。
- 行内区间由局部函数 `sel_span(sel,y,w)` 给：首行从 `x0` 开始，末行到 `x1` 结束，
  中间行整行 `1..w`；不在范围内返回 nil。
- `selection_text()`：逐行按**屏幕列**取 `rows[y]`，从 `sel_span` 的 `[a,b]` 取；
  宽字符在起始列加入、`cont` 列跳过，`nil` 列补空格。`gsub("%s+$","")` 去行尾空白，
  再丢掉整体首尾的空行，`\n` 连接 —— 复制出来的东西可以直接粘进邮件/patch。

**高亮（`styled_row(row,w,sel,y)`）** —— 关键点：高亮在**渲染时**按 `sel_span` 现算
（命中区间就把 style 覆盖成 `reverse`），不是 `put()` 时烧进 cell。因为
`put()` 发生在 `set_selection` 之前，烧进去会被下一次重绘覆盖，或者反过来在
拖动时留下残影；渲染时现算则顺序无关，任何时候 `invalidate` + `render` 都自洽。

**状态机（`mouse.lua`）** —— `Mouse.new(screen)` → `{dragging, moved, message}`，
`M:handle(ev,bounds)` 返回 `"begin"/"update"/"copy"/nil`：

- 只认左键（`ev.button ~= 0` 直接忽略），右键/中键留给终端和宿主程序。
- press：只在 transcript 可见区（`top..bottom`）内生效；composer/status 上的按下
  直接忽略。`dragging=true` `moved=false`，先摆一个零宽选区作为锚点。
- drag：与当前选区端点比，位置没变就早退（鼠标每像素都发事件，早退能省掉大量重绘）；
  否则 `moved=true` 并重设选区 → 视觉上就是反色块在跟手。
- release：`moved` 为假说明只是点了一下 → 清选区、返回 nil（不打扰用户）；
  有拖拽才 `selection_text()` → `clipboard.copy()` → 清选区 →
  返回 `"已复制 N 字符 · <通道>"`（`utf8.len` 数字符，不是字节）。
- `M:cancel()`：滚轮/切 overlay/窗口变化时调用，避免半截选区残留。

**剪贴板（`clipboard.lua`）** —— 按 `xclip → wl-copy → xsel → pbcopy` 顺序探测，
探测结果缓存（`io.popen("command -v ...")` 只跑一次）；命令不存在就落到
**OSC 52**（`ESC]52;c;<base64>BEL`），所以 ssh 里也能把选区送到本地剪贴板。
`M.copy(text)` 返回 `ok, how`，`how` 直接进上面那条提示——用户能立刻看出
"复制到哪去了"（`xclip` 还是 `osc52`），这比静默失败好排查得多。

**接线（`loop.lua` / `attach.lua`）** —— 事件循环里 mouse 分支排在最前：
任何 overlay（approval/help/session/todo/diff）打开时直接返回，把鼠标还给 overlay；
否则按 `M.layout(h,composer)` 算出 transcript 的可见行区间交给 `handle`，
返回消息就写进 transcript 的 `info` 块并 `draw()`。滚轮分支先 `cancel()`
再滚 —— 滚动会让内容位移，旧选区对应的文字已经不是用户看到的那些了。
`attach.lua` 同样处理（它没有 `session_view`）。overlay 打开时如果还有选区，
重绘前主动清掉。

**为什么不是"把选择权还给终端"** —— 可以，但代价是 TUI 内所有鼠标上报都得关掉，
滚轮、点击折叠、后续的点击定位全没了。自己实现选区换来的是一致的鼠标语义，
代价是几十行状态机 + 一个剪贴板探针。

**退化与边界** —— 没有 `xclip`/`wl-copy`/`xsel`/`pbcopy` 时不报错，走 OSC 52；
终端不支持 OSC 52（或 tmux 未配置 `set-clipboard on`）时复制静默无效，
但提示里的 `how` 会写 `osc52`，用户能自己判断；`resize`、切 overlay、
滚轮都会打断选区，符合"拖选是一次性的临时操作"的心智模型。

**验收** —— 单元测试覆盖：选区设置/取文本（`"world\nsecond"`）/反色高亮/
端点归一/行尾裁剪/清除/resize 丢弃、`utf8.len("中a")==2`、SGR
press `\27[<0;5;3M` / drag `\27[<32;9;4M` / release / 右键 / 滚轮解析，
以及 mouse 状态机的点击不清选区、拖拽后复制、`cancel` 三条路径；
UI 侧按 `AGENTS.md` §4 的铁律用 `tmux capture-pane` 或 `--tui --snapshot` 验收。

**当前回归** —— `./tools/test.sh`：单元 545 项 + `cli.json` / `tui.smoke` /
`serve.probe` / `serve.smoke` 全通过（`[verified]` 2026-11-07）。§8.30 / §8.33 里的
"385 项"/"424 项"是各自落地时的历史数字，不再逐节回填。
