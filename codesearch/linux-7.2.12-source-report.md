# Linux 7.2.12 内核源码结构报告（lens 索引版）

> 源码 `/opt/linux/src/linux-7.2.12`（63,833 个 `.c/.h`，3,721 万行）
> 索引 `lens project=linux_7212` → `/opt/code_caches/linux_7212_cache`（5.9G）
> 本文所有数字都在 2026-11-13 用 lens + grep 重测过；标 `[verified]` = 本轮实测，
> 标 `[static]` = 读源码得出、未跑程序。上一版本文里对不上的数字已在本轮修正（见 §6.4）。

---

## 0 TL;DR

1. **内核不是一个大程序，是「30 个子系统 + 一个共享头文件层」**。`include/linux/` 1,516 个头是唯一的
   全局部，跨子系统调用必须先在头文件里有声明 —— 这是唯一的防意大利面机制。
2. **子系统之间靠函数指针表调用，不靠直接调用**。7 张表、合计 183 个槽位（§3.1）。所以
   「谁调用了 `vfs_read`」这个问题本身就是错的，正确答案要问「谁填了 `file_operations.read_iter` 这一槽」。
   全树填表者 **1,986** 处 `[verified]`。
3. **静态调用图在表边界必断**。lens 已经把间接调用标出来（`read[via f_op]`、
   `pick_task[via idle_sched_class]`），全索引有 **16,441 处 `"indirect":true`**、**14,147 处 `"via"`** `[verified]`。
   看到 `indirect` 就当「扇出未知」，别当「扇出 = 1」。
4. **四条主路径值得背下来**：`read(2)`→`f_op->read_iter`→`filemap_read`→page cache；
   缺页→`handle_mm_fault`→`filemap_fault`；写回→`submit_bio`（99 个调用点 / 54 个唯一调用者）→`blk_mq_submit_bio`；
   收包→`netif_receive_skb`→协议栈。
5. **启动是 8 级 initcall + 3,261 个 `module_init`**（`[verified]`），顺序由段名决定，不由代码位置决定。

---

## 1 用什么看的：lens 的三种动作和四类失真

### 1.1 索引里到底有什么

| 产物 | 体积 | 规模 | 能回答什么 |
|---|---:|---|---|
| `chunks_meta.jsonl` | 317 MB | — | 每个 chunk 的位置/符号/语言 |
| `chunks_text.txt` | 213 MB | — | 切块后的正文（语义检索的输入） |
| `call_graph.json` | 205 MB | **1,659,126 行**，顶层 146,300 个函数 | 调用者/被调用者/参数实参 |
| `dataflow.json` | 796 MB | — | 函数读了哪些变量、变量流经哪些函数 |
| `code_local_linux_7212.jina.bin` | 1.09 GB | — | 向量 |
| `code_local_linux_7212.jina.bin.hnsw` | 1.19 GB | — | HNSW 图（语义检索近邻） |
| `word_freq.json` | 3.3 MB | 72,974 行 | 关键词打分 |

> 上一版写「调用图 749,584 行、KV 2.6G」，两个数都不对：本轮 `wc -l` 是 1,659,126 行，目录总量 5.9G。
> 记住这点：**索引规模这类数字只能现测**。

### 1.2 三种动作，各管一段

| 动作 | 适合的问题 | 本轮实例 |
|---|---|---|
| `action=context` | 「这个函数的上下家是谁」——最省事，一次给出 callers/callees/定义/解析统计 | `vfs_read` → 3 callers、7 callees、`resolution: local=4 global=5` |
| `action=peek/symbol` | 「这行代码长什么样」——带行号窗口 | `generic_file_read_iter` → `mm/filemap.c:2971` |
| `action=grep` | 「这一槽被填了几次」——作用域受限的正则扫描 | `\.read_iter\s*=` in `fs/` → 73 命中 / 2,369 文件 / 319 ms |
| `action=dataflow` | 「函数碰了哪些变量」 | `vfs_read` → 4 个变量，`f_op` 在 571/572/573 行出现 3 次 |

`dataflow` 对 `vfs_read` 的输出恰好把间接调用暴露得很干净：

