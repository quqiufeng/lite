# trace 实现原理 · 依赖 · 能力边界

`trace` 是 lite 自带的动态追踪子系统：**纯 LuaJIT + 内核 ABI**，直接 `perf_event_open` +
tracefs 探针，不依赖 `perf`/`bcc`/`bpftrace`/Python，也不起 Chrome。入口是工具
`helper/trace.lua`，实现在 `lua/trace/`，采样永远在**子进程**里跑。

本文写「它怎么做到的 / 要什么才能跑 / 能做到哪 / 做不到哪」。
快速上手看 `lua/trace/README.md`，代码细节看各文件头注释。

---

## 1. 与 `prof` 的边界（先分层，选错层会白测）

| 层 | 看什么 | 要权限 | 实现 |
|---|---|---|---|
| `trace action=prof` | **lite 自己**哪块慢：工具/API/记忆/prompt/serve/hook | 不要 | 同进程 O(1) 账本（`lua/trace/prof.lua`） |
| `trace mode=oncpu` | CPU 热点在哪个函数（含 C 帧） | root / `CAP_PERFMON` | perf 软件时钟采样 |
| `trace mode=offcpu` | 卡在哪个调用栈、阻塞多久 | 同上 | `sched_switch` 配对 |
| `trace mode=latency` | 某个 syscall/函数 entry→exit 的 p50/p99/max | 同上 | 双探针时间戳配对 |
| `trace mode=folded` | 任意探针命中时的调用栈分布 | 同上 | 探针 + callchain |
| `trace mode=count/samples` | 探针装没装上、字段取没取到 | 同上 | 只读计数器 / 打印 RAW |

一条判据：**「机器在干什么」用 engine（要 root）；「lite 在干什么」用 prof（不要 root）**。

---

## 2. 依赖

### 2.1 运行时（缺一不可）

| 依赖 | 用途 | 缺失表现 |
|---|---|---|
| LuaJIT（`ffi` + `bit`） | 全部系统调用与内存解析 | 插件直接不可用；标准 Lua 跑不了 |
| `syscall` 号 `298` | x86_64 的 `perf_event_open` | 非 x86_64 需改 `lua/trace/engine.lua:22` |
| `syscall` 号 `310` | `process_vm_readv`（`--str` 跨进程读串） | `--str` 退回 `__<name>_val` 或 `<0x...>` |
| root 或 `CAP_PERFMON` | `perf_event_open`、读写 tracefs | 非 root 时插件自动 `sudo -n`；`sudo` 要密码就**直接报错**，不弹 tty |

### 2.2 内核侧（`action=status` 逐条自检）

| 项 | 检查点 | 备注 |
|---|---|---|
| `CONFIG_PERF_EVENTS` | `perf_event_open` 返回值 | 关掉的话连 `oncpu` 都起不来 |
| `CONFIG_FTRACE` | tracefs 已挂载 `/sys/kernel/tracing` | 未挂载要 `mount -t tracefs tracefs …` |
| `CONFIG_TRACEPOINTS` | `events/sched/sched_switch/format` 可读 | `offcpu` 的基座 |
| `CONFIG_KPROBE_EVENTS` | `kprobe_events` 可写 | `kprobe:func` |
| `CONFIG_UPROBES` | `uprobe_events` 可写 | `uprobe:path:sym` |
| `kptr_restrict` | `/proc/kallsyms` 地址是否全 0 | 非 0 时走 `System.map` 退化路 |

tracefs 目录是 `0700 root`：非 root **读不到内容 ≠ 没挂载**，`status` 会分开报。

### 2.3 符号来源（按顺序退化，见 §4.4）

`/proc/kallsyms` → `/boot/System.map-$(uname -r)` → `/boot/System.map`（内核侧）；
`/tmp/perf-<pid>.map` → ELF `.symtab`/`.dynsym` → `.eh_frame` FDE → `模块+文件偏移`（用户侧）。
第一层对 LuaJIT 是 `jitmap.lua` 自动写，对 **Chez AOT 产物（StaticPy）要程序自己写**（`lib/chez-perfmap.scm`，见 §10）。

### 2.4 出图（PNG）

| 库 | 用途 | 缺失表现 |
|---|---|---|
| `libcairo.so.2` | 位图表面、PNG 编码 | 只出 `.svg`，插件明说「PNG 转换失败」，不假装成功 |
| `librsvg-2.so.2` | SVG 渲染 | 同上 |
| fontconfig + Noto Sans CJK | 中文标签 | 中文变方框，图仍出得来 |

三者都走 `ffi.load`（不链进二进制），`lua/trace/svgpng.lua` 自包含单文件，可整份拷走。
`dofile` 只能一次——`ffi.cdef` 重复会 `attempt to redefine`，插件用 `MODCACHE` 缓存。

---

## 3. 架构与调用链

