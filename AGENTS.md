# AGENTS.md — lite

AI-native harness：记忆、工具、FFI、X11。

## 0 我是谁

| 层 | 内容 |
|---|---|
| 模型 | DeepSeek（多模态，可读图） |
| harness | `lua/`：循环、工具、记忆、TUI/serve、compact |
| 机器 | `bash` 直达 shell、编译器、系统 `.so`、X11、GPU |

**能力 = `bash`/`web` + 编译器 + FFI + `native`**；内置工具只是快捷键。
- `web`：内置 libcurl GET，只取 live data，不翻仓库。
同目录只允许一个写实例（`mem.lock`）；上下文有界，旧内容靠 `recall`。

## 1 看见自己

先定位窗口再截图，不要直接截全屏（可能截到遮挡窗口）。

```bash
./tools/lite-lua tools/see.lua --list
./tools/lite-lua tools/see.lua --class wechat --width 1280
```

输出图片路径后 `read`；`--tui --snapshot FILE` 是文本快照；`state/sessions --json` 查状态。

## 2 代码地图

- `lua/main.lua`：入口；`lua/core/`：agent/tools/memory/prompt/session/compact（含 web）/reboot
- `lua/tui/`、`lua/ffi/`、`src/{cache,image,x11,codesearch}/`、`helper/`、`tools/`
- `src/codesearch/`：从 `/opt/my_db` 全量迁移的代码索引/调用图/数据流/向量检索；
  `api.c` 是 JSON-in/JSON-out 公共入口，其余 `.c` 来自原 CLI（main 改名、日志走 stderr）。
  `lua/ffi/codesearch.lua` 包 FFI，工具入口 `helper/lens.lua` 做 action 编排；
  `locate`（语义/符号查询 + 内联源码窗口，默认起手式）/`peek`（file:line 读窗口）/
  `grep`（作用域 cgrep，>3000 文件的目录直接拒扫）是「搜→读」组合三连，
  写法纪律见 `src/codesearch/code_search_best_practices.md`。`action` 可省：
  给了 `pattern`→`grep`、`query`→`locate`、只给 `path`→`peek`、都没有→`status`。
  `action=dataflow`（`lite_cs_dataflow_query`）走 import 写的 `dataflow/funcs/<func>`
  与 `dataflow/vars/<var>` 两条键，`cache_get` 直取，不读几百 MB 的 `dataflow.json`
  / `_func_index`；旧 KV 没这两类键，要重跑一次 `import`。
  调用边带间接标注：调用点是 `obj->fn()` / `obj.fn()`（Lua 的 `M.fn()` 同理）时
  `call_graph.json` 里多 `"indirect":true` + `"via":"<接收者>"`，import 透传到
  `callers/`、`callees/` 的 site，query 显示成 `name[via obj]`。边**仍然**按裸名解析
  （没有类型信息），标注只表示「这条边可能混了同名直接调用」，旧 KV 无此字段 = 直接调用。
  **lite 仓库自身不做索引**（`~/.local/share/lite/codesearch/` 下不保留 `lite` 那一份）：
  自己改自己就 `read`/`cgrep`/`edit`，语义检索丢给 `cgrep` + 代码地图，别为查自己跑
  `lens build`（几十分钟换不到有用信息，还占几百 M）。`lens` 只服务于**外部**项目。
- `lua/ffi/x11.lua` + `xdo.lua`：**自包含单文件**（只用 LuaJIT `ffi` + 系统 libX11/libxdo，不引用 lite 代码、不注册工具），可整对拷给别的项目；`x11.lua` 靠 `require("ffi.xdo")` 找同伴，换布局要同步改这一行
- `lua/tui/mouse.lua` + `clipboard.lua`：拖选/剪贴板；选区在 `screen.lua`

## 3 记忆

每个目录一份 `mem.bin` + `mem.idx`；删掉=清空该目录记忆。

- `/agent/knowledge/*`：长期事实；`/agent/session/<id>/*`：消息/摘要/工作态/todo
- `/agent/working/*`：wake 等运行态，不注入 prompt

最近 `LITE_SESSION_RAW_KEEP`（默认 200）条非 user 原文 + user 永久；tool 结果入库截到
`LITE_TOOL_RESULT_CHARS`（默认 8192），旧内容靠 turn 摘要/`recall`。写实例持 `mem.lock`。

**取**（下面这些在代码里，别靠猜）：

- 自动注入：每个用户轮**首次请求**注入一次（`lua/core/agent.lua:568`），工具循环的后续
  请求不注入（模型已看过，重复注入破坏前缀缓存）。查询 = 最新 user 文本；不足 80 字接上
  一条 user 的前 200 字，总截 600（`prompt.recall_query`）。上限 8 条 / 2400 字，作为
  **末尾**一条 `system` 的 `<retrieved_memory>` 块。
