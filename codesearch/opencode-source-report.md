# opencode 源码级架构报告

> 源码树 `/opt/opencode`（TypeScript / Bun / Effect），全文结论 `[static]`（源码直读，未运行）
> 或 `[verified]`（本机实际读/统计验证）。所有 `file:line` 相对该树，可 `sed -n 'N,Mp'` 复核。
> 索引：`lens project=opencode`（27,181 chunks、call_graph 88,968 行、dataflow 371,117 行、向量 84MB + HNSW 91MB）。

---

## 0. TL;DR —— 十句话

| # | 结论 | 证据 |
|---|---|---|
| 1 | 规模：35 个包、**5,701** 个 `.ts/.tsx`、约 **60 万行**；`app`（图形客户端）一家 164k 行，`core` 79k 行，`ai` 33k 行 | `find`+`wc -l` `[verified]` |
| 2 | 骨架是 **Effect-TS 的 Service/Layer**，不是类继承：每个子系统一个 `Context.Service` + `Layer.effect` + `makeLocationNode` 声明依赖 | `core/src/session/execution.ts:43,54` `[static]` |
| 3 | 主链一条：CLI(bun) → server(fetch/handlers) → `SessionExecution` → `SessionRunner.drain` → `SessionStep` → WebSocket 传输 → `ai/loop` → `tool-runtime.dispatch` | §5 `[static]` |
| 4 | 会话状态全在 **SQLite + drizzle**：`session/sql.ts` 九张表；进程内只有执行态，重启不丢会话 | `session/sql.ts:28,86,107,130` `[static]` |
| 5 | `drain` 就是 **一个 turn**，每次自带 trace root；入队工作由 durable **inbox** 表驱动，`promotable` 决定是否推进下一轮 | `runner/llm.ts:64`、`runner/index.ts:32` `[static]` |
| 6 | 执行业务有三种去向：`Complete` / `Moved` / `Reloaded` —— 换 Location 时**不重入**，返回 `Reloaded` 让上层在新实例上重跑 | `runner/index.ts:23` `[static]` |
| 7 | 单步结果是 6 种 tagged enum：Completed / Retry / Continue / RecoverFull / Compacted / OutputLimit | `runner/step.ts:30` `[static]` |
| 8 | 流式传输是**常驻 WebSocket 通道**：55 分钟轮换、15s 连接超时、30min 空闲超时、连续 5 次失败才放弃 | `session/model-transport.ts:22-27` `[static]` |
| 9 | Prompt 缓存是显式的：默认 `auto` 策略在**工具定义尾、system 首尾、对话尾**打满 4 个断点 | `ai/src/cache-policy.ts:5-12,27` `[static]` |
| 10 | 工具执行与 provider IO 解耦：`dispatch` 只吃 `(tools, ToolCallPart)`，回 `{result, output, events}`，续跑由 runner 决定 | `ai/src/tool-runtime.ts:24` `[static]` |

**一句话**：opencode = **durable inbox 驱动的 drain 循环**，外面裹一层 Effect 的 Layer 装配和一层 SQLite 事件日志。

---

## 1. 方法与边界

### 1.1 用什么读的

| 手段 | 目的 |
|---|---|
| `lens`（`project=opencode`，analysis=`/opt/code_caches/opencode_cache`） | 符号定位、语义检索、调用图扇入 |
| `lens grep` / `grep -rn` + `sed -n` | 取 `file:line`，本报告所有引用出处 |
| `find` + `wc -l` | 包级/目录级规模 |

### 1.2 明确**没**做

- **没有运行**：没 `bun install`、没起 server、没连任何 provider —— 全部 `[static]`。
- **`app`/`desktop`/`ui`/`tui` 只到目录与行数级别**：164k 行 React/自绘 UI 不逐个组件读（见 §7）。
- **生成代码未展开**：`client/src/promise/generated/types.ts`（3,418+ 行的 wire 类型）由 `httpapi-codegen` 产出。
- **没有量化性能**：65 处超时/退避常量只抄了几个关键的，没测真实延迟。