```
模型 / 人
  │  trace(mode=…, probe=…, duration=…)
  ▼
helper/trace.lua            参数归一 + 校验 + 落盘 + 摘要（不含任何内核细节）
  │  找 engine（$LITE_ROOT / 仓库 lua/trace/engine.lua）
  │  非 root → sudo -n；超时；json 时剥 [trace_engine]/[render] 告警行
  ▼
luajit lua/trace/engine.lua   ← 独立 CLI，可脱离 lite 直接跑
  ├── tracefs：装探针（tracepoint / kprobe / uprobe）
  ├── perf_event_open + mmap ring buffer → 解码 → 聚合
  ├── 符号化（kallsyms / System.map / maps / ELF / FDE / perf-map）
  └── 出图：dofile render.lua → SVG → svgpng.lua → PNG（同进程，零子进程）
```

**为什么采样必须放在子进程**（这是设计约束，不是随手）：
`sudo` 前缀只能加在 exec 上；崩溃/死循环不会带走 agent；reboot 语义干净
（主进程不持有任何 perf fd / mmap）；engine 可以单独当命令行工具调试。

---

## 4. 实现原理

### 4.1 事件源：三类探针统一成 tracefs event id

- `tracepoint:group:event`：读 `events/<g>/<e>/id` 与 `format`，**不写** tracefs。
- `kprobe:func[+off]` / `uprobe:path:sym`：往 `kprobe_events` / `uprobe_events` 写
  `p:<name> <def> <fetchargs>`，再从 `events/<grp>/<name>/{id,format}` 读回。
- **uprobe 必须自己算文件偏移**：这台内核的 `uprobe_events` 只认偏移，写符号名直接 `EIO`。
  `engine.lua:elf_sym_offset` 解析目标 ELF 的 `.symtab`/`.dynsym`，取 `st_value + 用户给的 extra`。
- 探针名带本进程 pid：`lite_<pid>_<seq>`。tracefs 是**全局命名空间**，固定前缀会让两个实例
  撞名、先退出的那个 `cleanup` 把还在跑的实例的探针抽走（表现为 `events` 中途归零）。
  `cleanup` 只删「自己的」和「属主进程已消失的」僵尸探针，活人的一律不碰。
- 注册是否成功**以事件目录是否出现为准**，不信 `io.write` 的返回值
  （内核只回 errno，Lua 侧可能仍返回成功）。名额统计必须在 write **之前**取样。

### 4.2 perf ring buffer：手写 ABI

- `perf_event_open(attr, pid, cpu, -1, flags)`，attr 是手工拼的位域
  （`sample_type`、`wakeup_events`、`inherit`、频率模式的 `freq/period`）。
- **目标枚举只有两种合法语义**，混了就采不到：
  - `pid=P, cpu=-1` → per-task 事件，跟一个线程；
  - `pid=-1, cpu=C` → per-CPU 事件，该 CPU 上所有任务共享（噪声也占 ring 槽）。
- `--pid P` = 展开 `/proc/P/L/task` 的每个 tid 各开一条 per-task，覆盖多线程
  （内核 `common_pid` 是 **tid 不是 tgid**）；超过 `MAX_TIDS=256` 时保留 tid 最小的那批并告警。
- `count` 模式例外：在 tgid 上挂**一条** `inherit=1` 的事件，内核把子孙任务计进同一个计数器，
  读父 fd 就是总数。旧的「每 tid 各开一条且都 inherit」会按祖先进制链重复计数，总数虚高几倍。
  采样模式不能开 `inherit`（内核拒绝 mmap），所以走 tid 展开。
- mmap `PAGE * (1 + RING_PAGES)`；`data_offset`/`data_size` 一律读
  `perf_event_mmap_page` 的 1040/1048 偏移（ABI），不假设等于 `PAGE`。
- `data_head`/`data_tail` 是**绝对累加值**，不是环内下标：
  写回时必须写绝对值。曾把 tail 取模写回 → 内核认为用户进度回退 → ring 满 → 大量丢样本。
- 记录可跨环尾：检测到 `off + sz > dsz` 时先拷进 scratch 再解析，绝不线性越界读
  （曾把时间戳读成「丢失计数」）。
- 统计 `PERF_RECORD_LOST(2)` 与 `PERF_RECORD_THROTTLE(5)`，在结果里报 `lost`/`throttled`：
  这两个数不为 0 就说明统计**偏小**，要调大 `ring_size` 或收窄探针。
- 唤醒批 `WAKEUP_BATCH=64`：攒够 64 个样本才 `poll` 一次，别一事件一唤醒。

### 4.3 解码：format 驱动，不硬编码结构体

- 启动时把 `format` 文件解析成字段表：`name/offset/size`，并识别三种特殊形态：
  - `__data_loc`：值是 `u32`，低 16 位=数据起点（相对记录头）、高 16 位=长度 —— 变长字符串；
  - 数组 `char prev_comm[16]` / `char[]`：按 `size` 读固定长度，并用本条 RAW 的字节数封顶
    （不然字段填满无 `\0` 会读到下一条样本，输出乱码）；
  - 指针 `*`：按 8 字节数读。
