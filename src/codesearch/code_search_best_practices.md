# 代码搜索最佳实践（内核实战版）

> 本文不是功能清单，是**用 lens 读懂一个大仓库的纪律**。结论全部来自一次真实作业：
> 用 lens 通读 Linux 7.2.12（`/opt/linux/src/linux-7.2.12`，36934 个 `.c` + 26899 个 `.h`），
> 拆成 8 个索引项目，产出源码级架构报告（见 `codesearch/linux-7.2.12-source-report.md`）。
>
> 方法论骨架仍来自 codedump《如何阅读源代码》（agent skill `lichuang/how-to-read-code`）；
> lens 的实现与命令见 `README.md` / `lua/ffi/codesearch.lua`，本文只讲**怎么用才不出错**。

---

## 0. 一句话原则

**搜索给的是「结构坐标」（`[static]`），运行/测试给的是「真相」（`[verified]`）；
lens 的本事是把坐标压缩到三跳以内，而不是替代运行时。**

内核这一次的实测收益排序：

| 动作 | 收益 | 典型耗时 |
|---|---|---|
| `locate`（搜 + 内联源码） | 最高，替代 80% 的 `read` 往返 | 秒级 |
| 指针表反查（ops 实例 grep） | 高，找回间接调用断链 | 秒级 |
| `context` 看扇入扇出 | 高，客观分主线/支线 | 秒级 |
| `dataflow` 看字段生命周期 | 中，专治「谁改了这个值」 | 秒级 |
| `search` 自然语言 | 中，用来找**入口**而不是找答案 | 秒级 |
| 全树重索引 | 低（见 §2），几乎不划算 | 小时级 |

---

## 1. 起手式（三条命令覆盖 90% 的阅读）

```text
lens action=locate query="<概念或符号>" [project=<p>] [max_results=3] [lines=40]
lens action=peek   path=<file> line=N [lines=40] [before=5]
lens action=grep   pattern=<re> path=<file|dir> [fixed=true]
```

- **`locate` 是默认动作**：一次往返拿到命中 + 带行号源码窗口，不用再发 `read`。
  语义没命中或该索引没向量时会自动退回 `symbol`；top1 `score < 0.35` 会打弱匹配警告——
  **警告就是提醒你别当真**。内核实测：`locate query="read_folio address_space_operations"`
  的 top3 分别是 `fs/ext4/verity.c`(0.948)、`fs/netfs/buffered_read.c`(0.891)、
  `fs/ntfs3/inode.c`(0.861)——**都是具体文件系统，没有一个是 VFS 门面**。
  想要门面（`read_mapping_folio`/`filemap_read`）就把 query 写具体，或直接 `symbol`。
- **`peek` 用于二次落地**：`locate` 给的窗口不够，就按 `file:line` 精确开窗，别整文件读。
- **`grep` 只用于字面/正则**（`\.read\s*=\s*`、`EXPORT_SYMBOL\(`）；护栏按「cgrep 真会扫的
  文件数」算（node_modules/dist/build 等先 prune 掉），上限 20000：opencode 这类多包仓
  prune 后 11233 个文件可以全树扫（实测 914 ms），内核树 ~80k 仍会被拒并提示先 locate 收窄。
  全树 grep 的产物是**热度表头**，不是全部命中——`max_hits` 给 5~20 就够定位。

探索任何项目**第一步**永远是对齐索引状态：

```text
lens action=status project=<p>     # chunks / vectors / .hnsw / kv 是否齐、覆盖哪些目录
```

`action` 也可以全省：给了 `pattern`→`grep`、`query`→`locate`、只给 `path`→`peek`、都没有→`status`。

---

## 2. 索引纪律：按子系统切项目，不要索引整棵树

内核这一次的硬教训，**先读这段再动手**：

1. **整棵树不要一个 project**。35 万个 chunk 的单一索引，查询会跨架构、跨子系统污染结果，
   且每次改一点都要重跑几十分钟。正确做法是**按阅读目的切**：
   `linux-fs`(55661 chunk) / `linux-net`(47663) / `linux-kernel`(23952) / `linux-mm`(8975) /
   `linux-security`(4706) / `linux-block`(3107) / `linux-io_uring`(1256) / `linux-ipc`(400)。
   项目名决定 analysis 目录 `~/.local/share/lite/codesearch/<project>` 与 KV 命名空间
   `/code/<project>`，彼此隔离、可并行阅读、可单独重建。
2. **`action=build` 一条龙**（index→word_freq→callgraph→dataflow→import→vectorize），
   别手工分步：只 `index` 不 `vectorize` → 语义搜索失效；只 `import` 不 `index` → KV 是旧的。
