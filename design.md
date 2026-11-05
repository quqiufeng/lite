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
- 同时 emit `memory` 事件（命中 items），TUI 状态栏显示 `mem:<总数> hit:<本轮命中>`。
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
- Prompt：`<todos>` 块注入最近 user 之前；规则要求多步任务维护 todo。
- TUI：状态栏 `todo:done/total`，`Ctrl+T` 全屏列表；serve 广播 `todos`，attach 同步显示。
- 测试：normalize/持久化/tool/prompt 注入/状态栏/TodoView；tmux TUI 与 serve/attach 冒烟均断言 `todo:1/2` 和列表内容。

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
- **会话恢复**：`Session.recent_ids` + `Session.new({id=...})`；TUI 启动时找同 cwd 的最近 JSONL，恢复 agent messages 与 transcript。
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
