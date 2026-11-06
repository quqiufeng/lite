# AGENTS.md — lite

LuaJIT + libcurl + cjson + C KV cache 的 native coding agent。细节见 `design.md`、`README.md`。

## 0 开发前

新功能或架构决策动手前，**先查参考实现**，不要凭记忆猜。只借鉴思路，不复制源码。

| 参考 | 源码目录 | code search 缓存 | KV namespace |
|---|---|---|---|
| Pi (TS) | `/opt/pi-mono` | `/opt/code_caches/pi-mono_cache` | `/code/pi-mono` |
| Reasonix (Go) | `/opt/reasonix` | `/opt/code_caches/reasonix_cache` | `/code/reasonix` |
| opencode (TS) | `/opt/opencode` | `/opt/code_caches/opencode_cache` | `/code/opencode` |

工具全在 `/opt/my_db`，下文命令都先 `cd /opt/my_db`。三套通道分工：
`ai_code_search.sh`（向量语义搜索）、`tools/cache_query`（KV 精确符号，**不需向量**）、
`tools/ctx.py`（批量 caller/callee，最省 context）。

```bash
cd /opt/my_db

# ① 前置检查（索引/向量/HNSW/KV 是否齐全）
./ai_code_search.sh check /opt/code_caches/pi-mono_cache  pi-mono
./ai_code_search.sh check /opt/code_caches/reasonix_cache reasonix
./ai_code_search.sh check /opt/code_caches/opencode_cache opencode

# ② 自然语言定位 file:line（默认 brief；要代码定义加 --rich）
./ai_code_search.sh search /opt/code_caches/opencode_cache "permission approval ask deny" 5
./ai_code_search.sh search /opt/code_caches/reasonix_cache "memory recall across sessions" 5 --rich

# ③ 单符号的 caller/callee/调用链（KV，快）
./tools/cache_query 'PermissionDecision' --repo /code/opencode --type context --brief
./tools/cache_query 'control.turnOrchestrator::runTurnLoopWithPreparedTurn' \
  --repo /code/reasonix --type context --depth 2 --brief   # Go 必须用 pkg::Func 全名

# ④ 批量符号关系（agent 首选，只回吐名字）
./tools/ctx.py /code/opencode PermissionDecision SessionStore --max 5

# ⑤ 字段级数据流（谁创建/持有/改）
./ai_code_search.sh dataflow /opt/code_caches/opencode_cache session

# ⑥ 第三个项目单独再跑一遍（同一 query，逐个比，不要聚合）
./ai_code_search.sh search /opt/code_caches/pi-mono_cache "session persistence" 5
```

> **逐个查，不要 `cross-search`**：聚合只给一锅混合排名，看不出「谁在哪个抽象层解决」；
> 而且每个项目 60s 级、默认扫 20 个缓存会跑到十分钟以上。
> 一次一个项目，各自 `search` → `cache_query` → 读源码，最后再横向列表对比。

规则：

- 结论标 `[static]`（搜索/调用图/数据流都是静态证据），**真正跑过**才标 `[verified]`。
- 引用写 `file:symbol`，行号仅参考。
- 符号命名：Go 是 `pkg::Func`，C++ 是 `Class::method`，TS 用导出名；裸名查不到。
- 缓存缺失才重建（索引任务必须串行）：`./analyze_nodejs_repo.sh <src> /code/<name> --jobs 4`；
  重建后补 `./tools/word_freq <cache>`，否则 TF-IDF 重排失效（`check` 会 WARN）。
