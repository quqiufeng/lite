# AGENTS.md — lite（DeepSeek 终端 Agent）

> 进入目录先读本文件，再读 `design.md`。
> 目标：用 LuaJIT + libcurl + cjson 实现一个最小可用的 DeepSeek coding agent；
> 当前已有 **无 UI 的 provider/agent/tools/session + 本地 KV 上下文记忆**，**还没有 TUI**。

---

## 0. 当前状态

已完成：

- `context.lua`：session/view/settings/ui 四个状态切片 + 事件/`touch()`。
- 无 UI 核心：DeepSeek streaming provider、bash/read/write/edit 工具、agent 循环、JSONL 会话。
- `lua/main.lua --once "<prompt>"`：无 UI 流式执行 + 工具循环。
- **上下文记忆**：`/opt/my_db` KV cache C 引擎（mmap 零拷贝）→ `liblite_cache.so` → `lua/ffi/cache.lua` → `lua/core/memory.lua`。
- 记忆文件：在**当前目录**生成 `mem.bin` + `mem.idx`，启动时 mmap 载入，约 30 秒落盘一次（`LITE_MEMORY_FLUSH`）。
- 上下文策略：prompt 只留 system + 最近 2 轮 + 相关记忆块（8k 字符预算）；旧信息写入 `mem.bin`，需要时用 `recall` 工具/`--recall` 查询。
- 记忆接入：agent 自动注入相关记忆并在回答后写入 turn；工具新增 `remember/recall`。
- `tools/`：依赖检查、构建、运行、测试、打包、安装。
- `design.md`：Pi / Reasonix 源码架构 + code search 探索流程。

未完成：

- TUI（输入框/对话区/工具状态/滚动）。
- 自动化客户端/`lite-agent`（socket 已有服务端模板）。
- 工具审批/沙箱（当前全部自动）。

**不要假装 UI 已存在；UI 完成后才做截图验收。**

---

## 1. 铁律（MUST / MUST NOT）

### MUST

- 改代码后跑 `./tools/test.sh`，通过才算完成。
- 依赖变更同步 `tools/check_deps.sh` 和本文件。
- C ABI/FFI 变更同步 `lua/ffi/*` 与文档。
- 提交信息：`feat/fix/style/docs/chore(scope): ...`。
- 只有用户明确要求时才 `git commit` / `git push`。
- UI 出现后，交互/视觉改动必须截图 + 读图验收。

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
│   ├── main.lua            # --check / --once / --help
│   ├── context.lua         # session/view/settings/ui + 事件
│   ├── ffi/cache.lua       # KV cache FFI
│   └── core/
│       ├── config.lua      # env + ~/.config/lite/config.lua
│       ├── deps.lua        # 依赖检查
│       ├── http.lua        # libcurl 流式 POST
│       ├── provider.lua    # DeepSeek SSE + tool calls
│       ├── tools.lua       # bash/read/write/edit
│       ├── agent.lua       # messages → model → tools
│       ├── memory.lua      # /agent/{knowledge,working,session} + TTL
│       ├── session.lua     # JSONL 会话
│       └── automation.lua  # socket JSON 服务端模板
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
lua/tui/                   终端 UI（对话/输入/流式/滚动）
automation/                lite-agent 客户端（state/call）
```

---

## 4. 全自动开发流程

```bash
./tools/build.sh           # 检查依赖 + 准备 build/
./tools/run.sh --check     # 依赖自检
./tools/run.sh --once "帮我看看当前目录"   # 无 UI 执行
./tools/run.sh --recall "django"          # 查询当前目录 mem.bin
./tools/run.sh --help
./tools/test.sh            # check + unit
./tools/package.sh         # dist/lite-linux-x64.tar.gz
./tools/install.sh         # 可选：安装到 ~/.local/share/lite
```

- `tools/lite-lua`：带 LUA_PATH/LUA_CPATH 的 LuaJIT 包装。
- `tools/lite`：启动入口（等同 run.sh）。
- 自动化 socket：`lua/core/automation.lua`，协议 JSON Lines；UI 完成后再接 `state/click/call`。

---

## 5. 测试分层

| 层 | 当前 | 说明 |
|---|---|---|
| 依赖 | `check_deps.sh` | LuaJIT/cjson/libcurl/OpenMP |
| 单元 | `tools/auto_unit.lua` | JSON、curl、入口 |
| Agent | `auto_unit.lua` | context/config/tools/provider parser/agent loop（mock） |
| 记忆 | `auto_unit.lua` | KV cache 持久化 / recall / agent 注入 / remember-recall 工具 / 上下文窗口 |
| UI | 待实现 | TUI + 截图验收 |
| 视觉 | 待实现 | 仅 UI 存在后 |

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
- 记忆：`LITE_MEMORY_MB` / `LITE_MEMORY_FLUSH` / `LITE_CONTEXT_CHARS` / `LITE_CONTEXT_TURNS`。
- 当前目录的 `mem.bin` / `mem.idx` 属于项目数据，不要提交。

参考 `design.md` 的 Pi / Reasonix 架构取舍。

---

## 7. 里程碑

1. **P0 基础设施**：依赖、目录、脚本、测试。✅
2. **P1 无 UI Agent**：DeepSeek provider + tools + agent loop + `--once`。✅
3. **P1.5 上下文记忆**：C KV cache + FFI + Lua memory + agent 注入。✅
4. **P2 TUI**：对话、流式输出、输入、工具状态、滚动。
5. **P3 自动化**：socket state/call；工具审批/沙箱按需加。

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
