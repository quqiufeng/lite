# AGENTS.md — lite

**lite = 会改自己的 agent 外壳**：`lua/` 提供循环/工具/记忆/TUI/serve，机器提供 shell/编译器/`.so`/X11。
本文件只写「每次都要遵守的规则和入口」；设计原理见 `design.md`，专题见各自 README。
**本文件必须 ≤16000 字节**——超了会被 `prompt.project_context` 截断（`DEFAULT_PROJECT_CHARS`），新增内容先想
「能不能挪进 README/代码头注释」。

| 层 | 你怎么用 |
|---|---|
| 模型 | DeepSeek，多模态（图可读） |
| harness | `lua/core`（循环/工具/记忆/prompt/session/compact）、`lua/tui`（自绘屏）、`lua/ffi` |
| 机器 | `bash` 直达 shell、`web` 取 live 数据、编译器、系统 `.so`、X11/GPU |

**能力 = `bash`/`web` + 编译器 + FFI + `native`**，内置工具只是常用快捷键，不是上限。
上下文有界（旧内容靠 `recall`）；同目录只允许一个写实例（`mem.lock`）。
原则：**缺能力先造，别降级**；**代码是唯一真相**，注解落后顺手修。

## 1 看见自己

先定位窗口再截图，别直接截全屏（会截到遮挡窗口）。

```bash
./tools/lite-lua tools/see.lua --list                        # 列可截窗口
./tools/lite-lua tools/see.lua --class wechat --width 1280   # 出图片路径，再 read
./tools/run.sh --tui --snapshot out.txt                      # 文本快照验收 TUI
./tools/run.sh state --json                                  # 进程/锁/用量
```

**自造 GUI 的验收环**：编译 → 起进程 → `see.lua --pid $PID`（重名别靠 `--name`）→ `read` 图 →
`Xdo:click(win,x,y,btn)`（`lua/ffi/xdo.lua`，窗口内坐标；xdotool 仍禁）→ 再截再断言。
断言优先截图 diff；OCR 认不了窄数字，要认就零填充 `%02d`。`--width` 只缩不放。

## 2 代码地图

| 位置 | 内容 |
|---|---|
| `lua/main.lua`、`lua/core/` | 入口；agent 循环、工具派发、记忆、prompt、session、compact、web、serve |
| `lua/tui/`、`lua/gui/`、`lua/charts/`、`lua/trace/` | 终端界面、SDL2 GUI、SVG 图表卡、纯 LuaJIT 动态追踪 |
| `lua/ffi/` | C 库绑定；`libfind.lua` 是 `liblite_*.so` 唯一解析点（见下） |
| `src/` | `cache` `codesearch` `html` `image` `storage` `utils` `x11`：重活实现 |
| `helper/` | 模型自造插件（`.lua` + `native` 编的 `.so`），发现只认这里 |
| `tools/` | 人的脚本：build/test/run/release/package/cluster/see/lua.sh…（**不当插件加载**） |
| `templates/` | 体系出口：规范 + 可跑骨架；`tools/newproject.sh` 起项目 |
| `helper/lib/` | 插件共享模块（`adb/music/usb/uimap/deepseek/webdav/md4c/htmlmd`），不是插件 |

`lua/ffi/x11.lua`+`xdo.lua` 是**自包含单文件**（只用 FFI + 系统 libX11/libxdo），可整对拷走。

## 3 记忆

记忆跟着目录走：每目录一份 `mem.bin`+`mem.idx`。键：`/agent/knowledge/*`（长期事实）、
`/agent/session/<id>/*`（消息/摘要/todo）、`/agent/working/*`（运行态，不注入 prompt）。JSONL 镜像
（`~/.local/share/lite/sessions/<id>.jsonl`）只在 KV 无会话时兜底。**真要清空**：
`rm mem.bin mem.idx` + 删对应 `.jsonl`，否则下次启动会从备份捞回来。

- **自动注入**：每个用户轮首次请求注入一次，作为末尾 system 的 `<retrieved_memory>`（≤8 条/2400 字），
  查询是最近 user 文本前 600 字；工具循环的后续请求不再注入（保前缀缓存）。
- **召回是字面匹配、无向量**：白名单 `knowledge/`(1.0) > `working/`(0.9) > user 原文(0.8) > `turn/` 摘要(0.6)。
  换个说法可能一条不中，且它失败了你不知道。
- **主动 `recall`**：hard_window 丢了且需要那段；用户说「上次/之前」而窗口里没有；动手前核对旧结论。显式 recall
  额外捞 `msg/` 里的 assistant/tool 原文（截 1200 字、≤3 条），被丢掉的长 tool 结果靠它找回。
