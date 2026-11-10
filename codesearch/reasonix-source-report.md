# Reasonix（DeepSeek-Reasonix）源码级架构报告

> 源码树 `/opt/reasonix`（Go 1.26 / 单 module `reasonix` / MIT），全文结论 `[static]`（源码直读，未运行）
> 或 `[verified]`（本机实际统计/读文件）。所有 `file:line` 相对该树，可 `sed -n 'N,Mp'` 复核。
> 索引：`lens project=reasonix`（58,770 chunks / 759MB，三者中最大的一份）。

---

## 0. TL;DR —— 十句话

| # | 结论 | 证据 |
|---|---|---|
| 1 | 规模：**6,657** 个 `.go`、**101.1 万行**、**303** 个包；测试文件 3,582 个、54.2 万行 —— **测试占 53.7%**，非测试代码 46.8 万行 | `find`+`wc -l` `[verified]` |
| 2 | 分层是硬约束：`internal/base` → `internal/contract`（纯契约） → `internal/{model,tools,safety,state}` → `internal/runtime` → `internal/frontend`；`contract` 只依赖 `base`，不许反向 | §2.3 `[static]` |
| 3 | 骨架只有两件东西：**一个 1,888 行的 `Agent` 结构体**（`agent.go`）+ **一个 `runToolLoop` 主循环**（`run_loop.go:195`）；其余 300 个包全是给这两件供货的 | `agent.go:270,832`、`run_loop.go:195` `[static]` |
| 4 | 模型侧的扩展面窄到只有 **2 个方法**：`Name()` + `Stream(ctx, Request) (<-chan Chunk, error)`；DeepSeek/OpenAI/Anthropic/Gemini 四种协议各一个包实现它 | `contract/provider/provider.go:536` `[static]` |
| 5 | 工具侧是 **5 个必需方法 + 21 个可选能力接口**（`Previewer`/`WritePathResolver`/`ReadPathResolver`/`ContextualTool`/`DecisionBarrier`/`Paged`/`SnipHinter`…）；内置 **38** 个工具全部 `init()` 自注册，注册表是**七个 map** 的 `Registry` | `contract/tool/tool.go:22-340`（22 个 interface）、`:375` `Registry`、`:489` `Add` `[static]` |
| 6 | 一次工具调用穿过 **9 道闸**：解析 → 策略 → 上下文可用性 → 变更依赖栅栏 → planmode/代理 → 交付策略 → 恢复+权限 → 准备 → 执行 → 收尾 | `execute_one.go:107,175,233,263,292,331,438,463,567,646` `[static]` |
| 7 | 并发只放行 `ReadOnly()==true` 的批次：`partitionToolCalls` 按只读性切段，写工具一律串行、且失败会升级成 **barrier** 拦住后续批 | `execute_batch.go:489,507,27,397` `[static]` |
| 8 | 上下文压缩是**预算常量表**而不是启发式：窗口用到 90% 触发，摘要输出上限 16K（重试 32K），近尾 verbatim 保留 clamp(窗口×10%, 32K, 96K)，摘要接受上限 50% | `agent/compact.go:25-44` `[static]` |
| 9 | 持久化在 `state/sessionstore`（1.47 万行，`save.go` 单文件 2,000 行）+ `state/sessionv4`（867 行，v4 帧格式）；`migrate.go` 934 行说明**格式演进是主要成本** | `sessionstore/save.go:1`、`sessionv4/frames.go:1` `[static]` |
| 10 | 扩展是**双轨**：声明式（skills/agents/commands/prompts/hooks/MCP/themes，跑在宿主权限里）+ 代码运行时（Manifest v2 `runtime` 块，sidecar 进程走 Extension Protocol，**完全信任**）；拦截点正好 **17** 个 | `docs/EXTENSIONS.md:10,20`、`ext/extension/intercept.go:14-31` `[static]` |

**一句话**：Reasonix = **一个 Agent 循环 + 9 道闸 + 预算常量表 + 双轨扩展**，外面裹一层 Go 包分层和一套多前端（CLI/TUI/serve/ACP/desktop）。

---

## 1. 方法与边界

### 1.1 用什么读的

主力是 `lens`（本仓库的代码索引：ctags + 调用图 + 数据流 + 向量），**先按符号/语义找，再读内联源码窗口**；`bash` 只用于 lens 不覆盖的目录级统计。

| 手段 | 目的 |
|---|---|
| `lens action=status`（`/opt/code_caches/reasonix_cache`） | 索引规模：58,770 chunk / 226,406 条调用边 / 48,361 条 dataflow 记录 |
| `lens action=symbol` / `locate` | 按符号或自然语言定位，`locate` 直接给命中行 ±N 行源码，省掉 `grep`+`sed` 两跳 |
| `lens action=context depth=2` | **调用图**：谁调它、它调谁，间接调用带 `[via recv]` 标注（接口分发看得见） |
| `lens action=peek` | `file:line` 精确读窗口（`Run`、`runToolLoop`、`executeOne`、`Provider`/`Tool` 契约） |
| `lens action=grep`（作用域限制） | 在单目录内做正则扫，避免整仓扫描 |
| `find` + `wc -l`（排除 `vendor`/`node_modules`/`testdata`） | 包级/目录级规模，全部 `[verified]`（lens 不给行数聚合） |
| `docs/*.md`（104 篇） | 作者自述的契约（EXTENSIONS/ACP/CLI/SPEC），与代码对照 |

**索引视角补上的事实**（纯 grep 扫不出来的，`[static]`）：