```
func vfs_read — 4 var(s)
  pos    line 554  occ=1   fs/read_write.c:554
  read   line 571  occ=1   fs/read_write.c:571
  f_mode line 558  occ=2   fs/read_write.c:558,560
  f_op   line 571  occ=3   fs/read_write.c:571,572,573
```

`f_op` 一行出现三次 = 「三次按表取函数」，就是那三个分支（`read` / `read_iter` / 都没有）。

### 1.3 四类失真，不知道就会读错

1. **裸名解析（bare-name）**。调用图按函数名连边，同名就串。`filemap_fault` 有两个定义
   （`mm/filemap.c:3546` 和 `mm/nommu.c:1626`），lens 标 `[?def 2]`；`do_page_fault` 的 36 个调用点也带着
   `[?def 2]`（各架构同名）。**看到 `?def` 就别断言「唯一实现」。**
2. **间接调用断层**。`file->f_op->read_iter(...)` 在图上只连到名为 `read` 的符号，标 `via f_op`。
   要补全必须换判据（§3.4）。
3. **parent 归属会串**。本轮实测：`ext4_file_read_iter`（`fs/ext4/file.c:130`）在调用图里被记成
   **3 个不同 parent 的被调者**（`ext4_dio_read_iter` / `ext4_forced_shutdown` / `file_inode`），
   而这 6 条记录的调用点行号全在 `file.c:132–147` —— 也就是它自己函数体里。
   → **`function` + `line` 可信，`parent` 在同文件相邻函数间不可信。**
4. **索引会漂移**。`lens symbol` 读 `generic_file_read_iter` 时给了
   `[stale: index copy ≠ disk @2971]` —— 索引里的副本和盘上不一致。要引用**精确行号正文**时，
   以盘上 `read`/`sed` 为准，别以索引窗口为准。

---

## 2 横向：树的形状

### 2.1 目录规模（`[verified]`，本轮 `find`/`wc -l` 实测）

| 目录 | `.c` 文件数 | 角色 | 一句话 |
|---|---:|---|---|
| `drivers/` | 22,247 | 硬件驱动 | 占全树 1/3，但与核心几乎零耦合：只用 `include/linux` 的抽象 |
| `arch/` | 4,236 | 架构相关 | `arch/x86/entry/` 是系统调用与中断的落地处 |
| `tools/` | 3,654 | 用户态工具 | **不在内核里**，可独立编译 |
| `sound/` | 1,887 | ALSA | 半个驱动子系统，但有自己的 core |
| `fs/` | 1,488 | 文件系统 | 156 个顶层条目；VFS 门面只占约 10 个文件 |
| `net/` | 1,472 | 协议栈 | `core/`+`ipv4/`+`ipv6/`+ 各协议，socket 层在 `net/socket.c` |
| `lib/` | 521 | 通用库 | `kobject`、`rbtree`、`idr`、`string`，被全树引用 |
| `kernel/` | 496 | 核心机制 | 调度、fork、信号、时间、cgroup、bpf、trace |
| `security/` | 167 | LSM | SELinux/AppArmor/bpf-lsm，**钩子式**接入 |
| `mm/` | 163 | 内存管理 | 163 个文件撑起 page cache + 分配器 + 缺页 + 回收 |
| `crypto/` | 148 | 密码学 | 算法注册表 + `crypto_*` API |
| `block/` | 76 | 块层 | 只有 76 个文件，却是所有存储的咽喉 |
| `ipc/`、`virt/` | 11 / 11 | SysV IPC / 虚拟化 | vmexit 极薄 |
| `include/linux/` | 1,516 个头 | **真正的接口层** | 全树共享契约都在这里 |

总量：**63,833 个 `.c/.h`、37,214,144 行** `[verified]`。

### 2.2 依赖方向（严格分层，反向依赖 = 编译错误）

```
tools/          用户态，随便依赖谁
   │
drivers/ sound/ fs/ net/ …     子系统们：互相**不** include 对方的内部头
   │
   └──────────────┬────────────────
                  │  只准向上依赖
        include/linux/*.h        1,516 个共享契约
                  │
      kernel/ mm/ lib/ block/    核心设施
                  │
              arch/<arch>/       唯一允许被下层反向看到的东西
```

