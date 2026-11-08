# lite

一个**精简的 native coding agent**：基于 [Pi](https://github.com/badlogic/pi-mono) 的极简 harness 思路，借鉴 [Reasonix](https://github.com/esengine/reasonix) 的 DeepSeek 原生与缓存优先设计，并参考 [opencode](https://github.com/anomalyco/opencode) 的工具行为与 diff/session 交互，用 **LuaJIT + libcurl + C** 重新实现，不依赖 Node/Python 运行时。

当前包含无 UI `--once`、本地 TUI、diff pager、TODO 列表、serve/attach 与本地 KV 记忆。

---

## 设计目标

- **性能**：LuaJIT + C KV cache；mmap 零拷贝；有界 prompt；缓存优先。
- **轻量**：无 Node / Python / WebView / Electron；运行时只需 LuaJIT/cjson/libcurl，图像和 FFI 扩展用系统 `.so` 或随包分发。
- **AI agent 友好**：`--once --json` 输出 JSONL 事件；`--check/--recall` 可脚本化；不依赖交互式 UI。
- **自动化开发测试循环**：`tools/build.sh` → `tools/test.sh` → `tools/package.sh`；单测 + 集成测试 + artifacts；每次改动可自动验证。

---

## 全新的开发模式

这个项目把“AI 参与自己的开发”当成一等目标：

- **AI 可以自己看见**：`--once --json` 输出结构化事件（delta / tool_start / tool_result / assistant / done / error）；`--check --json`、`--recall --json` 可被脚本读取；失败产物落 `artifacts/`。
- **AI 可以自己测试**：无 UI 的 `--once` 就是可自动化的执行入口；`tools/test.sh` 覆盖依赖、单元（context/tools/memory/agent）、真实 API 冒烟（有 key 时）、CLI JSON 输出；退出码可判定。
- **AI 可以循环迭代**：改代码 → `build.sh` → `test.sh` → 用 `--once` 验证行为；每次运行的对话/事实写入项目目录 `mem.bin`，下一次运行自动召回，形成跨迭代记忆。

```bash
# 一个最小编译/测试/观察循环
./tools/build.sh && ./tools/test.sh
./tools/run.sh --once --json "阅读当前项目并实现一个小功能"
# 读取 JSON 事件 / artifacts / mem.bin → 修改代码 → 重复
```

TUI 完成后，“看见”会进一步包含对话界面与截图，形成完整的自我观察闭环。

---

## 特性

- **DeepSeek 流式对话**：OpenAI 兼容 `/chat/completions` + SSE；支持 `thinking` / `reasoning_effort`，TUI 用灰色 `…` 块显示思考过程。
- **工具循环**：`bash / lua / web / read / ocr / write / edit / resize / native / todo`，文件工具限制在 workspace；TUI 即时显示 `tool:<name>` 与结果。`bash` 异步执行，长命令不冻结 TUI，`Ctrl+C` 可取消；`read` 支持文本/目录/图片（JPEG/PNG/GIF/WebP，图片以 user `image_url` 传入；图片还可从 `$TMPDIR`/`/tmp`/`/var/tmp` 只读打开，文本仍限 workspace；`paths` 数组可一次读 N 个文件，图片一次一张）；`web` 走内置 libcurl GET（live data 用，不读仓库）；`ocr` 走系统 PP-OCRv4（中文/英文，可选）；`resize` 走内置 `liblite_image.so`（LuaJIT FFI，PNG/JPEG/WebP 解码+缩放+编码）；`edit` 成功返回 unified diff；`lua` 在子进程里执行一段 LuaJIT（`args` 走 JSON、默认 30s 超时可到 120s、审批同 `bash`），是运行期试插件的唯一动态出口。工具输出统一 **head+tail 双端裁剪**（bash 32KB，其余 30KB）：只留头部会砍掉编译报错/测试失败摘要，模型只能重跑一遍，那是"省 token 反而更贵"。
- **工具审批**：`--approval ask|deny`；危险工具弹出 once / always / reject，always 按 session 记忆；serve/attach 通过协议审批。
- **本地上下文记忆**：
  - 每个项目目录生成 `mem.bin` + `mem.idx`；
  - C 引擎 mmap 零拷贝载入，约 30 秒落盘一次；
  - 前缀 / 范围 / 正则 / 模糊 / 标签搜索；
  - 旧轮次不进 prompt，需要时用 `recall` 查回；
  - `mem.bin` 头部损坏（magic/version 不符）不阻塞启动：自动改名为 `mem.bin.corrupt-<ts>` 后以空库继续，`mem.idx` 一并备份。
- **有界上下文 + 低频压缩**：prompt 一直 append-only，只在跨过预算阈值（`LITE_CONTEXT_CHARS`，默认 64k 字符）时压一次。压缩把旧内容折成**三段结构**——稳定前缀（system + 首条 user，≤8% 预算）、一段结构化 digest（固定小标题、禁止编造、硬性字数上限）、近期原文尾巴（预算的 10%，边界避开 tool result）——然后记 baseline 继续追加。用户自己的话有独立预算、逐字保留、不进摘要（约束被摘要丢掉就再也找不回来，而它约束的代码还在工作区里）；`ok/继续` 这类裸确认会过滤，摘要块明确标为 historical-only，当前 user 请求在块后且永远优先。视图不是按持久化的绝对 baseline 硬切：每轮从当前消息数组尾部按预算向前滑，baseline 只作 compact 锚点；重启只恢复最近消息时也会 rebase，当前 user 永不被截掉。折叠收益不足或摘要超标时**拒绝**这次检查点，并带迟滞（rearm）避免"每轮都压"——重复压会打断缓存前缀，比不压更贵。`--json` 输出 `{"type":"compact"}` 事件，TUI 里显示 `compact: prompt N -> M chars`。
- **prompt 前缀稳定 + 自我感知**：system prompt 字节不再逐轮漂移，时钟/`turn N/M`/剩余预算统一拼成**消息尾部的 runtime 块**，因此每一轮都能命中 prefix cache（热会话命中率从 97% 掉到 71% 的漂移被消掉）。尾部块同时告诉模型"还能用几轮工具循环""上下文还剩多少字符、超过多少就要压缩"，模型不必靠撞墙发现边界。工具失败会把**原始参数 + required 键 + 退出码语义**（124 超时 / 126 不能执行 / 127 命令不存在 / 其它 `[exit N]`）回传，同一调用连续失败会追加 `[this exact call has now failed N times…]`，恢复后给 `[recovered after N failed attempts]`；会话结束时 `session_end` 把"反复失败且未恢复"的教训落成程序性记忆（最多 3 条），下一轮自动召回。
- **用量与缓存可观测**：解析流末尾的 `usage`（`prompt_cache_hit/miss_tokens`），按会话累积；TUI 状态栏 `cache:N%` 显示前缀缓存命中率，`--once --json` 输出 `{"type":"usage"}` 事件。命中率是判断"prompt 前缀是否稳定"的唯一硬指标。**输出 token 按剩余窗口动态限制**；provider 报上下文过长时自动强制 compact 后重试一次。
- **上下文压力可见**：状态栏 `ctx:N%` 显示当前 prompt 占压缩触发线的比例（≥60% 才出现），数字来自真实 `usage` 校准的 chars→tokens 比例（实测误差 2%），不是纯字符猜测。预算小于固定前缀的 3 倍时会自动抬高并提示，避免"预算比 system prompt 还小"导致压缩永远失败、只能丢历史。
- **TUI + diff**：`--tui` 交互；assistant Markdown/代码块渲染、`Tab` 文件路径补全、鼠标滚轮/`PgUp`/`PgDn` 上翻历史、**左键拖选 transcript 选中文本，松开即复制到剪贴板**（`xclip`/`wl-copy`/`xsel`/`pbcopy`，都没有时退化为 OSC 52，走 ssh 也能用）、`?` 帮助、`Esc×2` 终止当前回复、忙时继续输入排队（`queue:N` / `⏳` 待发送）、`quit` + Enter 退出、启动时自动恢复同 cwd 最近会话；`/session` 选择/新建会话；`Ctrl+G` 打开 `git diff`，支持 split/unified、hunk 跳转、单文件、大 diff 虚拟滚动。
- **Todo list**：`todo` 工具维护多步任务；状态栏 `todo:done/total`，`Ctrl+T` 打开列表；持久化到本地记忆并随 serve/attach 广播。
- **serve / attach**：`lite serve --port 8765` 启动 headless 服务端；`lite attach --port 8765` 在任意终端或 tmux tab 实时显示并交互，所有客户端共享同一会话与事件流。待处理 prompt 持久化在 KV，重启可恢复；attach 连接时回放会话历史；SIGINT/SIGTERM 优雅退出。
- **定时唤醒**：`serve --wake 300 --task "检查 CI"`（或 `--task-file` / `.lite/wake.md`）；空闲时自动提交，记录上次结果并随 attach 广播。无人值守仍需先补工具审批/沙箱。
- **自扩展 native helper**：模型可用 `native` 工具自己写 C/C++、编译 `helper/<name>.so`、写 Lua wrapper + schema，立即变成可调用工具；插件可在 `<workspace>/helper` 或 `$LITE_ROOT/helper`，C `.so` 重编译后下一次调用即生效。纯 Lua 插件（`helper/<name>.lua` 返回 `{ schema, run }`）走会话启动快照，改完要重启；运行期试新脚本用 `lua` 工具。
- **纯 native**：LuaJIT + C KV cache + C 图像模块；无 Node / Python / WebView / Electron。图像 `.so` 随 dist 打包，目标机无需另装 ImageMagick/Pillow。

---

## 快速开始

```bash
# 构建（LuaJIT 缺失时会构建；同时编译 C KV cache）
./tools/build.sh

# 构建 + 打包 + 安装（源码安装默认把 lua/ 软链到源码树，改 Lua 重启即生效）
./tools/release.sh
# 想要实体拷贝：LITE_INSTALL_LINK_LUA=0 ./tools/release.sh

export DEEPSEEK_API_KEY="sk-..."
# 也可写入 .env（自动搜索 cwd → 父目录 → ~/.config/lite/.env → 安装目录，多层合并）

# 交互式 TUI（Ctrl+G 查看 git diff）
./tools/run.sh --tui

# 启用 thinking 模式
./tools/run.sh --tui --thinking --reasoning-effort high

# headless 服务端 + 任意终端/tmux tab attach
./tools/run.sh serve --port 8765
./tools/run.sh attach --port 8765
./tools/run.sh attach --port 8765 --tmux   # 新 tmux window

# 无人值守：每 300 秒唤醒执行任务
./tools/run.sh serve --port 8765 --wake 300 --task "检查 CI 并修复"

# 调试模式：记录每次请求的 system_prompt 和原始 API response
./tools/run.sh --tui --debug        # 默认 /tmp/lite-debug.jsonl
./tools/run.sh --tui --debug --debug-log /tmp/my.jsonl

# AI 自观察：整屏快照 / 机器可读状态
./tools/run.sh --tui --snapshot /tmp/lite-screen.txt --snapshot-text "hello"
./tools/run.sh state --json
./tools/run.sh sessions --json
./tools/run.sh plugins --json   # helper/ 插件清单 + 加载错误

# 无 UI 执行一轮（流式输出 + 工具循环）
./tools/run.sh --once "看一下当前目录，解释这个项目"

# 查询当前目录的本地记忆
./tools/run.sh --recall "关键词"

# AI agent 驱动：JSONL 事件（delta / tool / assistant / done）
./tools/run.sh --once --json "解释这个项目"

# 依赖 / 单元 / CLI / TUI(tmux) 冒烟
./tools/check_deps.sh
./tools/test.sh
```

配置也可写入 `~/.config/lite/config.lua`：

```lua
return {
  api_key = "sk-...",
  base_url = "https://api.deepseek.com",
  model = "deepseek-flash",
  max_turns = 256,
}
```

---

## 上下文记忆怎么工作

```
项目目录/
├── mem.bin        # mmap 数据（对话轮次/事实/工作记忆）
└── mem.idx        # 索引（hash/sorted/tag/vector）
```

- 命名空间：`/agent/knowledge/*`（本目录的长期事实，跨会话共享）、`/agent/session/<id>/*`（会话内容，含 `working/*`）、`/agent/working/*`（目录级运行态，如 wake，不注入 prompt）。
- 启动时载入 `mem.bin`；运行中按 `LITE_MEMORY_FLUSH`（默认 30s）`sync`，退出强制落盘。
- 每个用户轮开始时按当前输入搜索相关记忆，组装成小块 `<retrieved_memory>` system 消息，**追加到请求最末尾**（只影响请求，不写会话）：块内容每轮都变，插在会话中间会让后续消息整体位移、前缀缓存全部失效（实测命中 97% → 71%），且同一轮的后续工具请求不再重复注入。
- 召回 query：ASCII 词 + 中文 bigram；短追问会拼接上一轮 user，改善“继续/那个”的指代。
- 超预算时把旧消息压成 `<session_context>` 块，状态存 `/agent/session/<id>/compact`（`baseline` / `digest` / `block` / `rearm_chars`）；细节仍用 `recall` 找回。压缩只在跨阈值时发生，压完 `baseline` 推进、prompt 继续 append-only —— 这是缓存能命中的前提。
- system prompt 参考 Pi 分段：`<tools> / <rules> / <memory> / <project_context> / <cwd>`；自动加载 `AGENTS.md` / `CLAUDE.md` / `.lite/instructions.md`（默认上限 16000 字符）。
- 会话存储也在 KV：`/agent/session/<id>/meta`、`/agent/index/cwd/<hash>/<id>`、`/agent/session/<id>/msg/<seq>`、`/agent/session/<id>/turn/<n>`。
- `Session:append` 把消息镜像到 KV 的 `/msg/<seq>`；只保留最近 `LITE_SESSION_RAW_KEEP`（默认 200）条**非 user** 原始消息，user 消息永久保留。更老的 assistant/tool 靠 turn 摘要/`recall`。tool 结果入库前截到 `LITE_TOOL_RESULT_CHARS`（默认 8192）字符，避免一条命令吃满 `mem.bin`。JSONL 镜像同步做保留裁剪（user 行保留）。`/session` 优先用它精确重建，turn 摘要仅兜底。
- todo 按 `session_id` 存在 `/agent/session/<id>/todos`。
- `mem.bin` 用 `MAP_SHARED` mmap，`mem.idx` 只读 mmap；`cache_get/prefix` 返回指针，C 层零拷贝，Lua 解码 JSON 时才复制。
- `mem.lock`：TUI/serve 写进程持独占锁，防止多写覆盖；`--recall/state/sessions` 只读不加锁，可在运行中诊断。
- 轮次按 `session_id` 存；请求召回只注入当前 session 的轮次，facts/working 全局。
- `/session` 与启动恢复**只读当前目录 `mem.bin`** 里的会话；`~/.local/share/lite/sessions/*.jsonl`
  仅作消息镜像备份，不参与恢复（删掉 `mem.bin` 就等于清空该目录的记忆）。
- TUI 状态栏显示 `mem:<总条数>`；本轮召回命中显示为 `hit:<n>`；前缀缓存命中率为 `cache:<n>%`。
- 模型也可主动调用：
  - `remember {key,content,tags}` 写入长期事实；
  - `recall {query,limit}` 查询旧上下文。

容量：`LITE_MEMORY_MB`（默认 100MB）。

---

## 架构

```
lua/main.lua            --check / --once / --recall / --help
lua/context.lua         session/view/settings/ui + 事件
lua/core/provider.lua   DeepSeek SSE + tool_calls
lua/core/tools.lua      bash/read/write/edit/resize/native + remember/recall
lua/core/agent.lua      messages → model → tools → messages（压缩接入点）
lua/core/compact.lua    低频压缩：三段式计划 / 摘要提示词 / 验收与迟滞
lua/core/memory.lua     命名空间/TTL/召回/上下文组装
lua/core/prompt.lua     system prompt 分段 + 记忆块 + recall query
lua/core/session.lua    JSONL 会话
lua/core/net.lua        TCP + poll（serve/attach）
lua/core/serve.lua      headless serve + JSONL 事件广播
lua/tui/attach.lua      连接 serve 的远程 TUI
lua/ffi/cache.lua       KV cache FFI
lua/ffi/image.lua       liblite_image FFI（resize 主路径）
lua/ffi/ocr.lua         PP-OCRv4 FFI（中文/英文 OCR，可选）
src/cache/*.c           C KV cache（mmap / hash / sorted / tag / vector / hnsw）
src/image/image.c       PNG/JPEG/WebP decode + resize + encode
src/x11/capture.c       X11 截图（XGetImage + libpng）
src/storage/mmap.c      db_pool_t
build/liblite_cache.so  C KV cache 共享库
lib/liblite_image.so    C 图像共享库（打包时附 libpng/libjpeg/libwebp）
lib/liblite_capture.so  C X11 截图共享库
```

### 原生能力扩展

LuaJIT 自带 FFI，系统里已有的 `.so` 可以直接绑定，不需要 Python/Node 或官方 SDK：

```lua
local ffi = require("ffi")
ffi.cdef[[ int lite_image_resize(const char *, const char *, int, int, int); ]]
local lib = ffi.load(os.getenv("LITE_ROOT") .. "/lib/liblite_image.so")
```

约定：FFI 薄封装放 `lua/ffi/<feature>.lua`（`M.available()` + `M.<op>()` 返回 `true` 或 `false, err`），业务工具在 `lua/core/tools.lua` 暴露；复杂 ABI/热路径才写 `src/<feature>/` C shim。打包只复制非 libc 的 `.so` 到 `dist/lib/`，并用 `$ORIGIN` RPATH。参考 `src/image/image.c` + `lua/ffi/image.lua`。

`lua/ffi/xdo.lua` + `lua/ffi/x11.lua` 已经用同样方式封装 libX11/libxdo（窗口、鼠标、键盘、截图），模型可以直接 `require("ffi.x11")` / `require("ffi.xdo")`，不必启动 xdotool/wmctrl。这两个文件都是自包含单文件：除了 LuaJIT 自带的 `ffi` 和系统 `libX11`/`libxdo`，不引用任何 lite 代码，也不注册工具，纯库。所以想拿去别的项目用，整对拷过去就行（`x11.lua` 里只有一行 `require("ffi.xdo")` 依赖同伴位置；平铺到 `?.lua` 根目录时同步改这一行）。反方向也成立：删掉 lite 的其余部分，这两个文件照样能 require。

Lua 层（FFI 封装、tools、prompt）可以清 `package.loaded[...]` 后重新 `require` 热重载，不用重启；TUI 里输入 `/reload` 即可。已 `ffi.load` 的 C `.so` 不会卸载，C 代码改动需要重启。原生 FFI 在进程内执行，不经过 bwrap 沙箱，敏感操作仍应走审批/沙箱。

### 让模型自己造工具

内置工具和系统库都不够时，模型可以走 `native`：

```text
native(action="build", name="x", code=C_OR_CPP, lang="c", libs={"m"})
  -> helper/x-<timestamp>.so + helper/x.json
native(action="run", name="x", input="...")
native(action="wrap", name="x", lua=..., description=..., parameters={...})
  -> helper/x.lua + helper/x.tool.json（下次会话成为工具 x(...)）
```

C ABI 固定为 `char *lite_helper(const char *input)` + 可选 `lite_helper_free`；输入/输出是 UTF-8 字符串（通常 JSON）。插件按 `<workspace>/helper` → `$LITE_ROOT/helper` 顺序发现，本地优先；`scope=local|global` 控制写哪一侧。重编译生成新 `.so` 路径，下一次调用即生效。

纯 Lua 插件更省一步：一个文件同时声明工具名和实现。

```lua
-- helper/wordcount.lua
return {
  schema = { name = "wordcount", description = "统计文本词数",
             parameters = { type = "object", properties = { text = { type = "string" } },
                            required = { "text" } } },
  run = function(args, env) return tostring(#(args.text:gmatch("%S+"))) end,
}
```

**插件不热插拔**：schema 在会话启动时扫一次并记忆化（`<workspace>/helper` → `$LITE_ROOT/helper`，`.tool.json` 优先、内嵌 schema 其次），之后每轮复用快照 —— 运行中增删 `helper/*.lua` 不会悄悄改变工具列表（否则 system prompt 一变，DeepSeek 前缀缓存整段失效）。会话启动后新建的插件仍可按名调用，重启后进列表。加载了哪些、错在哪，用 `lite plugins`（`--json` 给脚本）看：它只读快照不触发加载，列 `name/path/scope/tool/hooks` 与错误；TUI 启动只在有错误时打一行 `plugin <name> failed: ...`。

**hook 插件**：插件也可以只返回 `hooks` 而不返回 `run`，此时它**不进工具列表**（不动 system prompt），只在关键节点被调用：

```lua
-- helper/guard.lua
return {
  hooks = {
    before_tool = function(name, args)
      if name == "bash" and args.command:match("rm%s+%-rf") then
        return "no destructive commands"
      end
    end,
    after_tool = function(name, args, out) return out .. "|after" end,
    on_user_turn = function(text) return text .. " [seen]" end,
  },
}
```

`before_tool` 返回字符串即拦截，文本原样成为工具结果，且**优先于审批**；`after_tool` 可替换结果；`on_user_turn` 可改写本轮用户文本；另有 `on_compact` / `on_session_end` 通知。hook 抛错一律 **fail-open**（记进 `_hook_errors`，不炸 agent）；`has_hooks()` 为空时零开销。插件与 agent 同进程同权限，跑不受信任的仓库用 `--no-plugins`（或 `LITE_PLUGINS=0`）把插件和 hook 一起关掉。

运行期要试新代码就走 `lua` 工具：

```lua
lua({ code = "return #(args.text:gmatch('%S+'))", input = { text = "a b c" } })
-- -> "3"
```

它在子进程里跑 `tools/lua.sh -e`，`args` 走 JSON，默认 30s 超时（最多 120s），审批同 `bash`；死循环只撞超时，不会卡住 agent。`tools/lua.sh` 是**插件/脚本专用入口**（仓库内部脚本仍用精简的 `tools/lite-lua`）：它把 `LITE_CWD`（缺省 `$PWD`，agent 里就是 workspace）当搜索根并 `cd` 过去，`LUA_PATH`/`LUA_CPATH` 额外含 `./?.lua`、`./helper/?.so` 等条目，所以片段能直接 `require("本地模块")`、`io.open("相对路径")`；自带的 `build/liblite_*.so` 会按绝对路径预加载，裸名 `ffi.load("liblite_image.so")` 在任何 cwd 下都可用。这也意味着**改 C `.so` 或 `helper/*.lua` 都要重启**（`/reload` 只重载 Lua 层模块，不重扫插件快照）。

更细的对比与设计取舍见 [design.md](design.md)；开发/测试规范见 [AGENTS.md](AGENTS.md)。

---

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `DEEPSEEK_API_KEY` | — | 必需；也可写在 `.env` 里由启动脚本注入 |
| `LITE_ENV_FILE` | 自动探测 | `.env` 路径；`/dev/null` 全关。默认顺序：workspace 向上 12 级 → `~/.config/lite/.env` → `$ROOT/.env`，**已存在的环境变量优先** |
| `DEEPSEEK_BASE_URL` | `https://api.deepseek.com` | API 地址 |
| `DEEPSEEK_MODEL` | `deepseek-flash` | 模型 |
| `LITE_CWD` | 当前目录 | workspace |
| `LITE_MAX_TURNS` | 256 | 单次 agent 循环上限 |
| `LITE_MEMORY_MB` | 100 | mem.bin 容量 |
| `LITE_MEMORY_FLUSH` | 30 | 自动落盘间隔（秒） |
| `LITE_CONTEXT_CHARS` | 64000 | prompt 字符预算（不是模型窗口） |
| `LITE_CONTEXT_TURNS` | 16 | 保留最近轮数 |
| `LITE_CONTEXT_WINDOW` | 64000 | 模型窗口 tokens（用于压缩触发/output limit） |
| `LITE_RESERVE_TOKENS` | 8192 | 预留输出 tokens |
| `LITE_MAX_OUTPUT_TOKENS` | 8192 | 单次输出上限 |
| `LITE_TOKEN_BUDGET` | 0 | 会话 token 预算，0=不限 |
| `LITE_SESSION_RAW_KEEP` | 200 | 保留的最近非 user 原始消息条数（user 永久保留） |
| `LITE_TOOL_RESULT_CHARS` | 8192 | tool 结果入库截断上限 |
| `LITE_INSTRUCTIONS_FILE` | 自动探测 | 项目指令文件；`/dev/null` 禁用 |
| `LITE_INSTRUCTIONS_CHARS` | 16000 | 指令文件截断上限 |
| `LITE_THINKING` | — | `1` 启用 thinking |
| `LITE_REASONING_EFFORT` | — | `high` / `medium` / `low` |
| `LITE_MAX_RETRIES` | `2` | 429/5xx/网络错误重试次数 |
| `LITE_DEBUG_LOG` | — | JSONL 调试日志（request/response/utf8 修复） |
| `LITE_READ_DIRS` | `$TMPDIR:/tmp:/var/tmp` | 额外允许只读图片的目录（冒号分隔） |
| `LITE_OCR_LIB` | `third_party/ocr/lib/libocr_simple.so` | OCR 共享库 |
| `LITE_OCR_MODELS` | `third_party/ocr/models/ocr/` | PP-OCRv4 模型目录 |
| `LITE_ORT` | `third_party/ocr/lib/libonnxruntime.so.1` | onnxruntime 1.26 |
| `LITE_APPROVAL` | `auto` | 工具审批：`auto` / `ask` / `deny` |
| `LITE_PLUGINS` | `1` | `0` 关闭 `helper/` 插件与 hook（同 `--no-plugins`） |
| `LITE_SANDBOX` | — | `1`/`enforce` 启用 bwrap bash 沙箱 |
| `LITE_SANDBOX_NET` | `1` | 沙箱内是否允许网络 |
| `LITE_JSON` | — | 设为 `1` 等价 `--json` |
| `LITE_SERVE_PORT` | `8765` | serve/attach 默认端口 |
| `LITE_WAKE_SEC` | — | 定时唤醒间隔（秒） |
| `LITE_WAKE_TASK` | — | 唤醒任务 prompt |
| `LITE_WAKE_TASK_FILE` | `.lite/wake.md` | 唤醒任务文件 |
| `LITE_WAKE_MAX` | `0` | 最大唤醒次数（0 不限） |

---

## 依赖

### 随包自带（`dist/lite-linux-x64/`，解包即用）

| 项 | 位置 | 说明 |
|---|---|---|
| LuaJIT | `third_party/luajit/` | 自带运行时 + `libluajit.a`，不依赖系统 lua |
| cjson | `third_party/cjson/` | JSON |
| `liblite_cache.so` | `build/` | C KV cache（mmap 零拷贝） |
| `liblite_image.so` | `lib/` | PNG/JPEG/WebP 解码+缩放+编码 |
| `liblite_capture.so` | `lib/` | X11 截图（`XGetImage` + libpng） |
| `libjpeg / libpng16 / libwebp / libz` | `lib/` | 上面两个 `.so` 的非 libc 依赖 |

### 需要系统提供

| 项 | 说明 | 缺失后果 |
|---|---|---|
| `libcurl` | DeepSeek HTTP/SSE | 无法调用 API |
| `libX11` / `libxdo` | 截图、窗口、鼠标键盘（`lua/ffi/*.lua` 走 FFI） | 无 `x11`/`xdo` 能力，其余照常 |
| `libgomp`（OpenMP） | KV cache 并行 | 加载失败 |

检查：`./tools/check_deps.sh`

### 可选 · 默认不打包，自己部署

这三样加起来占了原始包体的 **90%+**，所以 `tools/package.sh` 默认都不带。
需要 OCR 时按下面的方式自己下载部署 —— **拷贝到 dist 目录即可**，不需要重新打包。

| 组件 | 体积 | 默认 | 拷到哪里 |
|---|---|---|---|
| PP-OCRv4 模型（det + rec + 字典） | 14.8 MB | ❌ | `dist/lite-linux-x64/models/ocr/` |
| `libonnxruntime.so.1`（CPU 版） | 22 MB | ❌ | `dist/lite-linux-x64/lib/` |
| `libonnxruntime.so.1`（GPU 版） | 26 MB | ❌ | 同上 |
| `libonnxruntime_providers_cuda.so` | **329 MB** | ❌ | 同上（仅 GPU 需要） |

> 为什么 CPU / GPU 的核心库都这么大：`.text` 段 17.4 MB 是 MLAS 的算子 kernel
> 矩阵（每个算子 × 每种 dtype × 每代 CPU 指令集各一份），跟 CUDA 无关，两种版本
> 都带。GPU 版只多 3.2 MB；真正的大头是 329 MB 的 `providers_cuda.so`。

#### 部署步骤（解包后执行）

```bash
cd dist/lite-linux-x64

# 1) OCR 模型：从 clone 的源码树拷过来（或自己下载，见下）
./tools/ort_link.sh models /path/to/lite/third_party/ocr/models/ocr
#   -> models/ocr/{ch_PP-OCRv4_det_infer.onnx, ch_PP-OCRv4_rec_infer.onnx, ppocr_keys_v1.txt}

# 2) onnxruntime：从系统里拷一份（版本必须匹配，见 lib/ORT_VERSION）
LITE_ORT_PREFER=cpu ./tools/ort_link.sh copy
#   或指定目录
./tools/ort_link.sh copy /path/to/onnxruntime-linux-x64-1.26.0/lib

# 3) 验收
./tools/ort_link.sh status     # 动态库可加载 + 模型齐备
./tools/lite-lua -e 'package.path="./lua/?.lua;./lua/?/init.lua;"..package.path
  print(require("ffi.ocr").ready())'
```

`copy` 是**真拷贝**（拷完源目录可删，dist 可整体搬走）；`link` 只建软链（省空间，
但源目录不能删）。两者都会实测一次 OCR，失败自动回滚。

#### 从零下载

```bash
# onnxruntime CPU 版（推荐，22MB，零 CUDA 依赖）
python3 -m pip install onnxruntime==$(cat lib/ORT_VERSION) --target /tmp/ort
./tools/ort_link.sh copy /tmp/ort/onnxruntime/capi

# 或官方预编译包
curl -LO https://github.com/microsoft/onnxruntime/releases/download/v1.26.0/onnxruntime-linux-x64-1.26.0.tgz
tar xf onnxruntime-linux-x64-1.26.0.tgz
./tools/ort_link.sh copy onnxruntime-linux-x64-1.26.0/lib
```

PP-OCRv4 模型：从 PaddleOCR 官方下载 det/rec 推理模型与 `ppocr_keys_v1.txt`，
转成 onnx 后按上面的文件名放进 `models/ocr/`。最省事的是直接从另一份 lite
源码树 `cp -r third_party/ocr/models/ocr dist/lite-linux-x64/models/`。

#### CPU vs GPU

`LITE_ORT_PREFER=auto|gpu|cpu`（默认 `auto` = 有 GPU 用 GPU，没有用 CPU）。
GPU 判定要三项全齐：`nvidia-smi` 可用 + 版本匹配的 `providers_cuda` +
`cudnn`/`cublas` 能解析。

**实测单张小图 CPU 更快**（0.80s vs 2.41s，GPU 每次进程都要建 CUDA 上下文），
所以 OCR 想快就用 `LITE_ORT_PREFER=cpu`。

#### 想随包分发

```bash
LITE_DIST_WITH_OCR=1 LITE_DIST_WITH_ORT=1 ./tools/package.sh
# 包体 3.3M -> 27M；GPU provider 永不打包（tar -h 会解引用软链）
```

`package.sh` 有 16MB 单文件闸门（`LITE_DIST_MAX_FILE_MB`），误打包系统库会直接报错。

### 构建期依赖

pkg-config / gcc / cmake / OpenMP（编译 C KV cache + image）、`libpng`/`libjpeg`/`libwebp`
开发包（pkg-config 可见）。

---

## 状态

- [x] P0 基础设施 / 依赖 / 工具链
- [x] P1 无 UI Agent（provider / tools / agent loop / `--once`）
- [x] P1.5 上下文记忆（C KV cache + FFI + Lua + agent 注入）
- [x] P2 TUI（对话 / 输入 / 流式 / 滚动 / diff pager）
- [x] P3 serve / attach（TCP JSONL 自动化）
- [ ] P3 工具审批 / 沙箱

## 参考

- Pi: <https://github.com/badlogic/pi-mono>
- Reasonix: <https://github.com/esengine/reasonix>
- opencode: <https://github.com/anomalyco/opencode>
- 本仓库 `design.md`：三个项目的源码架构、横向对比与 code search 探索流程
