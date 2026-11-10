# Linux 7.2.12 内核源码级架构报告

> 源码树 `/opt/linux/src/linux-7.2.12`，全文结论标注 `[static]`（源码直读，无构建/无运行）
> 或 `[verified]`（本机实际执行验证）。本报告所有 `file:line` 均对应该树，可直接 `sed -n 'N,Mp' file` 复核。
> 索引：`lens project=linux_7212`（调用图 749,584 行、KV 2.6G、向量 2.2G）。

---

## 0. TL;DR —— 十句话

| # | 结论 | 证据 |
|---|---|---|
| 1 | 规模：63,833 个 `.c/.h`，约 3,721 万行；`drivers/` 一家占 22,247 个 `.c`（约 1/3 行数） | `find`+`cat|wc -l` `[verified]` |
| 2 | 架构是**五个 C 结构体的函数指针表**在撑：`file_operations`(34 槽)、`super_operations`(27)、`address_space_operations`(19)、`vm_operations_struct`(17)、`proto_ops`(28) | `include/linux/fs.h:1921` 等 `[static]` |
| 3 | 全树 **1,800 处** `struct file_operations x = {` —— 内核的「多态」不是继承，是填表 | `grep -rn --include=*.c` `[verified]` |
| 4 | `read(2)` 只做 30 行参数校验，之后**全部**转交 `file->f_op->read/read_iter`，VFS 不知道任何文件系统 | `fs/read_write.c:554` `[static]` |
| 5 | 调用图上 `vfs_read` 看起来「不调任何文件系统」——因为 `f_op->read_iter(...)` 是**间接调用**，静态调用图天然断链 | `[static]`，见 §3.2 |
| 6 | 缺页是唯一让「文件」变「内存」的地方：`handle_mm_fault` → `handle_pte_fault` → `do_fault` → `filemap_fault` | `mm/memory.c:6651` `[static]` |
| 7 | 块层唯一的入口是 `submit_bio()`，之下 `blk_mq_submit_bio` 把 bio 变 request，再经 `queue_rq` 进驱动 | `block/blk-core.c:952`、`block/blk-mq.c:3108` `[static]` |
| 8 | 网络对称：发 `__dev_queue_xmit`(net/core/dev.c:4841)，收 `netif_receive_skb`(6543)，两端都只认 `net_device` 的 ops | `[static]` |
| 9 | 调度器是 5 个 `sched_class` 实例（stop/dl/rt/fair/idle）按优先级串成链，`pick_next_task` 顺着链问 | `kernel/sched/sched.h:2587` `[static]` |
| 10 | 初始化是 **2,978 个 `module_init()`** 挂到 7 级 initcall 段上，`start_kernel` 顺序点火；驱动发现靠这个，不靠目录扫描 | `grep` `[verified]` |

**一句话**：内核 = **少量入口 + 大量填表**。读懂五张表，就懂了 80% 的架构；剩下 20% 是每张表背后的并发与内存模型。

---

## 1. 方法与边界

### 1.1 用什么读的

| 手段 | 目的 | 有效性 |
|---|---|---|
| `lens`（本机自建索引） | 符号/语义/调用图/数据流 | 全树切块成功，`call_graph.json` 749,584 行 |
| `grep -rn` + `sed -n` | 逐行核对，取 `file:line` | 本报告**所有**引用都这样取 |
| 调用图扇入/扇出 | 判断「谁是稳定门面」 | 只能看直接调用，间接调用断链（见 §3.2） |

### 1.2 明确**没**做（这些结论本报告不成立）

- **没有编译**，没有 `vmlinux`、没有 `System.map`、没有跑过任何内核代码 → 全部 `[static]`。
- **没有读 `.config`**：`drivers/` 22,247 个文件里绝大多数在你的机器上不参与编译，本报告的「驱动」结论一律是**源码存在性**，不是运行时行为。
- **没有时序/并发验证**：RCU、per-cpu、seqlock、内存序这些只能靠注释和 `smp_mb` 位置推断，属「读得懂但证不了」。
- **`arch/` 只抽了 x86 的入口**（4,236 个 `.c` 覆盖 20+ 架构，不逐个看）。

### 1.3 复现

```bash
cd /opt/linux/src/linux-7.2.12
grep -rn "^struct file_operations {" include/linux/fs.h    # 表定义
sed -n '554,590p' fs/read_write.c                            # vfs_read 全文
grep -rn "\.read_iter" fs/ext4/file.c                        # 谁填了这张表
# 有索引时（lite 仓库内）：
./tools/run.sh --once "lens locate vfs_read --path /opt/linux/src/linux-7.2.12"
```

---

## 2. 横向：代码在磁盘上怎么分

### 2.1 实测规模（`[verified]`，2026-11-10 实测）