判「这段代码属不属于核心」的快捷方式：**它 include 谁**。只 include `include/linux/*` 的是可插拔件；
include 了别人私有头的，说明耦合已经发生（内核里这类是少数，且通常被 LTO/Kconfig 约束）。

### 2.3 为什么 `include/linux` 是架构的一部分

1,516 个头文件不是「工具目录」，是**唯一契约层**：`struct file_operations` 在 `include/linux/fs.h:1921`，
`struct vm_operations_struct` 在 `include/linux/mm.h:783`，`struct proto_ops` 在 `include/linux/net.h:181`。
7.x 里连 `super_operations` 都被挪出去了 —— 现在在 `include/linux/fs/super_types.h:83` `[verified]`。
头文件的搬迁本身就是信号：**表结构在继续拆分，别照旧版本的路径写脚本。**

---

## 3 七张函数指针表：内核的「多态」实现方式

### 3.1 槽位实测（`[verified]`，本轮 awk 数 `(*)` 得到）

| 表 | 定义位置 | 槽数 | 实例/填表者 | 谁在用 |
|---|---|---:|---|---|
| `struct file_operations` | `include/linux/fs.h:1921` | **34** | 全树 **1,986** 处 `[verified]` | `vfs_read/write/open/ioctl/mmap` |
| `struct super_operations` | `include/linux/fs/super_types.h:83` | **27** | 每个文件系统类型 | `mount`/`sync`/`evict_inode` |
| `struct inode_operations` | `include/linux/fs.h` | **28** | 每个 FS | `lookup`/`create`/`permission` |
| `struct address_space_operations` | `include/linux/fs.h:401` | **19** | 每个 FS + page cache | `read_folio`/`writepages`/`dirty_folio` |
| `struct vm_operations_struct` | `include/linux/mm.h:783` | **17** | 每个能做 mmap 的对象 | `fault`/`map_pages`/`close` |
| `struct proto_ops` | `include/linux/net.h:181` | **28** | 每种 socket 家族 | `socket`/`sendmsg`/`recvmsg` |
| `struct sched_class` | `kernel/sched/sched.h:2587` | **30** | **5** 个（见 3.2） | `enqueue`/`pick_task`/`task_tick` |

合计 183 个槽。**记住 34 这个数**：`file_operations` 的 34 个槽就是「一切皆文件」的全部语义面。

### 3.2 `sched_class`：唯一一张「实例数固定」的表

其余 6 张表实例数是开放的（任何驱动都能加），`sched_class` 只有 5 个实例，用宏声明 `[verified]`：

| 实例 | 位置 | 策略 |
|---|---|---|
| `stop_sched_class` | `kernel/sched/stop_task.c:99` | 最高优先级，迁移/停机用，用户态不可见 |
| `dl_sched_class` | `kernel/sched/deadline.c:3647` | `SCHED_DEADLINE`，EDF |
| `rt_sched_class` | `kernel/sched/rt.c:2602` | `SCHED_FIFO/RR` |
| `fair_sched_class` | `kernel/sched/fair.c:15670` | `SCHED_NORMAL/BATCH`，EEVDF，**99% 的进程在这** |
| `idle_sched_class` | `kernel/sched/idle.c:572` | `SCHED_IDLE` + idle 线程 |

声明宏在 `kernel/sched/sched.h:2785` 的 `DEFINE_SCHED_CLASS(name)`。
所以 `grep 'struct sched_class [a-z_]* = {'` **一条都搜不到**（本轮实测 exit 1）—— 得搜 `DEFINE_SCHED_CLASS`。
这是「按老写法 grep 会漏」的典型例子。

### 3.3 表的规模对比：为什么不是「面向对象」

- 表数 7，槽数 183 —— 相对 3,721 万行，**极小**。内核用极小的接口面覆盖极大的实现面。
- `file_operations` 填表者 1,986 处，`.read_iter` 这一个槽在 `fs/ mm/ net/` 就填了 **77** 次 `[verified]`
  （fs 73 + mm 2 + net 2，lens grep 各自实测）。

