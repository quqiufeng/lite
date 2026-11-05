# AGENTS.md — lite（DeepSeek 终端 Agent）

> 进入目录先读本文件，再读 `design.md`。
> 目标：用 LuaJIT + libcurl + cjson 实现一个最小可用的 DeepSeek coding agent；
> 当前已有 **无 UI 的 provider/agent/tools/session + 本地 KV 上下文记忆 + TUI（`--tui`）**。

---

## 0. 强制规范：先查参考实现（code search）

任何新功能或架构决策（TUI、diff、agent、provider、工具、记忆等）动手前，**必须**先用 code search 查 Pi / Reasonix / opencode 的参考实现，再决定方案；结论标注证据等级（`[static]` / `[verified]`）。不要凭记忆猜。

**检索配比：90% code search / 10% 精确定位。**

- **90%**：用 `ai_code_search.sh search`、`ctx.py`、`cache_query` 做语义、调用图、数据流探索，回答“在哪、谁调用、什么形态”。
- **10%**：只对命中的文件/符号做精确读取（`read` / `snippet`），确认签名、分支、schema。
- **不要**全仓 `grep`/`find` 猜实现；静态索引只是线索，关键行为仍要测试/运行验证（`[static]` → `[verified]`）。

工具与缓存（命令都在 `/opt/my_db` 下执行）：

| 仓库 | 源码 | 缓存 | KV 命名空间 |
|---|---|---|---|
| Pi | `/opt/pi-mono` | `/opt/code_caches/pi-mono_cache` | `/code/pi-mono` |
| Reasonix | `/opt/reasonix` | `/opt/code_caches/reasonix_cache` | `/code/reasonix` |
| opencode | `/opt/opencode` | `/opt/code_caches/opencode_cache` | `/code/opencode` |

固定流程：

```bash
cd /opt/my_db

# 1) 缓存健康检查
./ai_code_search.sh check /opt/code_caches/pi-mono_cache pi-mono
./ai_code_search.sh check /opt/code_caches/reasonix_cache reasonix
./ai_code_search.sh check /opt/code_caches/opencode_cache opencode

# 2) 语义搜索定位文件/符号（默认 brief；看完整定义加 --rich）
./ai_code_search.sh search /opt/code_caches/opencode_cache "diff viewer split unified" 5
./ai_code_search.sh search /opt/code_caches/pi-mono_cache "diff component render" 5 --rich

# 3) 符号上下文（callers/callees）
./tools/ctx.py /code/pi-mono renderDiff handleTerminalInput --max 10
./tools/ctx.py /code/opencode DiffViewer DiffRenderable --max 10

# 4) 数据流 / 代码片段
./ai_code_search.sh dataflow /opt/code_caches/pi-mono_cache messages
./ai_code_search.sh snippet /opt/code_caches/opencode_cache ./packages/tui/src/feature-plugins/system/diff-viewer.tsx 5

# 5) 单符号上下文（Go 用 pkg::Func 完整名）
./tools/cache_query 'control.turnOrchestrator::runTurnLoopWithPreparedTurn' \
  --repo /code/reasonix --type context --brief
```

规则：

- 先语义搜索定位，再 `ctx.py`/`cache_query` 看调用关系，最后读源码确认；静态索引不等于运行时真相。
- Go 符号是 `pkg::Func`，C++ 是 `Class::method`；裸名查不到。
- 需要完整定义/实现时加 `--rich`；需要调用链时用 `ctx.py`。
- 结论标注 `[static]`；只有实际 build/运行验证后才标 `[verified]`。
- 新建/重建索引：`./analyze_nodejs_repo.sh <src> <ns> --jobs 4`（索引任务串行）。
- 只借鉴思路，不把 `/opt` 下的外部源码复制进本仓库。

---

## 0.1 当前状态

已完成：