| 目录 | `.c` 文件数 | 角色 | 一句话 |
|---|---:|---|---|
| `drivers/` | 22,247 | 硬件驱动 | 占全树 1/3 的体量，**但与核心几乎零耦合**：只依赖 `include/linux` 的抽象 |
| `arch/` | 4,236 | 架构相关 | x86/arm64/riscv...；`arch/x86/entry/` 是系统调用与中断的落地处 |
| `tools/` | 3,654 | 用户态工具 | **不在内核里**，`perf`/`bpftool`/`objtool`，可独立编译 |
| `sound/` | 1,887 | ALSA | 半个驱动子系统，但有自己的 core |
| `fs/` | 1,488 | 文件系统 | 156 个顶层条目、72 个顶层 `.c`；VFS 门面只占其中约 10 个（`super.c`/`namespace.c`/`open.c`/`read_write.c`/`namei.c`） |
| `net/` | 1,472 | 协议栈 | `core/`+`ipv4/`+`ipv6/`+ 各协议，socket 层在 `net/socket.c` |
| `lib/` | 521 | 通用库 | `kobject`、`rbtree`、`idr`、`string`，被全树引用 |
| `kernel/` | 496 | 核心机制 | 调度、fork、信号、时间、cgroup、bpf、trace |
| `security/` | 167 | LSM | SELinux/AppArmor/bpf-lsm，**钩子式**接入 |
| `mm/` | 163 | 内存管理 | 163 个文件撑起 page cache + 分配器 + 缺页 + 回收 |
| `crypto/` | 148 | 密码学 | 算法注册表 + `crypto_*` API |
| `block/` | 76 | 块层 | 只有 76 个文件，却是所有存储的咽喉 |
| `ipc/`、`virt/` | 11 / 11 | SysV IPC / 虚拟化 | vmexit 极薄 |
| `include/linux/` | 1,599 个头 | **真正的接口层** | 全树共享契约都在这里 |

**读法**：内核不是「一个大程序」，是**约 30 个子系统 + 一个共享头文件层**。`include/linux/*.h` 是唯一天然的全局部，任何跨子系统调用都必须先在这里有声明 —— 这就是内核防止意大利面的机制（没有它早烂了）。

### 2.2 依赖方向（严格分层，反向依赖 = 编译错误）

```
            ┌─────────────────────────────────────────────┐
 userspace  │  syscall ABI（arch/x86/entry/syscalls/）     │
            └───────────────┬─────────────────────────────┘
                            ▼
     ┌──────────────────────────────────────────────────────┐
     │ fs/（VFS） net/（socket） mm/（mmap/brk） kernel/（调度）│  ← 门面层：只认结构体 + 函数指针表
     └───────┬──────────────────┬──────────────────┬────────┘
             ▼                  ▼                  ▼
     ┌───────────────┐  ┌───────────────┐  ┌───────────────┐
     │ 具体 FS (ext4)│  │ 协议 (tcp/udp) │  │ 机制 (page alloc│
     │ 具体驱动      │  │ 具体驱动       │  │  /slab/vma)    │
     └───────┬───────┘  └───────┬───────┘  └───────┬───────┘
             └──────────────────┴──────────────────┘
                            ▼
     ┌──────────────────────────────────────────────────────┐
     │ block/（bio→request）  lib/（rbtree/idr/kobject）      │
     └──────────────────────────────────────────────────────┘
```

**硬规则**：`fs/ext4` 不许 include `net/ipv4` 的头；`mm/` 不知道 `fs/` 的具体实现。跨层只能通过 `include/linux` 里声明的**抽象**。违反 = 编译不过（内核没有 PIMPL 以外的选择）。

### 2.3 一句话记住每个大目录

| 你问的问题 | 去哪看 |
|---|---|
| 「这个文件系统怎么挂进来的？」 | `fs/super.c` + `fs/namespace.c` + 该 FS 的 `fill_super` |
| 「这个设备怎么被发现的？」 | `drivers/base/`（bus/driver/device 模型）+ 该 bus 的 `match()` |
| 「这块内存哪来的？」 | `mm/page_alloc.c`（页）、`mm/slub.c`（小块）、`mm/vmscan.c`（回收） |
| 「这个包怎么发出去的？」 | `net/core/dev.c`（`__dev_queue_xmit`）+ 驱动的 `ndo_start_xmit` |
| 「这个进程为什么不让出 CPU？」 | `kernel/sched/fair.c`（EEVDF）+ `kernel/sched/core.c:__schedule` |
| 「这个 syscall 谁实现的？」 | `arch/x86/entry/syscalls/syscall_64.tbl` → `SYSCALL_DEFINE*` |

---

## 3. 架构的真正骨架：五张函数指针表

### 3.1 表的定义与槽位（`[static]`，逐个数过）