### 3.4 判据替换：读内核调用图的第一原则

`vfs_read`（`fs/read_write.c:554`）的本体只有约 41 行有效代码 `[verified]`：

```c
if (file->f_op->read)
        ret = file->f_op->read(file, buf, count, pos);
else if (file->f_op->read_iter)
        ret = new_sync_read(file, buf, count, pos);   /* → f_op->read_iter */
else
        ret = -EINVAL;
```

lens 对它的判定是诚实但**不够用**的：

```
vfs_read  fs/read_write.c:554  kind=function
callers(3, 3 unique): ksys_read, ksys_pread64, read_code
callees(7, 7 unique): new_sync_read, inc_syscr, add_rchar, access_ok, fsnotify_access,
                      read[via f_op][?def 2], rw_verify_area
resolution: local=4 global=5 ambiguous=1 external=0
```

| 错误读法 | 正确读法 |
|---|---|
| 「`vfs_read` 扇出 7，不调用任何文件系统 → VFS 是死代码」 | 图上必断：`read_iter` 是**间接**调用 |
| 「`vfs_read` 是叶子附近的小函数」 | 真实扇出 = `file_operations.read_iter` 的**填表者数量**（≥77） |
| 「改 `vfs_read` 影响很小」 | 影响 1,986 个填表者里的**所有** read 路径 |
| 「谁调用了 `ext4_file_read_iter`」→ 查 callers 得 0 | 它只出现在 `.read_iter` 赋值处：`fs/ext4/file.c:983` |

**结论句**：读内核的调用图，问题要问「**谁填了这张表的这一槽**」，不是「谁调用了这个函数」。

---

## 4 纵向：四条真实路径（每一步都有本轮 lens 输出）

### 4.1 `read(2)`：从系统调用到 page cache

```
用户 read(2)
  └─ arch/x86/entry/ 系统调用入口（表驱动，不是 switch）
      └─ ksys_read                          fs/read_write.c
          └─ vfs_read                        fs/read_write.c:554      ← 34 槽表的第一跳
              ├─ file->f_op->read()          老式接口（还在，剩得很少）
              └─ new_sync_read               fs/read_write.c:483
                  └─ file->f_op->read_iter   ★ 间接调用，图在这里断
                      └─ ext4_file_read_iter fs/ext4/file.c:130  （填表在 :983）
                          ├─ ext4_dio_read_iter      O_DIRECT 分支
                          ├─ ext4_dax_read_iter      DAX 分支
                          └─ generic_file_read_iter  mm/filemap.c:2971
                              └─ filemap_read        mm/filemap.c:2783
                                  └─ 查 page cache → 没有就 readahead / read_folio
                                      └─ address_space_operations.read_folio（又一次间接）
                                          └─ ext4_read_folio → … → submit_bio
```

lens 对每一跳的回答（`[verified]`）：

| 节点 | 行号 | lens 给出的上下家 | 备注 |
|---|---|---|---|
| `vfs_read` | `fs/read_write.c:554` | callers: `ksys_read`/`ksys_pread64`/`read_code` | 入口只有 3 个，很收敛 |
| `new_sync_read` | `fs/read_write.c:483` | 组装 `kiocb` + `iov_iter`，再 `call_read_iter` | 真正的间接点 |
| `ext4_file_read_iter` | `fs/ext4/file.c:130` | callees: `ext4_dio_read_iter`/`ext4_dax_read_iter`/`generic_file_read_iter`/`ext4_forced_shutdown`/`file_inode`/`iov_iter_count` | 填表在 `file.c:983` |
| `generic_file_read_iter` | `mm/filemap.c:2971` | 直通 `filemap_read` | 索引副本与盘上不一致，已标 stale |
| `filemap_read` | `mm/filemap.c:2783` | 拿 folio → 拷到用户态 | page cache 的主循环 |

**要点**：这条链上有 **3 次间接**（`f_op->read_iter`、`a_ops->read_folio`、块层的 `queue_rq`）。
静态调用图能给出的最长确定路径到 `ext4_file_read_iter` 为止；往后都必须按表追。