- `common_type/common_flags/common_preempt_count/common_pid` 是引擎元数据，不进输出。
- `--str FIELD`：字段是**用户态指针**（如 `sys_enter_openat` 的 `filename`）时用
  `process_vm_readv` 跨进程读串；失败回退同一记录里内核自带的 `__<name>_val` 拷贝，
  再失败才回退 `<0x地址>`（至少还能自己拿 gdb 看）。
- 样本记录的内核落盘顺序是固定的，必须按序解：
  `TID → TIME → CPU{u32,u32} → CALLCHAIN{u64 nr, nr×u64} → RAW{u32 len, bytes}`。
  顺序错一位，`common_type` 就读成 0，整轮一条样本都认不出来。
- `common_type` 是 `u16`（事件 id），别按 `u32` 读。

### 4.4 符号化：五层退化

**内核帧**（`hi32 >= 0xffff8000`）：

1. `/proc/kallsyms`，用 16 位小写 hex 字符串比较 —— 64 位地址超出 `double` 的 2^53 精度，
   转 `number` 会错，所以全程**等长字符串字典序**（等价数值序）。
2. 地址全 0（`kptr_restrict≠0` 的非 root）→ `/boot/System.map-$(uname -r)`，再退 `/boot/System.map`。
   同一份数据、明文、已排序；自编内核可读。查用的是哪个源：`engine.lua --ksym`。
3. 命中后算偏移：`off < 0` 或 `off >= 0x20000` 一律返回 `nil`——System.map 是**链接时**地址，
   KASLR 开机的内核帧带整体平移，宁可不给名字也不给错名字。

**用户帧**：`/proc/pid/maps` 二分找模块 → `文件偏移 = addr - map.start + map.off`，得到
`模块名+0x偏移`（可直接喂 `addr2line -e libfoo.so 0xoffset`）。开 `--sym` 再往深走：

1. `/tmp/perf-<pid>.map`：JIT（LuaJIT/Node/JVM）运行时地址表，绝对地址，优先命中；
   Chez AOT 产物的顶层过程也走这张表（AOT 码在匿名可执行区，ELF 里查不到）——
   lite 的输出把**所有**来自这张表的帧都标成 `[jit]`，别误以为是 LuaJIT；
2. 模块 ELF：先按 `PT_LOAD` 把文件偏移折回 vaddr，再在 `.symtab`（strip 后只剩 `.dynsym`）
   二分最近的 `STT_FUNC`；
3. 无符号表 → 解 `.eh_frame` 的 **FDE**（`[pc_begin, pc_end)`）。FDE strip 不掉
   （C++ 异常/栈展开依赖它），于是能把一片地址切成函数框，给出 `sub_<pc_begin>`；
4. 全失败 → 退回 `模块+0x偏移` / `[anon+0x…]`，**不再输出 `[nosym]`**。

`--sym` 的要点：perfprobe 和 engine 用的是同一套退化顺序；`.eh_frame` 解析支持 DWARF32
与常见指针编码（`pcrel` 按记录起点算，`datarel/textrel` 放弃），只求「切出函数边界」，
不求行号。**行号/内联信息只能靠 debuginfo**，没有就只能到函数级。

### 4.5 六种模式

| mode | 机制 | 关键实现点 |
|---|---|---|
| `count` | `read(fd, &u64)` 计数器，不 mmap | 每个 CPU/线程一行；`inherit` 语义见 §4.2 |
| `samples` | ring + RAW 解码，打印前 `limit` 条 | 验证 fetchargs 是否取到（如 `file=` 字符串） |
| `latency` | entry/exit 双探针，按 `comm`（或 `key`）配对 | 直方图给 `avg/p50/p99/max`，配对不上的计入 `unpaired` |
| `folded` | 探针 + callchain → `root;…;leaf count` | 多探针时行首加 `<短探针名>;` 防串栈；跳过 context marker |
| `oncpu` | `PERF_COUNT_SW_CPU_CLOCK`，`freq=true`、`exclude_idle=true` | 周期采样 + callchain，按栈聚合，另出 `comms` 排行 |
| `offcpu` | `sched_switch` 配对：切出时间戳 → 下次切入 | 见下 |

`offcpu` 是唯一需要特殊处理顺序的模式：

- 必须 **per-CPU ring**：`sched_switch` 的 `prev`/`next` 要在同一处看到；按任务挂事件只拿得到
  「切出」那一侧，永远配不上。
- per-CPU ring 各自独立，**drain 顺序 ≠ 事件发生顺序**：必须按时间戳归并重排
  （像 perf 的 `ordered_events`），并压住 `HOLD_NS=200ms` 不结算，等落后的 ring 追上来。
  否则相邻两段阻塞会粘成一段（实测 100ms 睡眠报成 801ms）。
- 起始就已睡下的任务不会产生「切出」事件：用 `/proc/<tid>/stat` 状态 + 内核栈
  **补种**成 `t0` 切出，真切回时自然闭合（否则 `配对=0`）。