- **`remember` 判据**：跨会话仍成立 + 重踩成本 > 记录成本。存「`excludes` 不持久化」这类坑，不存行号。
- **单写者**：抢不到 `mem.lock` 时 `--tui/--once/serve` 报「被 pid N (comm) 占着」并以**退出码 3** 拒绝启动；
  明知不落盘就 `--readonly`/`LITE_ALLOW_READONLY=1`（状态栏 `mem:N RO!`），只读实例不持 fd。
- 截断：tool 结果 `LITE_TOOL_RESULT_CHARS`（8192），非 user 原文留 `LITE_SESSION_RAW_KEEP`（200）条。

**system prompt 必须字节稳定**：时钟/轮次/预算都在消息末尾的 `runtime_block`，工具**名字**也在那里
（helper 增删会打散清单），schema 以 API `tools` 为准。前缀 reset 按 `fold`/`hard_window`/`window` 记账
（落 `/agent/session/<id>/usage`）。会话结束把「同 tool+args 失败 ≥2 次」写成 `fail/<ts>`。

## 4 铁律

MUST：改代码后 `./tools/test.sh` 通过；依赖变更同步 `tools/check_deps.sh` 与本文件；C ABI/FFI 同步
`lua/ffi/*`；UI 用 `tmux capture-pane` 或 `--tui --snapshot` 验收；引用写 `file:symbol`，结论标
`[static]`/`[verified]`；commit 用 `feat/fix/style/docs/chore(scope): …`，**只在用户明确要求时** commit/push。

MUST NOT：`python`/`sed -i` 改仓库文件（用 `edit`/`write`）；Chrome/WebView/CEF/Electron；起
`xdotool/wmctrl/import`；`systemd --user`；`pkill -f`；把 API Key 或 `$ROOT/lib` 写进仓库或 `LD_LIBRARY_PATH`。

**密钥只活在环境变量里**：读 `os.getenv`，缺 key 时报变量名和该写进 `~/.config/lite/.env`。`run.sh`/`lua.sh`
启动时按 cwd 向上 → `~/.config/lite/.env` → `~/.env` → `$LITE_ROOT` 注入（`$LITE_ENV_FILE` 独占），
`sudo` 下靠 `SUDO_USER` 补读原用户 `.env`。不 print key、不拼进命令行（`ps` 可见）、仓库里无 `sk-` 字面量。

## 5 命令

```bash
./tools/build.sh        # 编 C（src/**）
./tools/test.sh         # 全量回归
./tools/release.sh      # build + package + install（跑安装版必须它，见 §6）
./tools/run.sh          # TUI：--once/--tui/--readonly/--gui/state/sessions/serve/attach
./tools/run.sh --once --json "prompt"                          # 单轮（脚本/集群用）
./tools/run.sh --memory-export|import kb.jsonl [--all] [--prefix P]  # 记忆 ⇄ JSONL（省略路径=stdout）
./tools/run.sh --memdb[-search "词"]                                # 共享记忆库统计 / 检索
./tools/run.sh plugins [--json]                                # 插件清单 + 加载错误
./tools/cluster.sh [--dry-run] [--jobs N] tasks.tsv            # 并行派活
```

- **`cluster.sh`：集群 = 槽 = 目录**（`mem.lock` 定并发上限）。`tasks.tsv` 一行一槽
  `<box>\t<dir>\t<prompt>[\t<task>]`，`local`/`-` 跑本机，prompt 走 base64 过 ssh；产物落
  `out/<task>.{jsonl,rc,sec,err}`；退出码 0 全 ok、1 有任务失败、2 用法错误。
- **TUI 两个 `#` 开关**（`submit()` 先拦，不进模型）：`#语音模式`；`#监工模式`/`#终止监工` 每
  `LITE_WATCHDOG_SEC`（180s）在**空闲+队列空+输入框空**时补发 `LITE_WATCHDOG_TEXT`（默认「继续」），
  状态落 `/agent/session/<sid>/watchdog`，reboot 自动接上。
- **HTML→PNG 三件套**走 `build/liblite_html.so`，与 `liblitehtml.so.0`/`libgumbo.so.0` 同目录靠 `$ORIGIN`：
  源码树要 `/opt/litehtml` 才能**编**，安装版不必也能**跑**；缺库别误读成「liblite_html 没编译」。
- 工具输出 ≤32KB；`read` 文本限 workspace，图片可读 `$TMPDIR:/tmp:/var/tmp`，多文件用 `paths` 批量读；
  `bash` 可异步长跑，TUI `Ctrl+C` 取消。回归测试先 commit 出 FAIL 再修。
- 工具失败要**可自修**：报错带原参数 + 缺的 `required` 键 + 退出码语义（`tools.exit_note`：124 超时/
  126 不可执行/127 未找到）；同一调用连续失败第 2 次起追加 `[this exact call has now failed N times]`。
  `finish_reason: length` = 撞 `LITE_MAX_OUTPUT_TOKENS`，**参数被截断不是写错 JSON**：拆小（长文档用 `write`
  的 `append=true`），别原样重试。