### 4.2 缺页 / mmap：`handle_mm_fault` 是真正的分发中心

```
CPU 缺页异常
  └─ do_page_fault（每个架构一份，lens 标 [?def 2]）
      └─ handle_mm_fault        mm/memory.c:6651        ← 82 个调用点 / 18 个唯一调用者
          └─ __handle_mm_fault
              └─ handle_pte_fault
                  └─ do_fault → vma->vm_ops->fault     ★ 间接调用（17 槽表）
                      └─ filemap_fault  mm/filemap.c:3546
                          ├─ do_sync_mmap_readahead    同步预读
                          ├─ do_async_mmap_readahead   异步预读
                          ├─ __filemap_get_folio       查缓存
                          ├─ filemap_read_folio        缺页读入
                          └─ lock_folio_maybe_drop_mmap / i_size_read
```

实测细节（`[verified]`）：

- `handle_mm_fault` 的 82 个调用点里，`do_page_fault`×36、`__do_page_fault`×7、`do_user_addr_fault`×4、
  `do_exception`×4、`do_sparc64_fault`×3 —— **架构代码是最大客户**，这也解释了为什么改它能炸半个 `arch/`。
- `filemap_fault` **有两份定义**：`mm/filemap.c:3546` 和 `mm/nommu.c:1626`。NOMMU 平台走后者。
- 它的 7 个调用者全是文件系统的 `*_filemap_fault`（xfs / f2fs / ceph / gfs2 / ocfs2 / orangefs），
  每家的包装函数都只是在 `filemap_fault` 前后加自己的锁或 COW 处理。
- `resolution: local=20 global=52 ambiguous=7` —— 一个函数里有 7 处「解析不唯一」，别把 `ambiguous`
  当错误，它是超大代码库的常态。

### 4.3 写回 / 块层：`submit_bio` 是唯一的漏斗

```
文件系统 / 直接 IO / swap / 各种日志
  └─ submit_bio                 block/blk-core.c:952
      └─ submit_bio_noacct      记账 + 递归展开
          └─ blk_mq_submit_bio  block/blk-mq.c:3108
              └─ 拿 tag → queue_rq ★ 间接调用（每个驱动一个 request_queue）
                  └─ nvme/scsi/virtio-blk/… 的 queue_rq
```

`submit_bio` 的 callers 是本轮最漂亮的一屏（`[verified]`）：**99 个调用点 / 54 个唯一调用者**，
覆盖了你能想到的所有存储路径 ——

| 来源 | 例子 |
|---|---|
| 文件系统日志 | `xlog_write_iclog`(xfs)×6、`nilfs_segbuf_submit_bio`、`gfs2_log_submit_write` |
| 元数据 | `write_dev_supers`(btrfs)×3、`ntfs_bio_fill_1` |
| 直接 IO | `__blkdev_direct_IO`×6、`dio_bio_submit` |
| 压缩文件系统 | `z_erofs_submit_queue`×5 |
| 加密 | `blk_crypto_submit_bio`、`__blk_crypto_fallback_encrypt_bio`×6 |
| 休眠 | `hib_submit_io_async` |
| 分区/zoned | `__submit_zone_reset_cmd`、`xfs_submit_zoned_bio` |

**判定**：`block/` 只有 76 个文件，但 `submit_bio` 有 54 个唯一调用者（分布在 fs/、drivers/、kernel/、
mm/），所以「块层改动影响面小」是错的 —— 影响面小的是**文件数**，不是**扇入**。

反过来，`submit_bio` 自己只调 5 个不同函数（`submit_bio_noacct`/`bio_set_ioprio`/`count_vm_events`/
`task_io_account_read`/`bio_op`）。**扇入极大、扇出极小**是「咽喉层」的典型形状。

### 4.4 网络：收发各一个漏斗，之后全是表

```
发送: dev_queue_xmit → __dev_queue_xmit  net/core/dev.c:4841 → qdisc → ndo_start_xmit ★间接
接收: 硬件中断 → napi → netif_receive_skb  net/core/dev.c:6543
                        └─ __netif_receive_skb        :6384
                            └─ netif_receive_skb_internal  :6468
                                └─ ptype 链表逐个试 ★间接（packet_type.func）
                                    └─ ip_rcv / arp_rcv / ipv6_rcv …
```