| 表 | 定义处 | 函数指针槽 | 谁填 | 谁调用 |
|---|---|---:|---|---|
| `struct file_operations` | `include/linux/fs.h:1921` | **34** | 每个 FS/字符设备（全树 1,800 处定义） | `vfs_read/vfs_write/open/ioctl/mmap` |
| `struct super_operations` | `include/linux/fs/super_types.h:83` | **27** | 每个 FS 类型一次 | `alloc_super`/`deactivate_locked_super`/`statfs` |
| `struct address_space_operations` | `include/linux/fs.h:401` | **19** | 每个 FS 的 `inode->i_mapping->a_ops` | page cache（`filemap.c`）、回写（`writeback`）、缺页 |
| `struct vm_operations_struct` | `include/linux/mm.h:783` | **17** | 特殊 VMA（驱动 `mmap`、`shmem`、`hugetlb`） | 缺页/回收/mremap 时 `vma->vm_ops->*` |
| `struct proto_ops` | `include/linux/net.h:181` | **28** | 每个 socket family（`inet_stream_ops` 等） | `__sys_accept4/sendto/recvfrom` 等 |
| `struct sched_class` | `kernel/sched/sched.h:2587` | **30** | 5 个实例：`stop/dl/rt/fair/idle` | `pick_next_task`、`enqueue_task` |

**这六张表（五类 + 调度类）承载了全树上千个实现**。数一下实现者就能量化「扩展点有多开放」：

```bash
grep -rn --include=*.c "struct file_operations [a-zA-Z_]* = {" . | wc -l   # 1800
grep -rn "DEFINE_SCHED_CLASS" kernel/sched/*.c                            # 5
```

### 3.2 调用图为什么在这里「断链」（方法论，必须知道）

`vfs_read` 的正文长这样（`fs/read_write.c:554`）`[verified]`：

```c
if (file->f_op->read)
        ret = file->f_op->read(file, buf, count, pos);
else if (file->f_op->read_iter)
        ret = new_sync_read(file, buf, count, pos);   /* → f_op->read_iter */
else
        ret = -EINVAL;
```

静态调用图看到的是「`vfs_read` 调用 `new_sync_read`」，**看不到**它后面其实是 ext4/overlayfs/fuse 里某个具体函数。于是：

| 错误读法 | 正确读法 |
|---|---|
| 「`vfs_read` 不调用任何文件系统 → VFS 是死代码」 | 调用图**按裸名解析**，`f_op->read_iter` 是间接调用，图上必断 |
| 「`vfs_read` 的扇出只有 2，说明它是叶子」 | 它的**真实**扇出 = `file_operations.read_iter` 的实现者数量 |
| 「改 `vfs_read` 影响很小」 | 影响 1,800 个填表者里的**所有** `read` 路径 |

**判据替换**：读内核的调用图，问题要问「**谁填了这张表的这一槽**」，而不是「谁调用了这个函数」：

```bash
grep -rn "\.read_iter\s*=" fs/ mm/ net/ | wc -l    # 140（只数赋值点，仍是下界）
grep -rn "\.read_iter" fs/ext4/file.c              # fs/ext4/file.c:983 .read_iter = ext4_file_read_iter
```

Lua 的 `M.fn()`、C 的 `obj->fn()` 在 lite 的 `call_graph.json` 里会带 `"indirect":true` + `"via":"<接收者>"`，本树索引里这条标注已经存在 —— 看到 `indirect` 就当「扇出未知」处理。

### 3.3 六张表在架构上的位置

```
 用户 read(2)
     │
     ▼
 vfs_read ──f_op->read_iter──► ext4_file_read_iter ──generic_file_read_iter──► filemap_read
                                                                                  │
                                                           a_ops->read_folio ◄────┘
                                                                                  │
                                                                       缺页 ──► filemap_fault
                                                                                  │
                                                                       块层 ──► submit_bio
                                                                                  │
                                                                     queue_rq ──► nvme/scsi 驱动
```

**一条 `read()` 穿过 5 张表**：`file_operations` → (`address_space_operations`) → `vm_operations_struct` → 块层 request → 驱动。这就是内核的分层：每层只知道「下一层的表在哪」，不知道谁填的。

---

## 4. 核心数据结构地图（全部 `file:line` 实测 `[verified]`）

### 4.1 十二个必须记住的结构体