- 耗时参考（已优化后）：`cache_query` 1~2s、`search` 1.5~2s、`check` <1s。
  载入成本拆开看（`/memory`：cache.bin 34GB、index.bin 179MB、6.5M 条）：
  | 阶段 | 耗时 | 说明 |
  |---|---|---|
  | `cache_get` 单次 | **186 ns** | 真零拷贝：value 指针直接指向 mmap，不复制 |
  | index.bin 反序列化 | 300ms | 快照要还原成哈希表+排序数组，不是零拷贝 |
  | `cache_vector_index_rebuild` | 100s+ / 18GB | ← 历史真凶，见下 |
  三个已修的坑（换机器或换库版本复现时先查这三条）：
  1. `cache_open` 默认对整个 34GB pool 线性扫描重建 KV 向量索引。纯文本查询
     （context/symbol）与 lite 记忆层用不到它 → `CACHE_SKIP_VECTOR_INDEX=1`。
  2. `cache_close` 每次都重写 179MB index.bin（727ms）+ `msync` 整个 pool。
     查询不改数据 → `CACHE_READONLY=1` 跳过写回（也防止把跳过的残缺索引写回去）。
  3. 单查询走 TensorRT 会反序列化 ~600MB engine（3.9s / 4.1GB vs 1.4s / 1.3GB），
     TRT 只在批量编码划算 → `ONNX_EMBEDDER_DISABLE_TRT=1`。
  `tools/cache_query` 包装器已默认导出这三个变量；`batch_embedder` 与
  `import_book` 等写入/批量路径**不要**设，否则失去向量索引与 TRT 加速。
- 详细方法论见 `/opt/my_db/code_search_best_practices.md`，命令速查见 `/opt/my_db/coding.md`。

### 0.1 范例：逐个项目探索同一功能

以「工具审批」为例（lite 待做项）。**顺序：一个项目 → 定位 → 关系 → 读源码 → 下一个项目**，
最后才横向列表。不要一开始就跨项目聚合，否则只会拿到一锅混合排名，看不出各自在哪个抽象层解决。

#### ① Pi（TypeScript monorepo）

```bash
cd /opt/my_db
# 第一轮：用「行为」描述，命中全是 UI 层，方向不对
./ai_code_search.sh search /opt/code_caches/pi-mono_cache \
  "tool approval permission confirm user prompt" 5
#   -> promptConfirm / grantNotice / showExtensionConfirm（都是终端交互，不是策略）

# 第二轮：换成「机制」描述，直接命中扩展点
./ai_code_search.sh search /opt/code_caches/pi-mono_cache \
  "beforeToolCall block tool execution deny result" 5
#   [1] BeforeToolCallResult  0.92  packages/agent/src/types.ts:66
#   [2] _beforeToolCall       0.87  packages/coding-agent/src/core/agent-session.ts:678
#   [4] _installAgentToolHooks 0.75 packages/coding-agent/src/core/agent-session.ts:672
```

```bash
./tools/cache_query '_beforeToolCall' --repo /code/pi-mono --type context --brief
#   callers(2): _installAgentToolHooks, _executeNestedToolCall
#   callees(2): emitToolCall, hasHandlers
```

读源码（`[static]`）：

- `packages/agent/src/types.ts:66` `BeforeToolCallResult { block?, reason?, terminate? }`
- `packages/agent/src/agent-loop.ts:738` 在 `beforeToolCall` 返回 `block` 时，**不执行工具**，
  直接 `createErrorToolResult(reason ?? "Tool execution was blocked")` 作为 `kind: "immediate"` 结果返回；
  `terminate` 透传到 tool result，整批结果都 terminate 才提前结束。
- `packages/coding-agent/src/core/agent-session.ts:672` 把 `this.agent.beforeToolCall` 接到扩展 runner。
- `packages/coding-agent/src/core/extensions/runner.ts:1256` `emitToolCall` 遍历所有 `tool_call`
  handler，**命中第一个 `block:true` 就 return**（短路）；handler 可原地改 `event.input` 改参数。

**结论**：Pi **没有内置规则引擎**，审批完全下放给扩展；核心只提供「可阻断的钩子 + 可改参数」。
`_isAllowedTool`（`:1581`）是 `--tools`/`--exclude-tools` 白名单，不是审批。

#### ② Reasonix（Go）

```bash
./ai_code_search.sh search /opt/code_caches/reasonix_cache \
  "permission policy decide mode rules allow deny ask" 6
#   [1] Policy::allowedOnlyByMode  1.00  internal/safety/permission/origin_ctx.go:34
#   [2] TestPolicyModeAllow        1.00  permission_test.go:200   （单测，跳过）
#   [5] Policy::Decide             0.89  internal/safety/permission/permission.go:148
```

