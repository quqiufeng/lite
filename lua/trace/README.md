# lua/trace — 动态追踪（纯 LuaJIT，零 perf/bcc 依赖）

`perf_event_open` + 内核 tracefs 探针，在 lite 进程外起一个 luajit 采样子进程，
把结果折成火焰图 / 热力图 / 卡点排行。工具入口是 `helper/trace.lua`（action=run/render/status），
本目录是**正式模块**：进仓库、有单测（`tools/auto_unit.lua`）、接口稳定。

| 文件 | 职责 |
|---|---|
| `engine.lua` | 采样主程序：perf ring buffer、探针装/卸、符号化（kallsyms/ELF/build-id）、六种模式、出图调用；可独立当 CLI 跑 |
| `render.lua` | 折叠栈 → SVG（flame/heat/rank），`tools/{flame,heat,rank}.py` 的等价移植，逐字节对齐 |
| `svgpng.lua` | SVG → PNG（cairo + librsvg，LuaJIT FFI），自包含单文件，可整份拷走 |
| `summary.lua` | engine `--json` → 人读摘要（纯函数，单测直接测） |
| `prof.lua` | 进程内追踪账本（O(1) 聚合：工具/API/记忆/serve/hook 的耗时·成败·字节），`helper/trace.lua action=prof` 读它 |

`helper/trace.lua` 只做参数归一 + 子进程调度（sudo/luajit/超时/落盘/摘要），
采样逻辑一律不进插件——插件层别塞内核细节。

## 快速上手

```text
trace action=status                                  # 先看：权限、tracefs、内核五环、渲染依赖
trace probe=tracepoint:sched:sched_switch mode=count duration=1   # 最便宜的验探针
trace probe=kprobe:do_sys_openat2 arg='file=+0(%si):string' mode=samples duration=1
trace probe=tracepoint:sched:sched_switch mode=offcpu duration=5 rank=/tmp/block.svg
trace mode=oncpu duration=5 flame=/tmp/oncpu.png sym=true   # 默认 perf 软件时钟
trace action=render json_in=/tmp/t.json kind=flame out=/tmp/f.png   # 从 JSON 重出图，毫秒级
```

出图三件套（`flame` / `heat` / `rank`）只吃 `oncpu` / `offcpu` / `folded` 的结果；
写 `.png` 需要 libcairo2 + librsvg2-2，缺库时插件会保留 `.svg` 并说明，不会假装成功。

## 六个模式

| mode | 干什么 | 关键参数 | 典型用途 |
|---|---|---|---|
| `count` | 只数触发次数 | `probe` | 验探针装没装上（events>0） |
| `samples` | 打印原始字段 | `probe`, `str` | 验 fetchargs 取没取到（如 `file=` 字符串） |
| `latency` | entry→exit 配对求时延分布 | `entry`, `exit`, `key` | 系统调用/函数耗时 p50/p99/max |
| `folded` | 采样折叠栈 | `probe`（可带 callchain）+ `freq`/`event` | 出火焰图/热力图/排行的通用输入 |
| `oncpu` | 周期性 on-CPU 采样 + 调用栈 | `freq`（默认 99Hz）, `sym` | CPU 热点在哪 |
| `offcpu` | `sched_switch` 配对阻塞时长 | `probe`（默认 sched_switch）, `sym` | 卡点排行首选 |

顺序纪律：`count` 验探针 → `samples` 验字段 → 再上 `folded`/`oncpu`/`offcpu` 出图。
`duration` 夹在 `[0.1, 120]` 秒且**阻塞**执行：探路用 1~2s，出图 3~5s 足够看清形状。

## 权限与内核（`action=status` 会逐条自检）

- 需要 root 或 `CAP_PERFMON`（`perf_event_open`）。非 root 时插件自动加 `sudo -n`，
  sudo 要密码就**直说不可用**，绝不弹 tty（TUI 里会卡死）。
- tracefs 必须挂载（`/sys/kernel/tracing`）；目录是 0700 root，所以 status 会区分
  「没挂载」和「挂了但非 root 读不到内容」。
- 内核开关：`FTRACE` / `TRACEPOINTS` / `PERF_EVENTS` / `KPROBE_EVENTS` / `UPROBES`。
  `events=0` 先看 status 的五环，别在 Lua 侧乱改。
