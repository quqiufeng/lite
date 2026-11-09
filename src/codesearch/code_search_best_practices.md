# 代码搜索最佳实践：用 how-to-read-code 方法论探索开源项目

> 本文是 **code search 系统的使用最佳实践**。
> 把 codedump《如何阅读源代码》方法论（agent skill: [lichuang/how-to-read-code](https://github.com/lichuang/how-to-read-code)）
> 作为工作流骨架，把 lite 的 codesearch（`helper/codesearch.lua` + 项目 `kv/`）作为检索底座，
> 目标：**有纪律、有真相、有横向参照地**探索一个陌生开源项目。
>
> lite 的实现、命令和依赖见 `README.md`；本文只讲「怎么用才高效、才不出错」。

---

## 0. 一句话原则

**用方法论定方向，用搜索做证据；搜索是静态证据（`[static]`），运行/断点才是真相（`[verified]`）。**

> **默认规则**：用户没有给出明确问题/指令时，**不要反问**，直接按「**整体架构（横向）→ 子模块下钻（纵向）**」推进。
> 只有用户给出了具体问题时，才聚焦该问题读取。

- 代码搜索 = 快、全、可对比的**静态结构与关系**检索。
- how-to-read-code = **目的界定** + **运行时验证**。
- 两者互补：搜索治「列文件猜架构」，方法论治「有片段无理解」。

---

## 1. 最佳实践速查（先看这个）

| # | 实践 | 说明 |
|---|---|---|
| 1 | **先定目的再搜；无明确指令则默认「整体架构→子模块」** | 有明确问题就聚焦它（问一句即可）；**用户未给明确目的时不要反问**，默认先从整体架构（横向）起手，再逐个下钻子模块（纵向） |
| 2 | **搜索结果是 `[static]`，不是真相** | `search`/`callgraph`/`dataflow` 本质静态分析；承重结论必须能跑出来才算 `[verified]` |
| 3 | **运行时栈反查，别沿路径读文件** | 断点 `bt` 拿到真路径后，对每帧 `context <frame> --depth 2` 秒懂角色（最大提效点） |
| 4 | **用扇入扇出客观分主线/支线** | `callgraph`：高扇入=公共接口（主线，纵读）；低扇入=支线（黑盒，只记接口） |
| 5 | **数据类型先于代码** | `--kind struct` 拿类型 + `dataflow <field>` 得「谁创建/持有/改」——数据结构定义架构 |
| 6 | **测试即现成场景** | `--file test` / `snippet <test>`：跑一个测试胜过读十个文件 |
| 7 | **跨项目提问几乎免费** | `cross-search` 一条命令对比 nginx/redis/sqlite/linux/postgres 的同类实现 |
| 8 | **引用用 `file:symbol`，行号仅参考** | 版本免疫 |
| 9 | **无产出不算读过** | 每阶段留下图/笔记/repro；最终交付结构化读码报告 |
| 10 | **索引纪律是前提** | index+vector 配套、串行、BATCH=16、老缓存先 chown，否则搜索结果不可信 |

---

## 2. 命令约定

```bash
ACS=./ai_code_search.sh          # 统一入口（index/vector/search/snippet/dataflow/callgraph/cross-search）
CQ=./tools/cache_query           # KV Cache 查询（exact/symbol/context/search，走 /memory，不需向量）
VS=./tools/vector_search         # 语义搜索引擎（需向量）
<cache> = /opt/code_caches/{project}_cache      # 分析目录
<ns>    = /code/{project}                        # KV 命名空间
```

| 需求 | 命令 |
|---|---|
| **探索前置检查**（索引/向量/HNSW/KV） | `$ACS check <cache> [project]` |
| 语义搜索（自然语言→file:line，默认 brief） | `$ACS search <cache> "<query>" [n] [--rich|--callgraph|--kind|--lang|--file]` |
| 单函数完整角色（caller/callee/调用链/dataflow） | `$CQ <fn> --repo <ns> --type context --depth N` |
| **批量符号关系（agent 友好）** | `./tools/ctx.py <ns> <fn> [fn2 ...] [--depth N]`（只回吐 符号+caller/callee 名） |
| **精简输出** | `$CQ <fn> --repo <ns> --type context --brief`（同上，单条） |
| 精确符号 | `$CQ <fn> --repo <ns> --type symbol` |
| 片段相似实现 | `$ACS snippet <cache> <code_file> [n]` |
| 变量/字段级数据流 | `$ACS dataflow <cache> <var>` |
| 调用图 | `$ACS callgraph <cache>`（看 `call_graph.json`） |
| 跨项目对比 | `$ACS cross-search "<query>"` |

> **约定**：`search` 默认 **brief**（只输出 `[n] name (score)` + `Location: file:line`），适合架构扫描；
> 需要完整定义/代码上下文时显式加 `--rich`。**探索前先跑 `$ACS check <cache> <project>`**，
> 确认 chunks/向量/HNSW 齐全且 KV 是否已导入（未导入则 `context/symbol` 不可用）。

---

## 3. 证据分级（最容易被违反的纪律）

- **`[static]`**：一切来自 `search` / `callgraph` / `dataflow` / `snippet` / `context` 的结果。
  即使用了 Jina 向量，也是静态分析，**不能标 `[verified]`**。
- **`[verified]`**：真实 build + 断点 backtrace / 测试实跑观测到的路径与变量值。
- **规则**：报告每条承重结论二选一标注；若是 `[static]`，附「如何验证」的步骤。
  若大部分结论都会是 `[static]`，要么去 Phase 1 把环境跑起来，要么在报告里明说。

---

## 4. Phase → 命令映射（工作流骨架）

| Phase | 用 code search 怎么做 | 证据 |
|---|---|---|
| **1 跑起来** | `search <cache> "main entry point"`、`search "build configuration cmake makefile"`、`--file Makefile` 定位入口与构建点 | static |
| **2 明确目的** | **有明确指令**：写进 Scope，用它决定 `--kind/--lang/--file` 过滤。**无明确指令（默认）**：不反问，直接进入「整体架构 → 子模块」探索路径 | — |
| **3 主线/支线** | `callgraph` 按扇入判主线；`context <fn>` 看单函数角色；支线只记接口（黑盒） | static |
| **4 纵横** | 横：`cross-search` + `--kind struct` 拼组件图，`call_graph.json` 看模块依赖；纵：`context <fn> --depth 3` 展开一条链 | static |
| **5 情景分析** | 断点 backtrace 得真相 `[verified]` → 对每帧 `context <frame> --depth 2` / `--rich` 秒懂角色 | verified |
| **6 测试用例** | `search "<module>" --file test`、`snippet <cache> <test_file>`，把测试当场景入口 | static |
| **7 数据结构** | `search "<概念>" --kind struct` 拿类型；`dataflow <field>` 直接产出「谁创建/持有/改」表 | static |
| **8 主动提问** | `cross-search "<机制>"` 对比其他已索引项目；回答「别人怎么做 / 我会不会这么设计」 | static |
| **9 写报告** | 引用 `file:symbol`，逐条标 `[verified]/[static]` | — |

---

## 5. 三个提效机制

### 机制 A：verified 闭环（最大增量）
运行时栈是唯一真相，但单帧看不懂。拿到栈后**立即反查每帧**：

```
断点 → bt 得真实调用栈                         # [verified]
   ↓ 对每一帧
$CQ <frame> --repo <ns> --type context --depth 2
   → 符号 + callers + callees + call_sites + dataflow
   ↓
「真路径 + 每步角色」→ 报告第 4 节 sequence diagram
```

比读完路径上所有文件快一个数量级，且结论有运行时背书。

### 机制 B：调用图客观分主线/支线
- **高扇入** = 被到处调用 → 公共接口 → 主线，必须纵读；
- **低扇入 + 内部工具** = 支线 → 只记接口，列进报告「黑盒」节。

### 机制 C：跨项目提问
Phase 8 问「同类问题别人怎么解」。`cross-search` 一条命令跨全部已索引项目回答，
是单机 grep / IDE 做不到的独有能力。

---

## 6. 标准工作流（示例：nginx HTTP 请求读路径）

```bash
ACS=./ai_code_search.sh; CQ=./tools/cache_query
NS=/code/nginx; CACHE=/opt/code_caches/nginx_cache

# ── 前置：确保已索引（串行）见 §7 ────────────────────────
$ACS index /opt/nginx $CACHE 4
$ACS vector $CACHE nginx

# ── Phase 2 目的：只关心『从 accept 到 reply 的读路径』────
# 写进 Scope；后续聚焦函数，不展开配置解析等支线

# ── Phase 3/4 横向：组件图 + 入口 ────────────────────────
$ACS search $CACHE "HTTP request phase handler pipeline" 10 --callgraph
$ACS search $CACHE "event loop epoll" 10
$CQ  "ngx_http_process_request" --repo $NS --type context --depth 3

# ── Phase 5/6 纵向：以真实请求/测试为场景 ────────────────
# 在 ngx_http_process_request 下断点，发一个请求，bt 抓栈 [verified]
# 对栈中每帧：
$CQ  "ngx_http_process_request_line" --repo $NS --type context --depth 2

# ── Phase 7 数据结构 ─────────────────────────────────────
$CQ  "ngx_http_request_s" --repo $NS --type search --kind struct
$ACS dataflow $CACHE r            # 字段级追踪 request 指针

# ── Phase 8 提问：其他服务器怎么做 ───────────────────────
$ACS cross-search "HTTP request parser state machine"

# ── Phase 9 写报告：file:symbol + [verified]/[static] ────
```

---

## 7. 前置条件与索引纪律（血泪教训）

1. **index + vector 必须配套**：只跑 `index` 没有向量 → `search` 失效。`$ACS vector` 内含 HNSW 自动验收。
2. **索引任务必须串行**：`code_indexer` worker 临时文件是固定 `/tmp` 名，并行会交叉污染。
3. **向量化 batch 默认 128**；编码失败不写零向量、非零退出，`vector` 校验失败即中止。
   当前只走 CUDA + FP16，不使用 TensorRT。
4. **老缓存 root 属主** → embedder/hnsw 静默写失败；先 `chown -R` 再重建；验收 = `.hnsw` 比 `.bin` 新。
5. **不要指望远程 `git pull`**：远程 `/opt/my_db` 非 git clone；本地改源码→`make`→`scp` 二进制。
6. **两套查询通道**：`$ACS search` 走向量（需向量文件）；`$CQ --type context/symbol` 走 KV Cache（不需向量）。
7. **无法本地运行的项目**：在报告里明说，Phase 5 降级为「测试 + 静态阅读」，**不要隐藏限制**。

---

## 8. 报告模板

```markdown
# Code Reading Report: {project/module}

> [verified] = 运行/断点/测试实测；[static] = 仅静态（含所有 code search 结果）。

## 1. Scope & purpose
- Purpose（用户原话）：...
- Environment：是否本地跑通？构建命令？未跑通原因与降级方案？
- Out of scope：...

## 2. Architecture overview（横向）                    [static]
{mermaid flowchart}；组件与职责

## 3. Core data structures & relationships             [static]
| 结构 | 定义 file:line | 创建者 | 持有者 | 修改处 | 角色 |
来源：`--kind struct` + `dataflow`

## 4. Vertical analysis: {flow}                        [verified]
{sequence diagram，标注 file:symbol}
Observed path（Phase 5 backtrace 摘录，短）：
```
...
```

## 5. Black boxes（有意不展开）
| 接口 | 输入 | 输出 | 作用 | 为何不开（支线理由） |

## 6. Design commentary & open questions（Phase 8）
- 为何选这个数据结构/算法；`cross-search` 显示同类项目怎么做
- 若我来设计会怎么改（至少 1 条）
- 可疑点：死代码/重复/缺错误处理

## 7. Follow-ups
- [ ] 未开黑盒、未覆盖场景、待验证的 [static] 结论
```

---

## 9. 反模式与边界

**应拒绝**：
- 无明确目的、无秩序的乱搜乱读 → 用默认路径「整体架构 → 子模块」有序推进，而非无目标翻文件。
- 只凭 `search` 命中就下架构结论且不跑/不测 → 必须标 `[static]` 并给出验证路径。
- 把搜索/数据流结果标成 `[verified]` → 严重违规。

**边界**：
- code search **不提供运行能力**；Phase 1/5 仍需真实构建 + gdb/lldb。
- 搜索质量受索引质量影响：chunk 缺失 / 向量与 chunks 不同批 → 结果不可信，先修索引（见 §7）。

---

## 10. 真实项目验证（必须）

工具是否"好用"**只能靠真实项目检验**——绝大多数缺陷只在真数据下触发。建议每次改动后跑：

```bash
./tests/validate_tools.sh          # 内置 openresty + linux_723
# 或指定：./tests/validate_tools.sh <name> <cache> <namespace> <symbol> "<query>"
```

不变量（任一失败即非零退出）：
- **向量**：`.bin` 存在、`.hnsw` 新于 `.bin`、`search top1 > 0.3`（防零向量/坏索引）
- **context**：`symbol` 命中、`callees` 非空且**不全自指**（防 call_graph 反向图 bug）
- **dataflow**：合法 JSON、变量数 > 阈值、无 `void`/`return` 噪声键

> 经验：本项目的关键缺陷（UTF-8 abort、cache_import O(n²)、namespace 去重爆炸、
> dataflow 内存/上限、symbol 未导入、`[CACHE]`/embedder 日志污染 stdout、callees 全自指）
> **全部由真实项目暴露**，而非单元测试。

---

## 11. 后续落地建议（可选）

固化为 opencode skill：
- 路径：`.opencode/skill/how-to-read-code-with-search/SKILL.md`
- 内容：§4 的 Phase 映射 + §3 证据分级 + §8 报告模板，附 `templates/report-template.md`
- frontmatter `description` 命中「读一下这个项目 / 分析这个模块 / how does X work internally」
- 前置探测：检测目标项目是否已有 `chunks_meta.jsonl` 与 `vectors/*.hnsw`，缺失则提示先 `index`+`vector`

**一句话**：原 skill 教 agent「怎么读」，本系统给 agent「读得快、看得全、能对比」的检索底座；
合起来 = **有纪律、有真相、有横向参照的代码探索**。