```bash
./tools/cache_query 'permission.Policy::Decide' --repo /code/reasonix --type context --depth 2 --brief
#   callers(1): permission.Policy::allowedOnlyByMode
```

读源码（`[static]`）：

- `permission.go:107` `Policy{Mode, Allow, Ask, Deny, SessionAllow, AllowDynamicBash, ReadOnly, AskOnOrigin}`
- `permission.go:282` `DecideSubjects`：多 subject（如 move 的源+目标）逐个判定，
  **任一 Deny 即 Deny，任一 Ask 则 Ask**，否则 Allow。
- `permission.go:170` `DecideSubject` 优先级：
  `ReadOnly 姿态 > bash 专项 > 浏览器凭据 > computer >`
  **`deny > SessionAllow > ask > allow > readOnly→Allow > subjectRequiresHuman→Ask > Mode`**
- 规则语法 `internal/contract/permrule`：`Tool` / `Tool(glob)` / `Tool=literal`（`=` 形式不允许通配）。
- `verdict.go:72` `Gate.Check` = `Gate.Verdict`；`ask()` 里 `Approver.Approve` 返回
  `(allow, remember, reason)`，`remember=true` 时**把 `ToolName` 整体追加进 `Policy.Allow`**
  （即“always allow”是工具级，不是命令级）。
- `permission.go:569` `Approver` 为 `nil` 时走 `unattendedAsk`：无人值守按“允许”以免打断自动流程，
  但 `ReadOnly` / `AskOnOrigin` 姿态下改为拒绝。
- bash 有额外两跳：`BashCommandIsReadOnly(args)` 可把非只读调用**升级成只读**（免审批）；
  `gitReadPrograms` 可把“只读”的 git 命令**降级回非只读**（仓库自己配置会跑程序）。

**结论**：Reasonix 把「规则求值」（纯函数 Policy）和「问人」（Approver 接口）彻底分离，
规则粒度 = 工具 + subject glob，且明确写出优先级。

#### ③ opencode（TypeScript monorepo）

```bash
./ai_code_search.sh search /opt/code_caches/opencode_cache \
  "permission ruleset evaluate tool call allow deny ask" 6
#   [2] PermissionDecision   0.78  app/src/session/requests/permission-machine.ts:5  （UI 状态机）
#   [5] PermissionRuleset    0.78  client/src/promise/generated/types.ts:1088      （生成的类型）
```

前 6 名都在 UI / 生成代码里，策略本体得按文件定位：

```bash
grep -n "export" /opt/opencode/packages/core/src/permission.ts | head -30
```

读源码（`[static]`）：

- `packages/core/src/permission.ts:94` 规则求值只有一个函数：
  ```ts
  evaluate(action, resource, ...rulesets) =
    rulesets.flat().findLast(r => Wildcard.match(action, r.action)
                               && Wildcard.match(resource, r.resource))
    ?? { action, resource: "*", effect: "ask" }      // 默认 ask
  ```
  **`findLast` → 后写的规则覆盖先写的**；`Wildcard` 支持 `*`/`?`（`util/wildcard.ts`）。
- `permission.ts:176` `denied()` 先用**配置规则**（agent + session）短路：任一 resource 为 `deny` 即拒，
  **saved（“总是允许”）无法翻掉配置的 deny**。
- `permission.ts:187` 合并顺序 `all = [...rules, ...savedRules()]`，saved 在后 → 可覆盖配置的 `ask`。
- `permission.ts:256` `assert()`：`deny → BlockedError`；`allow → 直接过`；
  `ask → 建 pending + 发 permission.asked + Deferred.await`。
  拒绝分两种：带反馈 → `CorrectedError`（模型继续）；纯拒绝 → `DeclinedError` 用 `Effect.die` 打穿。
- `permission.ts:306` `reply()`：`reject` 会**连带拒绝同 session 所有 pending**；
  `always` 时 `saved.add({projectID, action, resources: save})` 落库（项目级持久），
  然后重算 pending，把已变成 allow 的一并放行。
- `permission.ts:63` `Unattended = Context.Reference<Ruleset>`：无人值守时 ask 转 deny
  并附 `"...nobody is present to give it"`。