- `context.lua`：session/view/settings/ui 四个状态切片 + 事件/`touch()`。
- 无 UI 核心：DeepSeek streaming provider、bash/read/write/edit 工具、agent 循环、JSONL 会话。
- `lua/main.lua --once "<prompt>"`：无 UI 流式执行 + 工具循环。
- **上下文记忆**：`/opt/my_db` KV cache C 引擎（mmap 零拷贝）→ `liblite_cache.so` → `lua/ffi/cache.lua` → `lua/core/memory.lua`。
- 记忆文件：在**当前目录**生成 `mem.bin` + `mem.idx`，启动时 mmap 载入（`MAP_SHARED`/只读，C 层零拷贝），约 30 秒落盘一次（`LITE_MEMORY_FLUSH`）。`mem.lock` 为写进程独占锁；只读诊断命令不加锁。
- 会话存储：KV 内 `/agent/session/<id>/meta` + `/agent/index/cwd/<hash>/<id>` + `/msg/<seq>`（完整消息）+ `/turn/<n>`（摘要）+ `/todos`（session 级）；`/session` 从 KV 列会话/重建上下文，JSONL 仅兜底。
- 上下文策略：prompt 只留 system + 最近 2 轮 + 相关记忆块（8k 字符预算）；旧信息写入 `mem.bin`，需要时用 `recall` 工具/`--recall` 查询。
- 记忆接入：agent 自动注入相关记忆并在回答后写入 turn；工具新增 `remember/recall`。
- `tools/`：依赖检查、构建、运行、测试、打包、安装。
- `design.md`：Pi / Reasonix 源码架构 + code search 探索流程。
- **TUI**：`--tui`（纯 ANSI + `curl_multi` 异步流式 + 输入/滚动/工具显示 + 记忆命中 `mem:N hit:H`；Markdown/代码块、`?` help、`Tab` 补全、自动恢复最近会话、`/session` 选择/新建；记忆按 session_id 隔离）。
- **diff 视图**：`Ctrl+G` 全屏 pager，split/unified、hunk 跳转、单文件、wrap 高度前缀和虚拟化。
- **todo list**：`todo` 工具 + `ctx.session.todos`；状态栏 `todo:done/total`，`Ctrl+T` 覆盖层，持久化并随 serve/attach 广播。
- **serve / attach**：`lite serve --port 8765`（TCP JSONL 广播 + KV prompt 队列）+ `lite attach --port 8765`（远程 TUI，连接回放历史），支持 `--tmux` 新窗口。
- **定时唤醒**：`serve --wake <秒> --task/--task-file/.lite/wake.md`；仅空闲触发，记录上次结果并广播。

未完成：

- 工具审批/沙箱（当前全部自动）。

**TUI 已存在；交互/视觉改动必须用 `tmux capture-pane` 或整屏快照验收。**

---

## 1. 铁律（MUST / MUST NOT）

### MUST

- 改代码后跑 `./tools/test.sh`，通过才算完成。
- 依赖变更同步 `tools/check_deps.sh` 和本文件。
- C ABI/FFI 变更同步 `lua/ffi/*` 与文档。
- 提交信息：`feat/fix/style/docs/chore(scope): ...`。
- 只有用户明确要求时才 `git commit` / `git push`。
- UI 出现后，交互/视觉改动必须用 `tmux capture-pane` 或整屏快照验收。

### MUST NOT

- 不使用 Chrome / WebView / CEF / Electron。
- 不启动 `xdotool/wmctrl/import` 等外部进程；窗口控制用 LuaJIT FFI。
- 不用 `systemd --user` 启动 UI。
- 不用 `pkill -f`（用 `pkill -x` 或 `name[r]`）。
- 不把 API Key 写进仓库；只读环境变量或 `~/.config/lite/config.lua`。

---

## 2. 依赖

| 依赖 | 用途 | 来源 |
|---|---|---|
| LuaJIT | 运行时 | `third_party/luajit` |
| cjson | JSON | `third_party/cjson` |
| libcurl | DeepSeek HTTP/SSE | 系统 `libcurl.so` |
| OpenMP | KV cache (hnsw) | 系统 |
| gcc/cmake | 原生 KV cache / 启动器 | 系统 |
| git | 版本 | 系统 |
| tmux | TUI 冒烟测试（可选） | 系统 |

检查：

```bash
./tools/check_deps.sh
```

---

## 3. 目录