- `agent.Agent::runToolLoop` 在图上入度 **1**（`Agent.Run`）、出度 **30** —— 主循环是**单点枢纽**，所有分支（采样、压缩、工具轮、final）都挂在它下面，没有第二个入口。
- `agent.Agent::executeOne` 入度 **133**（其中大量是测试直接打它）：执行单点是**契约边界**，测试拿它当公开面来验策略，不经过 HTTP/serve。
- `Provider` 只有 `Name()` + `Stream()` 两个方法（`internal/contract/provider/provider.go:536`）—— 用 `peek` 验证过，不是摘要猜测。
- 索引里 `testdata`/测试用例占比极高：`executeOne` 的 133 个调用者里绝大多数是 `TestXxx`，印证了 §2.1 的 53.7% 测试密度。
- **dataflow 只作旁证，不作骨架依据**：`dataflow/funcs/<name>` 的键是**裸函数名**（无包限定），会跨语言撞名（查 `capToolOutput` 返回的是 `desktop/frontend-next/.../outputcap.ts`），且覆盖不全（`executeOne`/`handleToolRound` 都查不到）。所以本报告的主循环/短路逻辑全部以 `peek` 的源码原文为准，dataflow 只用来快速点名某个函数读了哪些变量。

### 1.2 明确**没**做

- **没有编译、没有运行**：没 `go build`、没起 `reasonix`、没连任何 provider —— 全 `[static]`。
- **`desktop/` 只到目录级**：它是**独立 module**（`desktop/go.mod`），8 个 Go 文件 + **1,709** 个 `.ts/.tsx`（Electron + `frontend-next`），不展开。
- **46.8 万行非测试代码里没逐个读**：只读了 `runtime/agent` 的入口与执行链、`contract/{tool,provider,event}` 的接口、`boot` 的装配签名、`compact` 的常量表。
- **平台适配层未量化**：`platform/`（44,330 行）与 `safety/sandbox/`（bwrap/Seatbelt/Windows 各一套）只到文件名级别。
- **没有测性能**：文中所有常量都是源码字面值，不是实测数值。

### 1.3 复现

用 `lens`（索引已建在 `/opt/code_caches/reasonix_cache`，无需重建）：

```
lens action=status project=reasonix                    # 58,770 chunk / 226,406 调用边 / 48,361 dataflow
lens action=locate query=runToolLoop                   # 命中行 + 源码窗口
lens action=context query=agent.Agent::runToolLoop depth=2   # 入度 1 / 出度 30
lens action=context query=agent.Agent::executeOne depth=2    # 入度 133
lens action=peek path=/opt/reasonix/internal/contract/provider/provider.go line=536 lines=10
lens action=peek path=/opt/reasonix/internal/ext/extension/intercept.go line=13 lines=18   # 17 个拦截点
lens action=peek path=/opt/reasonix/internal/runtime/agent/compact.go line=24 lines=16     # 预算常量
lens action=import project=reasonix only_dataflow=true       # dataflow.json 已存在但 KV 缺 funcs/vars 键时补一次
```

目录级规模（lens 不做行数聚合，用 `bash`，全 `[verified]`）：

```bash
cd /opt/reasonix
find . -name '*.go' -not -path './vendor/*' -not -path '*/node_modules/*' | wc -l   # 6657
find . -name '*_test.go' | wc -l                                                    # 3582
find . -name '*.go' -not -path './vendor/*' -not -path '*/node_modules/*' -exec cat {} + | wc -l   # 1,010,634

# §2.4 包级源码地图（注意 LANG=C：中文 locale 下 wc 会多一行「总计」）
cd /opt/reasonix && for d in $(find internal sdk -name '*.go' -not -path '*/testdata/*' -printf '%h\n' | sort -u); do
  nn=$(find $d -maxdepth 1 -name '*.go' -not -name '*_test.go' -exec cat {} + 2>/dev/null | wc -l)
  [ "$nn" -ge 1500 ] && echo "$nn $d $(LANG=C find $d -maxdepth 1 -name '*.go' -not -name '*_test.go' \
    -exec wc -l {} + | grep -v total | sort -rn | head -1)"
done | sort -rn
```

---

## 2. 横向：代码怎么分

### 2.1 实测规模（`[verified]`，2026-11-10）

| 指标 | 数值 |
|---|---|
| `.go` 文件（排除 vendor/node_modules/testdata） | **6,657** |
| 总行数 | **1,010,634** |
| 测试文件 / 测试行数 | **3,582** / **542,320（53.7%）** |
| 非测试文件 / 非测试行数 | **3,075** / **468,314** |
| 包数 | **303** |
| `docs/*.md` | **104** |
| 顶层目录 | `cmd desktop internal sdk tools workers benchmarks examples integrations npm scripts release-notes output android` |

> 这是三份报告里**测试密度最高**的一份。53.7% 不是礼貌性覆盖：`runtime/agent` 一个包里就有 **300+** 个 `_test.go`，且名字直指契约（`cache_body_test`、`delivery_visible_final_test`、`barrier`/`lease` 类）。

### 2.2 `internal/` 内部（46.8 万行怎么分的，`[verified]`，非测试行数）

| 目录 | 文件 | 行数 | 是什么 |
|---|---|---|---|
| `frontend/` | 474 | **78,312** | 多前端：`serve` 31,254 / `cli` 19,343 / `tui` 11,069 / `acp` 8,296 / `termrender` 3,612 / `doctor` 2,146 |
| `ext/` | 295 | **54,811** | 插件包、扩展 sidecar、MCP、skills、hooks、市场、主题 |
| `state/` | 267 | **47,562** | 会话存储（`sessionstore` 14,710）、checkpoint、memory、usage、workspace lease |
| `contract/` | 374 | **46,759** | **纯契约层**：`tool`/`provider`/`event`/`config`/`agentcomposition`/`permrule`… |
| `platform/` | 297 | **44,330** | OS 适配：浏览器、剪贴板、LSP、update、telemetry、git、WSL、remote |
| `runtime/` | 276 | **43,101** | **Agent 本体**：`agent`（23,370）、`coordinator`、`guardian`、`scheduler`、`delegation` |
| `session/` | 217 | **35,435** | 全在 `session/control/`：Controller、turn 编排、approval、inbox、rewind |
| `tools/` | 121 | **19,936** | 内置工具实现 + `shellrun`/`websearch`/`fetchchain`/`jobs`/`advisor` |
| `safety/` | 129 | **16,876** | `permission`（审批/规则/裁决）、`sandbox`（三平台）、`egress`、`evidence` |
| `base/` | 130 | **14,718** | 无业务依赖的底层：`diff`、`fileutil`、`tokencount`、`shellparse`、`textutil` |
| `assembly/` | 106 | **9,820** | 全在 `assembly/boot/`：**唯一装配点**，把 config 变成可运行的 `Agent` |
| `model/` | 66 | **9,028** | 四种协议实现 + `catalog`（GET /models 自动发现）+ `billing` |