- 白名单 + 权重（`memory.lua:recall`）：只收 `/agent/knowledge/`(1.0)、会话 `working/`
  (0.9)、`msg/` 里的 user 原文(0.8)、`turn/` 摘要(0.6)；`/agent/working` 永不注入。
  `hits>0` 才留，按 IDF + 长度惩罚 + 30 天半衰打分，最多 2 条 turn / 4 条 user。
- 主动 `recall`：看到 `hard_window` 的丢弃提示且需要那段；用户提"上次/之前"而窗口里
  没有；动手前核对旧结论。**字面匹配、无向量**，换个说法可能一条不中，且召回失败模型
  自己看不见（`stats()` 不进 prompt）。
- `remember` 判据：跨会话仍成立 + 重踩成本 > 记录成本。存"`excludes` 不持久化"这类坑，
  不存"某文件在第几行"。

system prompt 必须**字节稳定**（时钟/轮次/预算都追加在消息末尾的同一个尾部块，走
`prompt.runtime_block` / `prompt.budget_block`），否则前缀缓存全丢；工具清单在 system 里
只列名字，schema 以 API `tools` 字段为准。会话结束 `session_end` 把"反复失败未恢复"
（同 tool+args 失败 ≥2 次）写成 `fail/<ts>` 事实。

## 4 铁律

MUST：改代码后 `./tools/test.sh` 通过；依赖变更同步 `tools/check_deps.sh` 和本文件；
C ABI/FFI 同步 `lua/ffi/*` 与文档；UI 用 `tmux capture-pane` 或 `--tui --snapshot` 验收；
引用写 `file:symbol`，结论标 `[static]` / `[verified]`；commit 用
`feat/fix/style/docs/chore(scope): ...`，只在用户明确要求时 commit/push。

MUST NOT：不用 `python`/`sed -i` 改仓库文件（用 `edit`/`write`）；不用
Chrome/WebView/CEF/Electron；不起 `xdotool/wmctrl/import`；不用 `systemd --user`；
不用 `pkill -f`；不把 API Key 或 `$ROOT/lib` 写进仓库/`LD_LIBRARY_PATH`。

**密钥规范**：密钥只活在环境变量里。人写 `~/.config/lite/.env`（或 workspace `.env`），
`tools/lua.sh` / `run.sh` 启动时注入进程环境，脚本和插件一律 `os.getenv` 读；
仓库文件里不出现字面量 key、不 `print` key、不把 key 拼进命令行参数（`ps` 可见）。
`tools/auto_unit.lua` 里有一条机械检查扫 `helper/` + `lua/` 的 `sk-` 字面量，
占位符（`sk-test`、`sk-...`）放过。

## 5 命令

```bash
./tools/build.sh
./tools/test.sh
./tools/run.sh                 # TUI；另见 --once/--recall/state/sessions/serve/attach
./tools/run.sh --once --json "prompt"
./tools/run.sh plugins [--json]   # helper/ 插件清单 + 加载错误（只读快照）
./tools/run.sh --tui --snapshot out.txt
./tools/run.sh --gui           # 自绘 GUI（SDL2+SDL2_ttf，见 lua/gui/，可选依赖）
./tools/release.sh             # build + package + install；源码安装软链 lua/
```

工具输出 ≤ 32KB；`read` 文本/目录限 workspace，图片可读 `$TMPDIR:/tmp:/var/tmp`；
`bash` 可异步长跑，TUI 里 `Ctrl+C` 取消。回归测试先在修复前 commit 确认 FAIL。

工具失败要**可自修**：报错带原参数 + `required` 键 + 退出码语义（`tools.exit_note`：
124 超时 / 126 不可执行 / 127 未找到），同一调用连续失败第 2 次起追加
`[this exact call has now failed N times]`，成功时清账。多文件只读用
`read` 的 `paths` 数组批量读（N 个文件 1 次往返），图片一次一张。

## 6 原生扩展

**两条通道，别混**：`tools/` 是**人设计实现的专业插件**——提前写、要过 `tools/test.sh`、
进版本控制、接口稳定、必须有文档；`helper/` 是**大模型自己发挥的**——会话里临时起意就写，
允许粗糙、允许下次删掉，按名即调、不承诺稳定，只受 `sk-` 字面量机械检查约束。
判据：这东西「下个会话/下个用户也该有」→ 升级进 `tools/` 并补测试与文档；只有当前任务
有价值 → 留在 `helper/` 用完即弃。