### 1.3 复现

```bash
cd /opt/opencode
find packages -name '*.ts' -not -path '*/node_modules/*' | wc -l          # 5,701
sed -n '20,44p' packages/core/src/session/runner/index.ts                 # DrainResult + Interface
sed -n '64,180p' packages/core/src/session/runner/llm.ts                  # drain 主循环
sed -n '9,40p' packages/ai/src/cache-policy.ts                            # 缓存断点策略
# lite 仓库内：
./tools/run.sh --once "lens locate drain --path /opt/opencode"
```

---

## 2. 横向：代码怎么分

### 2.1 实测规模（`[verified]`，2026-11-10）

| 包 | 文件 | 行数 | 是什么 |
|---|---|---|---|
| `app` | 718 | 164,161 | 图形客户端运行时（`runtime/` 84.7k、`session/` 38.5k、`composer/` 16.7k） |
| `core` | 475 | 79,025 | **全部业务逻辑**：session / tool / permission / plugin / mcp |
| `gui-plugins` | 949 | 78,410 | 内建 GUI 插件（文件多、单文件小） |
| `ui` | 176 | 39,466 | 通用组件 |
| `ai` | 247 | 33,488 | provider 协议层、消息 schema、缓存策略、工具运行时 |
| `codemode` | 105 | 29,870 | 以代码（而非 JSON）表达工具调用 |
| `desktop` | 208 | 25,186 | Electron 打包壳 |
| `tui` | 146 | 22,269 | 终端 UI |
| `merman` | 88 | 22,131 | 内嵌 DSL/渲染 |
| `session-ui` | 126 | 21,405 | 会话渲染层 |
| `client` | 35 | 17,433 | 生成式 HTTP 客户端 |
| `cli` | 118 | 12,401 | 入口、命令、进程管理 |
| `plugin` | 88 | 10,956 | 插件 SDK |
| `schema` | 107 | 7,024 | **wire 类型单一真源**（event/session/tool/config…） |
| `server` | 60 | 5,062 | fetch 路由 + handlers |
| `protocol` | 43 | 5,000 | 传输协议 |
| 其余 19 包 | — | <5k 各 | patchmark/latex/simulation/theme/http-recorder… |
| **合计** | **5,701** | **~600k** | 测试 `*.test.ts` **1,466** 个 |

### 2.2 `core/src` 内部（79k 行怎么分的，`[verified]`）

```
plugin/      14,006   ★ 最大，插件宿主/钩子/身份/sdk 装配
session/     12,474   ★ 会话域：runner + inbox + 压缩 + 投影
database/     6,782   drizzle schema、迁移、连接池
tool/         5,592   内建工具实现 + runtime（权限/输出裁剪/插件钩子）
shell/        3,494   shell 集成（tmux 类会话）
config/       3,444   配置合并与校验
mcp/          3,349   MCP 客户端
persistent-pty/1,251   常驻终端
codemode/       934   code-mode 工具目录
```

`session/` 单文件排行前几：`compaction.ts` 1,271、`projector.ts` 1,178、`inbox.ts` 625、`model-transport.ts` 571、`blob.ts` 503、`message-updater.ts` 491、`stats.ts` 463、`model-request.ts` 457、`session.ts` 445、`history.ts` 400。
`session/runner/`：`publish-llm-event.ts` 619、`llm.ts` 468、`step.ts` 343、`to-llm-message.ts` 301、`model.ts` 104、`retry.ts` 78、`index.ts` 44、`max-steps.ts` 16 —— **契约文件只有 44 行**，实现拆成六个小文件。

### 2.3 依赖方向（单向，反向即循环依赖报错）

```
schema  ←  ai  ←  core  ←  server/cli/tui/app
   ↑                  ↑
   └── protocol ──────┘        util 是叶子（effect 工具、process、npm、global）
```

`packages/core/src/tool.ts:1-16` 里能看到这个约束的用法：`Tool` 只从 `@opencode/schema/tool` 取类型、从 `@opencode/ai/effect` 取 `ToolDefinition`，实现细节留在 `./tool/runtime.js`——**schema 与 ai 都不会反向 import core**。

