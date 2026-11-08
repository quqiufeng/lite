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

- `lua/main.lua`：入口；`lua/core/`：agent/tools/memory/prompt/session/compact（含 web）
- `lua/tui/`、`lua/ffi/`、`src/{cache,image,x11}/`、`helper/`、`tools/`
- `lua/ffi/x11.lua` + `xdo.lua`：**自包含单文件**（只用 LuaJIT `ffi` + 系统 libX11/libxdo，不引用 lite 代码、不注册工具），可整对拷给别的项目；`x11.lua` 靠 `require("ffi.xdo")` 找同伴，换布局要同步改这一行
- `lua/tui/mouse.lua` + `clipboard.lua`：拖选/剪贴板；选区在 `screen.lua`

## 3 记忆

每个目录一份 `mem.bin` + `mem.idx`；删掉=清空该目录记忆。

- `/agent/knowledge/*`：长期事实；`/agent/session/<id>/*`：消息/摘要/工作态/todo
- `/agent/working/*`：wake 等运行态，不注入 prompt

最近 `LITE_SESSION_RAW_KEEP`（默认 200）条非 user 原文 + user 永久；tool 结果入库截到
`LITE_TOOL_RESULT_CHARS`（默认 8192），旧内容靠 turn 摘要/`recall`。写实例持 `mem.lock`。

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

注意发现机制：插件只扫 `<cwd>/helper` → `$LITE_ROOT/helper`（`lua/core/tools.lua:_helper_roots`），
**`tools/` 里的 `.lua` 不会被当插件加载**（那是 build/test/run/release 这类仓库脚本）。
现有 adb/wechat/music/search/fetch/tokens/uimap/usb 八个住 `helper/`，因为发现只认那里。

**缺能力先造，别降级**（自我进化流程）。碰到「这个命令没装 / 这个库没有 / 内置工具缺这个
动作」时，不许手工硬凑、更不许直接回「做不到」——按下表走一遍。整条链**会话内**可用，
不需要重启：

| 步 | 动作 | 怎么落 |
|---|---|---|
| 1 判 | 内置工具能覆盖？系统已有 `.so` 能 `ffi.load`？`helper/` 里已经有？（`lite plugins` / `ldconfig -p \| grep`） | 三者都不行才造 |
| 2 估 | 只跑一次的用 `lua` 内联；会反复用的才落 `helper/` | 代价/收益判定见 `design.md:8.37` |
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
- 热重载：Lua 清 `package.loaded[...]` 后 require；TUI `/reload` 只重载 `core.tools` /
  `core.prompt` / `ffi.*`，**不重扫插件快照**。进程内 `ffi.load` 过的同路径 `.so` 换不掉，
  但 `native build` 每次出新文件名（`<name>-<ts>.so` + `<name>.json` 清单），下一次
  helper 调用按清单重新 `ffi.load` → **不用重启**。

`native` 自造工具：`build` / `run` / `wrap`；ABI 为
`char *lite_helper(const char *input)` + 可选 `lite_helper_free`（UTF-8/JSON）。
插件发现 `<workspace>/helper` → `$LITE_ROOT/helper`；`scope=local|global` 控制写入侧。
wrapper 返回 `{ run=function(args,env) ... end }`；重新 build 生成新 `.so`，免重启。

**只有清单冻结，派发全是动态的**（`design.md:8.35`）：`helper/*.lua` 里返回
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
| 想让新工具**出现在 API 清单** | 新会话（或 system prompt 里点名） |
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
| `music` | 后台常驻 VLC 放歌：play/pause/next/volume/seek/playlist | 源可为本地路径、关键词（WebDAV 搜）、`dav://host:port/路径`（流播不下载） |
| `search` | DeepSeek Search：关键词→rerank 结果+摘要 | 需要 `DEEPSEEK_API_KEY` |
| `fetch` | DeepSeek Fetch：URL→Markdown 正文 | 同上；替代原始 HTTP 抓页面 |
| `tokens` | 每日 token 账本查询 | 数据源 `/agent/usage`，跨会话同一本账 |
| `pdftext` | 抽 PDF 文本（`path/first/last/max_chars`） | 纯 Lua FFI 直连 `libpoppler-glib.so.8`，零编译零子进程；本机无 poppler 头文件，cdef 手写（导出符号 `poppler_document_get_page`/`poppler_page_get_text`），释放用 `g_object_unref`（`poppler_page_free`/`poppler_document_free` 已不在 134 里）；缺库报装 `libpoppler-glib8` |

`music` 的 `dav://` 语义：`dav://host:port/路径` 列目录**直接流播**（默认整库随机，
`limit=N` 限首数，`index=N` 选第几首）；**只写 `dav://` 不带路径会 PROPFIND 失败**，
因为 host 拆不出来——要整库就带上 `WEBDAV_MUSIC` 的路径（`~/.env` 里有）。

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

## 7 参考实现（新功能先查）

参考：Pi `/opt/pi-mono`、Reasonix `/opt/reasonix`、opencode `/opt/opencode`；缓存
`/opt/code_caches/<name>_cache`；工具 `/opt/my_db`。逐项目查，不 cross-search，只借鉴思路。
符号：Go `pkg::Func`、C++ `Class::method`、TS 导出名。