| 结构体 | 定义 | 一句话职责 | 关键字段（读源码时盯这几个） |
|---|---|---|---|
| `task_struct` | `include/linux/sched.h:826` | 进程/线程 = 一个内核栈 + 一套记账 | `state`、`stack`、`mm`、`active_mm`、`sched_class`、`se`、`files`、`nsproxy` |
| `mm_struct` | `include/linux/mm_types.h:1160` | 一个地址空间的全部 | `mmap`(VMA 树)、`pgd`、`mmap_lock`、`map_count`、`rss_stat` |
| `vm_area_struct` | `include/linux/mm_types.h:920` | 一段连续权限相同的虚拟内存 | `vm_start/vm_end`、`vm_flags`、`vm_ops`、`vm_file`、`vm_pgoff`、`anon_vma` |
| `struct page` / `struct folio` | `include/linux/mm_types.h:80` | 物理页元数据（`folio` 是复合页视图） | `flags`、`_refcount`、`mapping`、`index`、`lru` |
| `struct inode` | `include/linux/fs.h:762` | 磁盘上一个对象（文件/目录/设备） | `i_ino`、`i_mode`、`i_size`、`i_mapping`、`i_op`、`i_fop`、`i_sb` |
| `struct file` | `include/linux/fs.h:1255` | **一次** `open()` 的实例 | `f_op`、`f_path`(dentry+vfsmount)、`f_pos`、`f_mapping`、`f_mode`、`f_flags` |
| `struct dentry` | `include/linux/dcache.h:93` | 路径名的内存缓存项 | `d_name`、`d_inode`、`d_parent`、`d_sb`、`d_op`、`d_lockref` |
| `struct super_block` | `include/linux/fs/super_types.h:132` | 一个已挂载的文件系统实例 | `s_op`、`s_root`、`s_dev`、`s_blocksize`、`s_flags`、`s_mounts` |
| `struct address_space` | `include/linux/fs.h:472` | **page cache 实例**（inode 与页之间的桥） | `i_pages`(xarray)、`a_ops`、`host`、`i_mmap`(反向映射)、`nrpages` |
| `struct sk_buff` | `include/linux/skbuff.h:886` | 一个网络包（含头/尾/数据三段指针） | `head/data/tail/end`、`len`、`dev`、`sk`、`protocol`、`cb[]` |
| `struct sock` | `include/net/sock.h:365` | 协议无关的 socket 内核态 | `sk_state`、`sk_prot`、`sk_receive_queue`、`sk_write_queue`、`sk_timer` |
| `struct net_device` | `include/linux/netdevice.h:2155` | 一块网卡 | `netdev_ops`、`flags`、`mtu`、`dev_addr`、`napi` |
| `struct bio` / `struct request` | `include/linux/blk_types.h:210` / `blk-mq.h:105` | 块 IO 的「请求前/请求后」两种形态 | `bi_bdev`、`bi_iter`、`bi_opf` / `q`、`cmd_flags`、`bio`、`mq_hctx` |

### 4.2 一个对象从路径到字节的完整链（本报告最重要的一张图）

```
  "/etc/passwd"  ──namei──►  dentry ──► inode ──► address_space(i_mapping) ──► xarray of folio ──► 物理页
      (字符串)              (缓存项)    (对象)        (page cache 实例)        (索引：页号)      (struct page)
                                  │                                                      ▲
                                  └── i_fop ──► file_operations ◄── open() 生成 struct file ──┘
                                                     │
                                             f_op->read_iter ──► filemap_read 从这里取页
```

**三个「多对一」必须记清**：

| 关系 | 基数 | 后果 |
|---|---|---|
| `file` ↔ `dentry/inode` | 多 : 1 | 同一个 inode 可有 N 个 `file`（N 个 `open`），`f_pos` 各自独立 |
| `inode` ↔ `address_space` | 1 : 1（`inode->i_mapping` 通常指回自身内嵌的 `i_data`） | 页缓存挂在 inode 上，**不是**挂在 `file` 上，所以多进程读同一文件共享页 |
| `address_space` ↔ `folio` | 1 : N | `i_pages` 是 xarray，key = 页号（`index`），缺页就是 `xarray_load(index)` |

### 4.3 关键不变量（源码里反复出现的假设）

1. **`file->f_mapping` 一般等于 `file_inode(file)->i_mapping`**，但设备文件可以是「私有 mapping」（`f_mapping` 可被 `->open` 改写成别的 inode 的）。读到 `f_mapping != i_mapping` 的地方 = 有人在做特殊 page cache（如 `shmem`、`fuse`）。
2. **`inode->i_rwsem` 是写者锁**：`vfs_write` 路径里没有它，写保护靠 `file_start_write()`（`fs/read_write.c:683`）拿的 **sb 级** `s_writers`，粒度是「整个文件系统的写冻结」，不是单文件。
3. **`mmap_lock` 是 VMA 操作的总锁**（读写信号量），缺页快路径只拿读锁；`mmap_region`（`mm/vma.c:2858`）要写锁。看到 `mmap_read_lock` 就知道这段不会改 VMA 树。
4. **`sk_buff` 的 `head/end` 是分配窗口，`data/tail` 是当前有效区间**：任何 `skb_push/skb_pull` 只动 `data`，越界就是内存破坏；`skb->cb` 是 48 字节私有区，跨层复用时必须清零（历史 bug 高发区）。
5. **`struct page` 的 `mapping` 低两位是标志位**（`PAGE_MAPPING_ANON/FLAGS`），所以判断「匿名页」必须 `page_mapping()` 而不是直接比指针 —— `mm_types.h` 附近的注释写得很清楚。

