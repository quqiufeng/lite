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
- **AI 可以自己测试**：无 UI 的 `--once` 就是可自动化的执行入口；`tools/test.sh` 覆盖依赖、单元（context/tools/memory/agent）、CLI JSON 输出；退出码可判定。
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
- **工具循环**：`bash / read / ocr / write / edit / resize / native / todo`，文件工具限制在 workspace；TUI 即时显示 `tool:<name>` 与结果。`bash` 异步执行，长命令不冻结 TUI，`Ctrl+C` 可取消；`read` 支持文本/目录/图片（JPEG/PNG/GIF/WebP，图片以 user `image_url` 传入；图片还可从 `$TMPDIR`/`/tmp`/`/var/tmp` 只读打开，文本仍限 workspace）；`ocr` 走系统 PP-OCRv4（中文/英文，可选）；`resize` 走内置 `liblite_image.so`（LuaJIT FFI，PNG/JPEG/WebP 解码+缩放+编码）；`edit` 成功返回 unified diff。
- **工具审批**：`--approval ask|deny`；危险工具弹出 once / always / reject，always 按 session 记忆；serve/attach 通过协议审批。
- **本地上下文记忆**：
  - 每个项目目录生成 `mem.bin` + `mem.idx`；
  - C 引擎 mmap 零拷贝载入，约 30 秒落盘一次；
  - 前缀 / 范围 / 正则 / 模糊 / 标签搜索；
  - 旧轮次不进 prompt，需要时用 `recall` 查回；
  - `mem.bin` 头部损坏（magic/version 不符）不阻塞启动：自动改名为 `mem.bin.corrupt-<ts>` 后以空库继续，`mem.idx` 一并备份。
- **有界上下文**：system + 最近 2 轮 + 相关记忆块（默认 8k 字符预算）。
- **TUI + diff**：`--tui` 交互；assistant Markdown/代码块渲染、`Tab` 文件路径补全、鼠标滚轮/`PgUp`/`PgDn` 上翻历史、`?` 帮助、`Esc×2` 终止当前回复、忙时继续输入排队（`queue:N` / `⏳` 待发送）、`quit` + Enter 退出、启动时自动恢复同 cwd 最近会话；`/session` 选择/新建会话；`Ctrl+G` 打开 `git diff`，支持 split/unified、hunk 跳转、单文件、大 diff 虚拟滚动。
- **Todo list**：`todo` 工具维护多步任务；状态栏 `todo:done/total`，`Ctrl+T` 打开列表；持久化到本地记忆并随 serve/attach 广播。
- **serve / attach**：`lite serve --port 8765` 启动 headless 服务端；`lite attach --port 8765` 在任意终端或 tmux tab 实时显示并交互，所有客户端共享同一会话与事件流。待处理 prompt 持久化在 KV，重启可恢复；attach 连接时回放会话历史；SIGINT/SIGTERM 优雅退出。
- **定时唤醒**：`serve --wake 300 --task "检查 CI"`（或 `--task-file` / `.lite/wake.md`）；空闲时自动提交，记录上次结果并随 attach 广播。无人值守仍需先补工具审批/沙箱。
- **自扩展 native helper**：模型可用 `native` 工具自己写 C/C++、编译 `helper/<name>.so`、写 Lua wrapper + schema，立即变成可调用工具；插件可在 `<workspace>/helper` 或 `$LITE_ROOT/helper`，重编译不需要重启。
- **纯 native**：LuaJIT + C KV cache + C 图像模块；无 Node / Python / WebView / Electron。图像 `.so` 随 dist 打包，目标机无需另装 ImageMagick/Pillow。

---

## 快速开始