- 收包路径的关键结构是 `struct packet_type` 链表，链表节点里存函数指针 —— 这是除 7 张表之外的
  **第 8 种多态**（散在链表里，不是数组/结构体表）。`proto_ops`（28 槽）只管 socket 层的系统调用面，
  真正的收发走 `tcp_prot`/`udp_prot` 那套 `struct proto`。
- 所以「网络调用图」比文件系统更不可静态化：至少 2 层间接（`ptype->func`、`sk->sk_prot`）。

### 4.5 调度：`pick_next_task` 的间接调用带接收者标注

```
__schedule（kernel/sched/core.c）
  └─ pick_next_task            kernel/sched/core.c:6241
      └─ __pick_next_task
          └─ sched_class->pick_task ★ 间接调用（30 槽表，5 个实例）
              └─ fair_sched_class.pick_task → EEVDF
```

lens 在这里表现很好：callees 里直接写着 `pick_task[via idle_sched_class]×3` ——
**它知道这个间接调用至少有一个可解析的目标**，并把接收者名字带出来了。
这是全索引 14,147 处 `"via"` 标注里最有用的形态：`[via X]` 比裸 `indirect:true` 信息量高一个档。

---

## 5 启动：8 级 initcall 与 3,261 个 `module_init`

| 级别 | 宏 | 段名 | 谁在这 |
|---:|---|---|---|
| early | `early_initcall` | `.initcall.early` | 极早期，几乎只有 x86 特例 |
| 1 | `core_initcall` | `.initcall.1` | 内存、锁、kobject |
| 2 | `postcore_initcall` | `.initcall.2` | bus 基础设施 |
| 3 | `arch_initcall` | `.initcall.3` | 架构设备 |
| 4 | `subsys_initcall` | `.initcall.4` | 子系统（`net/`、`fs/` 大半） |
| 5 | `fs_initcall` | `.initcall.5` | 文件系统类型注册 |
| 6 | `device_initcall` | `.initcall.6` | **绝大多数驱动**（`module_init` 默认落这级） |
| 7 | `late_initcall` | `.initcall.7` | 收尾 |
| — | `*_initcall_sync` | `.initcall.<n>s` | 同级内的第二遍（先全部 async，再全部 sync） |

- 定义在 `include/linux/init.h:284–306` `[verified]`。
- `module_init(...)` 全树 **3,261 处** `[verified]`；内建时它等于 `device_initcall`，编成模块时变成
  `module_init` 段。**同一行代码，两种执行时机** —— 这是读内核源码最容易误解的一处。
- 顺序由**段名排序**决定，不是文件顺序，也不是依赖图。所以「A 一定在 B 之前」只有靠级别差保证，
  同级别内顺序是链接顺序，不可依赖。`*_initcall_sync` 就是给「必须等我这一级全跑完」的人准备的。

---

## 6 lens 用下来的真实结论

### 6.1 它对什么特别省事（本轮实测）

| 场景 | 一条命令 | 耗时 |
|---|---|---|
| 定位函数 + 上下家 | `lens context vfs_read` | 亚秒 |
| 作用域内数赋值点 | `lens grep \.read_iter\s*= fs/` | 319 ms / 2,369 文件 |
| 看某函数碰了哪些变量 | `lens dataflow vfs_read` | 亚秒，输出可直接读 |
| 带行号看代码 | `lens peek 或 symbol` | 亚秒 |

对比：直接 `grep -rn` 全树（95,000 文件）要 600 ms 以上且输出不可控；`call_graph.json` 有 166 万行、
205 MB，用 `jq`/文本工具翻是折磨 —— 这正是上一版报告出错的直接原因（手工从原始 JSON 里数数字）。

### 6.2 它答不了的（必须换工具）