- 跨 CPU 迁回的任务单独计 `migrated`，区间本身仍是真实的。
- 内核给的栈天然从 `__schedule`/`finish_task_switch` 开始，头几帧无信息量 → `trim_sched` 剥掉。

### 4.6 folded 是统一契约

所有能出图的模式最终都归到标准 folded：`根;…;叶 次数`，一行一栈。
`--folded-in` 让**外部**采集器走同一入口（`luasamp.lua` 的 Lua hook 采样因此不需要 root），
`render.lua` 只认这一种输入。

`render.lua` 的归一化（三张图共用）：

- 折叠连续重复帧（内核 unwind 在坏栈上会刷几十层同一地址），但 **源码行帧例外**
  ——`fib` 的真递归就是同一行号连续重复，折了会把 14 层压成 1 层；`--collapse` 才强制折；
- 裸用户态地址归并成占位帧（ASLR 下几乎每条都不同，展开会炸成上万节点）；
- 颜色 = 名字的 MD5 前 32 位定色相，用户态冷色 / 内核暖色，**同一函数跨图同色**；
- 出 SVG 后，PNG 由 `svgpng.lua` 用 cairo+librsvg 在**同一进程**转换（2× 图）。

### 4.7 `prof`：进程内账本（另一条路）

`lua/trace/prof.lua` 在 lite 进程内记账，O(1)、异常全静默、`LITE_PROF=0` 可整层关：

- 聚合：`count/err/total/max/min/bytes` + 有界 `recent` 流水 + 有界 reservoir（只喂 `p50/p99`）；
  **`avg/min/max` 走累加，永远精确**，不受 `SAMPLE_MAX` 影响（常见误判）。
- 埋点：`tool:*`、`hook:*`、`api.stream/ttfb/retry`、`http.*`、`memory.*`、`prompt.build`、
  `session.save`、`compact.fold`、`serve.request`。
- 快照 `<memory_dir>/prof.json`，`session_end` 落盘；进程内账本为空时 `action=prof`
  自动退化读快照（因此**先看 `events` 判断读到的是哪一轮**）。

### 4.8 补 Lua 帧的两条路

perf 只能看到 JIT 机器码与 C 帧，纯解释执行的 Lua 帧在 native 栈上根本不存在。

| 路 | 文件 | 做什么 | 代价 |
|---|---|---|---|
| JIT 地址表 | `jitmap.lua` | `jit.util.tracemc` 取 mcode 起址/长度 + `jit.attach("trace")` 取源码行，写 `/tmp/perf-<pid>.map` | 只覆盖 JIT 过的 trace；flush 后地址会复用，要重写 |
| Lua hook 采样 | `luasamp.lua` | `debug.sethook(count)` 取 `file:line`，输出标准 folded | 同进程、要关 JIT（否则钩子不触发）、慢 4~7% |

两条路的产物都能 `engine --folded-in` 出图，第 3 层不分叉。

---

## 5. 能做什么（能力清单）

### 5.1 系统/进程侧（要 root 或 `CAP_PERFMON`）

- **验探针**：`count` 一秒确认 `kprobe/uprobe/tracepoint` 装得上、触发得了。
- **看字段**：`samples` 打印解码后的 RAW，确认 fetchargs（寄存器、字符串、结构体偏移）取对了。
- **测时延**：`latency` 对任意 entry/exit 探针对，按 `comm`/自定义 key 出 `avg/p50/p99/max`，
  适合 syscall、锁、驱动函数。
- **找 CPU 热点**：`oncpu --freq 99 --pid N` → 火焰图/热力图；带 `comms` 排行回答「哪个进程在烧 CPU」。
- **自己起目标（不用先拿到 pid）**：`argv=["dist/translator","x.static.py"]`（不走 shell）或
  `command="... > out.scm"`（整串交 `sh -c`，要管道/重定向时用）→ 插件以**当前用户/当前 cwd/env**
  起进程（`setsid` 独立进程组），取 pid 交给 engine，采完整组收掉。短命目标（1.3 s 的 translator）
  可以直接采；长命目标只采前 `duration` 秒然后收掉，不用等它自己跑完。
  **但短命目标样本少**：1.3 s × 99 Hz ≈ 110 样本 → 单次 1~2% 是噪声，只能看粗粒度；
  要比两个版本，靠重复跑 10+ 次累加，别信单次榜。
- **找卡点**：`offcpu` 回答「睡在哪、阻塞多久」，是 IO/锁/调度问题首选（比 oncpu 更接近用户体感）。
- **任意事件出栈**：`folded` + 自定义探针，看「谁在调用 `do_sys_openat2`」。
- **符号化**：`--sym` 把 `0x55b3…` 变成 `libc.so.6+0x…` / `func+0x1a` / `sub_401156`；
  `--ksym` 单独自检内核符号来源与条数（免 root、不装探针）。
- **出图**：火焰图（可交互 SVG）、热力图、卡点排行；`.png` 直接进汇报材料。
- **重出图**：`action=render json_in=… kind=flame`，毫秒级换图不重采。
- **JIT 帧命名**：`action=perfmap` 让 LuaJIT trace 显示成 `file.lua:123 [tr7]`。