---

## 3. 骨架：Service / Layer / Node

### 3.1 一个子系统长什么样（`[static]`）

以执行调度为例，四段固定套路：

```ts
// packages/core/src/session/execution.ts:43
export class Service extends Context.Service<Service, Interface>()("@opencode/SessionExecution") {}
// :47 纯函数式终端态归类，不抛异常
export function terminal(exit: Exit.Exit<void, SessionRunner.RunError>, reason?: InterruptReason) { ... }
// :54 依赖用 Layer.effect 现场组装
export const layer = Layer.effect(Service, Effect.gen(function* () { const store = yield* SessionStore.Service; ... }))
// :176 声明「我是谁、依赖谁」，供 app-node 装配与热重载
export const node = makeGlobalNode({ service: Service, layer, deps: [...] })
```

- **没有 IOC 容器**：依赖图 = `node(deps=[...])` 的静态声明，`makeLocationNode` / `makeGlobalNode` 区分「每个工作区一份」和「全进程一份」。
- **错误是类型不是异常**：`RunError` 是 8 个 tag 的联合（`runner/index.ts:13-21`），包括 `AIError`、`StepFailedError`、`Instructions.InitializationBlocked`。
- **状态收敛在 `State` 服务**：`agent.ts:22,27` 的 `Selection` 与 `Data = { agents: Map<...>, default? }` 进了 `State`，别的模块通过服务读，不各自缓存。

### 3.2 drain 契约（全文最重要的 20 行）

```ts
// runner/index.ts:20-27
export type DrainResult = Data.TaggedEnum<{
  Complete: {}
  Moved:    { continuation?: Continuation; stepped?: true }
  Reloaded: { force: boolean; continuation?: Continuation; stepped?: true }
}>
```

三条语义（读 `llm.ts` 全流程得出的，不是注释原文）：

| 结果 | 含义 | 谁接着干 |
|---|---|---|
| `Complete` | 这个 Location 上没有可推进的 durable 工作了 | 调用方置 idle，跑 idle hook |
| `Moved` | 会话被 move 到别处（worktree/项目切换），本地通道已关 | 上层在新 Location 起新 drain |
| `Reloaded` | 本进程的 lifecycle 关闭 / 实例被替换，**进程内不能重入** | 上层重新解析实例后带 `continuation.step` 重跑 |

`continuation: {step}` 是唯一的跨进程续跑凭据 —— 所以 drain 是**可重放**的：历史已落 SQLite，重放从记录态继续，而不是内存态。

---

## 4. 数据结构地图

### 4.1 SQLite 九张表（`session/sql.ts`，`[verified]`）

| 行 | 表 | 作用 |
|---|---|---|
| 28 | `SessionTable` | 会话头（id / parentID / 标题 / Location） |
| 86 | `SessionMessageTable` | 消息（user/assistant 角色 + 模型引用） |
| 107 | `SessionPartTable` | 消息分片（text / tool-call / tool-result / reasoning） |
| 130 | `SessionInboxTable` | **durable 输入队列**（type: input/compaction/move, delivery: queue/steer） |
| 154 | `InstructionEntryTable` | 指令源（AGENTS.md 等）注册 |
| 169 | `InstructionBlobTable` | 指令原文（按内容寻址） |
| 174 | `InstructionStateTable` | 指令已读/版本状态 |
| 185 | `BlobTable` | 大对象（截图、附件、工具输出） |
| 197 | `BlobRefTable` | blob 引用计数 |

设计要点：**消息与分片分开**（message/part），因为一条 assistant 消息会流式追加 N 个 part；**blob 与引用分开**，因为工具输出会重复引用同一张图。

### 4.2 三阶段请求组装（`session/context.ts:28-52`）

```
select(sessionID)  →  Selection{ session, agent, instructions, tools }   // 定「用谁、带哪些工具」
load(selection)    →  Loaded{ ..., model, initial, messages, tools }       // 定「模型、活跃历史」
prepare(loaded)    →  SessionModelRequest.Prepared                        // 定「这次请求体」
```