---

## 5. 纵切：一条 `read()` 从用户态走到硬盘（全链路 `file:line`）

### 5.1 存储读路径（10 跳）

| 跳 | 位置 | 做了什么 | 关键判据 |
|---:|---|---|---|
| 1 | `arch/x86/entry/syscalls/syscall_64.tbl` | `read` = 0，落到 `__x64_sys_read` | 表驱动，不是手写汇编分支 |
| 2 | `fs/read_write.c:723` `SYSCALL_DEFINE3(read,...)` | `fdget` → `vfs_read` | `SYSCALL_DEFINE*` 宏负责 `pt_regs` 拆参 |
| 3 | `fs/read_write.c:554` `vfs_read()` | 权限/`access_ok`/`rw_verify_area`/长度截断 | 只有 ~30 行；**`count > MAX_RW_COUNT` 会被截**（2GB 上限） |
| 4 | `fs/read_write.c:554` 尾部 | `f_op->read` 或 `new_sync_read → f_op->read_iter` | 旧接口优先，新 FS 只实现 `read_iter` |
| 5 | `fs/ext4/file.c:130` `ext4_file_read_iter` | 判断 `O_DIRECT`/内联数据，否则走通用路径 | ext4 只在这一层加「direct IO / inline data」特例 |
| 6 | `mm/filemap.c:2971` `generic_file_read_iter` | → `filemap_read` | 通用 page-cache 读 |
| 7 | `mm/filemap.c:2783` `filemap_read` | 批量取页（`filemap_get_pages:2682`）、拷到用户 | `folio_batch` 批处理，一次最多 15 页 |
| 8 | `mm/filemap.c:3546` `filemap_fault`（缺页时才进） | `__filemap_get_folio_mpol:1947` 查 xarray；miss → `read_folio` | 命中 = 纯内存；miss = 触发块层 |
| 9 | `block/blk-core.c:952` `submit_bio` → `:817 submit_bio_noacct` | bio 合并、限流、交给 `blk_mq_submit_bio` | `submit_bio` 是**唯一**块入口 |
| 10 | `block/blk-mq.c:3108` `blk_mq_submit_bio` → `queue_rq` | 分配 `request`，进硬件队列 | plug（`current->plug`）可缓存请求，减少锁 |

最后进驱动：`drivers/nvme/host/apple.c:1007 .queue_rq = apple_nvme_queue_rq` 这类填表。

**这十跳里没有一跳「知道」下一跳的具体实现**，全靠表。这就是为什么「换文件系统不动块层、换硬盘不动 VFS」。

### 5.2 写路径的差异点（源码里只差三处）

| 差异 | 位置 | 含义 |
|---|---|---|
| `file_start_write(file)` / `file_end_write` | `fs/read_write.c:660/683` | 写要拿 sb 级写者计数（防 `remount-ro`/`freeze` 竞态），读不用 |
| `rw_verify_area(WRITE, ...)` | 同上 | 写要做 `mandatory lock`（`flock`）检查 |
| `fsnotify_modify` vs `fsnotify_access` | 同上 | 审计钩子不同 |

其余（`vfs_write` → `f_op->write_iter` → `generic_file_write_iter` → `filemap` 写时缺页 `do_cow_fault`）与读同构。

### 5.3 mmap + 缺页：另一条入口

```
ksys_mmap_pgoff (mm/mmap.c:568)
   └─ mmap_region (mm/vma.c:2858)            ← 建 VMA，拿 mmap_write_lock
        └─ __mmap_region (mm/vma.c:2763)
             ├─ .mmap_prepare 存在（新接口，7.x）
             │    └─ call_mmap_prepare (:2689) → vfs_mmap_prepare (fs.h:2071)
             │         └─ ext4_file_mmap_prepare (fs/ext4/file.c:826)
             │              └─ 填 desc->vm_ops = &ext4_file_vm_ops (:820)
             └─ 否则走老接口 vfs_mmap (fs.h:2063) → f_op->mmap（fs.h:1935）

--- 之后任意一次访问 ---
CPU #PF → exc_page_fault → handle_mm_fault (mm/memory.c:6651)
   └─ __handle_mm_fault (:6417)             ← 逐级补齐 pgd→p4d→pud→pmd
        └─ handle_pte_fault (:6335)         ← pte 为空 = 首次访问
             └─ do_fault (:5964)            ← 有 vm_ops->fault
                  ├─ do_read_fault  (:5840) ── filemap_fault ── 读盘
                  ├─ do_cow_fault   (:5872) ── 写时复制：分配新页 + 拷内容
                  └─ do_shared_fault         ── MAP_SHARED 写
```