## 6 扩展：两条通道

| 通道 | 谁写 | 纪律 |
|---|---|---|
| `helper/` | 模型自己，会话里临时起意 | 粗糙可接受，下次可删；按名即调，不承诺稳定 |
| `tools/` + `src/` | 人要长期用的 | 必须过 `tools/test.sh`、接口稳定、有文档 |

判据：「下个会话/下个用户也该有」→ 升级进 `tools/`+`src/`；只有当前任务有价值 → 留 `helper/` 用完即弃。
`tools/` 不是封地：不够用就改它、重编、测过、补文档，只是代价更高。

**选路（从省力到费劲，别跳级）**

1. **系统已有 `.so`** → `ffi.cdef` + `ffi.load`，一个 `helper/<x>.lua` 完事（零编译零子进程）。无头文件就
   `nm -D --defined-only lib<x>.so.N` 抄符号手写 cdef（范例 `helper/pdftext.lua`）；符号错只在调用时炸
   `undefined symbol`，别猜符号表里没有的东西。
2. **库没有 / 热路径 / 复杂 ABI** → 自己写 C：`native build`（`helper/`）或 `src/<feature>/`（进仓库，封装到
   `lua/ffi/<feature>.lua`，在 `lua/core/tools.lua` 暴露）。
3. **只跑一次** → `lua` 内联（进程外 30s 超时，崩了不带崩 agent），不落盘。

**改过 C/C++ 就必须重编再 `/reboot`**（reboot 只重启进程、不编译；进程内 `ffi.load` 的同路径换不掉）：

1. 仓库 C/C++ → `./tools/build.sh`；**跑安装版就 `./tools/release.sh`**（`lua/` 是软链、`build/liblite_*.so` 是
   install 时的实体拷贝，只 build 会「新源码配旧二进制」，对不上就比两处 `.so` 大小）。
2. `helper/<x>.c` → `native action=build name=x`（每次出新 `<name>-<ts>.so`，免重启生效）。
3. 先进程外验：`./tools/lite-lua -e …` 或 `native action=run`，喂真实输入 + 空/非法/超限三边界。
4. `/reboot` 让新 `.so` 与 schema 进清单，再跑真实用例 + `./tools/test.sh`（ABI 改了忘改 cdef 在这炸）。

别跳步：只改 C 不重编就 reboot、拿 `native build` 冒充 `./tools/build.sh`、改完 C 直接 `shutdown`。用法与坑写进
文件头注释 + `remember`，反复踩的升级进本节。

**native ABI**：`char *lite_helper(const char *input)` + 可选 `lite_helper_free`，UTF-8/JSON。`build`/`run`/`wrap`，
`scope=local|global` 决定写 `<cwd>/helper` 还是 `$LITE_ROOT/helper`。踩过的约束：JSON 里**键名不能与数组同名**
（`{"hits":[…],"hits":3}` 会被覆盖，计数器叫 `count`）；缺参数回 `required: pattern (string)`。

**只有工具清单冻结，派发全是动态的**：schema 启动扫一次并 memo（保前缀缓存），执行侧每次调用都读盘
（`loadfile` 重读、`.so` 按 `<name>.json` 重新 `ffi.load`）。所以：改已存在插件的 `run`、`native build` 出新
`.so`、新建 `helper/x.lua` 都**立刻按名可调**（只是清单里没描述）；想让新工具进 API `tools` 清单才要
`/reboot`；删插件立刻不可调用，清单残留的 schema 报 `helper not found`。

**`/reboot`**：退出码 75 → 监督循环拉起新进程（裸跑退化成 `execv`），会话/记忆/todo 都在盘上，新进程自动发
「重启成功，继续工作。」；`/reboot <提示词>` 的提示词优先，不设次数上限。`shutdown` 才是真停；serve/attach
不跑斜杠命令（要重启自己 kill 再拉）。

**hook 插件**：只返回 `hooks`（`before_tool`/`after_tool`/`on_user_turn`/`on_compact`/`on_session_end`）
不返回 `run` 的不进工具列表；`before_tool` 返回字符串即拦截（优先于审批），钩子错误 fail-open。插件与 agent
同进程同权限，跑不受信任的仓库用 `--no-plugins`/`LITE_PLUGINS=0`。

## 7 现有插件

细节看文件头注释；共享逻辑放 `helper/lib/`（`app_<class>_map.lua` 勿手改）。

只列**作用 + 在哪**；参数和坑看各文件头注释（`helper/<name>.lua` 开头几行），用到再读。