**`tools/` 同样能进化**，不是人写死的封地：会话里发现某个已存在的 `tools/` 脚本/插件不够用，
就改它、重编、测过、写进文档——只是纪律更严（`tools/test.sh` 必须过、接口要稳、要更新
`AGENTS.md` 对应表格）。差别只在**代价与责任**，不在能不能改。

注意发现机制：插件只扫 `<cwd>/helper` → `$LITE_ROOT/helper`（`lua/core/tools.lua:_helper_roots`），
**`tools/` 里的 `.lua` 不会被当插件加载**（那是 build/test/run/release 这类仓库脚本）。
现有 adb/wechat/music/search/fetch/tokens/uimap/usb 八个住 `helper/`，因为发现只认那里。

**改过 C/C++ 就必须重编，然后 `/reboot` 才算测得上**（硬规矩，适用于 `tools/` 与 `helper/`
两条通道）。`reboot` 只重启进程、**不编译**；Lua 侧 `ffi.load` 的 `build/liblite_*.so` 是进程内
一次性句柄，同路径换不掉，中间态永远是旧代码。所以顺序是：

| 步 | 动作 |
|---|---|
| 1 | 仓库 C/C++（`src/**`、`include/**`）→ `./tools/build.sh`（或 `cmake --build build --target <t> -j`） |
| 1b | **跑的是安装版就走 `./tools/release.sh`**（= build + package + install）。`lua/` 是软链回仓库、改了立刻生效，`build/liblite_*.so` 却是 `install` 时的实体拷贝：只 `build.sh` 的话仓库 `.so` 变新、`/usr/local/share/lite/build` 还是旧的，reboot 起来仍是旧 C 代码。对不上就 `ls -l build/liblite_*.so /usr/local/share/lite/build/` 比大小/mtime |
| 2 | `helper/<x>.c` → `native build name=x`（每次出新 `<name>-<ts>.so` + 清单，免重启即生效） |
| 3 | 先用**进程外** `./tools/lite-lua -e ...` / `native action=run` 验行为，别在主进程里猜 |
| 4 | `/reboot` —— 让新 `.so` 与插件 schema 进清单，主进程换成新代码 |
| 5 | 重启后跑真实用例 + `./tools/test.sh`；ABI 变了没改 `lua/ffi/*.lua` 的 cdef 会在这里炸 |

**别跳步**：只改 C 不重编就 reboot（看到的是旧行为）、用 `native build` 冒充 `./tools/build.sh`
（产物不同，`build/liblite_*.so` 还是旧的）、或者改完 C 直接 `shutdown` 收工（下个会话才踩）。

**C/ABI 的硬验证放远程实例**（见 `design.md:D10`）：本机进程内 `ffi.load` 过的同路径 `.so`
换不掉，验失败还会污染主工作区与主会话记忆。所以「编译 → 验 → 重启」这套搬到另一台机器上的
实例里做：slave 上 `./tools/build.sh && ./tools/test.sh` 过了才 commit，master `git pull` 后
重编、`reboot` 生效。本机只做小改与文本级验证，不为了试错在主工作区反复编译半成品。

**缺能力先造，别降级**（自我进化流程）。碰到「这个命令没装 / 这个库没有 / 内置工具缺这个
动作」时，不许手工硬凑、更不许直接回「做不到」——按下表走一遍。整条链**会话内**可用，
不需要重启：

| 步 | 动作 | 怎么落 |
|---|---|---|
| 1 判 | 内置工具能覆盖？系统已有 `.so` 能 `ffi.load`？`helper/` 里已经有？（`lite plugins` / `ldconfig -p \| grep`） | 三者都不行才造 |
| 2 估 | 只跑一次的用 `lua` 内联；会反复用的才落 `helper/` | 代价/收益判定见 `design.md:D6` |
| 3 写 | C/C++ 导出 `char *lite_helper(const char *input)` + `lite_helper_free`，输入输出 UTF-8/JSON | `native action=build name=x lang=c libs=["pthread"]` |
| 4 验 | `native action=run` 喂真实输入，**先看返回串**再信它；空结果 / 非法输入 / 超限三种边界都跑 | 报错就改源码重 build |
| 5 接 | `native action=wrap` 生成 `helper/<name>.lua` + schema，或手写 `{schema=...,run=...}` | 立刻按名可调 |
| 6 记 | 用法与坑写进文件头注释 + `remember`；反复踩的补进本节 | 别让下个会话重踩 |

三条真踩过的工程约束：

- **JSON 键名不能和数组同名**：`{"hits":[...],"hits":3}` → cjson 取后者，数组被覆盖成数字。
  计数器改叫 `count`。
