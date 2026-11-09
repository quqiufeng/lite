# lite 设计

> 只写「现在为什么是这样」。历史过程在 git log，外部项目探索压到附录 A。
> 结论标 `[static]`（读代码）/ `[verified]`（真机真 API 跑过）。

## 1 分层

```
lua/main.lua          入口：--check / --once / --recall / --tui / serve / state / sessions / plugins
lua/context.lua       会话视图 / settings / ui 钩子 / 事件
lua/core/agent.lua    循环：messages → model → tools → messages；窗口与压缩接入点
lua/core/provider.lua DeepSeek SSE + tool_calls + usage
lua/core/tools.lua    内置工具 + 插件派发（helper/*.lua → {schema,run}）
lua/core/{memory,session,prompt,compact}.lua   记忆 / 存储 / system prompt / 三段式摘要
lua/core/{net,serve,scheduler,approval,sandbox,voice}.lua   服务端 / 唤醒 / 审批 / 沙箱 / 语音
lua/tui/*             自绘终端 UI（screen / mouse / clipboard / diff / snapshot）
lua/gui/*             可选 SDL2 GUI
lua/ffi/*             cache / image / ocr / x11 / xdo（薄封装：M.available() + 值或 err）
src/{cache,image,x11,storage}/*.c   C 引擎
helper/*.lua          随包插件（含 C 编出的 .so）+ helper/lib/ 共享逻辑
tools/                人写的仓库脚本（build/test/run/release…），不当插件加载
```

三条边界：

- **工具**：Lua 表 + JSON schema；schema 进 API `tools` 字段，system prompt 只列名字。
- **插件两条通道**：`tools/` 是人设计、进版本控制、必须过 `test.sh` 且要有文档；
  `helper/` 是模型自己造的，允许粗糙、按名即调、不承诺稳定。
- **FFI 选路**（省力到费劲，不许跳级）：系统已有 `.so` → 一个 `helper/<x>.lua` 手写 cdef
  （没头文件就 `nm -D --defined-only` 抄符号）→ 库没有/热路径/复杂 ABI 才写 C。

## 2 关键决定

### D1 可缓存前缀：动态内容只能追加在末尾

DeepSeek 按前缀命中，命中价约为 miss 的 1/10，「prompt 前缀字节稳定」比任何单点优化都值钱。

- system prompt **字节稳定**：不写时钟、不写轮次、不写预算；工具只列名字。
- 每轮都变的（时钟、`turn N/M`、召回块）统一拼成**消息尾部的 system 块**。
- 召回内容**每个用户轮只注入一次**，工具循环的后续请求复用同一前缀。

实测 `[verified]`：召回块插在「最后一条 user 之前」下一轮命中 71%，追加到末尾 97%；
同一条链 miss 计价 37126 → 10529（-72%），有效成本约为原来的 35%。
（`agent.lua:M.request_messages`）

### D2 有界上下文：丢弃优先，摘要是开关

prompt 会线性增长，窗口固定。默认策略是**丢**，不是压：

- 跨过触发线（默认 `budget × 0.85` = 54400 字符）就从最新往回装窗口，更老整条丢；
- `session.messages` 与 `mem.bin` 一条不删 —— 丢的只是**发出去的视图**，`recall` 能捞回；
- 丢弃提示是固定字符串（不带条数），同一丢弃窗口内字节稳定，不打断缓存。

`LITE_COMPACT=1` 回到三段式摘要（稳定前缀 · 结构化 digest · 近期原文尾巴），
机制完整保留：迟滞 rearm、摘要长度验收、上一次 digest 显式合并、尾巴逐级缩小重试、
预算抬到固定前缀的 3 倍。它的代价是每次改写历史 = 只能当低频 cache-reset 点。

为什么默认改成丢：摘要是唯一「丢了什么」的索引，但也是有损改写；prompt 宽度固定，
新信息比旧摘要更相关，缺细节用一次 `recall` 换回来更便宜。
代价（已声明）：纯丢弃只报条数，模型得多花一轮 `recall`。

`/compact` 可手动把窗口滑到 `budget × LITE_KEEP_RATIO`（默认 0.6），只影响请求。

### D3 记忆是唯一真相

prompt 可以有界，`mem.bin` 不能。

- 每个目录一份 `mem.bin` + `mem.idx`，C 引擎 `MAP_SHARED` mmap 零拷贝，30s `sync`；
  `cache_get`/`prefix` 返回指针，Lua 只在解码 JSON 时复制。
- 命名空间：`/agent/knowledge/*` 长期事实 · `/agent/session/<id>/*` 消息/摘要/todo ·
  `/agent/working/*` 运行态（不注入 prompt）。