### 5.2 lite 自身侧（不要权限）

- 工具/插件/API/http/记忆/prompt/serve 的耗时、失败次数、输出字节；
- `spans`（谁最贵）+ `recent`（长尾在什么时候）两视角；
- 进程退出后仍可读快照，用于对比 build/reboot 前后。

### 5.3 典型闭环

```text
trace action=status                       # 权限/内核五环/render 依赖过一遍
trace probe=tracepoint:sched:sched_switch mode=count duration=1    # 探针能触发？
trace mode=offcpu duration=5 rank=/tmp/block.png                   # 卡在哪
trace mode=oncpu duration=3 flame=/tmp/cpu.png sym=true            # 热点在哪
trace mode=oncpu argv=["dist/translator","x.static.py"] sym=true   # 目标没在跑：自己起、自己收
trace action=render json_in=/tmp/t.json kind=flame out=/tmp/f.svg  # 换图不重采
```

---

## 6. 做不到 / 边界（明确写出来，避免误判成 bug）

| 限制 | 原因 | 替代 |
|---|---|---|
| 非 root 且无 `CAP_PERFMON` | 内核对 `perf_event_open` 的硬限制 | 配 `sudo -n` NOPASSWD，或有 `perf_event_paranoid` 放宽的场景 |
| 纯解释执行的 Lua 帧 | native 栈上只有解释器 C 帧 | `luasamp.lua` hook 采样 |
| Chez AOT 产物的 lambda/内联代码 | AOT 码在匿名可执行区，perfmap 只能标顶层过程入口 | `STATICPY_PROFILE=source` + `sprof` 出到行（§10.4） |
| 行号 / 内联展开 | 需要 debuginfo，`.eh_frame` 只有函数边界 | `addr2line -e <模块> <偏移>`（engine 已给出文件偏移） |
| KASLR 内核 + 非 root 的精确符号 | `System.map` 是链接时地址，整体平移未知 | 以 root 跑（`/proc/kallsyms` 可读）；或只看导出符号 |
| `strip -s` 后的函数名 | 名字被删了，FDE 只能给 `sub_<地址>` | 保留符号表 / 装 debuginfo / 用 build-id 找 ddebs |
| 内核栈的完整性 | 默认 frame-pointer / ORC 依赖内核编译选项 | 栈被截断时只看得到叶子几帧，不是工具丢数据 |
| 旧事件缺失 | ring 溢出（`lost`/`throttled`） | 调大 `ring_size`（默认 8 页=32KB/CPU）、收窄探针、缩短 duration |
| 跨实例并存 | tracefs 探针名全局唯一 | 已用 `lite_<pid>_` 前缀 + 自愈 cleanup 解决；但同名 kprobe 点位仍受内核限制 |
| 长时间连续采样 | `duration` 夹在 `[0.1,120]` 秒且**阻塞** | 多轮短采样，或用 `count` 长跑 |
| 无 tracefs 的容器 | 宿主未挂载 / 未给 `CAP_SYS_ADMIN` | 在宿主采，或 `--pid` 采目标进程（仍需 perf 权限） |

---

## 7. 已知坑（实现层，改代码前必读）

1. `data_tail` 必须写绝对值；取模写回会让内核判定 ring 满。
2. 记录跨环尾要拷 scratch，不能线性越过 `dsz`。
3. 样本字段顺序固定：CPU 在 CALLCHAIN **之前**；错位后整轮 `events=0`。
4. `common_type` 是 `u16`；`data_loc` 的偏移/长度是 `u32` 的高低 16 位。
5. `mmap` 后必须按 ABI 读 `data_offset/data_size`，不要假设 `=PAGE`。
6. 已 `munmap` 的 ring 不能再 `munmap`（fd/VA 可能已被复用，会把 LuaJIT 堆一起卸掉）。
7. `ffi.cdef` 每进程一次：`render.lua`/`svgpng.lua` 必须缓存 `dofile` 结果。
8. tracefs 探针注册成功与否以 `events/…/id` 是否存在为准。
9. `sym()` 的 `off >= 0x20000` 守卫别删：它挡的是 KASLR 平移导致的错名字。
10. 采自己（未给 `pid` 或等于本进程）时才会自动写 perf-map；采别人要目标进程自己写过。
11. `event` 参数目前**只解析未使用**（`engine.lua:637` 存进 `opt.event` 后无人读）[static]，
    `oncpu` 固定用 `PERF_COUNT_SW_CPU_CLOCK`；要别的 perf 事件得改 `run_oncpu` 的 `src`。
12. 起目标**不能**借用 `capture()`：它外面套 `timeout N`，`$!` 拿到的是 timeout 的 pid →
    采它就永远 0 样本（而且它随目标退出消失，看着像「目标提前退出」）。用 `capture_raw()` 直接
    `sh -c` 起，`$!` 才是 `setsid` 出来的目标本身。