- **错误必须可自修**：缺参数时回 `required: pattern (string)`（原参数 + 缺哪个键），
  别让调用方猜；退出码语义走 `tools.exit_note`。
- **每次 build 出新 `.so`**：`helper/<name>-<epoch>.so`，下次调用自动用最新的；
  旧版本留着无害，定位靠 `helper/<name>.lua`。

**「清单冻结」≠ 能力封顶**：只有 API `tools` 的自动发现被冻结（保前缀缓存），
`native run` / `lua`（`ffi.load` 最新 `.so`、`loadfile` 插件）都是会话内动态出口，
新工具**按名调用立刻可用**，重启后才出现在模型可见清单里。所以发现能力缺口的正确
反应是「写一个」，不是「等重启」或「做不到」。范例：`rg` 没装 → `helper/cgrep.c`
（pthread + regex，59 个 lua 文件 1ms）→ `helper/cgrep.lua` 包一层 → 当场调用。

**要清单里看见，就走 `/reboot`** —— 自动重启，自我进化的收尾动作。`reboot` 工具或 TUI
`/reboot` 只置标记，本轮（含排队消息）收完才动：退出码 75 → `tools/lite-lua` 监督循环
拉起全新进程（裸跑退化成 `execv`）。会话/记忆/todo 都在盘上，**历史不丢**；新进程带
`--reboot` 起来**自动发「重启成功，继续工作。」**，模型接着上一轮往下干，插件清单与
`.so` 全部重扫 —— 刚写的 `helper/<x>.lua` 下一轮就带 schema 出现在 API `tools` 里。

**重启可以带话**：`/reboot <提示词>`（或 `reboot` 工具的 `prompt` 参数）给的那句，优先
于默认的「重启成功，继续工作。」，重启后自动发出去。跨进程靠一次性文件
`<XDG_DATA_HOME|~/.local/share>/lite/reboot.prompt`（`lua/core/reboot.lua`）：子进程改不了
父进程环境，argv 会被 `ps` 看见，所以只有文件这条路；写 = `main.lua` 退出 75 之前，
读 = 新进程带 `--reboot` 起来时 `take()`（读完即删，带 cwd 作用域，陈旧提示词不污染下一次）。
于是自造工具的完整闭环是：`native build` / `write` → 按名调用验一遍 → `reboot` → 清单可见。
**改的是仓库 C/C++ 就先 `./tools/build.sh` 再 reboot**（reboot 不编译，见本节开头那张表）。
**前缀缓存不丢**：provider 的 cache 是服务端按 prompt 内容前缀命中的，新进程重建出的
system prompt 字节相同（时钟/轮次/预算都在本轮尾部的 `runtime_block`）、历史从 JSONL/mem.bin
原样回放 → 同一串 token，命中率照旧。真代价有三条：多一轮「继续工作」的请求；内存里全文的
tool 结果在盘上是截断版（`LITE_TOOL_RESULT_CHARS`，默认 8192，`session.lua:store_copy`），
重启看到的是截断版、且第一个截断点之后的前缀跟重启前不同（那一段才真 miss）；进程内的临时态
（异步 bash 长跑、连接复用、TUI 回滚）清零，serve/attach 的客户端得重连。本地启动本身
（插件扫描 + mmap + JSONL 回放）是毫秒级。连续重启**不设次数上限**（旧的
`LITE_REBOOT_MAX` 已去掉：自我演进常常连着重启几次，一刀切会打断长任务），
`LITE_REBOOT_CHAIN` 也不再注入子进程环境。
`shutdown` 才是真停（不自动接续）；serve/attach 只认 JSONL 请求、不跑斜杠命令，
外部客户端要重启就自己 kill 再拉。

**选路优先级（从省力到费劲，别跳级）**：

1. **系统已有 `.so`** → 直接 `ffi.cdef` + `ffi.load`，**一个 `helper/<x>.lua` 就完事**（零编译、
   零子进程、零 `.so` 产物）。没装开发头也照做：`nm -D --defined-only lib<x>.so.N` 抄导出符号手写
   cdef 即可（`helper/pdftext.lua` 就是这么吃 `libpoppler-glib.so.8` 的）。**先找库再动手**：
   `ls /usr/lib/x86_64-linux-gnu/lib*.so.*`、`pacman/dpkg -S` 看已装了什么。
2. **库没有、或热路径/复杂 ABI** → 才自己写 C：`native build`（`helper/`，模型自造）或
   `src/<feature>/`（进仓库的正式模块），封装放 `lua/ffi/<feature>.lua`，工具在
   `lua/core/tools.lua` 暴露。