- `--sym` 依赖 kallsyms；`kptr_restrict≠0` 时符号会糊，status 里会提示。
- ring 溢出（`lost`/`throttled`）说明统计偏小 → 调大 `ring_size`（页数，默认 8=32KB/CPU，
  oncpu/offcpu/folded 插件默认给 64）或收窄探针。
- `pid=` 跟**进程的全部线程**（展开 `/proc/PID/task`），内核里 `common_pid` 是 tid 不是 tgid。

## 目录外的两个约束

- 采样在**子进程**里跑（engine 当 CLI），主进程不 `ffi.load` 任何采样句柄：
  reboot 语义、崩溃隔离、sudo 前缀都靠这层。engine 的进度/告警走 stderr，
  `json=true` 时插件会剥掉 `[trace_engine]` / `[render]` 行再解析。
- `svgpng.lua` 里 `ffi.cdef` 了 cairo/GError，一个进程只能加载一次：
  插件用 `MODCACHE` 缓存 `dofile` 结果，别改成每次重载（会 `attempt to redefine '_GError'`）。

## 进程内账本（`action=prof`，与内核侧分工）

`engine` 看的是「CPU/系统在干什么」，要权限；`prof` 看的是「lite 自己的哪块慢」，
不需要任何权限、不需要子进程。埋点是 O(1) 记账，异常一律静默：

| 埋点名 | 来源 |
|---|---|
| `tool:<name>` | 每次工具调用（含 `bash`/`web`/插件），带输出字节 |
| `hook:<kind>` | 插件 hook 调用（`before_tool`/`after_tool`/`on_user_*`/`on_compact`/`on_session_end`） |
| `api.stream` / `api.ttfb_ms` / `api.retry` | 模型 API 总时长、首字节、重试次数 |
| `http.get` / `http.post_stream` / `http.stream` | libcurl 各通道耗时（分清「模型慢」还是「网慢」） |
| `memory.recall` / `memory.put` / `memory.del` | 记忆召回与落盘 |
| `prompt.build` / `session.save` / `compact.fold` | 组 prompt、存会话、压缩摘要 |
| `serve.request` | serve 的 HTTP/JSONL 请求（含排队时间） |

```text
trace action=prof                     # 进程内账本（agent 同进程，实时）
trace action=prof json=true           # 原始 JSON，便于别的工具吃
trace action=prof reset=true          # 读之前清零
trace action=prof path=/tmp/pf.json   # 读退出时落的快照（进程已退 / 独立 lua 进程）
```

`LITE_PROF=0` 整层关掉。快照路径 `<memory_dir>/prof.json`（默认 cwd），
`agent:session_end` 收口时写；进程内账本为空时 `action=prof` 自动退化读快照。
空账本不落盘（省得每次 `--once` 都留个空文件）。

## 性能问题闭环：定位 → 修复 → reboot → 复验

问题先分层，选错层会白测：

| 现象 | 用哪层 | 起手命令 |
|---|---|---|
| lite 自己哪块慢（工具/API/记忆/prompt/serve） | `action=prof`（进程内，零权限） | `trace action=prof json=true` |
| CPU 热点在哪 | engine `mode=oncpu` | `trace mode=oncpu duration=3 flame=/tmp/oncpu.png` |
| 卡在哪个 syscall / 阻塞多久 | engine `mode=latency` / `offcpu` | 见上文六模式表 |

### 五步

1. **定位**：`trace action=prof json=true`。先看 `events` 确认这是哪个窗口（坑 1），
   再按 `total_ms` 给 `spans` 排序取 top，最后翻 `recent` 找单次长尾——
   `spans` 是聚合（谁最贵），`recent` 是流水（贵在什么时候）。
2. **量化基线**：进程外跑，别在 agent 里跑（否则结论会写进你自己的账本）：
   ```bash
   ./tools/lite-lua /tmp/ab.lua     # 同参数重复 N 次，报 中位 / p95 / max
   ```
   基线必须落成数字（中位 + p95），**不拿单次极值当基线**（坑 3）。
3. **改代码**：动手前写下这次要动的**是哪个量**——均值？p99？可见样本数？
   改错口径比改错代码更常见（坑 2），而且错了照样能测出「变好了」。
