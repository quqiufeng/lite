# AGENTS.md — lite

LuaJIT + libcurl + cjson + C KV cache 的 native coding agent。细节见 `design.md`、`README.md`。

## 0 开发前

- 新功能先查参考实现：Pi `/opt/pi-mono`、Reasonix `/opt/reasonix`、opencode `/opt/opencode`。
- 先用 code search / `ctx.py` / `cache_query` 定位，不要全仓 grep 猜；只借鉴思路，不复制源码。
- 结论标 `[static]`，运行验证后才标 `[verified]`。命令见 `/opt/my_db`。

## 1 铁律

MUST：

- 改代码后跑 `./tools/test.sh`，通过才算完成。
- 依赖变更同步 `tools/check_deps.sh` 和本文件；C ABI/FFI 变更同步 `lua/ffi/*` 与文档。
- UI 改动用 `tmux capture-pane` 或快照验收。
- Commit：`feat/fix/style/docs/chore(scope): ...`；仅用户明确要求时 commit/push。

MUST NOT：

- 不用 Chrome/WebView/CEF/Electron。
- 不启动 `xdotool/wmctrl/import`；窗口控制用 LuaJIT FFI。
- 不用 `systemd --user` 启 UI；不用 `pkill -f`（用 `pkill -x`）。
- 不把 API Key 写进仓库。

## 2 依赖

LuaJIT/cjson、libcurl、OpenMP、libpng/libjpeg/libwebp + X11 + pkg-config、gcc/cmake/cc/c++、tmux（可选）。
OCR：PP-OCRv4 + onnxruntime 1.26 放 `third_party/ocr/`；CUDA provider 不打包，系统有则用。

`./tools/check_deps.sh`

## 3 命令

```bash
./tools/build.sh
./tools/run.sh --tui
./tools/run.sh --once "prompt"
./tools/run.sh serve --port 8765
./tools/test.sh
./tools/package.sh
./tools/release.sh
```

## 4 目录

```
lua/main.lua context.lua core/ tui/ ffi/
src/cache src/image   C KV cache / image
automation/           x11/xdo FFI
helper/               动态 native helper
tools/                build/run/test/package/release
```

## 5 约定

- 模块 `M.new(ctx)` + `M:method()`；不反向 require `main.lua`，依赖用 ctx 注入。
- FFI 薄封装；指针/内存成对释放；工具输出单次 ≤ 32KB。
- 会话 JSONL + KV；旧上下文靠 memory/recall；审批 `auto|ask|deny`。
- `LITE_SANDBOX=1` 用 bwrap；FFI/native 在进程内、不经过 bwrap，靠审批守边界。
- `read` 文本/目录限 workspace；图片可读 `$TMPDIR:/tmp:/var/tmp`，`LITE_READ_DIRS` 可加白名单。
- Prompt 在 `lua/core/prompt.lua`；自动加载 `AGENTS.md`/`CLAUDE.md`/`.lite/instructions.md`，`LITE_INSTRUCTIONS_FILE` 覆盖，`LITE_INSTRUCTIONS_CHARS` 截断。

## 6 原生扩展

LuaJIT 自带 FFI：系统有 `.so` 就直接 `ffi.cdef` + `ffi.load`，封装放 `lua/ffi/<feature>.lua`，工具在 `lua/core/tools.lua` 暴露；复杂 ABI/热路径才写 `src/<feature>/`。

- C 导出 `int lite_<feature>_...` + `const char *lite_<feature>_error(void)`；失败返回非 0。
- `.so` 设 `$ORIGIN` RPATH；`package.sh` 复制 `.so` 及非 libc 依赖到 `dist/lib/`。
- **禁止把 `$ROOT/lib` 注入 `LD_LIBRARY_PATH`**：该变量被 exec 的子进程（`bash` 工具、native helper、外部脚本）继承，随包的 `libonnxruntime.so.1` 会遮蔽系统同名库（缺 `VERS_1.20.1` 等版本符号），让依赖系统 onnxruntime 的 `ai_code_search.sh` 等工具**静默失败**。自带 `.so` 靠 `$ORIGIN`；无 RPATH 的第三方库（如 `libocr_simple.so`）由 FFI 层按绝对路径 `ffi.load(path, true)` 预加载。回归由 `check_deps.sh` 的 `ocr self-contained` 项守护。
- 热重载：Lua 清 `package.loaded[...]` 重新 require；TUI `/reload`。C `.so` 不卸载，C 改动需重启。

## 7 native helper

`native` 让模型写 C/C++、编译 `.so`、写 Lua wrapper + schema，立即成为工具。

- 发现：`<workspace>/helper` 优先，`$LITE_ROOT/helper` 兜底；`scope=local|global`。
- ABI：`char *lite_helper(const char *input)`；可选 `void lite_helper_free(char *out)`；UTF-8 字符串（通常 JSON）。
- `build` → `<name>-<ts>.so` + manifest；`run` 调最新；`wrap` 写 `<name>.lua` + `.tool.json`，`schemas()` 自动发现。
- Wrapper 返回 `{ run = function(args, env) ... end }`；`env` 有 `cwd/helper_dir/scope/ffi/load(name)/call(name,input)`。
- 新 build 用新路径，免重启；也可 `bash` 直接 `cc -shared -fPIC ...` 或用 `luajit -e` 加载。动态工具需审批。

## 8 能力原则

不要把能力全硬编码进工具。给模型**手和眼睛**：bash、文件、编译器、系统 `.so`、FFI、进程/网络、X11/xdo、`native`；长尾能力让模型现场组合，harness 守审批/沙箱边界。

## 9 测试

`check_deps.sh` / `auto_unit.lua` / `tui_smoke.sh` / `serve_smoke.sh`；视觉用 `tmux capture-pane`，失败存 `artifacts/`。