13. 判目标「还活着」**不能只看 `/proc/<pid>/stat` 存在**：目标退出后到父进程 reap 之前是**僵尸**，
    stat 照样在 → 采样会白等到 `duration` 满，报告里看不出是提前结束的。要读 stat 第三字段，
    `Z`/`X` 算已结束（`comm` 可能含空格/括号，从最后一个 `)` 之后取）。且检查频率必须**高于**
    `wait_ready`（per-task 事件没了以后它会一直阻塞到 deadline），所以 oncpu 循环按 100 ms 切片。
14. `command` 里**别写 `exec` 前缀**：`setsid exec …` 会去找名为 `exec` 的程序，目标 50 ms 内就没了；
    想收尾统一由进程组负责（`kill -s TERM -- -<pid>`），不需要 `exec`。

---

## 8. 参数与输出契约

### 8.1 工具参数（`helper/trace.lua` schema）

| 组 | 参数 |
|---|---|
| 动作 | `action=status/run/render/perfmap/prof`（`run` 是默认推断） |
| 探针 | `probe[]`、`entry`/`exit`（latency）、`arg[]`（fetchargs） |
| 采样 | `mode`、`duration`、`freq`、`pid`、`ring_size`、`str`、`key`、`limit` |
| 自己起目标 | `argv[]` 或 `command`（与 `pid` 二选一）、`target_out`（目标 stdout/stderr 落盘，默认 `/dev/null`） |
| 符号 | `sym`、`ksym` |
| 出图 | `flame`/`heat`/`rank`、`heat_top`、`rank_top`、`rank_by=self/incl/count` |
| 复用 | `json`、`json_out`、`json_in`+`kind`+`out`（render） |
| 外部输入 | `folded_in`、`collapse` |
| 进程内 | `path`、`reset`（prof） |
| JIT | `action=perfmap`、`off` |

### 8.2 engine JSON 字段（`json=true`）

| 字段 | 出现在 | 含义 |
|---|---|---|
| `mode` / `probes[]` | 全部 | 本次模式与已装探针 |
| `events` | 全部 | 有效样本/事件数（偏小时看 `lost`） |
| `lost` / `throttled` | 全部 | ring 溢出与内核限流计数 |
| `count` / `rate` / `per_cpu[]` | count | 总数、每秒、按 CPU/tid 明细 |
| `samples[]` | samples | 解码后的原始字段 |
| `paired` / `unpaired` / `overall` / `top[]` | latency/offcpu | 配对率 + 直方图 + 按 key/栈排行 |
| `folded[]` / `stacks` / `frame_dir` | folded/oncpu/offcpu | 折叠栈、栈种类、方向 |
| `freq` / `comms[]` | oncpu | 采样频率、进程排行 |
| `matched/blocked/preempted/unmatched/seeded/migrated` | offcpu | 配对诊断 |
| `elapsed` / `target_exited` | oncpu | 实际采样秒数；`true`=目标先于 `duration` 退出（此时 `elapsed < duration`，样本按真实时长算占比） |
| `sym` / `sym_hits` | 全开 `--sym` | 是否符号化 + 命中次数 |
| `source` / `no_collapse` | folded-in | 外部文件来源、是否折叠递归帧 |

`frame_dir` 决定 `render.lua` 的树方向：`oncpu`/`folded-in` 是 `root-first`（叶在末尾），
engine 自己的 `folded` 是 `leaf-first`。**改这个字段会让三张图上下颠倒**。

---

## 9. 测试与验收

| 层 | 文件 | 覆盖 |
|---|---|---|
| 纯函数/契约 | `tools/auto_unit.lua` | summary 各模式、prof 聚合/落盘读回、参数归一 |
| 符号化 | `tools/trace_check.lua` | `--ksym` 报源与条数；`--sym` 采 spin fixture 出 `hot_alpha`；`strip -s` 后出 `sub_<入口>` |
| 插件契约 | `tools/perfprobe_check.lua` | 同一套 ELF/FDE 退化在 C 侧的实现（25 checks） |
| 真采样 | 不进单测 | 要 root、机器相关；靠 `action=status` + `count` 现场验 |

`tools/test.sh` 的 `== trace ==` 段在拿不到 root 时 **SKIP 而不是 FAIL**：环境问题不算回归。
改了 engine/render 之后，还要至少跑一次真实出图（`--tui --snapshot` 不适用，直接 `read` PNG）。

## 10. 优化 StaticPy 产物（Chez AOT）怎么办

StaticPy 的产物是「Chez AOT 编出的匿名可执行段 + 独立 ELF」。它不像 LuaJIT 有 `jitmap.lua`，
也不像 C 程序有完整符号表——**默认 68% 的样本是 `[anon]`**（translator 实测），
直接看成"热点不可读"。这一章给出把 `[anon]` 变成可改名字的完整闭环。

### 10.1 先选层：名字 / 行 / 库，三层不重叠