```
lite/
├── AGENTS.md
├── design.md               # Pi / Reasonix 架构与 code search 流程
├── CMakeLists.txt          # liblite_cache.so
├── include/                # cache.h / mydb.h / metrics.h
├── src/
│   ├── cache/              # cache / hash / sorted / tag / vector / hnsw
│   ├── storage/mmap.c      # db_pool_t
│   └── utils/metrics.c
├── lua/
│   ├── main.lua            # --tui / serve / attach / --once / --check
│   ├── context.lua         # session/view/settings/ui + 事件
│   ├── ffi/cache.lua       # KV cache FFI
│   ├── tui/                # screen/terminal/input/composer/transcript/markdown/help/complete/diff/todo/attach
│   └── core/
│       ├── config.lua      # env + .env + ~/.config/lite/config.lua
│       ├── deps.lua        # 依赖检查
│       ├── http.lua        # libcurl 流式 POST / curl_multi
│       ├── provider.lua    # DeepSeek SSE + tool calls
│       ├── tools.lua       # bash/read/write/edit + diff
│       ├── agent.lua       # messages → model → tools
│       ├── memory.lua      # /agent/{knowledge,working,session} + TTL
│       ├── session.lua     # JSONL 会话
│       ├── prompt.lua      # system prompt 分段 + 记忆块 + recall query
│       ├── todos.lua       # todo 规范化/持久化/渲染
│       ├── net.lua         # TCP + poll（serve/attach）
│       ├── inputs.lua      # session 级待处理 prompt 队列（KV）
│       ├── scheduler.lua   # 定时唤醒（间隔/最大次数/上次结果）
│       ├── serve.lua       # headless serve + JSONL 广播
│       └── automation.lua  # Unix socket JSON 服务端模板
├── automation/             # x11/xdo FFI 兜底
├── third_party/            # luajit / cjson
├── tools/                  # build/run/test/package/install
├── assets/                 # 暂无
├── testdata/
├── artifacts/              # 失败证据
└── build/
```

下一步：

```
工具审批/沙箱              serve/attach 的审批覆盖层
automation/                可选的 ACP/外部客户端
```

---

## 4. 全自动开发流程

```bash
./tools/build.sh           # 检查依赖 + 准备 build/
./tools/run.sh --check     # 依赖自检
./tools/run.sh --tui                      # 本地 TUI
./tools/run.sh --tui --snapshot out.txt   # 整屏快照（AI 验收）
./tools/run.sh state --json               # 会话/记忆/todo 状态
./tools/run.sh sessions --json            # 同 cwd 会话列表
./tools/run.sh serve --port 8765          # headless 服务端
./tools/run.sh attach --port 8765         # 远程 TUI
./tools/run.sh attach --port 8765 --tmux  # 新 tmux 窗口
./tools/run.sh --once "帮我看看当前目录"   # 无 UI 执行
./tools/run.sh --recall "django"          # 查询当前目录 mem.bin
./tools/run.sh --help
./tools/test.sh            # check + unit + cli + tui + serve smoke
./tools/package.sh         # dist/lite-linux-x64.tar.gz
./tools/release.sh         # build + package + install /usr/local/bin
./tools/release.sh --no-install          # 只构建打包
PREFIX=$HOME/.local ./tools/release.sh   # 安装到用户目录
./tools/install.sh         # 可选：安装到 $PREFIX/share/lite
```

### 4.1 编译发布

`tools/release.sh` = `build.sh` + `package.sh` + `install.sh`。

- 默认安装到 `/usr/local`：二进制链接 `<prefix>/bin/lite`，应用在 `<prefix>/share/lite`。
- 目标目录不可写时自动用 `sudo`（可用 `--prefix DIR` 或 `PREFIX=DIR` 改前缀）。
- `--no-install` 只构建并生成 `dist/lite-linux-x64.tar.gz`。
- `.env` 不会被打包；key 放在运行目录/父目录 `.env`、`~/.config/lite/.env` 或 `~/.config/lite/config.lua`。
- 发布后自检：`lite --version`、`lite --check`、`lite state --json`。

- `tools/lite-lua`：带 LUA_PATH/LUA_CPATH 的 LuaJIT 包装。
- `tools/lite`：启动入口（等同 run.sh）。
- serve/attach：`lua/core/serve.lua` + `lua/core/net.lua`，TCP JSON Lines；`lua/tui/attach.lua` 复用 TUI 渲染。
- `lua/core/automation.lua` 仍是 Unix socket JSON 模板，用于可选外部自动化。

---

## 5. 测试分层