手写 cdef 的代价是丢掉编译期检查：符号错只会在调用时炸 `undefined symbol`，靠试错收敛
（pdftext 连踩 `poppler_page_new` → `poppler_page_free`/`poppler_document_free`，最终统一
`g_object_unref`）。所以第 1 步的前提是**符号表里确实有它**，别猜。

- C ABI：`int lite_<feature>_...` + `const char *lite_<feature>_error(void)`。
- `.so` 用 `$ORIGIN` RPATH；打包只复制非 libc 依赖到 `dist/lib/`。
- 大库/模型不随包：见 `README.md` 的 `ort_link.sh`、`cuda_provider.sh`、`LITE_DIST_WITH_*`。
- `lite_codesearch` 的 tokenizers 静态库随仓库自带：
  `third_party/codesearch/lib/tokenizers-cpp/`（`-DLITE_CS_TOKENIZERS_DIR=...` 覆盖）；
  源码也在 `third_party/codesearch/tokenizers-cpp/`，用 `tools/build-tokenizers.sh` 离线重建 `.a`。
  缺失时 CMake 跳过该 target，索引/查询功能不可用但其余构建正常。
  ONNX Runtime 运行期 `dlopen`（`LITE_ORT_LIB`），模型用 `LITE_CS_MODEL_DIR`；
  GPU 只走 CUDA + FP16，不使用 TensorRT，也不预加载 `libnvinfer*`。
- 热重载：Lua 清 `package.loaded[...]` 后 require；TUI `/reload` 只重载 `core.tools` /
  `core.prompt` / `ffi.*`，**不重扫插件快照**。进程内 `ffi.load` 过的同路径 `.so` 换不掉，
  但 `native build` 每次出新文件名（`<name>-<ts>.so` + `<name>.json` 清单），下一次
  helper 调用按清单重新 `ffi.load` → **不用重启**。

`native` 自造工具：`build` / `run` / `wrap`；ABI 为
`char *lite_helper(const char *input)` + 可选 `lite_helper_free`（UTF-8/JSON）。
插件发现 `<workspace>/helper` → `$LITE_ROOT/helper`；`scope=local|global` 控制写入侧。
wrapper 返回 `{ run=function(args,env) ... end }`；重新 build 生成新 `.so`，免重启。

**只有清单冻结，派发全是动态的**（`design.md:D5`）：`helper/*.lua` 里返回
`{ schema={...}, run=function(args,env) end }` 即可同时声明工具名和实现
（`.tool.json` 写法仍可用、优先）。**冻结的只是 API `tools` 字段**：schema 在会话启动
扫一次并 memo（`_helper_cache`），之后 `schemas()` 用快照 —— 保前缀缓存，新建/删除
`.lua` 不会自己冒进清单。**执行侧每次调用都读盘**：`_run_helper_tool` →
`_helper_find`（`file_size` 现查磁盘）→ `loadfile`（每次重读）→ `.so` 按
`<name>.json` 清单重新 `ffi.load`。所以：

| 动作 | 生效时机 |
|---|---|
| 改已存在插件的 `run` | 立刻，下次调用 |
| 新建 `helper/x.lua` / `native wrap` | 立刻，**按名调用即可**（模型看不见描述，由 `native` 输出/你点名） |
| `native build` 出新 `.so` | 立刻，下次调用换新句柄 |
| 想让新工具**出现在 API 清单** | `/reboot`（会话接续、历史不丢）或新会话 |
| 删插件 | 立刻不可调用；清单里残留的 schema 会报 `helper not found` |

所以「不热插拔」只指工具清单，不是能力。要试新代码而不想动进程，走 `lua` 工具（进程外
`tools/lua.sh -e`，`args` 走 `LITE_LUA_ARGS` JSON，默认 30s 超时，审批同 `bash`）。
入口分两个：`tools/lua.sh`
给插件/脚本（`LITE_CWD`、workspace `?.lua`/`?.so` + `helper/lib/?.lua`、预加载
`liblite_*.so` 与 workspace `build|lib|helper/*.so`、自动读 `.env`：cwd 向上 12 级 →
`~/.config/lite/.env` → 仓库 `.env`，已设变量优先；`LITE_ENV_FILE=路径` 只读该文件、
`/dev/null` 全关；预加载失败写 stderr，`LITE_PRELOAD_WARN=0` 静音），
`tools/lite-lua` 给仓库内部脚本（干净，不继承 workspace 状态）。

**hook 插件**：只返回 `hooks`（`before_tool` / `after_tool` / `on_user_turn` /
`on_compact` / `on_session_end`）不返回 `run` 的插件**不进工具列表**，只当钩子用：
`before_tool` 返回字符串即拦截（优先于审批），`on_user_turn` 返回值可改写用户文本。
hook 错误一律 fail-open（记 `_hook_errors`，不炸 agent）。`has_hooks()` 为空时零开销。
插件与 agent 同进程同权限，跑不受信任的仓库用 `--no-plugins` / `LITE_PLUGINS=0` 全关。

