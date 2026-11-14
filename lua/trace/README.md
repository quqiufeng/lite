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