| 你想知道 | 用什么 | 得到的名字 | 天花板 |
|---|---|---|---|
| 哪个**顶层过程**在烧 CPU | perfmap 自报 + `oncpu`/perfprobe | `static_tget`、`string-hash`、`sweep_generation_pass` | 只覆盖顶层过程；lambda/内联代码仍是 `[anon]` |
| 哪**一行 Python** 在烧 CPU | `STATICPY_PROFILE=source` + `dist/sprof` | `t.static.py:541`（**报的是你编译的那个 bundle 文件名**：拼 translator 时是 `t.static.py`，不是 `parse_lib.static.py`；行号是 bundle 内的行） | 要专门重编一次；只归因 py 侧，Scheme 运行时算在 runtime 名下 |
| 哪个 **C 库/GC** 在烧 CPU | `oncpu` 默认就够（不用额外准备） | `libc.so.6+0x188d80`、`libstaticpyrt.so` 内的 `sweep_generation_pass` | strip 过的库只能到 `sub_<入口>` |

判据：**先跑 §10.2 拿到函数级**（免重编、一次到位），**只有需要精确到行才上 §10.4**。

### 10.2 让产物自报名字（构建期门禁）

```bash
# 1. 翻译这一步带环境变量：IR 里就会多出一段"运行期自报"的调用
STATICPY_PERFMAP=1 ./dist/translator app.static.py > ~/iso_gen/app.code.scm
#    （走 build 脚本也行：翻译在脚本内部跑，env 一样生效）
bash staticpy/static_build_comfycli.sh ~/iso_gen/app.code.scm app
# 2. 用 perfprobe 采（它跑完再统一归因，正好吃得到事后才写出来的 map）
perfprobe argv=["/opt/StaticPy/dist/app"] freq=199
```

**时刻要记牢**：map 是 `(static_main)` 之后才写的 → **进程退出前才出现**（见原理第 5 条）。
所以它是 **post-mortem 归因**：`perfprobe` 采完、目标退出、再读 map，能对上；
而 `trace mode=oncpu --sym` 是**边采边符号化**（`engine.lua` 的 `perf_map()` 还带负缓存，
第一次读不到就锁成"没有"），对这类目标会全程 `[anon]` —— 要命名请用 `perfprobe`。

**这条不因为 `argv` 直采而改变**：`trace argv=[...]` 现在已经能自己起目标，但 perfmap 是
退出前才落盘、engine 又是边采边符号化 —— 起法解决了"采不到"，没解决"采时没名"。
**perfmap 目标 → `perfprobe`；只要时间分布 → `trace oncpu`（接受 `[anon]`）**，两者别互相指望。

原理只有五条，不需要任何名字表：

1. `(environment-symbols (interaction-environment))` 在 **AOT 产物里能枚举到全部顶层符号**
   ——程序自己的定义 + 内联进去的库 + prelude，全在。
2. `top-level-value` 对未绑定名抛**普通条件**，`guard` 兜得住，所以可以闭眼逐个探。
3. `(object->reference-address p)` 掩掉低 3 位就是 code entry。
4. 码长用「与下一个入口的间距」估，上限 `#x2000`（没跑过的函数估不准，宁短勿长）。
5. 写在 `(static_main)` **之后**：函数跑过一轮，对象才稳定指向代码段。
   ——代价是 map 只在进程结束前才落盘（live 采样看不到，见上）；
   这是"名字准"与"采样期就有名字"的取舍，当前选了名字准。

覆盖量：translator 从 **399 条 → 2283 条（5.7×）**。构建期门禁只影响这份 IR，
**不开 `STATICPY_PERFMAP` 时 IR 逐字节不变**（`n5` → 2104828 B，`cmp` 通过）。

### 10.3 读结果：哪类名字代表什么

采样 translator 后的真实分布（`[jit]` 占 25.3%，全部有名）：

| 名字 | 占比 | 是什么 |
|---|---|---|
| `[anon]` | 45.8% | lambda / 内联展开 / 闭包体 —— **perfmap 的固有上限**，只能靠 §10.4 |
| `sweep_generation_pass` | 10.2% | Chez GC 清扫 |
| `string-hash` / `string=?` / `dict-get` | 4.0 / 3.1 / 2.7% | **符号表/字典查找**——合集约 10%，是最肥的可改块 |
| `static_tget` | 1.8% | tokenizer 读字符（`int_array_ref` 每次都调） |
| `sub_188d80`（libc） | 3.1% | `__memmove_avx_unaligned_erms`（AVX2 版 memmove） |

**经验判读**：
- 名字带 `static_` 前缀 = 程序自己的顶层函数；不带前缀且不是 C 库 = prelude（内联进来的）。
- `[jit]` 不是 LuaJIT；在 Chez AOT 场景它就是"自报的那批顶层过程"。
- libc 里 `sub_<地址>` 且落地在 `vmovdqu` + `and $-32` = AVX2 `memmove/memcpy` 变体，
  优化方向是**减少调用次数与字节数**（列表增长、结构体拷贝），而不是调 GC。