注释原话：`select` fixes the Session, agent, instruction sources, and tool snapshot; `load` adds the model and active history。**工具快照固定在 select 阶段**，所以同一次 drain 里工具集不会中途变化（插件热装只影响下一 turn）。

---

## 5. 纵切：一条用户消息的 11 跳

| # | 位置 | 动作 |
|---|---|---|
| 1 | `packages/cli/src/index.ts:1` | `#!/usr/bin/env bun` 入口，喂 `NodeServices` + `ensurePluginRuntime`，再交给 `Commands` |
| 2 | `server/src/handlers/*.ts` | 本地 HTTP/RPC handler 收 `session.prompt`（`schema` 包定义请求形状） |
| 3 | `session/inbox.ts:72` | `serialized(sessionID, effect)` —— **同一会话串行**，跨会话并行；写 `SessionInboxTable` |
| 4 | `session/execution.ts:43` | `SessionExecution` 按 sessionID 找所属 instance，起/复用该 instance 的 runner |
| 5 | `runner/llm.ts:64` | `drain`（`root: true`，独立 trace）。先 `settleStaleCompactions` / `settleStaleToolCalls` 收尸 |
| 6 | `runner/llm.ts:73` | `SessionInbox.nextPromotable(db, sessionID, "input")`：没活就直接 `Complete` |
| 7 | `runner/llm.ts:82` | `advanceToStep`：`isClosed()` → `Reloaded`；`move` → `Moved`；`compaction` → 现场压缩后 `continue` |
| 8 | `session/context.ts` | `select` → `load` → `prepare`，`history.preview`（`session/history.ts:96` `withParts`）拼出窗口 |
| 9 | `session/model-transport.ts` | 常驻 WebSocket 发帧；55min 轮换连接、15s 连接超时、30min 空闲判死、5 次失败才放弃 |
| 10 | `runner/step.ts:67` | `SessionStep.make` 跑一步，按 `Outcome`（`:30`）分类：Completed/Retry/Continue/RecoverFull/Compacted/OutputLimit |
| 11 | `ai/src/tool-runtime.ts:24` | `dispatch(tools, ToolCallPart)` → 找 `name`（或 `namespace.name`）→ 执行 → 回 `{result, output, events}` |

补三处「其实在这里分叉」的细节：

- **断流不是错误**：`llm.ts:37`、`:40` 两个字符串常量是**给模型的续写指令**（上半句被截断 / 撞输出上限），runner 自动补一条 user 文本继续，用户看不到。
- **压缩由 runner 拥有**：`step.ts` 的 `recoverOverflow` 只在**落盘输出之前**调用压缩，避免出现「压缩时已有 durably 输出」的撕裂。
- **title 生成不阻塞**：`llm.ts:61` `FiberMap<SessionID, void>`，首次输入可见即起 fiber，主干不等它。

### 5.1 工具调用与权限（`[static]`）

```
tool-runtime.dispatch  →  core/tool.ts: execute(definition, call)
                       →  Permission（permission.ts，Wildcard 规则 + saved 白名单）
                       →  PluginHooks（plugin/hooks.ts 的前/后钩子）
                       →  normalizeContent / ToolOutput 裁剪 → part 表
```

`packages/core/src/tool.ts:13-16` 明确把 `Permission`、`PluginHooks`、`Image`、`CodeModeCatalog` 都塞进工具执行上下文——**权限是工具层的事，不是 UI 层的事**；`schema/tool.ts` 只描述数据。

---

## 6. 设计评注

### 6.1 用 durable inbox 换「可重启」

会话不是内存里的 loop，而是 `SessionInboxTable` + `SessionMessageTable` 两张表的状态机。drain 每跳都先读表再决定动作，因此：进程被杀 → 重启 → `nextPromotable` 还在 → 继续。代价是**每次 turn 至少两次 DB 读**（inbox 判定 + 历史预览）。

