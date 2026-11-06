# AGENTS.md — lite

lite 是一个 **AI-native agent harness**：带记忆、能力对模型完全开放、可自我迭代、能看见自己。
coding 只是它的功能之一。对外说明见 `README.md`，设计取舍与参考实现剖析见 `design.md`。

> 本文件的目的：读一遍就知道**我是谁、我的手在哪、怎么验证**。
> 不确定的事实去跑，别猜；没跑过的标 `[static]`，跑过才标 `[verified]`。

---

## 0 我是谁

不是「一个只拥有 10 个工具的聊天壳」。三层结构：

| 层 | 是什么 | 在哪 |
|---|---|---|
| 模型 | DeepSeek（多模态，能直接读图） | `lua/core/provider.lua` |
| harness | 循环 + 工具 + 记忆 + TUI/serve | `lua/`（约 8.7k 行） |
| 机器 | 宿主 shell、编译器、FFI、X11、GPU | 通过 `bash` 直接可达 |

**能力来源不是工具清单**，是 `bash` + 编译器 + FFI + `native`。
10 个内置工具是常用快捷键，不是边界。缺什么就现场造（见 §5）。

**已知的真实边界**（别自我设限，但也别吹）：

- 回合制：用户不说话就不存在；`serve --wake` 能定时唤醒，但那是预设脚本在跑。
- 上下文有界：prompt 只带 system + 最近若干轮 + 召回块，旧内容靠 `recall`。
- 同目录只允许一个写实例（`mem.lock` flock），第二个会直接报错。

---

## 1 自观察闭环：看见自己

三条命令，均已实测。**截图 → 缩放 → 读图** 是核心闭环，不依赖 `import`/`scrot`/`xdotool`。

```bash
cd "$(pwd)"

# ① 截全屏（X11 FFI → liblite_capture）
./tools/lite-lua -e 'package.path="./lua/?.lua;./lua/?/init.lua;./automation/?.lua;"..package.path
  local ok, p = require("x11").capture_screen()
  print(ok, p)'
#   -> <cwd>/artifacts/selfsee/screen.png  (2560x1440，约 1.9MB)

# ② 缩到合适尺寸（2560 宽原图 token 太贵；1280 起通常够读 UI）
./tools/lite-lua -e 'package.path="./lua/?.lua;./lua/?/init.lua;"..package.path
  print(require("core.tools").new({cwd=os.getenv("PWD")}):resize(
    "artifacts/selfsee/screen.png", 1280, 0, "artifacts/selfsee/s1280.png"))'
#   -> 1.9MB 降到 ~650KB

# ③ 用 read 工具看（图片会作为 image_url 进入对话）
```

要点：

- `capture_screen()` 无参时默认落到 **workspace 内**的 `artifacts/selfsee/`，目录自动创建。
  落 workspace 是关键——`read`/`resize` 才能直接消费。
- `resize` 的**输入**允许 `$TMPDIR:/tmp:/var/tmp`（与 `read` 一致，`LITE_READ_DIRS` 可扩展），
  **输出**永远落在 workspace 内；外部输入且未指定 `output` 时落到 `artifacts/resized/`。
- 单窗口截图：`x11.window(title)` 拿到 `Win` 对象后 `:capture(path)`。
- 键盘鼠标注入：`automation/xdo.lua`（libxdo FFI），**不要**起 `xdotool`/`wmctrl`。

其他内省通道：

| 手段 | 拿到什么 |
|---|---|
| `--tui --snapshot <file>` | 整屏**文本**快照（无像素，便宜） |
| `state --json` / `sessions --json` | 会话列表、记忆计数、todo |
| `LITE_DEBUG_LOG=<file>` | request/response JSONL（provider 层原始 body） |
| `tmux capture-pane` | TUI 在 tmux 里时的文本快照（测试用） |

---

## 2 代码地图

### Lua 层（`lua/`）