> **7.x 的变化（本树实测）**：`ext4` 已经**不再实现** `.mmap`，只填 `.mmap_prepare`（`fs/ext4/file.c:990`）。
> 新接口入参是 `struct vm_area_desc`（`include/linux/mm_types.h:887`）而不是 `vm_area_struct`，
> 好处是驱动只能改**白名单字段**、且在 VMA 合并之前就定型（`mm/vma.c:2685` 注释）。
> 所以 7.2.12 上读到「文件系统没有 `.mmap`」是正常的，别当 bug。

**三个必背事实**（`[static]`）：

1. `do_fault` 开头就检查 `vma->vm_ops->fault` 存不存在；**`VM_MIXEDMAP`/驱动自管 VMA 没有 `fault` 时走 `pte_none` 判断**，否则 `SIGBUS`（`mm/memory.c:5986`）。
2. `MAP_SHARED` 写 = 直接改 page cache 页，最终由回写线程落盘；`MAP_PRIVATE` 写 = `do_cow_fault` 拷一份，**永不落盘**。
3. `mmap_lock` 在读缺页里只拿读锁，所以缺页路径里**不能**改 VMA 树，只能改 PTE —— 这是 `do_fault` 全族都不碰 `vma` 链表的原因。

### 5.4 网络：对称的两条链

**发**：

```
write(2)/sendto(2)
  └─ __sys_sendto → sock_sendmsg → sk->sk_prot->sendmsg
       └─ tcp_sendmsg (net/ipv4/tcp.c:1446) → tcp_sendmsg_locked (:1116)   ← 切段、算窗口
            └─ ip_queue_xmit → ip_finish_output → dev_queue_xmit
                 └─ __dev_queue_xmit (net/core/dev.c:4841)                 ← 选 qdisc/直发
                      └─ sch_direct_xmit (net/sched/sch_generic.c:344)
                           └─ netdev_start_xmit (include/linux/netdevice.h:5404)
                                └─ ops->ndo_start_xmit  ← 驱动填：e1000e/netdev.c:7356
```

**收**：

```
网卡中断 → napi_schedule → net_rx_action (net/core/dev.c:8005)
  └─ __napi_poll (:7810) → n->poll        ← 驱动实现的轮询（NAPI 的「下半部」）
       └─ netif_receive_skb (:6543) → __netif_receive_skb_core (:6061)     ← 分发到协议
            └─ ip_rcv → tcp_v4_rcv → tcp_data_queue                        ← 入 sk_receive_queue
                 └─ tcp_recvmsg (net/ipv4/tcp.c:2932)  ← 用户 recv 时拷贝
```

**判据**：收包是**软中断 + NAPI 轮询**驱动的，不是「中断里直接处理」；`net_rx_action` 有 budget（默认 64/300），超了让出 CPU。发包是**同步**的（`__dev_queue_xmit` 在进程上下文跑），除非 qdisc 排队。

### 5.5 调度：5 个类串成一条链

```
schedule() (kernel/sched/core.c:7362)
  └─ __schedule (:7107)                    ← 关抢占、更新 rq 时钟
       ├─ pick_next_task (:6241) → __pick_next_task (:6149)   ← 按 sched_class 优先级问
       │     stop ▸ dl ▸ rt ▸ fair(EEVDF) ▸ idle              ← DEFINE_SCHED_CLASS 5 个实例
       └─ context_switch (:5475)           ← 切 mm（若跨进程）+ 切寄存器
wake_up_process (:4569) → ttwu → enqueue_task + 必要时 resched_curr
```

**关键不变量**（`[static]`）：`__schedule` 全程持 `rq->lock`，`context_switch` 之前在 `finish_task_switch` 里放锁 —— 所以「切栈之后不能再碰 prev 的栈」。`sched_class` 30 个槽里 `pick_next_task`/`enqueue_task`/`dequeue_task` 是必需项，其余可选（`CONFIG_SCHED_*` 决定填不填）。

### 5.6 初始化：2,978 个 `module_init` 怎么上电

```
start_kernel (init/main.c)
  ├─ setup_arch / mm_init / sched_init / ...
  ├─ do_pre_smp_initcalls (init/main.c:1458)
  │     for (fn = __initcall_start; fn < __initcall0_start; fn++)   ← 7 级段：0..6 + 7s
  └─ run_init_process("/sbin/init")
```

**为什么驱动能被发现**：`module_init(foo_init)` 把函数指针塞进 `.initcall6.init` 段；链接器把这些段按 level 拼成一串，`start_kernel` 顺序点火。**没有目录扫描、没有注册表文件** —— 发现机制就是「链接器 + 段排序」。`grep -rn --include=*.c "module_init(" . | wc -l` = **2,978**（实测）。