3. **索引任务串行**。`code_indexer` 的临时文件是固定 `/tmp` 名，两个 build 并行会交叉污染。
   `fork=true`/`workers=N` 只用在**单次** index 内部。
4. **验收看 `.hnsw` 是否新于 `.jina.bin`**，且 `search` top1 `score > 0.3`；
   零向量/坏索引的表现是「结果全是无关文件」，不报错。
5. **老 analysis 目录 root 属主** → embedder/hnsw 静默写失败，`chown -R` 后重建。
6. **索引是快照，不是源码**。`drivers/` 这次就没进索引（22247 个 `.c`）。
   任何「项目里没有 X」的结论，必须先用 `ls`/`grep` 在**源码树**上复核（§3.1）。

---

## 3. 四条「检索结果 ≠ 事实」的铁律

这四条全部是内核实战中真实踩出来的，违反任何一条，报告就会写出看似有理实则错误的架构结论。

### 3.1 快照偏差：没索引 ≠ 不存在

判定某机制是否存在前，先确认**该目录在索引覆盖范围内**：

```bash
wc -l ~/.local/share/lite/codesearch/<p>/chunks_meta.jsonl
grep -o '"/opt/linux/src/linux-7.2.12/[a-z_0-9-]*' ~/.local/share/lite/codesearch/<p>/chunks_meta.jsonl \
  | sed 's#.*/##' | sort | uniq -c   # 每个索引只覆盖一个顶层目录
```

内核这次 `drivers/` 为 0 →「内核没有驱动框架」这种结论会把整个报告带偏。
写法纪律：**「在本次索引快照内未命中」**，而不是「不存在」。

### 3.2 指针表断链：ops 结构体让 call_graph 静默缺边

内核（以及任何 C 面向对象代码）的调用大量走函数指针：

| 表 | 槽数 | 定义 | 树内规模 |
|---|---|---|---|
| `struct file_operations` | 34 | `include/linux/fs.h` | 2001 个实例（`grep -rn "struct file_operations [a-z_0-9]* *=" --include=*.c`） |
| `struct proto_ops` | 28 | `include/linux/net.h` | 每个协议族一份 |
| `struct super_operations` | 27 | `include/linux/fs/super_types.h` | 116 个 `file_system_type` 挂靠 |
| `struct address_space_operations` | 19 | `include/linux/fs.h` | 每个 inode 后端一份 |
| `struct vm_operations_struct` | 17 | `include/linux/mm.h` | 每个 mmap 提供者一份 |
| `struct sched_class` | 30 | `kernel/sched/sched.h` | 6 个 `DEFINE_SCHED_CLASS` |

`call_graph.json` **没有类型信息**：`file->f_op->read(...)` 在图上完全消失，
`vfs_read` 的 callee 只有 `new_sync_read` / `rw_verify_area`（实测），
看不到任何一个具体文件系统。所以：

```text
# 错：只 context query=vfs_read → 「vfs_read 不调用任何文件系统」
# 对：反查实例，再用 grep 数实现者
lens action=grep pattern="\.read\s*=\s*" path=fs/
lens action=grep pattern="DEFINE_SCHED_CLASS\(" path=kernel/sched
```

工具已在能推断的地方补标注：调用点是 `obj->fn()` / `obj.fn()` 时，边带
`"indirect":true` + `"via":"<接收者>"`，`context` 显示成 `name[via obj]`。
**看到 `[via ...]` 就是提醒你这条边可能混了同名直接调用**，不算精确边。

### 3.3 多架构污染：一定要 `path_prefix`

`arch/` 下有几十份同名函数。整树索引时代实测：`do_page_fault` 扇入 142 条，分布在
arm64(22)/nios2(17)/openrisc(17)/arm(11)/alpha(10)…——**这不是「被 142 处调用」，
是把几十个架构的独立实现混在一起**。

这也是 §2 主张**按目录切项目**的第二个理由：本次 8 个索引各自只覆盖一个顶层目录
（`linux-kernel`→`kernel/`、`linux-fs`→`fs/`、`linux-mm`→`mm/`、`linux-net`→`net/`…），
`arch/` 根本不在索引里，污染从源头消失。所以查 `do_page_fault` 这类架构相关符号时，
**先 `ls` 源码树确认它在不在本次快照内**，别指望 `linux-mm` 能回答 x86 缺页细节。
需要混读时（`fs/` + `block/`）用 `path_prefix` 显式收窄：

```text
lens action=context query=<fn> path_prefix=fs/    # 只过滤 callers/callees，被滤条数见 stats.filtered_out
```