### 6.2 `steer` vs `queue` 是并发语义的最小表达

`nextPromotable(db, id, "input" | "steer")`（`llm.ts:73`、`:98`）：
- `input`：推进下一条待处理输入 → 开始新 turn；
- `steer`：**只结算当前意图**，不把排队中的下一轮工作提前拉进来。

用户「插话」和「排队」的区别就压在这一个参数上，没有另建线程模型。

### 6.3 Location 是一等公民

`Moved` / `Reloaded` 两种结果说明代码把「工作区/worktree/实例」当成可迁移的执行环境，而不是全局单例。`makeLocationNode` 与 `makeGlobalNode` 的区分贯穿 `core/`：`SessionContext`、`SessionExecution` 是 location 级，`Bus`、`State` 是全局级。

### 6.4 缓存断点是显式布局

`ai/src/cache-policy.ts:5-12` 的注释直说了设计意图：4 个断点分别落在**最后一个工具定义、system 首尾分界、对话尾**，让「工具 + base-agent + 项目 + 会话」四段前缀各自可复用，而尾部随每个工具结果前移，长跑时最近前缀始终命中。这是**按 provider 缓存语义反向设计 prompt 组装顺序**的少数实现。

### 6.5 UI 是最大的一份代码，但不是核心

`app` 164k 行 > `core` 79k 行。架构上 UI 只经 `client`（生成式 HTTP 客户端）与 `protocol` 说话，`bus` 事件经 `server/src/event-feed.ts` 流出。**改业务不该碰 app**，改 UI 才碰。

---

## 7. 黑盒（本报告不展开）

- `app` / `desktop` / `gui-plugins` / `ui` / `tui` / `session-ui`（约 35 万行 UI 代码）。
- `codemode`（以代码表达工具调用）的执行沙箱细节。
- `merman` DSL、`patchmark` 补丁格式、`latex`/`mermaid` 渲染。
- MCP 客户端（`core/mcp`，3,349 行）的协议实现。
- 生成的 `client/src/promise/generated/types.ts` 与 `httpapi-codegen` 的关系。

---

## 8. 阅读路线（按天）

| 天 | 读什么 | 目标 |
|---|---|---|
| 1 | `session/runner/index.ts`(44 行) → `runner/llm.ts:64-200` | 记住 drain 三态与 turn 边界 |
| 2 | `runner/step.ts:30-120` + `runner/to-llm-message.ts` | 一步之内发生什么、消息怎么转成 provider 格式 |
| 3 | `session/inbox.ts` + `session/sql.ts` | 状态机与表结构 |
| 4 | `session/context.ts` + `session/model-request.ts` + `ai/src/cache-policy.ts` | 请求体怎么拼、缓存断点在哪 |
| 5 | `tool/runtime.ts` + `permission.ts` + `plugin/hooks.ts` | 工具执行与权限/钩子 |
| 6 | `ai/src/llm.ts` + `ai/src/loop.ts` + `session/model-transport.ts` | 流式与重试 |
| 7 | `session/compaction.ts` + `projector.ts` | 压缩与事件投影 |

---

## 附：一页速查

```
入口      packages/cli/src/index.ts:1            (bun)
HTTP      packages/server/src/handlers/*.ts
串行化    core/src/session/inbox.ts:72           serialized()
调度      core/src/session/execution.ts:43       SessionExecution
turn      core/src/session/runner/llm.ts:64      drain (root trace)
结果      core/src/session/runner/index.ts:20     DrainResult{Complete,Moved,Reloaded}
单步      core/src/session/runner/step.ts:30      Outcome(6 态)
组装      core/src/session/context.ts:28/35/44    select → load → prepare
表        core/src/session/sql.ts:28..197         9 张
传输      core/src/session/model-transport.ts:22  WS 55min/15s/30min/5 次
缓存      packages/ai/src/cache-policy.ts:27      AUTO 4 断点
工具      packages/ai/src/tool-runtime.ts:24      dispatch(tools, call)
权限      core/src/permission.ts                  Wildcard + saved
```