### 2.3 依赖方向（单向，反向即循环依赖报错）

```
base  ←  contract  ←  {model, tools, safety, state, ext, platform}  ←  runtime  ←  frontend
                          ↑                                          ↑
                       assembly/boot  ────────────────────────────────┘（唯一装配点）
```

- `contract/` 只 import `base/`：`contract/tool/tool.go` 只引入 `base/diff` 与 `contract/provider`，**没有任何 runtime 依赖**。这是整个仓库能拆 303 个包还不炸的根本原因。
- `runtime/agent` import `contract/*`、`state/sessionstore`、`safety/*`，但**不认识任何具体 provider**：`prov` 字段是 `provider.Provider` 接口。
- `frontend/*` 只认 `session/control.Controller`，不认识 `Agent`：`serve`/`tui`/`acp` 三个前端共用同一套 Controller API。
- `assembly/boot` 是全仓唯一「知道所有人」的包（`build.go` 730 + `runtime.go` 628 + 100+ 个 `composition_*.go`），也是唯一允许 import 一切的地方。

**一句话**：`contract` 挡在中间，`boot` 收口在顶上，中间 300 个包互不越层。

### 2.4 包级源码地图（`[verified]`，非测试行数 ≥ 1500 的 39 个包，占全部非测试代码的 **67.8%**）

读一个 303 包的仓库，先要有一张「哪 39 个包占了三分之二代码」的表，否则 `locate` 出来的位置没有坐标系。
下表按**非测试行数**排序，最大单文件用 `LANG=C wc -l` 取（中文 locale 下 `grep -v total` 会漏掉「总计」行，这是本次踩到的坑）。

| 包 | 非测试行 | 最大单文件 | 是什么 |
|---|---|---|---|
| `internal/session/control` | 35,435 | `controller.go` 1218 | **前端唯一入口**：turn 提交、编排、steer、审批桥 |
| `internal/frontend/serve` | 31,254 | `serve.go` 967 | WebSocket/HTTP 前端 + 远程会话 |
| `internal/contract/config` | 29,456 | `edit.go` 2007 | 配置契约 + 编辑器（294 个文件里最大的一块「接口」） |
| `internal/runtime/agent` | 23,143 | `agent.go` 1888 | **骨架本体**：Agent + runToolLoop + 九道闸 + 压缩 |
| `internal/frontend/cli` | 19,343 | `cli.go` 1770 | 28 个子命令、`RunWithBuildInfo` |
| `internal/state/sessionstore` | 14,710 | `save.go` 2000 | 会话快照/事件/分支/迁移 |
| `internal/tools/builtin` | 13,410 | `encoding_helpers.go` 633 | 86 个非测试文件的内置工具实现 |
| `internal/ext/plugin` | 12,252 | `plugin.go` 1658 | 插件宿主（Manifest v2、生命周期） |
| `internal/frontend/tui` | 11,069 | `screen.go` 692 | 自绘 TUI |
| `internal/assembly/boot` | 9,820 | `build.go` 730 | **唯一装配点**，100+ `composition_*.go` |
| `internal/frontend/acp` | 8,296 | `service.go` 1556 | ACP（NDJSON JSON-RPC）前端 |
| `internal/platform/repair` | 7,726 | `update.go` 3290 | 自愈/修复引擎（单文件极大） |
| `internal/safety/evidence` | 6,815 | `evidence.go` 683 | 证据账本：什么算「已交付」 |
| `internal/state/memory` | 5,744 | `store.go` 779 | 长期记忆 |
| `internal/ext/installsource` | 5,417 | `plugin_package.go` 792 | 扩展安装源解析 |
| `internal/state/checkpoint` | 5,013 | `transaction.go` 1448 | 事务式 checkpoint |
| `internal/safety/sandbox` | 4,932 | `shell.go` 762 | bwrap/Seatbelt/Windows 三套沙箱抽象 |
| `internal/ext/extension` | 4,778 | `builder.go` 451 | 扩展贡献者模型 + 17 个拦截点 |
| `internal/platform/browser` | 4,308 | `act.go` 651 | 浏览器自动化 |
| `internal/ext/hook` | 4,278 | `hook.go` 1574 | 宿主钩子（spawn 子进程） |
| `internal/base/i18n` | 4,272 | `messages_zh_tw.go` 799 | 文案表（zh-CN/zh-TW/en） |
| `internal/platform/update` | 4,205 | `apply_darwin.go` 723 | 自更新（分平台） |
| `internal/ext/skill` | 4,195 | `skill.go` 1250 | Skill 加载与作用域 |
| `internal/ext/pluginpkg` | 4,122 | `pluginpkg.go` 1141 | 插件打包格式 |
| `internal/contract/provider` | 3,385 | `provider.go` 660 | Provider 契约 + 归一化/重试/schema |
| `internal/frontend/termrender` | 3,612 | `md.go` 553 | Markdown→终端渲染 |
| `internal/runtime/recovery` | 3,346 | `gate.go` 1191 | 恢复闸（Auto Guard 的载体） |
| `internal/contract/tool` | 3,289 | `tool.go` 794 | Tool 契约 + 22 个接口 + Registry |
| `internal/tools/jobs` | 3,182 | `jobs.go` 1796 | 后台任务 |
| `sdk/go` | 3,014 | `sdk.go` 928 | 对外 Go SDK |
| `internal/runtime/usecap` | 3,001 | `usecapability.go` 1457 | 能力探测/使用记录 |
| `internal/ext/extension/sidecar` | 2,898 | `client.go` 797 | 扩展 sidecar 进程客户端 |
| `internal/platform/remote` | 2,786 | `client.go` 592 | 远程执行 |
| `internal/state/sessioninbox` | 2,755 | `store.go` 542 | steer/inbox 队列 |
| `internal/runtime/taskmonitor` | 2,678 | `jsonstore.go` 783 | 任务监控 + tmux 会话 |
| `internal/model/openai` | 2,541 | `openai.go` 1225 | OpenAI 兼容协议（DeepSeek 也走这条） |
| `internal/contract/event` | 2,534 | `event.go` 719 | 20+ 事件 Kind，只追加 |
| `internal/ext/extension/protocol` | 2,253 | `validate.go` 419 | Extension Protocol 校验 |
| `internal/safety/permission` | 2,185 | `permission.go` 790 | 权限策略与审批 |