- 镜像自带裁剪：只保留最近 `LITE_SESSION_RAW_KEEP`(200) 条非 user 原文，user 永久保留；
  tool 结果入库截到 8192。更老的靠 turn 摘要 + `recall`。
- `mem.lock` 防多写实例覆盖；`--recall/state/sessions` 只读不加锁，运行中可诊断。
- 头部损坏（magic/version 不符）不阻塞启动：改名 `mem.bin.corrupt-<ts>` 后以空库继续。
- 会话结束把「同 tool+args 失败 ≥2 次且未恢复」写成 `fail/<ts>` 事实，下次自动召回。

### D4 工具：省 token 不等于砍信息

- **头尾双端裁剪**（bash 32KB / 其余 30KB，头 2/3 + 尾 1/3）：只留头部会砍掉编译报错和
  测试结论，模型只能重跑一遍 —— 那是「省 token 反而更贵」。
- **失败可自修**：报错回传原始参数 + `required: key (type)` + 退出码语义（`tools.exit_note`：
  124 超时 / 126 不可执行 / 127 未找到）；同一调用连续失败第 2 次起追加
  `[this exact call has now failed N times]`，成功清账，恢复时给 `[recovered after N]`。
- `read` 一次可读 N 个文本文件（`paths`），图片一次一张、可从 `$TMPDIR:/tmp:/var/tmp` 读，
  文本仍限 workspace。
- 单条消息超预算时只截 `role == "tool"`（assistant 的 `tool_calls` 是配对结构、user 是约束，
  都不能动），上限 = 触发线/4、地板 2000；裁剪是纯函数且不落 KV，前缀照样命中。

### D5 插件：清单冻结，派发动态

问题：插件每轮都变 → system prompt 跟着变 → 前缀缓存整段失效；但「改完立刻生效」必须支持。

- **清单**：会话启动扫一次 `<cwd>/helper` → `$LITE_ROOT/helper`（平铺，子目录不算），
  `schema`/`run`/`hooks` 进 `_helper_cache`，之后 `schemas()` 用快照。
- **执行**：每次调用都 `loadfile` 重读文件、`.so` 按 `<name>.json` 清单重新 `ffi.load`。
- 只返回 `hooks` 的插件不进工具列表（不动 prompt）：`before_tool` 返回字符串即拦截且优先于
  审批，`after_tool` 可换结果，`on_user_turn` 可改写用户文本；hook 抛错一律 fail-open，
  错误留在 `_hook_errors`。
- 运行期试新代码走 `lua` 工具：进程外 `tools/lua.sh -e`，默认 30s 超时 —— 死循环只撞超时，
  崩溃不带崩 agent。这就是不做进程内 `loadstring` 的理由。
- 可见性：`lite plugins [--json]` 只读快照、不触发加载，列 `name/path/scope/tool/hooks` 与错误；
  `--no-plugins` / `LITE_PLUGINS=0` 全关（插件与 agent 同进程同权限）。

| 动作 | 立刻生效 | 进 API `tools` |
|---|---|---|
| 改已存在插件的 `run` | 是 | 已是工具 |
| 新建 `helper/x.lua` / `native wrap` | 是（按名调用） | 新会话 |
| `native build` 出新 `.so` | 是（下次调用换句柄） | 新会话 |
| 删插件 | 是（`unknown tool`） | 重启后消失 |

### D6 自扩展：缺能力先造，不降级

判（内置工具 → 系统 `.so` → 已有插件，三者都不行才造）→ 估（只跑一次的用 `lua` 内联，
反复用的落 `helper/`）→ 写（`char *lite_helper(const char*)` 加 `lite_helper_free`）→
验（喂真实输入，空结果 / 非法输入 / 超限三边界）→ 接（`wrap` 或手写 `{schema,run}`）→
记（坑写进知识）。

三条踩过的约束：JSON 键名不能与数组同名（同名时 cjson 取后者，计数器要改叫 `count`）；
错误必须写明缺哪个键；每次 build 出新 `.so` 文件名，免重启。

### D7 TUI：自绘虚拟屏幕

终端对鼠标上报、宽字符、颜色的支持不一致，所以不用 ncurses：`screen.lua` 维护一屏 cells，
只把变化的行 diff 出去；`mouse.lua` 把 `?1002h`/`?1006h` 事件翻译成点击、拖选、滚轮；
`clipboard.lua` 依次找 `xclip`/`wl-copy`/`xsel`/`pbcopy`，都没有就退化为 OSC 52（走 ssh 可用）。
好处是「拖选即时复制」能自己实现（终端原生选择在有鼠标上报时会被吃掉）；代价是换行、
宽字符、resize 重排都得自己写，靠 `--snapshot` 与 tmux 冒烟兜住。

### D8 serve / attach / wake

