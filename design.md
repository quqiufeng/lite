# Pi / Reasonix 代码架构与 Code Search 探索

> 本文基于 `/opt/pi-mono` 与 `/opt/reasonix` 的实际源码，以及 `/opt/my_db` 的 code search 索引。
> 所有结论标注为 `[static]`（静态索引/源码）；未做运行时 build/断点验证。

---

## 0. 索引与缓存

| 项目 | 源码 | 缓存 | Chunks | Call graph keys |
|---|---|---|---|---|
| Pi | `/opt/pi-mono` | `/opt/code_caches/pi-mono_cache` | 17,099 | 6,518 |
| Reasonix | `/opt/reasonix` | `/opt/code_caches/reasonix_cache` | 109,141 | 16,968 |

KV 命名空间：

- `/code/pi-mono`
- `/code/reasonix`（symbols 234,338 / callers 18,193 / callees 28,048）

索引命令：

```bash
cd /opt/my_db
./analyze_nodejs_repo.sh /opt/pi-mono  /code/pi-mono  --jobs 4
./analyze_nodejs_repo.sh /opt/reasonix /code/reasonix --jobs 4
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

- 上下文窗口：system + 最近 2 轮 + 8k 字符预算；更早的轮次不留在 prompt，只留在 `mem.bin`。
- 每次请求前：`memory:context(user_text, {limit=8,max_chars=2400})` 搜索并按预算组装，作为一条 `system` 消息插入到最近 `user` 之前（不写入会话）。
- 回答完成后：`memory:remember_turn(session_id, turn, user, answer, tools)`。
- 工具新增：
  - `remember {key,content,tags}` → `/agent/knowledge/*`
  - `recall {query,limit}` → 返回命中记忆
- 这样既保留 DeepSeek 前缀缓存（历史消息只追加），又给模型当前相关记忆。

### 7.6 验证

- `./tools/test.sh`：43 项单测，含 KV 持久化、recall、agent 注入、remember/recall 工具、上下文窗口裁剪。
- 打包：`dist/lite-linux-x64.tar.gz` 含 `build/liblite_cache.so`；包内 `core.memory` 可用。
- 手动验证：在项目目录运行 `lite --recall "关键词"`，会使用该目录的 `mem.bin`。
- 未做真实 DeepSeek 请求验证（需要 `DEEPSEEK_API_KEY`）。