> 剩下 260 多个包单个 100–1500 行，按目录自然聚合（`[verified]`：`platform/` 41 包、`base/` 31 包、
> `ext/` 30 包、`state/` 28 包、`runtime/` 23 包、`contract/` 21 包、`model/` 12 包、`frontend/` 11 包、
> `safety/` 8 包、`tools/` 9 包，`session/`、`assembly/` 各 1 包）。**读的顺序就是这张表的顺序**：
> `runtime/agent` → `session/control` → `contract/{tool,provider,event}` → `state/sessionstore` → `ext/extension`，其余按需。

---

## 3. 骨架：Agent + runToolLoop

### 3.1 一个子系统长什么样（`[static]`）

`Agent` 是**唯一的状态容器**（`agent.go:270`），字段按职责分块：`svc`（服务句柄：provider/tools/sink/jobs/workspaceLease/recoveryGate）、`sess`（会话：`conversation`/`todoState`/`lastUsage`/`lastPrefixShape`）、`recovery`、`task`（evidence ledger/checkpoint/scopeID）、`plan`（planmode 状态）、`steer`（inbox 队列）。

装配是纯 setter，一共 20+ 个（`agent.go:395-620`）：

```go
func (a *Agent) SetTools(tools *tool.Registry)          // agent.go:400
func (a *Agent) SetGate(g Gate)                         // agent.go:428
func (a *Agent) SetExtensions(d *dispatch.Dispatcher)    // agent.go:439
func (a *Agent) SetRecoveryGate(g RecoveryGate)          // agent.go:448
func (a *Agent) SetSandboxEscapeApprover(...)            // agent.go:477
func (a *Agent) SetAsker(as Asker)                       // agent.go:529
func (a *Agent) SetPreEditHook(fn func(diff.Change))     // agent.go:538
```

没有构造函数、没有 `New()`：`boot.Build` 造完 `Agent` 后逐个 setter 注入。好处是**每个依赖都能在测试里单独换掉**（这解释了 300+ 个测试文件怎么写得出来）；代价是 `boot/build.go` 730 行全是这种填空。

### 3.2 主循环（`run_loop.go:195`，全文最重要的 120 行）

```go
func (a *Agent) runToolLoop(ctx context.Context, state *turnRuntime) error {
    for step := 0; state.runMaxSteps <= 0 || step < state.runMaxSteps || state.graceRound; step++ {
        // 1. 消费队列里的 steer（用户中途插话），落盘后作为「指导」而非「新任务」
        if text, entry, ok := a.consumeSteer(); ok { a.landSteer(text, entry) }
        a.appendTurnTailNotices()

        // 2. 采样前冻结 prefix 形状（流重试不许改历史）
        schemas := a.svc.tools.ProviderSchemas(ctx)
        prefixShape := a.capturePrefixShape(schemas)
        authority := a.plan().State()          // 采样前取，回合中变 plan 不追认

        // 3. 流式采样（含重试恢复）
        streamed := a.streamWithSamplingRecovery(ctx, step+1)

        // 4. 失败：只落一条有界恢复记录，中间失败 attempt 不写会话
        if streamed.err != nil { a.recordInterruptedDisplay(...); return streamed.err }

        // 5. 终局分类：被输出上限截一半的调用，既不进历史也不执行
        boundary := classifyResponseBoundary(usage, calls)
        calls = a.prepareCallBatch(boundary.committed)

        // 6. 提交点：只有干净的终局 attempt 才到这里
        a.sess.conversation.Add(provider.Message{Role: RoleAssistant, ...ToolCalls: committed})

        // 7. 无调用 → 终答（handleFinalResponse，可能续跑）；有调用 → handleToolRound
        if len(calls) == 0 { ...; continue }
        cont, terr := a.handleToolRound(planmode.WithAuthority(ctx, authority), state, step, ...)
    }
    return a.gracePause(ctx, state)   // 撞 maxSteps
}
```

四个设计点值得单独抄：

1. **前缀形状在采样前冻结**：`prefixShape` 一次采样一个值，`streamed.bodyChain` 记录「实际发出去的是什么」，`CompareShape(prev, cur, usage, reasons)` 事后归因缓存命中/丢失。**流重试期间绝不改会话历史** —— 否则重试的 body 和第一次不同，前缀缓存直接失效。
2. **只有干净的终局 attempt 能提交**：`classifyResponseBoundary` 把「输出被 `max_tokens` 截断」和「正常结束」分开，截断的 tool call 连历史都不进（`boundary.committed`）。注释原话：*"a call the output limit cut in half must reach neither history nor execution, and why it did not is the host's to state, not the model's to infer"*。
3. **`authority` 采样前取**：planmode 的状态在请求构造时就钉死，模型回合中间 plan 变了也不追认这一轮 —— 防 TOCTOU。
4. **撞 maxSteps 不报错**：`gracePause` 打住，工作已经在会话里，用户再发一句就接着跑。

### 3.3 `Agent.Run`（`agent.go:832`）

`Run` 只做五件事：`compositionContext`（拼组合/角色）→ `workspaceLease.BeginRun()`（**懒取写锁**，第一次真写才升级独占）→ `interceptAgentStart`（`agent.before_start` 扩展点，可中止）→ `beginRunTurn` + `bindRootTokenBudget` → `runToolLoop`。