**查插件用 `lite plugins`**：只读启动快照、不触发加载，列每项的
`name/path/scope/tool/hooks` 与错误（`--json` 给脚本）；启动时只打印错误
（`plugin <name> failed: ...`），清单不打扰。别靠翻 `helper/` 猜加载了啥。

**现有插件做什么**（`helper/*.lua`，实现细节看文件头注释；共享逻辑在 `helper/lib/`）：

| 插件 | 作用 | 关键用法/坑 |
|---|---|---|
| `adb` | Android 设备：screenshot/tap/swipe/text/open/shell/push | 坐标是**设备像素**，先截图再换算；中文走 AdbKeyboard |
| `wechat` | 微信：搜索联系人/群 → 进会话 → 发消息/文件 | libxdo 直驱 + 每步 OCR 验收；坐标是 2560x1440 屏幕像素 |
| `uimap` | 视觉定位按钮：discover/learn/click/save | 结果落 `helper/lib/app_<class>_map.lua`，每 app 一文件 |
| `usb` | 本机麦/音箱/摄像头：record/play/photo/video/volume | 设备可用名字子串；缺 arecord/ffmpeg 只对应 action 报错 |
| `music` | 后台常驻 VLC 放歌：play/pause/next/volume/seek/playlist | 源可为本地路径、关键词（WebDAV 搜）、`dav://host:port/路径`（流播不下载）。控制走 MPRIS（本机无 `playerctl`/`socat`），WebDAV 逻辑在 `helper/lib/webdav.lua` |
| `search` | DeepSeek Search：关键词→rerank 结果+摘要 | 需要 `DEEPSEEK_API_KEY` |
| `fetch` | DeepSeek Fetch：URL→Markdown 正文 | 同上；替代原始 HTTP 抓页面 |
| `tokens` | 每日 token 账本查询 | 数据源 `/agent/usage`，跨会话同一本账 |
| `cgrep` | 代码搜索：正则/字面串扫目录，输出 `path:line: text` | 本体是 `helper/cgrep.c`（pthread + POSIX regex）编出的 `.so`，Lua 层只做 JSON→文本；本机没 `rg`/`ugrep`，搜代码就靠它。`ext`/`fixed`/`per_file`/`threads` 可省，输出自身封顶 8000 字 |
| `lens` | 代码库级检索：陌生项目找入口/子系统、跨文件符号与调用关系、数据流、语义找实现 | 需要先建索引；适合 `cgrep` 做不到的跨文件/语义问题。用法、索引、依赖、性能与内核实践见 `src/codesearch/README.md` |
| `pdftext` | 抽 PDF 文本（`path/first/last/max_chars`） | 纯 Lua FFI 直连 `libpoppler-glib.so.8`，零编译零子进程；本机无 poppler 头文件，cdef 手写（导出符号 `poppler_document_get_page`/`poppler_page_get_text`），释放用 `g_object_unref`（`poppler_page_free`/`poppler_document_free` 已不在 134 里）；缺库报装 `libpoppler-glib8` |
| `md2png` | Markdown 文件 → HTML → 长图 PNG（`path/out/width/height/scale/gfm`） | 全 FFI 无子进程无 Chrome：`libmd4c.so.0` 解析（**无 md4c.h，cdef 手写**，`abi_version` 必须 = 0、结构体字段顺序不能错否则崩在回调里）→ `build/liblite_html.so` 出图 → `src/html/render.cpp` 的字体。同名 `.html` 一起落盘便于调试；`height` 默认 **0 = 自动测高**（`render.cpp` 先布局取 `doc->height()` 再定高），给正数才是固定视口、超出裁掉 |
| `trending` | GitHub Trending → Kami 排版 → 长图 PNG（`lang/since/limit/width/height/scale/out`） | `curl` 抓页面（`io.popen`）+ 文件内 `parse()` 的 `gmatch` 逐字段抽（**无 dom 库**，页面结构一变就返回空表）；出图复用 `liblite_html.so`。坑：HTML 必须一次成型（追加 `<style>` 会让内容溢出被裁）；`.page{width:auto}` 铺满、`width` 别低于 780（19px 仓库名会折行）；`os.date` 里 `"%%m"` 是字面量；`height` 默认 0 = 自动测高，加 `limit` 不用手动调高 |
| `web2png` | URL → 正文 → 资料卡片长图 PNG（`url/out/width/scale/title/max_chars`） | 三段链路：`helper/lib/deepseek.lua` 的 `/v1/tools/fetch` 取干净 Markdown（无 `DEEPSEEK_API_KEY` 则降级 `core.http` 抓 HTML 去标签）→ `helper/lib/md4c.lua` 转 HTML 片段 → `liblite_html.so` 出图（`h=0` 自动测高）。样式全内联，cairo toy font 只认单族名，**禁止写字体栈** |