```bash
# 构建（LuaJIT 缺失时会构建；同时编译 C KV cache）
./tools/build.sh

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

# AI 自观察：整屏快照 / 机器可读状态
./tools/run.sh --tui --snapshot /tmp/lite-screen.txt --snapshot-text "hello"
./tools/run.sh state --json
./tools/run.sh sessions --json

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
  max_turns = 128,
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
- 每次请求前按当前输入搜索相关记忆，组装成小块 `<retrieved_memory>` system 消息；最近 2 轮之外的消息只从记忆召回。
- 召回 query：ASCII 词 + 中文 bigram；短追问会拼接上一轮 user，改善“继续/那个”的指代。
- 窗口裁剪时把旧消息压成 `<session_context>` digest，存 `/agent/session/<id>/context`；细节仍用 `recall`。
- system prompt 参考 Pi 分段：`<tools> / <rules> / <memory> / <project_context> / <cwd>`；自动加载 `AGENTS.md` / `CLAUDE.md` / `.lite/instructions.md`（默认截断 4000 字符）。
- 会话存储也在 KV：`/agent/session/<id>/meta`、`/agent/index/cwd/<hash>/<id>`、`/agent/session/<id>/msg/<seq>`、`/agent/session/<id>/turn/<n>`。
- `Session:append` 会把完整消息（含 tool_calls/tool result）镜像到 KV 的 `/msg/<seq>`；`/session` 优先用它精确重建，turn 摘要仅兜底。
- todo 按 `session_id` 存在 `/agent/session/<id>/todos`。
- `mem.bin` 用 `MAP_SHARED` mmap，`mem.idx` 只读 mmap；`cache_get/prefix` 返回指针，C 层零拷贝，Lua 解码 JSON 时才复制。
- `mem.lock`：TUI/serve 写进程持独占锁，防止多写覆盖；`--recall/state/sessions` 只读不加锁，可在运行中诊断。
- 轮次按 `session_id` 存；请求召回只注入当前 session 的轮次，facts/working 全局。
- `/session` 与启动恢复**只读当前目录 `mem.bin`** 里的会话；`~/.local/share/lite/sessions/*.jsonl`
  仅作消息镜像备份，不参与恢复（删掉 `mem.bin` 就等于清空该目录的记忆）。
- TUI 状态栏显示 `mem:<总条数>`；本轮召回命中显示为 `hit:<n>`。
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
lua/core/agent.lua      messages → model → tools → messages
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

`automation/xdo.lua` + `automation/x11.lua` 已经用同样方式封装 libX11/libxdo（窗口、鼠标、键盘、截图），模型可以直接 `require("x11")` / `require("xdo")`，不必启动 xdotool/wmctrl。

Lua 层（FFI 封装、tools、prompt）可以清 `package.loaded[...]` 后重新 `require` 热重载，不用重启；TUI 里输入 `/reload` 即可。已 `ffi.load` 的 C `.so` 不会卸载，C 代码改动需要重启。原生 FFI 在进程内执行，不经过 bwrap 沙箱，敏感操作仍应走审批/沙箱。

### 让模型自己造工具

内置工具和系统库都不够时，模型可以走 `native`：

```text
native(action="build", name="x", code=C_OR_CPP, lang="c", libs={"m"})
  -> helper/x-<timestamp>.so + helper/x.json
native(action="run", name="x", input="...")
native(action="wrap", name="x", lua=..., description=..., parameters={...})
  -> helper/x.lua + helper/x.tool.json，立即成为可调用工具 x(...)
```

C ABI 固定为 `char *lite_helper(const char *input)` + 可选 `lite_helper_free`；输入/输出是 UTF-8 字符串（通常 JSON）。插件按 `<workspace>/helper` → `$LITE_ROOT/helper` 顺序发现，本地优先；`scope=local|global` 控制写哪一侧。重编译生成新 `.so` 路径，下一次调用即生效。

更细的对比与设计取舍见 [design.md](design.md)；开发/测试规范见 [AGENTS.md](AGENTS.md)。

---

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `DEEPSEEK_API_KEY` | — | 必需 |
| `DEEPSEEK_BASE_URL` | `https://api.deepseek.com` | API 地址 |
| `DEEPSEEK_MODEL` | `deepseek-flash` | 模型 |
| `LITE_CWD` | 当前目录 | workspace |
| `LITE_MAX_TURNS` | 128 | 单次 agent 循环上限 |
| `LITE_MEMORY_MB` | 100 | mem.bin 容量 |
| `LITE_MEMORY_FLUSH` | 30 | 自动落盘间隔（秒） |
| `LITE_CONTEXT_CHARS` | 8000 | prompt 字符预算 |
| `LITE_CONTEXT_TURNS` | 2 | 保留最近轮数 |
| `LITE_INSTRUCTIONS_FILE` | 自动探测 | 项目指令文件；`/dev/null` 禁用 |
| `LITE_INSTRUCTIONS_CHARS` | 4000 | 指令文件截断上限 |
| `LITE_THINKING` | — | `1` 启用 thinking |
| `LITE_REASONING_EFFORT` | — | `high` / `medium` / `low` |
| `LITE_MAX_RETRIES` | `2` | 429/5xx/网络错误重试次数 |
| `LITE_DEBUG_LOG` | — | JSONL 调试日志（request/response/utf8 修复） |
| `LITE_READ_DIRS` | `$TMPDIR:/tmp:/var/tmp` | 额外允许只读图片的目录（冒号分隔） |
| `LITE_OCR_LIB` | `third_party/ocr/lib/libocr_simple.so` | OCR 共享库 |
| `LITE_OCR_MODELS` | `third_party/ocr/models/ocr/` | PP-OCRv4 模型目录 |
| `LITE_ORT` | `third_party/ocr/lib/libonnxruntime.so.1` | onnxruntime 1.26 |
| `LITE_APPROVAL` | `auto` | 工具审批：`auto` / `ask` / `deny` |
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

- LuaJIT（`third_party/luajit`，缺失时 `tools/build.sh` 构建）
- cjson（`third_party/cjson`）
- libcurl（系统）
- libpng / libjpeg / libwebp（系统；打包时 `.so` 进 `dist/lib/`）
- libX11 / libxdo（系统；X11 截图与窗口控制）
- OCR：PP-OCRv4 `third_party/ocr/`（lib + models + onnxruntime 1.26，随包进 `dist/lib`/`dist/models`）
  - **默认不带 OCR 模型**（14.8MB，占解包六成）：OCR 是可选项，需要时把
    `third_party/ocr/models/ocr/` 拷到目标机，或设 `LITE_OCR_MODELS` 指向既有副本。
    要随包分发：`LITE_DIST_WITH_OCR=1 ./tools/package.sh`。
    dist 包因此从 27M 降到 **3.3M**
  - **onnxruntime 核心库不打包**（25MB，占 dist 一半）：目标机执行
    `./tools/ort_link.sh link` 接入系统里**版本匹配**的那份；`status` 查看、`unlink` 撤销。
    版本要求记在 `lib/ORT_VERSION`。确实要随包分发：`LITE_DIST_WITH_ORT=1 ./tools/package.sh`
  - CUDA provider 同样**不打包**（329MB）：`./tools/cuda_provider.sh link` 按需接入
  - 默认留 CPU：单张小图 CUDA 反而更慢（实测 2.3s vs 0.75s，初始化开销占主导），批量/大图才值得
- pkg-config / gcc / cmake / OpenMP（编译 C KV cache + image）

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