- 调用侧 `packages/core/src/tool/plugin/shell.ts:127`：
  ```ts
  permission.assert({ action: name,
                      resources: parsed.commands.map(c => c.resource),
                      save:      parsed.commands.map(c => c.save), ... })
  ```
  `save` 是**前缀通配**（`shell/parse.ts:229`，取前几个词拼 `"git status *"`），
  所以“总是允许”落到具体命令前缀，而不是整个 bash。

**结论**：opencode 用 `(action, resource)` 二元组 + glob 规则表，默认 `ask`；
持久化授权是**项目级**，粒度是命令前缀。

#### 横向对比（三个都读完之后再列）

| 维度 | Pi | Reasonix | opencode |
|---|---|---|---|
| 内置策略 | 无，全靠扩展 | `Policy` 纯函数 | `evaluate()` + ruleset |
| 挂点 | `beforeToolCall` 钩子 | `Gate.Check/Verdict` | `Permission.assert/ask` |
| 判定键 | 工具名 + args（自定义） | 工具名 + **subject** glob | **action + resource** glob |
| 优先级 | 扩展自定义 | deny > sessionAllow > ask > allow > readOnly > Mode | 配置 deny 短路 → 其余 `findLast`（saved 覆盖 ask） |
| 默认动作 | 无 → 执行 | writer 回落 `Mode`（默认 ask） | 无匹配 → `ask` |
| 记住范围 | 扩展自定义 | 进程内 `SessionAllow`；`OnRemember` 落配置 | 项目级 DB，粒度=命令前缀 |
| 拒绝语义 | 文本塞回 tool result | `Verdict.Reason` 喂模型 | 带反馈 `CorrectedError`；纯拒 `DeclinedError` 终止 |
| 无人值守 | 不阻塞（钩子自己决定） | `Approver=nil` → 允许 | `Unattended` → deny |
| 只读姿态 | 无 | `ReadOnly` 硬拒写；bash 可动态升级/降级只读 | 无独立姿态 |

**对 lite 的启示**：`lua/core/approval.lua` 现在是 `decide(tool)` —— **只有工具名，没有参数**，
「允许 bash」等于放行所有 bash 命令。三家一致的解法是**把审批键扩成「动作 + 目标」**：

- 最小改动：`decide(tool, args)`，对 `bash` 取命令前缀作为 subject（对齐 opencode 的 `save`）
- `allow[tool]` 改成 `allow[rule]`，规则写成 `bash(git status *)` 形式（对齐 Reasonix 的 permrule）
- 保持「deny 优先 + 无匹配回落 mode」，不要引入 opencode 那种 `findLast` 覆盖语义

## 1 铁律

MUST：

- 改代码后跑 `./tools/test.sh`，通过才算完成。
- 依赖变更同步 `tools/check_deps.sh` 和本文件；C ABI/FFI 变更同步 `lua/ffi/*` 与文档。
- UI 改动用 `tmux capture-pane` 或快照验收。
- Commit：`feat/fix/style/docs/chore(scope): ...`；仅用户明确要求时 commit/push。

MUST NOT：

- 不用 Chrome/WebView/CEF/Electron。
- 不启动 `xdotool/wmctrl/import`；窗口控制用 LuaJIT FFI。
- 不用 `systemd --user` 启 UI；不用 `pkill -f`（用 `pkill -x`）。
- 不把 API Key 写进仓库。

## 2 依赖

LuaJIT/cjson、libcurl、OpenMP、libpng/libjpeg/libwebp + X11 + pkg-config、gcc/cmake/cc/c++、tmux（可选）。
OCR：PP-OCRv4 + onnxruntime 1.26 放 `third_party/ocr/`；CUDA provider 不打包，系统有则用。

`./tools/check_deps.sh`

## 3 命令

```bash
./tools/build.sh
./tools/run.sh --tui
./tools/run.sh --once "prompt"
./tools/run.sh serve --port 8765
./tools/test.sh
./tools/package.sh
./tools/release.sh
```

## 4 目录