收尾有一个**证据租约**机制值得记：`defer` 里只有 `runErr == nil`（本轮真的交付了答案）才 `CommitEvidenceForSession`；失败/取消则租约留着，下一轮重新收集。这是「后台任务改了文件，但本轮没交付 → 不算数」的实现。

---

## 4. 数据结构地图

### 4.1 会话存储分层（`state/`，`[static]`）

| 层 | 位置 | 干什么 |
|---|---|---|
| 语义层 | `state/sessionstore/session.go` (497) | 进程内会话对象：消息、todo、usage、附件 |
| 落盘层 | `sessionstore/save.go` (**2,000**) | 快照写盘、原子替换、恢复 |
| 事件层 | `sessionstore/session_events.go` (749) | 增量事件（工具派发/结果）单独记 |
| 分支层 | `sessionstore/branch.go` (711) | 会话分支/回退 |
| 回收层 | `sessionstore/recovery_gc.go` (657) | 崩溃恢复 GC |
| 迁移层 | `sessionstore/migrate.go` (**934**) | 旧格式 → 新格式 |
| v4 帧层 | `state/sessionv4/frames.go` (171) | 新格式的帧编解码（`session.go` 268 做容器） |

`migrate.go` 934 行是**格式演进税**的量化指标：v1 → v4 一路兼容，`session_v4_import.go`(449)、`legacy_listings.go`(383)、`goal_legacy.go`、`goal_state_compat.go` 都是同一笔账。

### 4.2 三张关键契约

**`Tool`（`contract/tool/tool.go:22`）—— 5 必需 + 6 可选：**

```go
type Tool interface {
    Name() string
    Description() string
    Schema() json.RawMessage
    Execute(ctx, args json.RawMessage) (string, error)
    ReadOnly() bool          // 批次能否并行的唯一判据
}
// 可选能力共 21 个（tool.go:22-340 一共 22 个 interface，去掉 Tool 本身）：
//   常用 6 个 —— FilePresenter / ContextualTool(ProviderVisible) / ContextualReasoner(Unavailable)
//               / Previewer(Preview→diff.Change) / WritePathResolver / ReadPathResolver
//   其余 15 个 —— ReadRefusalFormatter / SequentialTool / PathWriter / ImageTool / PlanModeClassifier
//               / DecisionBarrier / ReadOnlyExecutionHostMutation / ReadOnlyExecutionBlockReason
//               / CapabilityAliased / MCPMetadata / MCPVisibleMetadata / MCPPackageMetadata
//               / SnipHinter / Paged / ReadTargeter
```

`ReadOnly()` 的注释直接把策略写在接口上：*"A batch parallelises only when every call in it is ReadOnly... bash and plugin tools return false, their effects being unknowable from args alone."* —— **不可知就当写**，这是整个并发模型的默认值。

`Previewer` 的存在理由也写在注释里：预览必须走和 `Execute` **同一个** `FileOverlay`，否则用户批准的 diff 和真正跑的不是一回事。

**`Provider`（`contract/provider/provider.go:536`）—— 只有 2 个方法：**

```go
type Provider interface {
    Name() string
    Stream(ctx context.Context, req Request) (<-chan Chunk, error)
}
```

其余全是**可选能力接口**按需断言：`ToolCallReasoningPolicy`（DeepSeek thinking 模式要在 tool_calls 回合回放 reasoning）、`ReasoningRoundTripPolicy`（Anthropic 要求所有 assistant 消息保留 reasoning）等，每个配一个 `RequiresXxx(p Provider) bool` 做 nil-safe 断言。比在接口里堆 10 个方法、让 4 个 provider 全填空壳干净得多。

**`event.Kind`（`contract/event/event.go:28+`）—— 20 个事件，且只追加不改序：**

```
TurnStarted / Reasoning / Text / Message / ToolDispatch / ToolResult / Usage / Notice
/ Phase / ApprovalRequest / AskRequest / TurnDone / CompactionStarted / CompactionDone
/ ToolProgress / MCPSurfaceReady / Retrying / ...
```

每个新增 Kind 的注释都写 *"Appended last to keep the Kind values before it wire-stable."* —— 因为 `serve`(WebSocket) 和 `acp`(NDJSON JSON-RPC) 都按这个序号走线。

### 4.3 压缩预算表（`runtime/agent/compact.go:25-44`，`[static]`）

```go
defaultCompactRatio        = 0.90   // 窗口用到 90% 触发维护
checkpointCeilingRatio     = 0.50   // 摘要后目标占用上限（不补齐到这个值）
recentTailBudgetRatio      = 0.10   // 近尾 verbatim 占比
minRecentTailTokens        = 32 * 1024
maxRecentTailTokens        = 96 * 1024
summaryOutputMaxTokens     = 16 * 1024    // 摘要输出上限
summaryRetryOutputMaxTokens= 32 * 1024    // 截断后一次重试可花到这么多
summaryEffort              = "low"        // 摘要用最低推理档
exceptionalMinSavingsRatio = 0.25         // 固定前缀超 50% 时要求至少省这么多
minRecentKeep              = 2            // 至少留 2 条最近消息
fallbackTokPerChar         = 0.25         // 还没有 usage 时的 4 字符/ token 估算
defaultPinnedFirstUserTokens = 1500       // 首轮 user 原文钉住的上限
protocolReserveTokens      = 256          // provider 框架字段预留
```

文件头注释把这个机制定性成**低频率的缓存重置点**：*"the prompt grows append-only until a maintenance boundary is crossed, then one content-driven summary checkpoint is installed (stable prefix + one structured digest + recent tail)."* —— 压缩不是随时发生，而是攒到边界一次性重构；这样中间的每一轮请求前缀都字节稳定。

`capacityCompactTrigger()`（`compact.go:96`）还有一条反向逻辑：ablation 关掉压缩时 ratio 从 0.90 降到 0.50 —— **关掉功能反而更早报警**，避免静默溢出。