| 插件 | 作用 | 实现在哪 |
|---|---|---|
| `adb` | Android：screenshot/tap/swipe/text/open/shell/push | `helper/adb.lua` + `helper/lib/adb.lua` |
| `wechat` | 搜联系人/群 → 进会话 → 发消息/文件 | `helper/wechat.lua` |
| `uimap` | 视觉定位按钮：discover/learn/click/save | `helper/uimap.lua`，映射落 `helper/lib/app_<class>_map.lua` |
| `usb` | 麦/音箱/摄像头：record/play/photo/video/volume | `helper/usb.lua` |
| `music` | 常驻 VLC 播放器（本地/URL/WebDAV） | `helper/music.lua` + `helper/lib/webdav.lua` |
| `search`/`fetch` | DeepSeek 搜索 / URL→Markdown | `helper/{search,fetch}.lua` + `helper/lib/deepseek.lua` |
| `tokens` | 每日 token 账本（源 `/agent/usage`） | `helper/tokens.lua` |
| `cgrep` | 正则/字面串扫目录 → `path:line: text` | `helper/cgrep.c` + `helper/cgrep.lua` |
| `lens` | 代码库检索：`locate`/`peek`/`grep`/`dataflow` | `helper/lens.lua` → `lua/ffi/codesearch.lua` → `src/codesearch/` |
| `pdftext` | PDF 抽文本 | `helper/pdftext.lua`（纯 FFI） |
| `md2png`/`web2png`/`trending` | MD / 网页 / Trending → 长图 PNG | `helper/{md2png,web2png,trending}.lua` + `helper/lib/{md4c,htmlmd}.lua` + `src/html/` |
| `charts` | 手绘风 SVG 图表卡（54 种）→ PNG | `helper/charts.lua` → `lua/charts/` |
| `trace` | perf 探针采样 → 火焰图/热力/排行 | `helper/trace.lua` → `lua/trace/` |

`lens` **只索引 cwd 之外的项目**（lite 自身不建索引），细节见 `src/codesearch/README.md`
与 `code_search_best_practices.md`。

## 8 serve

`./tools/run.sh serve --host 0.0.0.0 --port 8765`：同一端口靠首包嗅探分流 JSONL(attach)/HTTP，HTTP 复用同一条
队列和同一个 agent（谁先来谁先答）；**不鉴权**，暴露面由 `--host` 控制（默认 `127.0.0.1`）。

| 端点 | 说明 |
|---|---|
| `GET /health` | 探活 `{ok,live,busy,queued,shell,pid,shell_sec}`，不排队 |
| `POST /prompt` | `{"prompt":"…"}`（也收裸文本），回 `{"ok":true,"text":…}`；超时 `LITE_SERVE_HTTP_TIMEOUT`（900s）回 504 |

判「远端闲置没」用 `lite serve --probe HOST:PORT`（采样 3 次、间隔 2s，连续 N 次空闲才判闲）：**单次采样不当
判决**（`active_proc:alive()` 是「尽快」不是瞬时）。退出码 0=`wake`、3=`busy`、4=`unreachable`、5=`unstable`（再采）。

## 9 进化

**进化任务由人下达**：lite 没有内在目标，是「接到任务就能把能力补齐的执行器」，要求「缺能力不降级」，
不是「自己找活干」。环 = 感知（内置工具够吗/系统 `.so` 有吗/`helper/` 已有吗：`lite plugins`、`ldconfig -p`、
`nm -D`）→ 造（§6 选路）→ 验（真实输入 + 空/非法/超限，进程外）→ 留（一次性 `helper/`，长期 `tools/`+测试+本文件）。

**靠摩擦小，不靠聪明**：造（秒级）、试（进程外）、退（`git checkout`+重编+reboot）、留（升级进 `tools/`）都便宜，
所以不必事前判准——`tools/test.sh` 只测契约。`helper/*.so` 多版本共存无害（按 `<name>.json` 取）。

**知识来源与冲突**：代码 > gitlog > 本文件 > `mem.bin`。冲突时**代码赢**，顺手修注解。跨实例知识放 gitlog
（`git pull` 即合并）；`mem.bin` 不进 git，它是缓存不是真相。commit subject 做目录、body 记「为什么」和
「反着改会踩什么」；踩过一次写 body，两次升级进本文件。

**多实例收敛**：一致 = 源码一致 + 重编 + `reboot`。单写者：slave（远程实例）验过才 commit，master 只
`git pull`+重编+reboot。C/ABI 硬验证放远程实例（`design.md:D10`），本机只做小改与文本级验证。

## 10 参考

Pi `/opt/pi-mono`、Reasonix `/opt/reasonix`、opencode `/opt/opencode`；缓存 `/opt/code_caches/<name>_cache`。
逐项目查不 cross-search，只借思路。符号写法：Go `pkg::Func`、C++ `Class::method`、TS 导出名。