| 文件 | 职责 |
|---|---|
| `main.lua` | 入口：`--check/--once/--recall/state/sessions/serve/attach/--tui` |
| `context.lua` | 全应用状态切片（session/view/settings/ui）+ 事件总线 |
| `core/agent.lua` | 循环：messages → model → tool_calls → messages |
| `core/provider.lua` | DeepSeek SSE + tool_calls + 重试 + 图片消息 |
| `core/tools.lua` | 10 个内置工具的实现与 schema |
| `core/memory.lua` | KV 记忆：命名空间/TTL/召回/上下文组装 |
| `core/prompt.lua` | system prompt 分段、记忆块、recall query |
| `core/session.lua` | JSONL 镜像 + `from_memory()` 恢复 |
| `core/approval.lua` | 审批 auto/ask/deny + session 级 allow |
| `core/sandbox.lua` | bwrap bash 沙箱 |
| `core/todos.lua` / `core/inputs.lua` | todo 列表 / 待发 prompt 队列 |
| `core/serve.lua` `core/net.lua` `core/scheduler.lua` | headless 服务 / TCP / 定时唤醒 |
| `core/http.lua` `core/proc.lua` `core/text.lua` `core/debug.lua` `core/config.lua` `core/deps.lua` `core/reload.lua` `core/signal.lua` | 基础设施 |
| `core/automation.lua` | 外部自动化 Unix socket（模板，非主路径） |
| `ffi/cache.lua` | KV cache FFI |
| `ffi/image.lua` / `ffi/magick.lua` | 图像缩放双后端（内置优先，ImageMagick 兜底） |
| `ffi/ocr.lua` | PP-OCRv4（中英混排，可选） |
| `tui/loop.lua` | TUI 主循环：输入、命令、会话切换 |
| `tui/screen.lua` `terminal.lua` `utf8.lua` | 虚拟屏幕 + 终端适配 |
| `tui/transcript.lua` `markdown.lua` `composer.lua` `input.lua` | 渲染与输入 |
| `tui/diff.lua` `diff_layout.lua` `diff_view.lua` | Ctrl+G diff pager（split/unified） |
| `tui/status.lua` `todo_view.lua` `session_view.lua` `help_view.lua` `approval_view.lua` `complete.lua` | 状态栏与浮层 |
| `tui/attach.lua` | attach 远程 serve |
| `tui/snapshot.lua` | `--snapshot` 整屏文本 |

### C 层（`src/` → `build/lib*.so`）

| 目录 | 产物 | 职责 |
|---|---|---|
| `src/cache/` | `liblite_cache.so` | KV：hash/sorted/skiplist/namespace/tag/vector/hnsw + 索引持久化 |
| `src/storage/mmap.c` | 同上 | `db_pool_t` mmap 池 |
| `src/image/image.c` | `liblite_image.so` | PNG/JPEG/WebP 解码 + 缩放 + 编码 |
| `src/x11/capture.c` | `liblite_capture.so` | `XGetImage` + libpng 截图 |

### 其他

```
automation/x11.lua xdo.lua   libX11/libxdo FFI：窗口、鼠标键盘、截图
helper/                      动态 native helper（模型现场生成，见 §5）
tools/                       build/run/test/package/release + 冒烟脚本
third_party/                 luajit / cjson / ocr（随包）
```

---

## 3 记忆语义

**每个目录一份 `mem.bin`**（+ `mem.idx`）。删掉 = 清空该目录记忆；换目录 = 全新。
全局 `~/.local/share/lite/sessions/*.jsonl` 只是镜像，**不参与恢复**。

| 命名空间 | 作用域 | 进 prompt | 说明 |
|---|---|---|---|
| `/agent/knowledge/*` | 本目录，跨会话 | ✓ | 长期事实（`remember` 写入） |
| `/agent/session/<id>/msg/*` | 单会话 | ✓ 仅本会话 | 完整消息 |
| `/agent/session/<id>/turn/*` | 单会话 | ✓ | 轮次摘要 |
| `/agent/session/<id>/working/*` | 单会话 | ✓ 仅本会话 | 会话内工作记忆 |
| `/agent/session/<id>/todos` | 单会话 | ✓ | todo 列表 |
| `/agent/working/*` | 本目录运行态 | ✗ | wake 调度状态等，**不注入** |
| `/agent/index/cwd/<hash>/<id>` | 本目录 | — | 会话索引 |