### 4.4 扩展点与注册表总表（`[static]`）

Go 没有 ops 表，但间接调用的坑一样存在：`Provider`/`Tool` 都是接口，`call_graph.json` 只能看到
`Stream` 的边，看不见「谁实现了它」。所以下面这张表必须**反查实现者**，不能只看调用图。

| 表 / 注册表 | 定义 `file:symbol` | 槽位 | 实例数 | 谁注册 | 断链后果 |
|---|---|---|---|---|---|
| 工具注册表 | `contract/tool/tool.go:375` `Registry`（`tools`/`order`/`canon`/`suspended`/`disabledTools`/`disabledMCP`/`heldMCP` 七个 map） | `Add` @ `:489` | `builtin/` 86 个非测试文件、28 个含 `init()`；内置 **38** 个工具 | `init()` 自注册 + MCP `BindMCPRuntime` | 工具不进 schema，模型**完全看不见**该能力（无报错） |
| 能力接口（可选） | `contract/tool/tool.go:22-340` | **22 个 interface** = `Tool` + **21** 个可选（`Previewer`/`WritePathResolver`/`ContextualTool`/`DecisionBarrier`/`Paged`/`SnipHinter`…） | 按工具各自断言 | 工具作者 | 断言失败 → 该路径静默退化为普通执行（如无预览、无路径解析） |
| 拦截点 | `ext/extension/intercept.go:14-31` `InterceptorPoint` | **17 个**（session.{start,end,load,save,rotate} / input.receive / agent.before_start / system_prompt.build / context.prepare / provider.{request,response} / tool.{before,after} / permission.decision / compaction.{prepare,complete} / frontend.event） | 每个扩展任意条 | 扩展 `KindInterceptor` 贡献 | `knownInterceptorPoint` 校验期就拒掉拼错点名的拦截器（`:34-46`） |
| 拦截器优先级 | 同上 | `MinInterceptorPriority=-1000` / `Max=+1000` | — | 扩展 | 越界被 `ValidatePriority` 拒；防止某个扩展永远抢在所有内建闸之前 |
| Provider | `contract/provider/provider.go:536` | **2 个方法**（`Name`/`Stream`）+ 可选策略接口（`RequiresToolCallReasoning` 等 `RequiresXxx` 自由函数） | **4** 个协议实现：openai / anthropic / gemini / responses | `cmd/reasonix/main.go:15-18` blank import | 未注册 → `boot` 的 provider catalog 解析失败，启动即报错（**不静默**） |
| 事件 Kind | `contract/event/event.go` | **20+** 个（TurnStarted/Reasoning/Text/Message/ToolDispatch/ToolResult/Usage/Notice/Phase/ApprovalRequest/AskRequest/TurnDone/Compaction*/ToolProgress/MCPSurfaceReady/Retrying…） | 每个前端一个 `Sink` | `runtime/agent` 发，`frontend/{tui,serve,acp}` 收 | 新 Kind 只能**追加在末尾**，否则 serve/acp 的 wire 序号错位 |
| 扩展贡献 | `ext/extension/builder.go` | `Kind` 分类（skill/agent/command/prompt/hook/theme/interceptor/MCP） | `ext/` 下 24 个包各管一类 | Manifest v1 声明式；v2 `runtime` 走 sidecar | 声明式跑在宿主权限内；sidecar 是**完全信任**的外部进程 |
| MCP | `ext/{mcpregistry,mcplaunch,mcpsetup,mcpdiag}` + `contract/tool/{disabled_mcp,held_mcp}.go` | 每 server 一组绑定 | 运行时发现 | `mcpsetup` 握手 | 工具定义变了 → 进 `heldMCP` 等重新批准，别名不覆盖用户禁用策略 |
| Skill / Rules / Hooks | `ext/{skill,rules,hook}` | skill 注入 prompt，rules 注入约束，hook spawn 子进程 | — | 用户目录 + 扩展 | hook 失败只影响该次动作；skill 未加载则 prompt 里少一段（无报错） |
| 配置契约 | `contract/config/`（**29,456 行 / 294 文件**，`edit.go` 2007） | 100+ 个 `composition_*.go` 按配置分支 | — | 用户 `config.toml` | `boot.Build` 是唯一装配点；配置项与装配分支一一对应，新增字段必须两边同时改 |

**一句话**：这张表就是「300 个包怎么长在一起」的接线图——**工具/Provider/扩展三条注册链，四条内建闸（权限/沙箱/恢复/证据）夹在中间**，其余全是适配。

---

## 5. 纵切：一条用户消息到 tool 结果

前四跳是装配与入口，后九跳全在 `executeOne`（`execute_one.go:107`）里：

| # | 跳 | 位置 | 关键点 |
|---|---|---|---|
| 1 | `cli.RunWithBuildInfo` 分发子命令 | `frontend/cli/cli.go:55,91-159` | 28 个子命令；裸跑有 tty 进 TUI，无 tty 打印用法 |
| 2 | `boot.Build(Options)` | `assembly/boot/build.go`、`options.go:35` | 唯一 config → runtime 装配点，100+ 个 `composition_*.go` 分支 |
| 3 | `Controller` 收 turn | `session/control/turn_submit.go`、`turn_orchestrator.go` | 前端只认 Controller，不认 Agent |
| 4 | `Agent.Run` | `agent.go:832` | `agent.before_start` 拦截 → `beginRunTurn` → 绑 root token 预算 |
| 5 | `runToolLoop` 采样 | `run_loop.go:195,337` | 冻结 prefix 形状 → `streamWithSamplingRecovery` → 终局分类 |
| 6 | `handleToolRound` → `executeBatch` | `run_loop.go:489`、`execute_batch.go:157` | 按 `ReadOnly` 切批，只读批并行 |
| 7 | `executeOne` 九道闸 | `execute_one.go:107` | 见 §5.1 |
| 8 | `tool.Execute` | `contract/tool/tool.go:28` | 返回值直接回喂模型 |
| 9 | 结果回灌 + 落盘 | `execute_one.go:646`、`sessionstore/session_events.go` | `ToolResult` 事件 → sink 广播 → 会话增量 |