4. **reboot**：`trace.prof` 被 8 个 core 模块在加载时 `require` 进 `package.loaded`，
   纯 Lua 改了**必须 reboot** 才生效；C/C++ 改了先 `./tools/build.sh`
   （跑安装版用 `./tools/release.sh`）再 reboot。
5. **复验**：同脚本、同种子重跑，前后对比**同一个指标**；再在进程内
   `trace action=prof` 看真实轮次是否同向。合成数据变好只是必要条件。

### 四个坑（都真踩过）

| 坑 | 表现 | 怎么避 |
|---|---|---|
| **窗口错认** | 读到的是 `<memory_dir>/prof.json` 快照（上一轮或 `test.sh` 写的），却当成当前轮次，得出「没埋点」 | 先看 `events` 计数和 span 名单里有没有当前动作；独立 lua 进程里 `require` 到的是空账本，`action=prof` 会静默退化读快照 |
| **口径错认** | 以为 `SAMPLE_MAX` 影响均值。实际 `avg/min/max/count` 走 `total/count` 累加，**不经 reservoir，永远精确** | `SAMPLE_MAX` 只喂 `p50/p99`；要改善均值精度是白改，只有尾延迟口径才动它 |
| **单次判决** | 一次 `max_ms` 差 10 倍就当结论（GC / 调度 / 页缓存抖动） | ≥30 次重复，比中位与 p95；样本数要远大于采样上限才看得到采样误差 |
| **退化实验** | 用分组交替造样本（`i % 2`），任何子样本都精确恒等 → 误差恒 `0.00%`，看起来像「完美」 | 用随机分布；**看到 0.00% 先怀疑实验设计**，别当成有效证据 |

### 复验三问（答不全就不算有效）

1. 目标指标动了没？（同脚本、同种子、前后对比）
2. 没瞄准的指标有没有被误伤？
3. 结论在进程内真实轮次也成立，还是只在合成数据里成立？

### 范例：`memory.del`

- **定位**：`prof` 里 `memory.del` 是 `recent` 常客，`avg_ms` 随记忆库增大而上升 → 疑似 O(n)。
- **改**：删除下沉到 `src/cache`，`lua/core/memory.lua:M.del` 只剩计时与 `NOENT` 归类。
- **reboot**：这是 C 侧改动 → `./tools/build.sh` → `reboot`（只改 Lua 就跳过 build）。
- **复验**（`/tmp/bench_del.lua`，逐个删到底、取中位数）：

  | 规模 | 旧中位 | 新中位 | 倍数 | 旧 p99 | 新 p99 |
  |---|---|---|---|---|---|
  | n=1000 | 31.0µs | 2.0µs | **15.5×** | 64µs | 3µs |
  | n=4000 | 140.0µs | 5.0µs | **28.0×** | 277µs | 10µs |
  | n=16000 | 658.0µs | 18.0µs | **36.6×** | 1292µs | 36µs |

  旧值随规模近似 4 倍翻番（31→140→658µs）＝ O(n)；新值基本平坦（2→5→18µs，
  增幅主要来自计时器粒度与删除后的页回收）＝ 常数级，不是「同一个 O(n) 变快了一点」。
  进程内 `trace action=prof` 同向：`memory.del count=7 avg=0.002ms max=0.006ms`。

## 渲染契约

`render.lua` 吃 engine `--json` 的 `top[]`（oncpu/offcpu）或 `folded[]`，
用 `frame_dir` 决定方向（root-first / leaf-first），`unit` 决定权重口径（样本 / ms）。
输出属性顺序、数字格式、颜色哈希（纯 Lua MD5）都对齐 Python 原版，
同名列在两张图上必须是同一种颜色——换成别的哈希会破坏跨图可读性。

## 测试

`./tools/test.sh` 里的 `trace *` 用例覆盖：探针参数归一、summary 各模式输出、
SVG 生成与尺寸、PNG 转换（缺库时跳过）、engine 的 JSON 字段契约；
内核侧真采样不进单测（要 root，机器相关），靠 `action=status` + `count` 现场验。
`prof` 的记账/聚合/落盘读回/关闭语义与 `action=prof`（含空账本退化读快照）在
`tools/auto_unit.lua` 的 `trace.prof` 段。