**推论**：`drivers/` 里 22,247 个文件，实际被链接进你的 vmlinux 的只由 `.config` 决定；未选中的代码**连编译都不参与**。所以「内核里有多少驱动」这个问法本身是错的，正确问法是「你的 `.config` 选了哪些」。

---

## 6. 设计评注：这份代码为什么长这样

### 6.1 用「填表」换「不用继承」

C 没有虚函数，内核的解法是**结构体里放函数指针 + 首槽放版本/owner**。代价与收益：

| 收益 | 代价 |
|---|---|
| 零运行时开销（一次间接跳转，可内联预测） | 静态分析看不到边（§3.2），IDE 跳转失效 |
| 新 FS/驱动**不改一行核心代码** | 表填错（槽位错、NULL 未判）是内核 CVE 高发区 |
| 二进制层面可裁剪（`#ifdef` 直接删槽） | 表布局不 ABI 稳定，**禁止**跨版本 `struct` 传递 |

**证据**：`file_operations` 34 个槽，但 `vfs_read` 只判 `read` 和 `read_iter` 两个；其余槽（`splice_read`、`uring_cmd`、`remap_file_range`…）由各自的入口按需调用。**表是能力清单，不是必须实现清单** —— 读表时先看「我这个路径用到哪个槽」。

### 6.2 命名即契约

| 前缀 | 语义 | 例子 |
|---|---|---|
| `__` 双下划线 | 调用者必须已持锁 / 已做检查 | `__schedule`、`__handle_mm_fault`、`__dev_queue_xmit` |
| `_locked` / `_nolock` | 锁状态写在名字里 | `tcp_sendmsg_locked`、`alloc_pages_nolock_noprof` |
| `_noprof` | 由宏生成的 profiling 变体 | `__alloc_pages_noprof`(`mm/page_alloc.c:5389`) |
| `vfs_*` | 稳定门面，语义不随 FS 变 | `vfs_read`/`vfs_write`/`vfs_open` |
| `generic_*` / `filemap_*` | 「给大多数 FS 用的通用实现」 | `generic_file_read_iter`、`filemap_read` |
| `do_*` | 真正干活的内层 | `do_fault`、`do_cow_fault` |

**读源码时**：看到 `__` 就去上面找谁持锁；看到 `_locked` 就确认锁不是这层拿的；看到 `generic_` 就是「可以抄的默认实现」。

### 6.3 错误处理是统一风格，不是随意的

```c
ret = f_op->read_iter(...);
if (ret > 0) { fsnotify_access(file); add_rchar(current, ret); }
inc_syscr(current);
return ret;
```

- **负数 = errno**，0 = EOF，正数 = 字节数，全树统一（`fs/read_write.c:554` 可作为模板）。
- `unlikely()` 几乎只包三种东西：参数越界、NULL 检查、`WARN` 前的判断。它**不影响正确性**，只影响布局。
- 资源释放一律 `goto out_*` 阶梯，`out:` 标签数量 ≈ 函数复杂度。看到 5 个以上 `out_xxx` 就该警惕。

### 6.4 并发模型：三层，别混

| 层 | 机制 | 典型位置 | 读法 |
|---|---|---|---|
| 进程上下文 | mutex / rwsem（可睡眠） | `mmap_lock`、`inode->i_rwsem` | 可以 `copy_to_user`、可以 `submit_bio` |
| 软中断/中断 | spinlock / RCU（不可睡眠） | `rq->lock`、`net_rx_action`、`sk_receive_queue` | **禁止**睡眠，`GFP_ATOMIC` 分配 |
| 无锁快路径 | per-cpu / seqlock / RCU | `add_rchar(current,...)`、`net_hotdata` | 只读或单写者，靠内存序 |

**判据**：`in_interrupt()` / `spin_lock_bh()` 出现的地方，后面绝不允许 `kmalloc(GFP_KERNEL)`。这是内核最常见的死锁形态（sleeping in atomic）。

---

## 7. 黑盒（本报告明确不展开的部分）

| 区域 | 为什么没展开 | 想读从哪起 |
|---|---|---|
| `drivers/` 22,247 个文件 | 体量与架构无关，且强依赖 `.config` | `drivers/base/dd.c`（设备-驱动绑定）+ 目标驱动的 `probe` |
| `arch/` 4,236 个文件 | 20+ 架构，且大量是汇编 | `arch/x86/entry/entry_64.S` + `syscall_64.tbl` |
| `security/` LSM | 钩子式，读起来是「到处都有 `security_*`」 | `security/security.c` 的 hook 表 |
| `crypto/` | 注册表 + 算法实现，机械 | `crypto/algapi.c` + `crypto/cipher.c` |
| `sound/` | 半个独立子系统（ALSA 自己的 core） | `sound/core/pcm.c` |
| `tools/` 3,654 | **不是内核**，用户态程序 | 与内核无关，单独看 |
| `bpf/`、`kernel/bpf` | JIT + verifier，独立学科 | `kernel/bpf/verifier.c`（1.4 万行，建议只看 `do_check`） |