- 看到 `__nss_database_lookup`、`malloc` 这类"一眼不对"的大头，先怀疑符号归因
  （IFUNC 变体没有 `st_size`，会被折到最近的前一个符号上），别顺着它优化。

### 10.4 行级：sprof（perfmap 代替不了）

```bash
STATICPY_PROFILE=source STATICPY_CACHE=$HOME/iso_gen/prof-cache \
  STATICPY_OUTDIR=$HOME/iso_gen/prof_src bash staticpy/static_build_comfycli.sh app.static.py app
./dist/app && ./dist/sprof --top=15        # 读 ~/iso_gen/prof/*.prof
```

输出两截：**py 行**（`parse_binop_left` 4.1%、`tget` 11.4% 之类，直接对着改）
与 **runtime 过程名**（`py-list-ref` 12.3%、`str_code_at` 4.3%），后者和 §10.2 的
函数级画像能对上号。注意 source 模式要**独立 cache 目录**，否则污染正常构建缓存。

### 10.5 改完怎么判断"真的快了"

1. **A/B 交替**：两个二进制放不同目录，交替跑 10+ 轮，比 **min**（或 med）；
   单次读数在 ±5% 抖动，同一台机器上"看起来快了"经常是噪声。
2. **IR 门禁**：`dist/translator ~/iso_gen/n5.static.py` 必须仍是 2104828 B 且 `cmp` 一致
   ——emit 侧改动最容易悄悄改变输出。
3. **四层验收**（改翻译器/runtime 时）：`check_tokenize.sh` → `check_parse.sh` →
   `check_translate.sh` → `semantics_diff.py`；插件单一真源 `tools/split_plugins.py --check`
   必须报「变更 0 个文件」。
4. **分层优化顺序**：先砍**调用次数/字节数**（memmove、`py-list-length` 重复算），
   再谈标量特化——translator 上多个"局部加速"方案实测是负收益，别凭直觉改。

### 10.6 别的 Chez AOT 项目也能用

自报逻辑不依赖 StaticPy，通用件是 `lib/chez-perfmap.scm`（66 行，只依赖 Chez 自带过程）：

```scheme
(load "chez-perfmap.scm")
(chez-perfmap-publish!)      ; ① 起手先发一次：live 采样才看得见名字
... (main) ...
(chez-perfmap-publish!)      ; ② 收尾再发一次覆盖：修准尺寸与首调漂移
```

纯 `.scm` 通道（不走 StaticPy）实测 1967 条，程序自己的定义在册，码长也估对了。
StaticPy 的 `emit_lib` 只是把同一段代码内联进 IR。

### 10.7 这一层的坑

- **map 是 per-pid 的**：进程退出即失效；要复现必须"当次采、当次写"，地址每轮都漂（ASLR + 分配顺序）。
- **只有顶层过程有名**：`[anon]` 45% 是常态，别指望把火焰图里每一帧都点亮。
- **`publish` 要发两次（起手 + 收尾），别只发末尾**：只在最后发，map 直到进程退出前
  才落盘，而 `trace oncpu --sym` / `perfrecord` 这类**边采边符号化**的工具在样本到手的
  那一刻就去读表 → 整个运行期只见 `[anon]`，自报等于白做（实测：同程序仅末尾发布，
  进程跑到 t≈1s 时 `/tmp/perf-<pid>.map` 根本不存在）。
  早调的顾虑——"过程首字还没指向代码段"——实测不成立：1550 个顶层的纯 Chez 产物，
  起手发布 **1550/1550 条已落在可执行段**，与收尾发布地址一致率 **99.6%**
  （漂移的只有"自报时还没跑过"的那几个）。收尾那次负责把尺寸/漂移修准。
  StaticPy 产物实测：t≈50ms 表即落盘，`--sym` 直接给出 `static_spin` / `remainder` / `py-mod`。
- **起手那次覆盖不全，属正常**：自报是运行期枚举顶层环境（`environment-symbols` +
  `top-level-value` + `procedure?`），不是构建期名单——所以只认"**此刻已绑定**"的过程，
  后面才 `(define ...)` 的和 prelude 里还没首次调用的，要等收尾那次补齐。
  实测：纯 Chez 产物 1550/1550；StaticPy 的 t 产物 起手 1160 → 收尾 2283 条。
  热点函数通常先定义，所以起手那半张表已经够 live 归因用。
- **IFUNC/strip**：libc 的 memcpy/memset 是一堆 17 字节的变体，归因必须按 `st_size` 判界内，
  否则会出现 37.8% 的假热点（踩着 `.eh_frame` FDE 才收敛成一个 `sub_<addr>`）。
- **别把 `STATICPY_PERFMAP` 当成常开**：它只影响 IR 里那一段，但开了就和基准 IR 不同，
  做性能对照时两边必须同时开或同时关。
- **StaticPy 侧的说明**在 `docs/HOTATTR.md`（§「更省事的路径」）；`hotattr` 是另一条
  **不重编**的路（按 4K/64B 切块命名），名字是坐标而非函数名，适合"先定位再决定要不要重编"。

