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
- `lua/tui/`、`lua/ffi/`、`src/{cache,image,x11}/`、`automation/`、`helper/`、`tools/`
- `lua/tui/mouse.lua` + `clipboard.lua`：拖选/剪贴板；选区在 `screen.lua`

## 3 记忆

每个目录一份 `mem.bin` + `mem.idx`；删掉=清空该目录记忆。

- `/agent/knowledge/*`：长期事实；`/agent/session/<id>/*`：消息/摘要/工作态/todo
- `/agent/working/*`：wake 等运行态，不注入 prompt

最近 `LITE_SESSION_RAW_KEEP`（默认 200）条非 user 原文 + user 永久；tool 结果入库截到
`LITE_TOOL_RESULT_CHARS`（默认 8192），旧内容靠 turn 摘要/`recall`。写实例持 `mem.lock`。

## 4 铁律

MUST：改代码后 `./tools/test.sh` 通过；依赖变更同步 `tools/check_deps.sh` 和本文件；
C ABI/FFI 同步 `lua/ffi/*` 与文档；UI 用 `tmux capture-pane` 或 `--tui --snapshot` 验收；
引用写 `file:symbol`，结论标 `[static]` / `[verified]`；commit 用
`feat/fix/style/docs/chore(scope): ...`，只在用户明确要求时 commit/push。

MUST NOT：不用 `python`/`sed -i` 改仓库文件（用 `edit`/`write`）；不用
Chrome/WebView/CEF/Electron；不起 `xdotool/wmctrl/import`；不用 `systemd --user`；
不用 `pkill -f`；不把 API Key 或 `$ROOT/lib` 写进仓库/`LD_LIBRARY_PATH`。

## 5 命令

```bash
./tools/build.sh
./tools/test.sh
./tools/run.sh                 # TUI；另见 --once/--recall/state/sessions/serve/attach
./tools/run.sh --once --json "prompt"
./tools/run.sh --tui --snapshot out.txt
./tools/release.sh             # build + package + install；源码安装软链 lua/
```

工具输出 ≤ 32KB；`read` 文本/目录限 workspace，图片可读 `$TMPDIR:/tmp:/var/tmp`；
`bash` 可异步长跑，TUI 里 `Ctrl+C` 取消。回归测试先在修复前 commit 确认 FAIL。

## 6 原生扩展

系统有 `.so` 就直接 `ffi.cdef` + `ffi.load`，封装放 `lua/ffi/<feature>.lua`，
工具在 `lua/core/tools.lua` 暴露；复杂 ABI/热路径才写 `src/<feature>/`。

- C ABI：`int lite_<feature>_...` + `const char *lite_<feature>_error(void)`。
- `.so` 用 `$ORIGIN` RPATH；打包只复制非 libc 依赖到 `dist/lib/`。
- 大库/模型不随包：见 `README.md` 的 `ort_link.sh`、`cuda_provider.sh`、`LITE_DIST_WITH_*`。
- 热重载：Lua 清 `package.loaded[...]` 后 require；TUI `/reload`。C `.so` 改完要重启。

`native` 自造工具：`build` / `run` / `wrap`；ABI 为
`char *lite_helper(const char *input)` + 可选 `lite_helper_free`（UTF-8/JSON）。
插件发现 `<workspace>/helper` → `$LITE_ROOT/helper`；`scope=local|global` 控制写入侧。
wrapper 返回 `{ run=function(args,env) ... end }`；重新 build 生成新 `.so`，免重启。

## 7 参考实现（新功能先查）

参考：Pi `/opt/pi-mono`、Reasonix `/opt/reasonix`、opencode `/opt/opencode`；缓存
`/opt/code_caches/<name>_cache`；工具 `/opt/my_db`。逐项目查，不 cross-search，只借鉴思路。
符号：Go `pkg::Func`、C++ `Class::method`、TS 导出名。