1. **表边界的扇出** —— 得 `lens grep '\.槽名\s*='` 数填表者（§3.4）。
2. **精确行号正文** —— 索引会 stale，用盘上文件。
3. **跨函数的语义因果**（「为什么 O_DIRECT 跳过 page cache」）—— 索引只给结构，不给理由。
4. **`DEFINE_*` 宏生成的符号** —— `sched_class` 五个实例在普通 grep 下**完全隐形**（§3.2），
   得知道去搜宏名。

### 6.3 建议工作流（下次照做）

```bash
# 1 先问结构：这个 symbol 在哪、上下家是谁
lens action=context query=<symbol>
# 2 再问「谁填了这张表」
lens action=grep pattern='\.<slot>\s*=' path=fs/
# 3 需要精确正文 → 回到盘上
sed -n '554,595p' fs/read_write.c
# 4 只有真的要统计全树时才碰 call_graph.json，且用 lens 的 symbol/exact，别手数
```

### 6.4 数字校正表（旧稿 → 本轮实测）

| 项 | 旧稿 | 本轮 `[verified]` | 差异原因 |
|---|---:|---:|---|
| `call_graph.json` 行数 | 749,584 | **1,659,126** | 手工计数/旧索引 |
| 索引总体积 | 「KV 2.6G、向量 2.2G」 | **5.9G**（`du -sh`） | 口径不同且未加向量 |
| `dataflow.json` | 未提 | **796 MB** | 漏项 |
| `file_operations` 填表者 | 1,800 | **1,986** | 疑似按头文件口径数 |
| `.read_iter` 赋值点 | 140 | **77**（fs 73+mm 2+net 2） | 旧数把 `.read` 等其它槽也算进去了 |
| `module_init` 调用点 | 2,978 | **3,261** | 旧树/口径 |
| `include/linux` 头文件 | 1,599 | **1,516** | — |
| `super_operations` 位置 | `include/linux/fs.h` | **`include/linux/fs/super_types.h:83`** | 7.x 拆出去了 |
| `netif_receive_skb` | `net/core/dev.c:6468` | **:6543**（`:6468` 是 `..._internal`） | 行号漂移 |

**教训**：凡「A 点了 B 处」这类数字，必须给能重跑的命令；给不出命令的数字不要写进报告。

---

## 7 设计评论：这套结构为什么成立

1. **极小的接口面 × 极大的实现面**。183 个槽位支撑 3,721 万行。代价是：所有灵活性都压在
   「填表」这一动作上，于是**填错一个槽不报错、只在跑到时才炸**。这也解释了内核为什么大量用
   `WARN_ON`/`BUG_ON`/`static_key` 而不是类型系统。
2. **扇入大、扇出小 = 咽喉层**（`submit_bio`：99 个调用点 / 5 个被调）。咽喉层是改动杠杆最大的地方，
   也是最不该塞逻辑的地方。`blk-mq` 把这些逻辑推到 per-cpu 队列，正是为了不噎住。
3. **间接调用是为了编译期解耦，不是为了运行期快**。retpoline/IBRS 之后每次间接调用都有成本，
   内核用 `static_call`（`sched_class` 之外的热路径）把一部分又抢回直调 —— 这是 5.x 之后的新趋势：
   **能静态化就静态化**。
4. **架构代码是最大客户**（`handle_mm_fault` 的 82 个调用点里 50+ 来自 `arch/`）。所以「跨架构可移植」
   不是抽象得好，而是**抽象点选在极少数几个函数上**（缺页、系统调用入口、上下文切换）。
5. **头文件搬迁是架构演进的足迹**。`super_operations` 从 `fs.h` 挪到 `fs/super_types.h` 说明
   `fs.h` 已经大到编译不动了。判「这块代码最近活跃吗」的捷径：看它有没有被拆出去。

---

## 8 下一步（按性价比排）