### 3.4 伪符号：扇入榜首常常是垃圾

未净化的 `call_graph.json` 扇入第一可能是 `ntt` 这类不存在的符号（ctags 对宏/汇编/生成代码
误切）。**任何「扇入 top10」先人工扫一遍名字**，`ntt`/`container...`/`void`/`return`/`__fentry__`
一律剔除后再排序。同理 `dataflow`：变量键里出现 `void`/`return`/`__key` 说明该函数切得不干净，
只能当噪声，别据此下「谁改了这个字段」的结论。

---

## 4. 主线/支线：用扇入客观排序，用方向校核

`call_graph.json` 的方向是 **callee → callers**
（实测 `{"efivar_entry_set_get_size": {"calls":[{"function":"efivarfs_file_write"}]}}`
= 前者被后者调用）。方向搞反会把「底层原语」当成「顶层门面」。

```bash
jq -r 'to_entries | map({f:.key, n:(.value.calls|length)}) | sort_by(-.n) | .[0:15][]
       | "\(.n)\t\(.f)"' ~/.local/share/lite/codesearch/<p>/call_graph.json
```

判据：

- **高扇入 + 稳定签名** → 公共接口 → 主线，必须纵读；
- **低扇入 + 单一调用者 + 内部工具** → 支线 → 只记接口，写进报告「黑盒」节；
- 扇入高但**只被同文件调用** → 局部辅助，不是主线。

内核骨架就是靠这条判出来的：`vfs_*` 系列（高扇入、不依赖 f_op）是**稳定门面**，
具体文件系统是**可插拔实现**——这个结论先于任何一次单文件阅读。

---

## 5. 数据结构先于代码：内核的经验

读内核如果按「文件」读，永远读不完；按**数据结构 + 生命周期**读，一天能画出骨架。

| 问题 | 命令 |
|---|---|
| 这个类型长什么样、几个槽 | `locate query="struct address_space"` 或 `search kind=struct` |
| 谁创建 / 持有 / 修改某字段 | `dataflow query=<field 或 fn>` |
| 这个结构是谁的成员 | `grep pattern="struct address_space\s+\w+;"` |

内核那 6 张 ops 表就是**架构本身**：`file_operations`（VFS↔FS）、`address_space_operations`
（page cache↔FS）、`super_operations`（挂载↔FS）、`vm_operations_struct`（mm↔VM 提供者）、
`proto_ops`（socket↔协议族）、`sched_class`（调度器↔策略）。**认全这 6 张表，
内核 60% 的「架构」就解释完了**——它们同时是扩展点、也是 `call_graph` 的断点。

纪律：报告里给每个核心结构一行 `file:line` + 创建者 + 持有者 + 改写点，
凑不齐这一行说明还没读懂，不要往下写结论。

---

## 6. Phase → 命令映射（精简）

| Phase | 动作 | 证据 |
|---|---|---|
| 1 跑起来 | `action=status`；`search query="main entry point"`、`file=Makefile`、`file=test` | static |
| 2 定目的 | 有明确问题就聚焦；**没有就默认「横向架构→纵向一条路径」，不要反问** | — |
| 3 分主线 | §4 扇入排序（先剔伪符号）+ `context depth=2` | static |
| 4 纵横 | 横：`kind=struct` + ops 表；纵：`context depth=3` 展开一条链 | static |
| 5 拿真相 | 真跑 / gdb `bt`，对每帧 `context query=<frame> depth=2` 秒懂角色 | verified |
| 6 用测试 | `search file=test` / `query="<test 名>"`，跑一个测试胜过读十个文件 | static |
| 7 数据流 | `dataflow query=<field>`（注意 §3.4 噪声） | static |
| 8 横向参照 | 对每个已索引项目各跑一次 `search project=<p>`（没有 cross-search 子命令） | static |
| 9 写报告 | `file:symbol` 引用 + `[static]`/`[verified]` 逐条标注 | — |

---

## 7. 证据分级与引用

- **`[static]`**：`search` / `locate` / `context` / `dataflow` / `symbol` / `call_graph.json`
  的一切结果——**即使用了向量，也只是静态分析**。
- **`[verified]`**：真实构建 + 断点 backtrace / 测试实跑观测到的路径与变量值。
- 承重结论必须二选一标注；标 `[static]` 的必须附「怎么验证」的步骤。
- 引用写 `file:symbol`（如 `fs/read_write.c:vfs_read`），**行号只作参考**，版本无关。

内核那次报告能立住，全靠 6 张 ops 表的槽数 / 实例数、`do_page_fault` 的 arch 分布这类
**可复跑的命令输出**，而不是「我觉得它大概是这样」。