### 5.1 `executeOne` 的九道闸（`[static]`）

```go
parseToolCall                  (175)  // JSON 解析 + 参数归一化，坏参数在这里挡
resolveToolPolicy              (233)  // 工具是否存在、是否被 config 禁用
applyContextualToolGate        (263)  // ContextualTool.ProviderVisible，不可用就 fail closed
applyMutationDependencyBarrier (292)  // 写后写 / 写后验证的依赖序
applyPlanModeAndProxy          (331)  // plan mode 下写工具降级为提案
applyDeliveryPolicyGates       (438)  // 交付范围 / 证据要求
applyRecoveryAndPermission     (463)  // Auto Guard + 权限审批 + 沙箱逃逸审批
prepareToolExecution           (567)  // 取写锁、快照、pre-edit hook
executeStoppable               (744)  // 真跑，可被 cancel
finishToolExecution            (646)  // 收据、证据入账、touched paths
```

闸门的**顺序本身是设计**，两处注释说得很直白：

- Auto Guard 在权限审批**之前**、写锁**之前**：*"so a waiting recovery card never holds a write lease"*（`execute_one.go:465`）。
- `plan.verification` / `plan.planTransition` 在恢复闸之前算好，因为闸的判据要带上「这次是不是验证命令」「是不是在换 plan」（`execute_one.go:469-473`）。

### 5.2 并发与失败升级（`execute_batch.go`）

```go
func partitionToolCalls(...) []toolCallBatch              // 489  按只读性切段
func parallelisable(..., call) bool                       // 507  单调用判据
func runParallel(ctx, start, end int, run func(int)) int   // 528  段内并行
func batchFailureBarrier(a *Agent, call, o) barrierLevel   // 397  失败升级
```

失败不是「记一笔继续」：一次写失败会根据结果算出一个 `barrierLevel`，**拦住后续依赖它的批次**（写后写、写后验证都算依赖）。这是把「前一步失败了后面别瞎跑」写进调度器，而不是交给模型判断。

---

## 6. 设计评注

### 6.1 接口窄、能力接口多 —— 整个仓库的中心思想

`Provider` 只有 2 个方法，`Tool` 只有 5 个，其余能力全部拆成**可选接口 + nil-safe 自由函数断言**：

```go
type ToolCallReasoningPolicy interface{ RequiresToolCallReasoning() bool }
func RequiresToolCallReasoning(p Provider) bool {   // provider.go:559
    if nilutil.IsNil(p) { return false }
    policy, ok := p.(ToolCallReasoningPolicy)
    return ok && policy.RequiresToolCallReasoning()
}
```

好处是**没有空壳实现**：4 个 provider 只实现自己协议的怪癖，剩下 6 个可选能力谁需要谁实现。代价是判断散在调用点的类型断言里，但每个都包了 nil-safe 函数，调用方不用重复操心。

### 6.2 缓存稳定性是一级约束，写进了代码

这是本仓库最不一样的地方，三处证据：

1. 循环里**采样前冻结** `prefixShape`，事后用 `CompareShape` 归因缓存命中/丢失（`run_loop.go:216-260`）。
2. 流重试**不许改历史**：*"stream retries must not rewrite session history mid-round, so the shape stays stable across body replays"*（`run_loop.go:228`）。
3. 参数归一化**不改 provider 字节**：`ArgumentNormalization` 只记 `Original`/`Effective`，序列化时用 `withoutArgumentNormalization` 剥掉（`contract/provider/argument_normalization.go`），测试名就叫 `TestArgumentNormalizationIsLocalAndSurvivesProjection`。

第 3 条最细：模型返回 `{"arguments":{"path":"a"}}` 这种多余包裹时，宿主剥掉再执行，但**历史里仍保留原始字节** —— 改历史就是改前缀，前缀变了缓存全丢。

### 6.3 压缩是「攒到边界一次重构」而不是「随时裁剪」

大多数实现是每轮到了阈值就裁一轮。这里是 append-only 增长到边界、**一次性**装一个摘要 checkpoint（`compact.go:20-23`），且压缩后目标占用是 50% 上限而**不补齐**（注释原话 *"candidates are never padded up to it"*）。理由同上：中间每轮前缀都稳定，只有压缩那一次是不可避免的 cache miss。

### 6.4 扩展双轨 + 明确「完全信任」

`docs/EXTENSIONS.md:10-20` 分得很清楚：

- **声明式**（skills/agents/commands/prompts/hooks/MCP/themes）——「run with the host's normal permissions」，本质是配置文件。
- **代码运行时**（Manifest v2 `runtime` 块）—— sidecar 进程走 Extension Protocol，文档直接标 **FULL TRUST**，并说明「安装/更新/替换/`--link` 就是授权，没有第二次确认」。

17 个拦截点（`ext/extension/intercept.go:14-31`）覆盖 session 5 个、input/agent/prompt/context 4 个、provider 2 个、tool 2 个、permission 1 个、compaction 2 个、frontend 1 个。优先级别限死在 `[-1000, 1000]`，注释给了理由：*"Unbounded priorities would let one contributor squeeze ahead of every future interceptor, including ones the runtime itself needs to run first."*

### 6.5 guardian 是独立的 reviewer agent，不是规则表

`safety/permission` 是确定性规则（`rule_group.go`/`verdict.go`/`write_fence.go`）；`runtime/guardian` 是**另一个 LLM**：`Session` 复用一个独立 `Agent` 会话，policy 从 `guardian_policy.md` 编译期嵌入，30s 超时，每 50 次评审压缩一次（`guardian.go:32-40`）。注释点明这样做的缓存收益：*"It reuses one underlying Agent session so the policy system prompt and prior transcript stay in the prefix cache."* —— 连安全审查都要吃前缀缓存，这是同一个主题的第 n 次重复。

### 6.6 `migrate.go` 934 行 —— 长寿命产品的真实成本