| 优先 | 动作 | 为什么 |
|---:|---|---|
| 1 | 把 §4 的四条路径各自补一张「间接点表」（表名 / 槽 / 填表者数 / 是否 `static_call`） | 这张表才是可复用的资产，一次做完四条路径都受益 |
| 2 | 抽 `net/` 的 `struct proto` + `packet_type` 链表，做成第 8/9 张表的槽位统计 | 网络是唯一没有集中表的子系统，缺口最大 |
| 3 | 用 `lens dataflow` 对 `struct file` 的字段做一次写入点普查 | 现在 `vfs_read` 只给了 4 个变量，`struct file` 的字段级流没摸 |
| 4 | 给本文每个数字配一条 `tools/` 下的脚本 | 本轮教训是「手数量错」；固化成脚本后下次只跑不数 |
| 5 | 索引刷新（`lens action=index`）后复核 §6.4 的 stale 项 | 现在 `generic_file_read_iter` 已标 stale |

**别做**：手工翻 `call_graph.json` / `dataflow.json`。796 MB 的 JSON 靠眼睛数，只会再产出一版错报告。

---

## 附录 A 复现命令（全部按本轮实际执行记录）

```bash
cd /opt/linux/src/linux-7.2.12

# 规模
find . -name '*.c' -o -name '*.h' | wc -l                       # 63833
find . -name '*.[ch]' -print0 | xargs -0 cat | wc -l            # 37214144
for d in drivers arch tools sound fs net lib kernel mm; do
  printf '%-8s %s\n' $d $(find $d -name '*.c' | wc -l); done

# 表的槽数（数 struct 体内的 "(*"）
awk '/^struct file_operations \{/{f=1} f&&/\(\*/{c++} f&&/^\};/{print c; exit}' include/linux/fs.h
#   file_operations 34  @ fs.h:1921
#   super_operations 27 @ include/linux/fs/super_types.h:83
#   address_space_operations 19 @ fs.h:401
#   inode_operations 28 @ fs.h
#   vm_operations_struct 17 @ mm.h:783
#   proto_ops 28 @ net.h:181
#   sched_class 30 @ kernel/sched/sched.h:2587

# 填表者
grep -rn --include=*.c -E 'struct file_operations [a-zA-Z_0-9]+ = \{' . | wc -l   # 1986
grep -rnE '\.read_iter[[:space:]]*=' fs/ mm/ net/ | wc -l                        # 77

# 关键行号
# sched_class 实例：普通写法搜不到（exit 1），必须搜宏
grep -rn 'DEFINE_SCHED_CLASS' kernel/sched/*.c   # dl/fair/idle/rt/stop 五个
grep -nE '^(void|int|ssize_t) (submit_bio|blk_mq_submit_bio|__dev_queue_xmit|netif_receive_skb)\(' \
     block/blk-core.c block/blk-mq.c net/core/dev.c
grep -rny 'module_init(' --include=*.c . | wc -l  # 3261
```

lens 侧：

```
lens action=context  query=vfs_read                project=linux_7212
lens action=context  query=handle_mm_fault         project=linux_7212
lens action=context  query=filemap_fault           project=linux_7212
lens action=context  query=submit_bio              project=linux_7212
lens action=context  query=pick_next_task          project=linux_7212
lens action=context  query=ext4_file_read_iter     project=linux_7212
lens action=symbol   query=generic_file_read_iter  project=linux_7212
lens action=dataflow query=vfs_read                project=linux_7212
lens action=grep     pattern='\.read_iter\s*='  path=fs/  project=linux_7212
```

## 附录 B 名词对照

| 名词 | 一句话 | 出处 |
|---|---|---|
| VFS | 文件系统门面，就是 6 张表 + `struct file/inode/dentry/address_space` | `fs/`、`include/linux/fs.h` |
| folio | 多页为单位的内存对象，取代 `struct page` 做缓存基本单位 | `mm/` |
| blk-mq | 多队列块层，`submit_bio` 之后的必经之路 | `block/blk-mq.c` |
| ptype / `struct proto` | 收包分发链表 / socket 协议操作表 | `net/core/dev.c`、`include/net/sock.h` |
| EEVDF | `fair_sched_class` 当前算法（取代 CFS 的 vruntime 规则） | `kernel/sched/fair.c` |
| initcall 段 | 用段名排序的执行阶段，共 8 级 + sync 变体 | `include/linux/init.h:284–306` |
| `static_call` | 把间接调用在引导期改写为直调，5.x 后的优化方向 | `include/linux/static_call.h` |