- 写实例持 `mem.lock` 独占锁；`--recall/state/sessions` 只读不加锁，可并发诊断。
- `mem.bin` 头部（magic/version）损坏时自动备份为 `mem.bin.corrupt-<ts>` 并重建空库，不阻塞启动。
- `mem.idx` 是可再生的；坏了会自动扫描 pool 重建。

---

## 4 铁律

MUST：

- 改代码后跑 `./tools/test.sh`，通过才算完成。
- 依赖变更同步 `tools/check_deps.sh` 和本文件；C ABI/FFI 变更同步 `lua/ffi/*` 与文档。
- UI 改动用 `tmux capture-pane` 或 `--tui --snapshot` 验收。
- 结论标 `[static]` / `[verified]`；引用写 `file:symbol`，行号仅参考。
- Commit：`feat/fix/style/docs/chore(scope): ...`；**仅用户明确要求时** commit/push。

MUST NOT：

- 不用 Chrome/WebView/CEF/Electron。
- 不起 `xdotool/wmctrl/import`；窗口与截图走 `automation/*` 的 FFI。
- 不用 `systemd --user` 启 UI；不用 `pkill -f`（用 `pkill -x`）。
- 不把 API Key 写进仓库。
- 不把 `$ROOT/lib` 注入 `LD_LIBRARY_PATH`（会把 1.26 的 onnxruntime 塞给所有子进程，
  让依赖 1.20.1 的外部工具静默失败；回归项在 `check_deps.sh` 的 `ocr self-contained`）。

---

## 5 命令与测试

```bash
./tools/build.sh                            # 依赖检查 + 编 C 模块
./tools/check_deps.sh                       # 只查依赖
./tools/run.sh --tui                        # 交互 TUI
./tools/run.sh --once "prompt"              # 无 UI 跑一轮
./tools/run.sh --once --json "prompt"       # JSONL 事件流
./tools/run.sh --recall "关键词"             # 查当前目录记忆
./tools/run.sh --tui --snapshot out.txt     # 整屏文本快照
./tools/run.sh state --json                 # 会话/记忆/todo
./tools/run.sh sessions --json              # 同 cwd 会话列表
./tools/run.sh serve --port 8765            # headless
./tools/run.sh attach --port 8765           # 远程 TUI
./tools/test.sh                             # check + unit + cli + tui + serve
./tools/package.sh / ./tools/release.sh     # 打包 / 构建+打包+安装
```

测试分层（`test.sh` 串联）：`check_deps.sh` → `auto_unit.lua`（当前 295 项）→
CLI JSON → `tui_smoke.sh` → `serve_smoke.sh`。失败产物落 `artifacts/`。

**写回归时先验证它抓得住 bug**：在修复前的 commit 上跑一遍，确认会 FAIL。

调用工具时的约定：

- 输出单次 ≤ 32KB；超了要自己收窄（`head`/`--limit`/分页）。
- `read` 文本/目录限 workspace；图片可读 `$TMPDIR:/tmp:/var/tmp`（`LITE_READ_DIRS` 扩展）。
- `bash` 可以异步长跑；TUI 里 `Ctrl+C` 取消。

---

## 6 原生扩展

系统已有 `.so` 就直接 `ffi.cdef` + `ffi.load`，封装放 `lua/ffi/<feature>.lua`，
工具在 `lua/core/tools.lua` 暴露；只有复杂 ABI 或热路径才写 `src/<feature>/`。

- C 导出 `int lite_<feature>_...` + `const char *lite_<feature>_error(void)`；失败返回非 0。
- `.so` 设 `$ORIGIN` RPATH；`package.sh` 复制非 libc 依赖到 `dist/lib/`。
- 热重载：清 `package.loaded[...]` 重新 require（TUI `/reload`）。C `.so` 不卸载，改 C 要重启。