`state/sessionstore/migrate.go`(934) + `session_v4_import.go`(449) + `legacy_listings.go`(383) + `goal_legacy.go` + `goal_state_compat.go` + `state/migration/`，加起来占 `state/` 相当一块。**这不在任何架构图里，但它是真实存在的第 13 个包**：格式一旦落盘就再也删不掉。

对照 lite 自己：`mem.bin` 一套就够用，是因为历史短；Reasonix 从 1.x 到现在 v4 帧格式，兼容层比实现还多。

---

## 7. 黑盒（本报告不展开）

| 位置 | 行数 | 为什么没展开 |
|---|---|---|
| `internal/frontend/serve/` | 31,254 | 最大的前端，WebSocket/HTTP 端点逐个文件平铺，本质是 Controller 的 RPC 投影 |
| `desktop/` | 8 Go + 1,709 ts/tsx | **独立 module**，Electron + `frontend-next`，跨栈 |
| `internal/platform/` | 44,330 | 纯 OS 适配，逐个平台读收益低 |
| `internal/safety/sandbox/` | (在 16,876 里) | bwrap(Linux)/Seatbelt(macOS)/`win_*.go`(Windows) 三套并行，只看了文件名 |
| `internal/state/{trajectory,execgraph,workgroup}/` | — | 观测/执行图，非主链 |
| `workers/` `npm/` `android/` `sdk/` | — | 发布与分发面 |
| `benchmarks/` `tools/`(仓库内) | — | `e2ebench`/`loopmetrics`/`relayfake` 是评测基建 |

---

## 8. 阅读路线（按天）

| 天 | 读什么 | 目标 |
|---|---|---|
| 1 | `cmd/reasonix/main.go`(69) → `frontend/cli/cli.go:55-160` → `assembly/boot/build.go`(730) | 搞清楚「一个 config 怎么变成一个能跑的 Agent」 |
| 2 | `runtime/agent/agent.go:270-400`（Agent 字段）→ `run_loop.go:195-320` | 主循环 + 九个状态块各自的职责 |
| 3 | `execute_one.go:107-233` + `execute_batch.go:157-530` | 九道闸与并发切段，**全仓最值得抄的一段** |
| 4 | `contract/{tool,provider,event}/*.go` | 三张契约与可选能力接口的写法 |
| 5 | `runtime/agent/compact.go:20-140` + `compact_projection.go`(708) | 压缩预算表与投影 |
| 6 | `state/sessionstore/save.go`(2,000) + `session_events.go` | 落盘与事件，以及 `migrate.go` 的历史债 |
| 7 | `ext/extension/intercept.go` + `docs/EXTENSIONS.md` + `ext/extension/dispatch/` | 双轨扩展与 17 个拦截点 |
| 8 | `safety/permission/*` + `runtime/guardian/*` + `safety/sandbox/` | 确定性规则 vs LLM 审查、三平台沙箱 |
| 9 | `frontend/{tui,acp,serve}` 各取 `controller_deps` 与入口 | 三个前端怎么共用一套 Controller |

---

## 附：一页速查

```bash
# 规模
find . -name '*.go' -not -path './vendor/*' | wc -l          # 6657
find . -name '*_test.go' | wc -l                              # 3582（53.7% 的行数）

# 骨架三件
sed -n '832,900p' internal/runtime/agent/agent.go             # Run
sed -n '195,300p' internal/runtime/agent/run_loop.go          # 主循环
sed -n '107,175p' internal/runtime/agent/execute_one.go       # 九道闸入口

# 三张契约
sed -n '22,50p'   internal/contract/tool/tool.go              # Tool: 5 必需
sed -n '536,545p' internal/contract/provider/provider.go      # Provider: 2 方法
sed -n '25,90p'   internal/contract/event/event.go            # 20 个 Kind

# 两个最值得抄的机制
sed -n '20,44p'   internal/runtime/agent/compact.go           # 预算常量表
sed -n '489,530p' internal/runtime/agent/execute_batch.go     # 只读切段并行

# 装配与扩展
sed -n '35,80p'   internal/assembly/boot/options.go           # Options（100+ 字段）
sed -n '14,32p'   internal/ext/extension/intercept.go         # 17 个拦截点
```

| 问题 | 答案 |
|---|---|
| 入口？ | `cmd/reasonix/main.go:62` → `cli.RunWithBuildInfo` → `boot.Build` → `Agent.Run` |
| 主循环在哪？ | `runtime/agent/run_loop.go:195` `runToolLoop` |
| 怎么加一个 provider？ | 实现 `Name()` + `Stream()`，在 `cmd/reasonix/main.go` 加一行 blank import |
| 怎么加一个工具？ | 实现 `Tool` 五方法 + `init()` 注册到 `tools/builtin`，同样 blank import |
| 怎么加一个扩展点？ | 改 `intercept.go` 的 `knownInterceptorPoint`（**破坏 wire 兼容，慎**） |
| 上下文怎么压？ | `compact.go` 预算表：90% 触发、16K 摘要、近尾 clamp(10%, 32K, 96K) |
| 会话存哪？ | `<state root>/sessions/`，`state/sessionstore` 快照 + `session_events` 增量 |
| 并发怎么决定？ | 只 `ReadOnly()` 全 true 的批次并行；其余串行，失败按 `barrierLevel` 拦住后续 |
| 为什么 300 个包不炸？ | `contract` 只依赖 `base`，`assembly/boot` 是唯一装配点 |

**规模对照**（三份报告）：

| | opencode | pi-mono | **Reasonix** |
|---|---|---|---|
| 语言 | TypeScript/Bun | TypeScript | **Go 1.26** |
| 行数 | ~60 万 | ~20 万 | **101 万** |
| 测试占比 | — | — | **53.7%（最高）** |
| 骨架 | Effect Service/Layer | — | **Agent 结构体 + 一个循环** |
| 扩展面 | Layer 组合 | — | **2 方法接口 + 6 可选能力 + 17 拦截点** |