---

## 8. 阅读路线（给新人，按周）

| 阶段 | 目标 | 具体动作 | 验收 |
|---|---|---|---|
| 第 1 周 | 建立「表 → 实现」的反射 | 只读 `vfs_read`+`vfs_write`+`filemap_read` 三个函数全文（约 400 行） | 能口述 §5.1 十跳 |
| 第 2 周 | 进程与内存 | `task_struct` 字段扫一遍、`handle_mm_fault` 全族、`mmap_region` | 能解释 `MAP_PRIVATE` 写为什么缺页 |
| 第 3 周 | 存储 | `submit_bio`→`blk_mq_submit_bio`→`nvme_queue_rq`；顺带看 `bio` 的 split/merge | 能说清 plug 的作用 |
| 第 4 周 | 网络 | `tcp_sendmsg_locked` + `__dev_queue_xmit` + NAPI 收包 | 能说清「为什么收包不用中断里干完」 |
| 第 5 周 | 调度 | `__schedule` + 5 个 `sched_class` + EEVDF 的 `vruntime` | 能解释「为什么 `schedule()` 前后不能碰 prev 栈」 |
| 长期 | 按需下钻 | 每个 bug 都从「哪张表填错」开始 | —— |

**反模式**（这三个读法一定浪费时间）：

1. 从 `start_kernel` 顺序往下读 —— 那是 2,978 个 `module_init` 的随机顺序，读完只记得一堆 `xxx_init`。
2. 试图读完 `drivers/` —— 你的 `.config` 只会链接其中极小一部分。
3. 相信静态调用图的「扇出 = 0」—— 见 §3.2，先看表。

---

## 9. 局限与升级路径

| 本报告缺的 | 怎么补上 | 代价 |
|---|---|---|
| 运行时行为验证 | `make defconfig && make -j$(nproc)` 出 `vmlinux`，再用 `perf`/`ftrace`/`bpftrace` 打点 | 首次编译 20–60 分钟、约 30G 磁盘 |
| 并发正确性 | 静态代码 + lockdep 跑一遍（需启动内核） | 需 QEMU |
| 具体 `.config` 下的真实代码量 | `make defconfig` 后看 `vmlinux` 的 `nm` 符号表 | 同上 |
| 各子系统的内部架构 | 本报告只做了 5 条纵切，`bpf`/`cgroup`/`io_uring`/`netfilter` 各有独立设计 | 每个都值得一份报告 |

**当前可升级的最小一步**：`make defconfig && make -j` 之后，本报告所有 `[static]` 都能升级成 `[verified]`——尤其是 §5.1 的十跳，可以用 `perf record -g` 或 `bpftrace -e 'kprobe:filemap_read'` 打出来对照。

---

## 附：一页速查表

```text
read(2)        fs/read_write.c:723 → :554 → filemap.c:2783 → blk-core.c:952 → blk-mq.c:3108
write(2)       fs/read_write.c:667（多 file_start_write）
mmap(2)        mm/mmap.c:568 → mm/vma.c:2858 → 缺页 mm/memory.c:6651 → :6417 → :6335 → :5964
send(2)        net/socket.c → tcp.c:1446 → dev.c:4841 → sch_generic.c:344 → ndo_start_xmit
recv(2)        dev.c:8005 → :7810 → :6543 → :6061 → tcp.c:2932
schedule()     kernel/sched/core.c:7362 → :7107 → :6241 → :5475
初始化         init/main.c:1458（7 级 initcall 段）+ 2,978 个 module_init
表             fs.h:1921(34) super_types.h:83(27) fs.h:401(19) mm.h:783(17) net.h:181(28) sched.h:2587(30)
结构体         sched.h:826 mm_types.h:1160/920/80 fs.h:1255/762/472 dcache.h:93 skbuff.h:886 sock.h:365 netdevice.h:2155
```

**验收命令**（任取一条都能复现本报告的结论）：

```bash
cd /opt/linux/src/linux-7.2.12
sed -n '554,590p' fs/read_write.c                  # §5.1 第 3-4 跳
sed -n '1458,1462p' init/main.c                    # initcall 段遍历
grep -rn --include=*.c "struct file_operations [a-zA-Z_]* = {" . | wc -l   # 1800
grep -rn "^struct file_operations {" include/linux/fs.h                    # 表定义 1921
```

---

*报告生成：源码直读 + `lens` 索引（`project=linux_7212`）；全树 63,833 个 C 文件、3,721 万行；本文所有行号对 `linux-7.2.12`，换版本需重核。*