```
lua/main.lua context.lua core/ tui/ ffi/
src/cache src/image   C KV cache / image
automation/           x11/xdo FFI
helper/               动态 native helper
tools/                build/run/test/package/release
```

## 5 约定

- 模块 `M.new(ctx)` + `M:method()`；不反向 require `main.lua`，依赖用 ctx 注入。
- FFI 薄封装；指针/内存成对释放；工具输出单次 ≤ 32KB。
- 会话 JSONL + KV；旧上下文靠 memory/recall；审批 `auto|ask|deny`。
- `LITE_SANDBOX=1` 用 bwrap；FFI/native 在进程内、不经过 bwrap，靠审批守边界。
- `read` 文本/目录限 workspace；图片可读 `$TMPDIR:/tmp:/var/tmp`，`LITE_READ_DIRS` 可加白名单。
- Prompt 在 `lua/core/prompt.lua`；自动加载 `AGENTS.md`/`CLAUDE.md`/`.lite/instructions.md`，`LITE_INSTRUCTIONS_FILE` 覆盖，`LITE_INSTRUCTIONS_CHARS` 截断。

## 6 原生扩展

LuaJIT 自带 FFI：系统有 `.so` 就直接 `ffi.cdef` + `ffi.load`，封装放 `lua/ffi/<feature>.lua`，工具在 `lua/core/tools.lua` 暴露；复杂 ABI/热路径才写 `src/<feature>/`。

- C 导出 `int lite_<feature>_...` + `const char *lite_<feature>_error(void)`；失败返回非 0。
- `.so` 设 `$ORIGIN` RPATH；`package.sh` 复制 `.so` 及非 libc 依赖到 `dist/lib/`。
- **禁止把 `$ROOT/lib` 注入 `LD_LIBRARY_PATH`**：该变量被 exec 的子进程（`bash` 工具、native helper、外部脚本）继承，随包的 `libonnxruntime.so.1` 会遮蔽系统同名库（缺 `VERS_1.20.1` 等版本符号），让依赖系统 onnxruntime 的 `ai_code_search.sh` 等工具**静默失败**。自带 `.so` 靠 `$ORIGIN`；无 RPATH 的第三方库（如 `libocr_simple.so`）由 FFI 层按绝对路径 `ffi.load(path, true)` 预加载。回归由 `check_deps.sh` 的 `ocr self-contained` 项守护。
- `mem.bin` 头部（magic/version）损坏时 `cache_open` 会把它改名为 `mem.bin.corrupt-<ts>` 并重建空库，`mem.idx` 一并备份，保证不阻塞启动；回归项在 `auto_unit.lua` 的 `corrupt:` 用例。
- 热重载：Lua 清 `package.loaded[...]` 重新 require；TUI `/reload`。C `.so` 不卸载，C 改动需重启。

## 7 native helper

`native` 让模型写 C/C++、编译 `.so`、写 Lua wrapper + schema，立即成为工具。

- 发现：`<workspace>/helper` 优先，`$LITE_ROOT/helper` 兜底；`scope=local|global`。
- ABI：`char *lite_helper(const char *input)`；可选 `void lite_helper_free(char *out)`；UTF-8 字符串（通常 JSON）。
- `build` → `<name>-<ts>.so` + manifest；`run` 调最新；`wrap` 写 `<name>.lua` + `.tool.json`，`schemas()` 自动发现。
- Wrapper 返回 `{ run = function(args, env) ... end }`；`env` 有 `cwd/helper_dir/scope/ffi/load(name)/call(name,input)`。
- 新 build 用新路径，免重启；也可 `bash` 直接 `cc -shared -fPIC ...` 或用 `luajit -e` 加载。动态工具需审批。

## 8 能力原则

不要把能力全硬编码进工具。给模型**手和眼睛**：bash、文件、编译器、系统 `.so`、FFI、进程/网络、X11/xdo、`native`；长尾能力让模型现场组合，harness 守审批/沙箱边界。

## 9 测试

`check_deps.sh` / `auto_unit.lua` / `tui_smoke.sh` / `serve_smoke.sh`；视觉用 `tmux capture-pane`，失败存 `artifacts/`。