| 层 | 当前 | 说明 |
|---|---|---|
| 依赖 | `check_deps.sh` | LuaJIT/cjson/libcurl/OpenMP |
| 单元 | `tools/auto_unit.lua` | JSON、curl、入口 |
| Agent | `auto_unit.lua` | context/config/tools/provider parser/agent loop（mock） |
| 记忆 | `auto_unit.lua` | KV 持久化 / recall / agent 注入 / remember-recall / session meta+turn 重建 / 上下文窗口 |
| TUI | `tui_smoke.sh` + `auto_unit.lua` | tmux：初始界面/状态栏/todo/diff split-unified；Markdown/help/补全/会话恢复；整屏快照 |
| serve | `serve_smoke.sh` + `serve_probe.lua` | TCP hello/replay/state/ping/diff + KV prompt 队列 + tmux attach（含 todo） |
| 视觉 | `tmux capture-pane` | 失败保存 `artifacts/<ts>/{tui,serve}.smoke/screen.txt` |

失败产物：

```
artifacts/<timestamp>/<case>/
├── state_before.json
├── state_after.json
├── screenshot.png
├── app.log
└── result.json
```

---

## 6. 代码规范

- 模块：`M.new(ctx)` 只保存 ctx；`M:method()`。
- 不反向 require `lua/main.lua`；依赖用 ctx 注入。
- 热路径避免每帧闭包/大表；LuaJIT 单函数局部变量 < 200。
- FFI：只做声明/薄封装；指针与内存成对释放。
- HTTP：流式 SSE，按行解析；错误回填给模型或 UI。
- 工具：先 `bash/read/write/edit`；输出截断（单次 ≤ 32KB）。
- 会话：先线性 JSONL；树/分支后续再做。
- 配置：`DEEPSEEK_API_KEY` / `DEEPSEEK_BASE_URL` / `DEEPSEEK_MODEL`，或 `~/.config/lite/config.lua`。
- `.env` 搜索/合并：cwd → 父目录 → `~/.config/lite/.env` → 安装目录；近处键优先，缺失键由全局补。
- 记忆：`LITE_MEMORY_MB` / `LITE_MEMORY_FLUSH` / `LITE_CONTEXT_CHARS` / `LITE_CONTEXT_TURNS`。
- Prompt：自动加载 `AGENTS.md`/`CLAUDE.md`/`.lite/instructions.md`；`LITE_INSTRUCTIONS_FILE` 覆盖，`/dev/null` 禁用；`LITE_INSTRUCTIONS_CHARS` 截断上限。
- Thinking：`LITE_THINKING` / `DEEPSEEK_THINKING`；`LITE_REASONING_EFFORT` / `DEEPSEEK_REASONING_EFFORT`；TUI/serve 也支持 `--thinking` / `--reasoning-effort`。
- 重试：`LITE_MAX_RETRIES`（默认 2，429/5xx/网络错误）；serve 用 signalfd 处理 SIGINT/SIGTERM。
- 沙箱：`LITE_SANDBOX=1` 用 bwrap（只读根 + workspace 可写），不可用则 fail closed；`LITE_SANDBOX_NET=0` 禁止网络。
- 异步 bash：`core/proc.lua` 后台进程 + 临时输出文件；TUI/serve 轮询，长命令不冻结，`Ctrl+C` 取消。
- 审批：`LITE_APPROVAL=auto|ask|deny` / `--approval`；ask 时 TUI/serve 弹 once/always/reject，always 记在 `/agent/session/<id>/approvals`。
- 上下文：窗口裁剪生成 `<session_context>` digest（`/agent/session/<id>/context`），预算扣除 memory/todo/digest；细节仍用 `recall`。
- serve/wake：`LITE_SERVE_PORT` / `LITE_WAKE_SEC` / `LITE_WAKE_TASK` / `LITE_WAKE_TASK_FILE` / `LITE_WAKE_MAX`。
- 当前目录的 `mem.bin` / `mem.idx` 属于项目数据，不要提交。

参考 `design.md` 的 Pi / Reasonix 架构取舍。

---

## 7. 里程碑

1. **P0 基础设施**：依赖、目录、脚本、测试。✅
2. **P1 无 UI Agent**：DeepSeek provider + tools + agent loop + `--once`。✅
3. **P1.5 上下文记忆**：C KV cache + FFI + Lua memory + agent 注入。✅
4. **P2 TUI**：对话、流式输出、输入、工具状态、滚动、diff。✅
5. **P3 serve/attach**：TCP JSONL 广播 + 远程 TUI + `--tmux`。✅
6. **P3.5 审批/沙箱**：工具审批覆盖层。待做。

---

## 8. 常用命令

```bash
./tools/check_deps.sh
./tools/build.sh
./tools/run.sh --check
./tools/test.sh
./tools/package.sh
./tools/lite-lua -e 'print(require("cjson").encode({ok=true}))'
```