`serve` 是 headless 事件源（TCP + JSONL 广播），`attach` 是远端 TUI：待处理 prompt 持久化在
KV，重启可恢复，连接时回放历史，SIGINT/SIGTERM 优雅退出。`--wake` 空闲时按间隔提交任务，
结果记 KV 并广播 —— 无人值守的缺口是审批/沙箱收口。

### D9 观测：两个命中率，别混着看

- `cache:ratio` = hit / prompt：会被「每轮新增的工具输出」稀释。
- `reuse` = hit / min(上一轮 prompt, 本轮 prompt)：才是「可复用前缀命中了多少」。
  低于 0.5 且分母 ≥1500 tokens 时发一次 `prefix_drop` 事件。
- 读法：cache 低而 reuse 高 = 正常（新增内容按 miss 计价）；两个都低 = 前缀真坏了。
- `ctx:N%` = 当前 prompt 占触发线的比例，来自真实 `usage` 校准的 chars→tokens
  （`tok_per_char` 用上轮 usage 反推加指数平滑，实测 0.3452 vs 真实 0.3563，误差 2%）。

## 3 数字与门槛（默认 `budget` = 64000 字符）

| 项 | 值 | 出处 |
|---|---|---|
| 触发线 | `budget × 0.85` = 54400 | `compact.lua:M.trigger` |
| 丢弃优先的硬线 | = 触发线；装窗口保留 `budget × 0.6` | `agent.lua:M.request_messages` |
| 摘要模式硬上限 | `budget × 2`（物理兜底，只保 system 加 digest） | 同上 |
| 单条 tool 消息上限 | 触发线/4，地板 2000 | `compact.lua:msg_cap` |
| 摘要近期尾巴 | `budget × 0.10`，clamp 到 `[min(8000, avail/3), 24000]` | `compact.lua` |
| 摘要稳定前缀 | `min(budget × 5%, 6000)`，硬性 ≤ budget/8 | `compact.lua` |
| 预算地板 | 抬到固定前缀 × 3，并发 `budget raised` 事件 | `agent.lua:compactor` |
| 工具输出 | bash 32KB，其余 30KB（头 2/3 加尾 1/3） | `tools.lua:12,15` |
| 入库截断 | tool 结果 8192 字符，非 user 原文 200 条 | `session.lua` |

## 4 已知代价与未做

- 纯丢弃不生成 digest，模型不知道「丢了什么」，缺信息要多一轮 `recall`。
- 触发线仍是字符口径；有 `tok_per_char` 后可以改 token 口径（参考实现都按 token 算）。
- 渐进降级只有两档（折叠 / 丢最老），缺中间档（截 tool output → 抹 output → 只留 user）。
- 提前压缩（Pi `backgroundTokens`）没做，后台写摘要要常驻任务，serve/wake 里更自然。
- 命中率逐轮曲线没落 KV，`lite state` 看不到趋势；`cache_shape` 诊断（hash(system+tools)
  变了就打 notice）也没做。
- 无人值守仍缺审批/沙箱收口。

## 附录 A 外部项目参考

`[static]` 基于 `/opt/pi-mono`、`/opt/reasonix`、`/opt/opencode` 源码（code search 索引位于
`/opt/my_db` 与 `/opt/code_caches/*`）。

| 维度 | Pi (TS) | Reasonix (Go) | opencode |
|---|---|---|---|
| 循环 | `packages/agent`，薄且通用 | runtime/agent + control，分层厚 | 产品化 |
| Provider | 多 provider，StreamFn 抽象 | 厚契约（重试/归一化/overflow/cache） | 多 provider |
| 会话 | 树/分支 | sessionstore + checkpoint + memory | 产品化 |
| 安全 | 工具钩子 | permission/sandbox/evidence | 权限系统 |
| lite 借什么 | 骨架 | 概念（压缩、前缀、归一化、32KB 上限） | 行为（read 图片、diff 双模式、审批三态） |

省 token 的四层，三家一致，lite 全落：

1. 单次工具输出硬上限（进 prompt 前砍）。
2. 追加式 prompt + 稳定的 system/tools 前缀（命中价约 1/10）。
3. 低频压缩 / 丢窗口（只在跨阈值时动一次）。
4. 用真实 usage 校准 chars→tokens（避免误压或爆窗）。

参考值：Pi `reserveTokens=16384` / `keepRecentTokens=20000` / `backgroundTokens=32768`；
Reasonix 尾巴 `clamp(window×10%, 32K, 96K)`、收益不足 100 tokens 不调摘要器；
opencode `RESERVE_MIN=16000` / `RESERVE_SHARE=0.15` / `PRECOMPUTE_LEAD=60000`，转录逐步降级。

**不抄**：多前端、MCP、subagent、goal、checkpoint 这些产品化体系，以及大量平台特化
（Windows/PowerShell/repair）。opencode 只借可验证的交互语义，不借体量。