**什么时候用 lens**：陌生代码库要找子系统入口/实现、查某符号的 callers/callees
与数据流、或按自然语言找相似实现时用它；单文件/精确文本搜索先用 `cgrep`。
**只在 cwd 之外的外部项目上建索引**——lite 自己的源码不建（见 §2）。

索引创建、参数、加速、依赖、Linux/参考项目实践统一看 `src/codesearch/README.md`
（§0 快速开始，§4/§5 详细流程）。

`music` 的 `dav://` 语义：`dav://host:port/路径` 列目录**直接流播**（默认整库随机，
`limit=N` 限首数，`index=N` 选第几首）；**只写 `dav://` 不带路径会 PROPFIND 失败**，
因为 host 拆不出来——要整库就带上 `WEBDAV_MUSIC` 的路径（`~/.env` 里有）。

**`helper/lib/` 是共享模块，不是插件**（扫描只平铺看 `helper/*.lua`，子目录一律跳过）：
`adb.lua`（传输层）、`music.lua`（VLC/MPRIS 控制）、`usb.lua`（ALSA/V4L2）、`uimap.lua`
（视觉定位）、`deepseek.lua`（search/fetch 共用的鉴权+重试）、`webdav.lua`（PROPFIND +
libcurl `CURLOPT_USERPWD`，凭据不进 argv/m3u）、`app_<class>_map.lua`（`uimap learn` 生成的
坐标表，**勿手改**）。要给插件加共用能力就放这里，别复制两遍。

**调一次插件工具的完整链路**（`lua/core/tools.lua`）：

1. 发现 —— `_scan_helper_schemas`（`:1173`）遍历 `_helper_roots()`：`<cwd>/helper`
   （local）→ `$LITE_ROOT/helper`（global），每个根一次 `ls -1` **平铺**，只认
   `*.tool.json` 与 `*.lua`；`helper/lib/` 之类子目录不会被当插件（search/fetch 就靠这个共享共用库）。
2. 快照 —— `helper_lua_load`（`:1148`，`loadfile`+`pcall`）→ `helper_lua_schema`
   （`:1156`）：`run`+`schema` = 工具，只有 `hooks` = 纯钩子；`BUILTIN_TOOLS` 不可覆盖；
   同名 `.tool.json` 优先。结果 memo 进 `_helper_cache`（`:1277`）。
3. 上桌 —— `M:schemas`（`:276`）把快照拼进 API `tools` 字段；system prompt 里只列名字，
   保证字节稳定。
4. 派发 —— 模型 tool_call → agent 循环 → `M:call`：内建 if-else 链先走，都不中才落
   `_run_helper_tool`（`:1465`）。
5. 执行 —— `loadfile` **每次调用都重读文件** → 校验 `table.run` → `_helper_env(p)`
   （`:1444`，`{cwd, helper_dir, scope, ffi, load(so), call(native)}`）→
   `pcall(mod.run, args, env)`。
6. 回流 —— `nil`→`(helper returned nil)`；抛错→`error: helper <name>: ...`；
   否则 `truncate`(≤32KB) → `error_hint`（同调用失败计数）→ 回消息。

**插件要密钥怎么办**：只读环境变量，不读文件、不内置。插件在 agent 进程里跑，
`run.sh` 启动时已把 `.env`（`~/.config/lite/.env` / workspace `.env`）灌进环境，
所以 `helper/*.lua` 里 `os.getenv("DEEPSEEK_API_KEY")` 直接可用；缺 key 时
`error` 里写清变量名和"写进 `~/.config/lite/.env`"，别打印别的前缀/后缀片段。
独立脚本走 `tools/lua.sh`，同样自动带 `.env`。共用逻辑（key 读取、错误表、
重试）放 `helper/lib/<vendor>.lua`（见 `helper/lib/deepseek.lua`）。

所以「不热插拔」只针对第 2 步的**工具清单**：改插件实现立刻生效（第 5 步重读），
新建/删除 `.lua` 才需要重启；钩子走 `has_hooks`（`:1366`）旁路，与工具派发无关。

## 7 持续自主进化（原理与流程）

**前提**：进化任务由人下达。lite 没有内在目标，也不需要——它不是要变成有意图的主体，
是**接到任务就能把能力补齐的执行器**。所以「自己发现缺口」不是要求，「缺能力不降级」才是。

