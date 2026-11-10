# 代码搜索最佳实践：用 how-to-read-code 方法论探索开源项目

> 本文是 **code search 系统的使用最佳实践**。
> 把 codedump《如何阅读源代码》方法论（agent skill: [lichuang/how-to-read-code](https://github.com/lichuang/how-to-read-code)）
> 作为工作流骨架，把 lite 的 lens（旧名 codesearch，`helper/lens.lua` + 项目 `kv/`）作为检索底座，
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
| 2 | **搜索结果是 `[static]`，不是真相** | `action=search`/`context`/`dataflow` 本质静态分析；承重结论必须能跑出来才算 `[verified]` |
| 3 | **运行时栈反查，别沿路径读文件** | 断点 `bt` 拿到真路径后，对每帧 `action=context query=<frame> depth=2` 秒懂角色（最大提效点） |
| 4 | **用扇入扇出客观分主线/支线** | `action=context` 的 callers/callees + `call_graph.json` 扇入统计：高扇入=公共接口（主线，纵读）；低扇入=支线（黑盒，只记接口） |
| 5 | **数据类型先于代码** | `action=search kind=struct` 拿类型 + `action=dataflow query=<field>` 得「谁创建/持有/改」——数据结构定义架构 |
| 6 | **测试即现成场景** | `action=search file=test` / `query="<test 名>"`：跑一个测试胜过读十个文件 |
| 7 | **跨项目提问几乎免费** | 对每个已索引项目各跑一次 `action=search`，对比 nginx/redis/sqlite/linux/postgres 的同类实现 |
| 8 | **引用用 `file:symbol`，行号仅参考** | 版本免疫 |
| 9 | **无产出不算读过** | 每阶段留下图/笔记/repro；最终交付结构化读码报告 |
| 10 | **索引纪律是前提** | `action=build` 一条龙（index→import→vectorize 配套）、索引任务串行、`batch=128`、老 analysis 目录先 chown，否则搜索结果不可信 |

> **起手式（默认动作）**：`lens action=locate query="<模块/概念>"` —— 命中 + 内联源码窗口
> 一次拿到，不用再为「读一眼」单独发 `read`。要收窄就 `action=peek path=<file> line=N`；
> 只有需要**字面/正则**匹配时才 `action=grep pattern=<re> path=<file|dir>`（整仓 grep 会被护栏拒掉）。

---

## 2. 命令约定

lite 只有**一个入口**：`lens` 工具（旧名 `codesearch`；实现 `helper/lens.lua`，底座 `liblite_codesearch.so`）。
仓库里**没有** `ai_code_search.sh` / `tools/cache_query` / `tools/vector_search` / `tools/ctx.py` /
`tests/validate_tools.sh`，看到旧文档里的这些名字一律按本节映射，不要去调。

```text
lens action=... query=... path=... project=... [max_results] [depth] [kind] [lang] [file] [json]
```

| 字段 | 含义 |
|---|---|
| `action` | `locate` `peek` `grep` `build` `index` `import` `search` `symbol` `context` `exact` `dataflow` `status` |
| `path` | 仓库路径（`index`/`build` 用，默认 cwd） |
| `project` | 项目名（默认仓库目录名）；决定 analysis 目录 `~/.local/share/lite/codesearch/<project>` 与 KV 命名空间 `/code/<project>` |
| `query` | 符号名 / 自然语言 / `exact` 的完整 KV key |
| `depth` | `context` 向上展开调用链深度（0–5） |
| `kind`/`lang`/`file` | 过滤（`function/struct/...`、`c/cpp/python/...`、文件名子串） |
| `json` | 返回原始 JSON（`locate`/`peek`/`grep` 只出文本，源码窗口不适合塞 JSON） |

shell 侧等价写法（一行封装，复制即用；`tools/lua.sh` 是仓库里真实存在的 LuaJIT 入口。
**在 lite 仓库根下执行**——`loadfile("helper/lens.lua")` 是相对路径；换目录用
`LITE_CWD=<lite 仓库根> cs ...`）：

```bash
cs() { LITE_LUA_ARGS="$1" ./tools/lua.sh -e 'local j=require("cjson"); local t=assert(loadfile("helper/lens.lua"))(); print(t.run(j.decode(os.getenv("LITE_LUA_ARGS")), {cwd=os.getenv("PWD")}))'; }
cs '{"action":"status","project":"lite"}'
cs '{"action":"search","query":"event loop epoll","project":"nginx","max_results":10}'
```

| 需求 | 调用 |
|---|---|
| **一步「搜 + 读」（**首选起手式**，省掉一次 `read` 往返）** | `action=locate query="..." [max_results=3] [lines=40] [before=2] [kind=] [lang=] [file=]` → 命中 + 内联带行号源码窗口 + `-- next --`（context/grep 建议）；语义没命中或没向量时自动退回 `symbol`，top1 `score<0.35` 会显式警告 |
| **file:line 定点读** | `action=peek path=<file> line=N [lines=40] [before=5]`，或 `query=<fn>` 让工具自己定位定义处 |
| **作用域 grep（配 cgrep 原生）** | `action=grep pattern=<re> [path=<file|dir>] [fixed=] [ext=] [max_hits=] [per_file=]`；**>3000 文件的目录直接拒扫**（提示先 `locate` 收窄，`LITE_CS_GREP_MAX_FILES` 可放宽） |
| **探索前置检查**（chunks/向量/HNSW/KV 是否齐） | `action=status project=<p>` |
| 语义搜索（自然语言→file:line，默认 brief） | `action=search query="..." max_results=N [kind=] [lang=] [file=]` |
| 单函数完整角色（caller/callee/调用链/dataflow） | `action=context query=<fn> depth=N` |
| 批量符号关系 | 循环调用，或用一个 `lua` 片段在单进程里跑多个 `context` |
| 精确符号 | `action=symbol query=<fn>` |
| 完整 KV key 直查 | `action=exact query=<key>` |
| 片段相似实现 | `action=search query="<这看起来像什么>"`，命中后 `read` 该文件（**没有 `snippet` 子命令**） |
| 变量/字段级数据流 | `action=dataflow query=<fn 或 var>` |
| 调用图 / 扇入排序 | `action=context` 看 callers/callees；全局图读 `<analysis>/call_graph.json`（见下） |
| 跨项目对比 | 对每个已索引项目各跑一次 `action=search project=<p>`（**没有 `cross-search` 子命令**） |
| 全量重建 | `action=build`（index→word_freq→callgraph→dataflow→import→vectorize） |

扇入排序（`call_graph.json` 是 `{caller: {calls: [{function,file,line}]}}`）：

```bash
jq -r '[ .[] | .calls[] | .function ] | group_by(.) | map({f:.[0], n:length})
       | sort_by(-.n) | .[0:10][] | "\(.n)\t\(.f)"' \
   ~/.local/share/lite/codesearch/<project>/call_graph.json
```

> **约定**：`search` 输出是 brief（`[n] name file:line kind score` + 截断签名），适合架构扫描；
> 需要完整定义就 `read` 命中文件或加 `json=true` 取原文。**探索前先跑 `action=status`**，
> 确认 chunks/向量/HNSW 齐全且 KV 已导入（`kv/mem.bin` 缺失则 `context/symbol/exact` 不可用，
> 报错会直接让你跑 `action=build`）。

---

## 3. 证据分级（最容易被违反的纪律）

- **`[static]`**：一切来自 `action=search` / `context` / `dataflow` / `symbol` / `call_graph.json` 的结果。
  即使用了 Jina 向量，也是静态分析，**不能标 `[verified]`**。
- **`[verified]`**：真实 build + 断点 backtrace / 测试实跑观测到的路径与变量值。
- **规则**：报告每条承重结论二选一标注；若是 `[static]`，附「如何验证」的步骤。
  若大部分结论都会是 `[static]`，要么去 Phase 1 把环境跑起来，要么在报告里明说。

---

## 4. Phase → 命令映射（工作流骨架）

| Phase | 用 code search 怎么做 | 证据 |
|---|---|---|
| **1 跑起来** | `action=search query="main entry point"`、`query="build configuration cmake makefile"`、`file=Makefile` 定位入口与构建点 | static |
| **2 明确目的** | **有明确指令**：写进 Scope，用它决定 `kind`/`lang`/`file` 过滤。**无明确指令（默认）**：不反问，直接进入「整体架构 → 子模块」探索路径 | — |
| **3 主线/支线** | `call_graph.json` 扇入判主线；`action=context query=<fn>` 看单函数角色；支线只记接口（黑盒） | static |
| **4 纵横** | 横：跨项目 `action=search` + `kind=struct` 拼组件图，`call_graph.json` 看模块依赖；纵：`action=context depth=3` 展开一条链 | static |
| **5 情景分析** | 断点 backtrace 得真相 `[verified]` → 对每帧 `action=context query=<frame> depth=2` / `json=true` 秒懂角色 | verified |
| **6 测试用例** | `action=search query="<module>" file=test`，把测试当场景入口（命中后 `read`） | static |
| **7 数据结构** | `action=search query="<概念>" kind=struct` 拿类型；`action=dataflow query=<field>` 直接产出「谁创建/持有/改」表 | static |
| **8 主动提问** | 对已索引项目逐个 `action=search project=<p>`，对比其他项目做法；回答「别人怎么做 / 我会不会这么设计」 | static |
| **9 写报告** | 引用 `file:symbol`，逐条标 `[verified]/[static]` | — |

---

## 5. 三个提效机制

### 机制 A：verified 闭环（最大增量）
运行时栈是唯一真相，但单帧看不懂。拿到栈后**立即反查每帧**：

```
断点 → bt 得真实调用栈                         # [verified]
   ↓ 对每一帧
lens action=context query=<frame> project=<p> depth=2
   → 符号 + callers + callees + call_sites + dataflow
   ↓
「真路径 + 每步角色」→ 报告第 4 节 sequence diagram
```

比读完路径上所有文件快一个数量级，且结论有运行时背书。

### 机制 B：调用图客观分主线/支线
- **高扇入** = 被到处调用 → 公共接口 → 主线，必须纵读；
- **低扇入 + 内部工具** = 支线 → 只记接口，列进报告「黑盒」节。

### 机制 C：跨项目提问
Phase 8 问「同类问题别人怎么解」。lite 没有单独的 `cross-search` 子命令：对每个已索引项目
各跑一次 `action=search project=<p>`（`ls ~/.local/share/lite/codesearch/` 看现成项目），
再横向比对结果——这是单机 grep / IDE 做不到的独有能力。

---

## 6. 标准工作流（示例：nginx HTTP 请求读路径）

> 示例假设 nginx 已索引为 `project=nginx`（`action=status project=nginx` 能看到
> `chunks_meta.jsonl` + `.jina.bin/.hnsw` + `kv/mem.bin`）。`cs` 见 §2。

```bash
# ── 前置：确保已索引（串行）见 §7 ────────────────────────
cs '{"action":"build","path":"/opt/nginx","project":"nginx","workers":4}'
cs '{"action":"status","project":"nginx"}'

# ── Phase 2 目的：只关心『从 accept 到 reply 的读路径』────
# 写进 Scope；后续聚焦函数，不展开配置解析等支线

# ── Phase 3/4 横向：组件图 + 入口 ────────────────────────
cs '{"action":"search","query":"HTTP request phase handler pipeline","project":"nginx","max_results":10}'
cs '{"action":"search","query":"event loop epoll","project":"nginx","max_results":10}'
cs '{"action":"context","query":"ngx_http_process_request","project":"nginx","depth":3}'
jq -r '[ .[] | .calls[] | .function ] | group_by(.) | map({f:.[0],n:length})
       | sort_by(-.n) | .[0:10][] | "\(.n)\t\(.f)"' \
   ~/.local/share/lite/codesearch/nginx/call_graph.json    # 扇入排序

# ── Phase 5/6 纵向：以真实请求/测试为场景 ────────────────
# 在 ngx_http_process_request 下断点，发一个请求，bt 抓栈 [verified]
# 对栈中每帧：
cs '{"action":"context","query":"ngx_http_process_request_line","project":"nginx","depth":2}'
cs '{"action":"search","query":"ngx_http_process_request","project":"nginx","file":"test"}'

# ── Phase 7 数据结构 ─────────────────────────────────────
cs '{"action":"search","query":"ngx_http_request_t","project":"nginx","kind":"struct"}'
cs '{"action":"dataflow","query":"ngx_http_request_t","project":"nginx"}'

# ── Phase 8 提问：其他服务器怎么做 ───────────────────────
for p in nginx redis sqlite; do
  cs "{\"action\":\"search\",\"query\":\"HTTP request parser state machine\",\"project\":\"$p\",\"max_results\":5}"
done

# ── Phase 9 写报告：file:symbol + [verified]/[static] ────
```

---

## 7. 前置条件与索引纪律（血泪教训）

1. **index + vector 必须配套**：只跑 `action=index` 没有向量 → 语义 `action=search` 退化/失效。
   `action=build` 一条龙跑 index→word_freq→callgraph→dataflow→import→vectorize，并内含 HNSW 验收。
2. **索引任务必须串行**：`code_indexer` worker 临时文件是固定 `/tmp` 名，并行会交叉污染。
   `action=index fork=true` 只是单次 index 内部的并行，别同时跑两个项目的 index/build。
3. **向量化 `batch` 默认 128**；编码失败不写零向量、非零退出，vectorize 失败即中止 build。
   当前只走 CUDA + FP16，不使用 TensorRT。
4. **老 analysis 目录 root 属主** → embedder/hnsw 静默写失败；先 `chown -R` 再重建；
   验收 = `action=status` 里 `.hnsw` 比 `.bin` 新。
5. **源码在仓库内**（`src/codesearch/`，`lua/ffi/codesearch.lua` 封装），不再依赖远程 `/opt/my_db`；
   `./tools/build.sh` 构建 `build/liblite_codesearch.so`。缺 tokenizers 静态库 / ONNX Runtime / Jina 模型时
   该 target 跳过：索引/查询不可用，但其余构建正常。
6. **两套查询通道**：`action=search` 走向量（需 `.jina.bin/.hnsw`）；`action=symbol|context|exact` 走 KV Cache
   （需 `kv/mem.bin`，不需要向量）。
7. **`dataflow`/`context` 用裸函数名**：`cache_set`、`M.run` 能命中，`M:drop_first` 这种
   带 `:` 的方法名查不到（ctags 里记的是定义处的名字）——查不到先用 `action=symbol` 或
   `action=search` 确认真名。
8. **无法本地运行的项目**：在报告里明说，Phase 5 降级为「测试 + 静态阅读」，**不要隐藏限制**。

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
来源：`action=search kind=struct` + `action=dataflow`

## 4. Vertical analysis: {flow}                        [verified]
{sequence diagram，标注 file:symbol}
Observed path（Phase 5 backtrace 摘录，短）：
```
...
```

## 5. Black boxes（有意不展开）
| 接口 | 输入 | 输出 | 作用 | 为何不开（支线理由） |

## 6. Design commentary & open questions（Phase 8）
- 为何选这个数据结构/算法；跨项目 `action=search` 显示同类项目怎么做
- 若我来设计会怎么改（至少 1 条）
- 可疑点：死代码/重复/缺错误处理

## 7. Follow-ups
- [ ] 未开黑盒、未覆盖场景、待验证的 [static] 结论
```

---

## 9. 反模式与边界

**应拒绝**：
- 无明确目的、无秩序的乱搜乱读 → 用默认路径「整体架构 → 子模块」有序推进，而非无目标翻文件。
- 只凭 `action=search` 命中就下架构结论且不跑/不测 → 必须标 `[static]` 并给出验证路径。
- 把搜索/数据流结果标成 `[verified]` → 严重违规。

**边界**：
- code search **不提供运行能力**；Phase 1/5 仍需真实构建 + gdb/lldb。
- 搜索质量受索引质量影响：chunk 缺失 / 向量与 chunks 不同批 → 结果不可信，先修索引（见 §7）。

---

## 10. 真实项目验证（必须）

工具是否"好用"**只能靠真实项目检验**——绝大多数缺陷只在真数据下触发。建议每次改动后跑：

```bash
./tools/test.sh                    # 单元 + 插件清单 + codesearch 索引/查询块（缺 lib 时整块跳过）

# 真实项目验收：换成已索引的 project（ls ~/.local/share/lite/codesearch/）
P=lite
cs "{\"action\":\"status\",\"project\":\"$P\"}"
cs "{\"action\":\"search\",\"query\":\"event loop poll\",\"project\":\"$P\",\"max_results\":5}"
cs "{\"action\":\"context\",\"query\":\"cache_set\",\"project\":\"$P\",\"depth\":2}"
cs "{\"action\":\"dataflow\",\"query\":\"cache_set\",\"project\":\"$P\"}"
```

不变量（`action=status` / 查询输出里直接核对；目前没有 `validate_tools.sh` 这种自动断言脚本）：
- **向量**：`.jina.bin` 存在、`.hnsw` 新于 `.bin`、`search` top1 `score > 0.3`（防零向量/坏索引）
- **KV**：`kv/mem.bin` 存在（否则 `context/symbol/exact` 报 "KV import missing"）
- **context**：`symbol` 命中、`callees` 非空且**不全自指**（防 call_graph 反向图 bug）
- **dataflow**：`action=dataflow` 输出不是 "not found"，变量列表里无 `void`/`return` 噪声键

> 经验：本项目的关键缺陷（UTF-8 abort、cache_import O(n²)、namespace 去重爆炸、
> dataflow 内存/上限、symbol 未导入、`[CACHE]`/embedder 日志污染 stdout、callees 全自指）
> **全部由真实项目暴露**，而非单元测试。

---

## 11. 后续落地建议（可选）

固化为 opencode skill：
- 路径：`.opencode/skill/how-to-read-code-with-search/SKILL.md`
- 内容：§4 的 Phase 映射 + §3 证据分级 + §8 报告模板，附 `templates/report-template.md`
- frontmatter `description` 命中「读一下这个项目 / 分析这个模块 / how does X work internally」
- 前置探测：`lens action=status project=<p>`，无 `chunks_meta.jsonl` / `.hnsw` / `kv/mem.bin` 则提示先 `action=build`

**一句话**：原 skill 教 agent「怎么读」，本系统给 agent「读得快、看得全、能对比」的检索底座；
合起来 = **有纪律、有真相、有横向参照的代码探索**。