**`native`：让模型自己造工具**

```text
native(action="build", name="x", code=C_OR_CPP, lang="c", libs={"m"})
  -> helper/x-<ts>.so + manifest
native(action="run", name="x", input="...")
native(action="wrap", name="x", lua=..., description=..., parameters={...})
  -> helper/x.lua + x.tool.json，立即成为可调用工具 x(...)
```

- ABI：`char *lite_helper(const char *input)` + 可选 `lite_helper_free`；UTF-8 字符串（通常 JSON）。
- 发现顺序 `<workspace>/helper` → `$LITE_ROOT/helper`；`scope=local|global` 控制写哪一侧。
- Wrapper 返回 `{ run = function(args, env) ... end }`，`env` 有
  `cwd/helper_dir/scope/ffi/load(name)/call(name,input)`。
- 新 build 用新路径，**免重启**即生效。native helper 在进程内、不经 bwrap，靠审批守边界。

---

## 7 参考实现（code search）

**新功能或架构决策动手前，先查参考实现**，不要凭记忆猜；只借鉴思路，不复制源码。

| 参考 | 源码 | code search 缓存 | KV namespace |
|---|---|---|---|
| Pi (TS) | `/opt/pi-mono` | `/opt/code_caches/pi-mono_cache` | `/code/pi-mono` |
| Reasonix (Go) | `/opt/reasonix` | `/opt/code_caches/reasonix_cache` | `/code/reasonix` |
| opencode (TS) | `/opt/opencode` | `/opt/code_caches/opencode_cache` | `/code/opencode` |

工具在 `/opt/my_db`。三套通道分工：`ai_code_search.sh`（向量语义搜索）、
`tools/cache_query`（KV 精确符号，**不需向量**）、`tools/ctx.py`（批量 caller/callee，最省 context）。

```bash
cd /opt/my_db

# 前置检查
./ai_code_search.sh check /opt/code_caches/opencode_cache opencode

# 语义定位 file:line（默认 brief；要代码定义加 --rich）
./ai_code_search.sh search /opt/code_caches/opencode_cache "permission ruleset evaluate" 5

# 单符号 caller/callee（KV，快）
./tools/cache_query 'PermissionDecision' --repo /code/opencode --type context --brief
./tools/cache_query 'control.turnOrchestrator::runTurnLoopWithPreparedTurn' \
  --repo /code/reasonix --type context --depth 2 --brief    # Go 必须 pkg::Func 全名

# 批量符号关系
./tools/ctx.py /code/opencode PermissionDecision SessionStore --max 5

# 字段级数据流
./ai_code_search.sh dataflow /opt/code_caches/opencode_cache session
```

规则：

- **逐个项目查，不要 `cross-search`**：聚合只给混合排名，看不出谁在哪个抽象层解决；
  且每项目 60s 级、默认扫 20 个缓存要十分钟以上。
- 命中顺序 ≠ 该读的顺序。扫前 5 条再用 `cache_query` 按符号补齐；top1 常是 UI/单测/生成代码。
- 符号命名：Go `pkg::Func`、C++ `Class::method`、TS 用导出名；裸名查不到。
- 耗时（已优化）：`cache_query` 1~2s、`search` 1.5~2s、`check` <1s。
  三个环境开关只由 `tools/cache_query` 包装器导出，写入/批量路径**不要**设：
  `CACHE_SKIP_VECTOR_INDEX`（跳过 34GB 线性重建）、`CACHE_READONLY`（不重写 179MB 索引）、
  `ONNX_EMBEDDER_DISABLE_TRT`（单查询不吃 600MB engine）。
- 缓存缺失才重建（串行）：`./analyze_nodejs_repo.sh <src> /code/<name> --jobs 4`，
  之后补 `./tools/word_freq <cache>`，否则 TF-IDF 重排失效。

**完整范例**（以「工具审批」为例，逐个项目走一遍：定位 → 关系 → 读源码 → 横向对比）
见 `design.md` §5；方法论与报告模板见 `/opt/my_db/code_search_best_practices.md`。