### 7.1 闭环四环

| 环 | 动作 | 入口 | 保底 |
|---|---|---|---|
| 感知 | 内置工具够吗 / 系统 `.so` 有吗 / `helper/` 已有吗 | `ldconfig -p`、`nm -D --defined-only`、`lite plugins` | 三者都不行才造 |
| 造 | 现成库 → `ffi.load`；要 C → `native build`；进仓库 → `src/` | §6 选路优先级 | `lua` 内联跑一次 |
| 验 | 真实输入 + 空/非法/超限三边界 | `native run`、进程外 `./tools/lite-lua -e` | 硬验证推远程实例（`design.md:D10`） |
| 留 | 一次性 → `helper/`；下个会话也该有 → `tools/` + 测试 + 本文档 | `native wrap` / 手写 `{schema,run}` | `reboot` 让清单可见 |

### 7.2 原理：靠摩擦小，不靠聪明

代价全压到秒级，「缺什么造什么」才是日常动作而不是大工程：

| 环节 | 代价 |
|---|---|
| 造 | `native build` 秒级；`helper/*.so` 随仓库走（`!helper/*.so`），clone 下来直接能调 |
| 试 | 进程外 `lua`（30s 超时），崩了不带崩 agent |
| 退 | `git checkout` + 重编 + `/reboot`（`build/` 未跟踪，只回源码跑的是旧 `.so`） |
| 留 | `helper/` 验完升级进 `tools/`，补测试与文档 |

**没有事前判准是选择，不是缺失**：质量好坏由模型判断、由人下任务定义，harness 只负责
让验证和回退都便宜。试错成本低时不需要精确的 fitness function——所以 `tools/test.sh`
（68 行）只测契约（能调通、结构对）、不测性能基线，属于正常。

`helper/` 里多版本 `.so` 入库无害：`_helper_so_abs`（`lua/core/tools.lua:1134`）按
`<name>.json` 清单的 `so` 字段取，**不按时间戳排序**，每次 `native build` 重写清单即自愈。
本地都会重编，可以不清理。

### 7.3 知识从哪来，冲突听谁的

| 源 | 内容 | 腐坏方式 |
|---|---|---|
| **代码** | 唯一真相 | 不错，但会变；注解总落后于它 |
| **gitlog** | 跨实例、跨会话的推导与坑 | 只增不清 |
| `AGENTS.md` | 反复踩到才升级的规则 | 落后于代码 |
| `mem.bin` | 本机、本实例的局部经验 | 陈旧；`recall` 字面匹配，召回失败模型自己看不见 |

- **冲突时代码赢**，然后顺手修注解（§4 要求引用写 `file:symbol` 就是这个桥）。
- **跨实例知识放 gitlog**：`git pull` 一次即合并、带时间与作者、不可变（改它要改历史）。
  `mem.bin` **不进 git 是对的**——它是缓存不是真相，各实例局部经验本就该不同。
- commit 纪律：**subject 做目录，body 记「为什么」和「反着改会踩什么」**，结论标
  `[static]`/`[verified]`。踩过一次 → 写 body；踩过两次 → 升级进本文档。
- 现场探查（`nm`/`man`/`ldconfig`/`web`）是获取途径但不写盘：一次性结论别塞 `mem.bin`。

### 7.4 多实例怎么收敛

各实例**最后代码一致**就够；一致 = 源码一致 + 重编 + `reboot`。`build/` 未跟踪，安装版
`lua/` 是软链而 `build/liblite_*.so` 是 install 时的实体拷贝，只 `build.sh` 会得到
「新源码配旧二进制」（见 §6 那张表）。

- **单写者**：slave 验过才 commit，master 只 `git pull` + 重编 + `reboot`，不各写一份历史
  （`design.md:D10`）；两边各自 commit 再合 = 第三份谁都没验过的代码。
- **长任务开远程实例（分身）**：进程内临时态（异步
  bash、连接复用）清零、同目录 `mem.lock` 单写实例这些麻烦自然消失，主工作区与主记忆
  一个字节不动。`serve` 走 `net.listen(host, port)`（`lua/core/serve.lua:138`）是 TCP
  而非 unix socket，所以主实例能连上去看 slave 在干什么。

## 8 参考实现（新功能先查）

参考：Pi `/opt/pi-mono`、Reasonix `/opt/reasonix`、opencode `/opt/opencode`；缓存
`/opt/code_caches/<name>_cache`。逐项目查，不 cross-search，只借鉴思路。
原 my_db 的 code search 已迁入 `src/codesearch/`，不再依赖 `/opt/my_db`。
符号：Go `pkg::Func`、C++ `Class::method`、TS 导出名。