---

## 8. 报告模板

```markdown
# Code Reading Report: {project/module}

> [verified] = 运行/断点/测试实测；[static] = 仅静态（含所有 code search 结果）。

## 1. Scope & method
- 用户原话目的：...
- 索引快照：project 名 / chunk 数 / 覆盖目录 / **明确未覆盖的目录**
- 能否本地构建运行？不能则说明降级方案

## 2. Architecture overview（横向）                              [static]
{mermaid}；分层与边界；稳定门面 vs 可插拔实现

## 3. Core data structures                                        [static]
| 结构 | 定义 file:line | 槽数/字段 | 创建者 | 持有者 | 改写点 | 角色 |

## 4. Extension points（ops 表 / 注册表）                          [static]
| 表 | 定义 | 槽数 | 实例数 | 谁注册 | 断链影响 |

## 5. Vertical analysis: {一条路径}                               [verified]
{sequence}，每步 file:symbol；Observed path（backtrace 摘录，短）

## 6. Black boxes（有意不展开）
| 接口 | 输入 | 输出 | 为何不开 |

## 7. Design commentary
- 为何这样设计；其他已索引项目怎么解同一个问题（§6 Phase 8）
- 若我重来会改什么（至少 1 条）
- 可疑点：死代码 / 重复实现 / 缺错误处理

## 8. Follow-ups
- [ ] 未开黑盒、未验证的 static 结论、待补索引的目录
```

---

## 9. 反模式

- **索引整棵树再问问题** → 慢，且结果互相污染（§2）。
- **只看 `search` 命中就下结构结论** → 必须有 `locate`/`peek` 的源码窗口或 grep 计数兜底。
- **把 `[static]` 写成 `[verified]`** → 最严重的一类错误。
- **顺着路径逐个 `read` 文件** → 用 `context` 反查每帧角色，快一个数量级。
- **拿扇入榜首当核心** → 先剔伪符号（§3.4）。
- **把 ops 间接调用当不存在** → §3.2，报告里会漏掉整个实现层。
- **用 `cross-search` / `snippet` / `tools/cache_query` 这类旧名字** → 不存在，
  等价动作见 §1/§6（对每个项目各跑一次 `search`）。

---

## 10. 验收：改完 lens 必须用真实项目跑

单元测试抓不到内核级缺陷，全部靠真数据暴露（UTF-8 abort、cache_import O(n²)、
namespace 去重爆炸、callees 全自指、日志污染 stdout——都是真实项目炸出来的）。

```bash
./tools/test.sh                                   # 单元 + 插件清单 + codesearch 块

P=linux-fs
lens action=status project=$P
lens action=locate query="writeback dirty inode" project=$P max_results=3
lens action=context query=vfs_read project=$P depth=2 path_prefix=fs/
lens action=dataflow query=vfs_read project=$P
```

不变量：

- **向量**：`.jina.bin` 存在、`.hnsw` 新于 `.bin`、`search` top1 `score > 0.3`；
- **置信度**：每条 `search` 结果带 `confidence`/`confidence_label`/`evidence`；
  `score` 只排序，`confidence` 才是「该不该信」（语义 0.6 + 词元命中 0.25 + 调用图 0.15，
  再乘 test/mock 降权）。top1 是 `low` 就等于「排第一也只是排第一」，改 `symbol`/`grep`；
  词元命中的分母只数实词——冠词/介词/助动词/wh-词（the/how/does/with…）不算 term，也不
  参与名字匹配，否则 `how does the retry backoff work` 的 lex 只有 2/6、置信度被凭功
  能词压低；语义分缺失时从 `score` 减去 kw/caller boost 回推，不拿含 boost 的分当语义证据；
- **KV**：`kv/mem.bin` 存在（否则 `context/symbol/exact` 直接报 "KV import missing"）；
- **context**：callees 非空且**不全自指**（防 call_graph 反向图 bug）；
- **dataflow**：不是 "not found"，且变量键里没有 `void`/`return` 噪声；
- **grep**：`path=fs/` 能扫；`path=.` 在多包仓（prune 后 ≤20000 文件）也能扫，内核树被拒（护栏生效）。
- **降权**：`*.test.ts`/`*.spec.ts`/`__tests__/`/`fixtures/` 与内核 `test/` 同级降权 ×0.85
  （早先只认 `/test` 前缀，JS/TS 仓里 22% 的 chunk 是测试却一次没降过权）。

**一句话**：lens 给的是「读得快、看得全、能横向对比」的坐标系统，
真相永远在运行里；把两者混为一谈，报告就是自欺。
