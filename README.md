# lite

一个精简的 **native coding agent**：LuaJIT + libcurl + C，无 Node / Python / WebView / Electron。
骨架借 [Pi](https://github.com/badlogic/pi-mono)，DeepSeek 原生与缓存优先借
[Reasonix](https://github.com/esengine/reasonix)，工具行为借 [opencode](https://github.com/anomalyco/opencode)。

它把四件事当作硬约束，其余都围着这四条转：

| | 做法 | 换来 |
|---|---|---|
| 缓存优先 | system prompt 字节稳定；时钟/轮次拼在消息尾部；召回块只在每轮首次请求追加到**最末尾** | 前缀命中 ~97%，计费 miss 少 72% |
| 有界上下文 | 默认**丢弃优先**：超线从最新往回装，更老整条丢，缺什么 `recall` 召回 | 长会话不用摘要也不炸；`LITE_COMPACT=1` 才回到「先摘要」 |
| 本地记忆 | 每个目录一份 `mem.bin`（C + mmap 零拷贝），旧轮次不进 prompt | 丢了能查回来，跨会话、跨迭代 |
| 无框架依赖 | 工具就是 Lua 表；系统 `.so` 直接 FFI；缺能力自己编译；`/reboot` 自动重启拿新工具 | 加能力不引运行时；重启换新进程但会话/记忆不丢 |

## 快速开始

```bash
./tools/build.sh              # 编译 C（KV cache / image / x11）+ 检查 LuaJIT
./tools/release.sh            # 构建 + 打包 + 安装（源码安装把 lua/ 软链过来，改完重启即生效）
export DEEPSEEK_API_KEY=...   # 或写进 .env / ~/.config/lite/.env

./tools/run.sh --tui                          # TUI：改文件后自动弹两栏 diff（Ctrl+G 手动看），/session 选会话，/reboot [提示词] 自动重启并从那句接着干
./tools/run.sh --tui --thinking --reasoning-effort high
./tools/run.sh --once --json "解释这个项目"    # 无 UI 一轮，JSONL 事件
./tools/run.sh --recall "关键词"               # 查当前目录的本地记忆
./tools/run.sh --memory-export kb.jsonl        # 知识层导出成 JSONL（省略文件 / - 打 stdout）
./tools/run.sh --memory-import kb.jsonl        # 导入合并进当前目录 mem.bin（加 --dry-run 先看）
./tools/run.sh plugins --json                  # helper/ 插件清单 + 加载错误
./tools/run.sh serve --port 8765               # headless 服务端
./tools/run.sh attach --port 8765              # 任意终端/tmux tab attach
./tools/run.sh serve --wake 300 --task "检查 CI"  # 无人值守定时唤醒
./tools/test.sh               # 依赖 + 单元 + CLI + TUI(tmux) 冒烟
```

调试与自观察：`--debug`（JSONL 记录 system prompt 与原始 response）、
`--tui --snapshot FILE`（整屏文本快照）、`state --json` / `sessions --json`。

配置优先级：flag → 环境变量 → `.env` → `~/.config/lite/config.lua` → 默认值。

## 工具

内置（schema 在 API `tools` 字段里，system prompt 只列名字）：
`bash` `lua` `web` `read` `ocr` `write` `edit` `resize` `native` `todo` `remember` `recall`。

- 输出统一 **头尾双端裁剪**（bash 32KB，其余 30KB）：只留头部会把编译报错/测试结论砍掉，模型只能重跑。
- 失败可自修：报错带原始参数 + `required` 键 + 退出码语义（124 超时 /126 不可执行 /127 未找到）；
  同一调用连续失败第 2 次起追加 `[this exact call has now failed N times]`，成功清账。
- `read` 支持文本/目录/图片，`paths` 数组一次读 N 个文件（图片一次一张）。
- `write` 有 `append=true`：长文档分段落盘，`write`(新建) → `write`(append) 循环，
  别指望一次请求写完（超 `LITE_MAX_OUTPUT_TOKENS` 会把参数 JSON 截断）。
- `bash` 异步执行，长命令不冻结 TUI，`Ctrl+C` 取消；`--approval ask|deny` 逐次确认。

随包插件（`./tools/run.sh plugins` 看本机实际加载）：

| 工具 | 作用 | 依赖 |
|---|---|---|
| `cgrep` | 多线程正则扫目录，出 `path:line: text` | 自带 C |
| `adb` | Android：screenshot/tap/swipe/text/open/shell/push | `adb` |
| `wechat` | 微信：搜联系人 → 进会话 → 发消息/文件 | X11 + libxdo + OCR |
| `uimap` | 视觉定位按钮并真点确认，产出坐标表 | 截图 + OCR |
| `usb` | 麦克风/音箱/摄像头：record/play/photo/video/volume | `ffmpeg`/`arecord`/`pactl` |
| `music` | 后台常驻 VLC 放歌，WebDAV 整库流播不下载 | `vlc` + `dbus-send` |
| `search` / `fetch` | DeepSeek 搜索 / URL → Markdown 正文 | `DEEPSEEK_API_KEY` |
| `tokens` | 每日 token 账本（prompt/completion/命中率） | 本地 `/agent/usage` |
| `pdftext` | 抽 PDF 文本 | 纯 FFI 直连 `libpoppler-glib` |
| `md2png` / `trending` | Markdown/GitHub Trending → 长图 PNG（无 Chrome） | `libmd4c` + 自带 `liblite_html` |

共享逻辑放 `helper/lib/`（子目录不参与发现，不会冒出多余工具）。

### 让模型自己造工具

缺能力先造，不降级。`native` 走三步：`build`（C/C++ → `helper/<name>-<ts>.so`）→
`run`（喂真实输入验边界）→ `wrap`（生成 `helper/<name>.lua` + schema，按名即调）。

```lua
-- helper/wordcount.lua：一个文件同时声明工具与实现
return {
  schema = { name = "wordcount", description = "统计词数",
             parameters = { type = "object", properties = { text = { type = "string" } },
                            required = { "text" } } },
  run = function(args) return tostring(#(args.text:gmatch("%S+"))) end,
}
```

只返回 `hooks`（`before_tool` / `after_tool` / `on_user_turn` / `on_compact` / `on_session_end`）
的插件不进工具列表，只当钩子；hook 抛错一律 fail-open。插件与 agent 同进程同权限，
跑不受信任的仓库用 `--no-plugins` 全关。

**清单冻结，派发动态**：schema 只在会话启动扫一次（前缀缓存的代价），但执行侧每次
`loadfile` 重读、`.so` 按清单重新 `ffi.load` —— 改插件立刻生效，新建插件按名可调，
下次会话才出现在 API `tools` 里。运行期试新代码用 `lua` 工具（子进程，默认 30s 超时）。

## 上下文与记忆

```
项目目录/mem.bin   mmap 数据（轮次 / 事实 / 工作态）   mem.idx   索引
```

- 命名空间：`/agent/knowledge/*`（本目录长期事实）、`/agent/session/<id>/*`（消息、摘要、todo）、
  `/agent/working/*`（wake 等运行态，不注入 prompt）。
- 每轮开始按当前输入召回一块 `<retrieved_memory>`，**追加到请求最末尾**（只影响请求，不写会话）；
  同一轮的工具循环不重复注入。
- 局部记忆：召回 query 用 ASCII 词 + 中文 bigram，短追问会拼上一轮 user 改善「继续/那个」。
- 每条消息镜像进 `/msg/<seq>`，只保留最近 `LITE_SESSION_RAW_KEEP`（200）条非 user 原文，
  user 永久保留；tool 结果入库截到 `LITE_TOOL_RESULT_CHARS`（8192）。更老的靠 turn 摘要和 `recall`。
- `mem.lock`：写实例持锁，`--recall` / `--memory-export` / `state` / `sessions` 只读不加锁，运行中也能诊断。
- 删除 `mem.bin` = 清空该目录记忆。

### 共享记忆库 `memdb/`（跨 agent）

`mem.bin` 是本机私有脑（按目录分、mmap + 独占写锁，第二个进程只能只读），
`memdb/` 是公共的一份：**一个目录、一个文件 `mem.shared.jsonl`，所有 agent 都往里面 append**。
不加锁、不合并、不覆盖——`O_APPEND` 单行写入原子，谁写的记在每行的 `o` 字段里。
冗余是设计选择——同一条事实被三个 agent 各写一遍很正常，去重和判断可信度是读的人的事。

```bash
export LITE_MEMDB_DIR=/srv/lite-memdb            # 指到共享盘（NFS/WebDAV 挂载点）就天然多机共享
export LITE_MEMDB_FILE=/srv/lite-memdb/mem.shared.jsonl   # 可选，单独指定那个文件
export LITE_AGENT_NAME=box-a                     # 可选，缺省 = <hostname>-<cwd 名>，只作署名
export LITE_MEMDB_SPLIT=1                        # 仅在多机 NFS 上用：退回每 agent 一个文件
./tools/run.sh --memdb                           # 有多少条、谁写的
./tools/run.sh --memdb-search "ollama 端口"       # 全库搜（ASCII 词 + 中文 bigram）
```

默认位置 `~/.local/share/lite/memdb/mem.shared.jsonl`（就在 `mem.bin` 旁边），
`cat`/`grep`/`git diff` 都行，人工改也不会坏（坏行读取时跳过）。

- `remember` 写完 `mem.bin` 后顺手 append 进共享库；`recall` 先给本地结果，
  再补最多 3 条 `shared@<origin>`（和本地重复的、自己刚写的都会先剔掉）。
- 写入靠 `O_APPEND` 单行原子性：40 个进程并发写同一文件，实测 200/200 行完好、无交织。
- 读到半行/坏行直接跳过，别人正在写的文件不会拖垮整次读取。
- 搬迁想用 SQL/全文索引再说；现在这套的定位是「便宜、能 grep、能 git diff、坏了只丢一行」。

### 记忆搬家（JSONL）

`mem.bin` 是 mmap 的二进制，还带指针偏移，不能跨机器/跨版本直接拷。要搬就过一遍 JSONL：

```bash
./tools/run.sh --memory-export                     # 只导 /agent/knowledge/，打到 stdout
./tools/run.sh --memory-export kb.jsonl --all      # 连 session/working 一起导
./tools/run.sh --memory-export kb.jsonl --prefix /agent/session/ --prefix /agent/knowledge/lite/
./tools/run.sh --memory-import kb.jsonl --dry-run  # 只报数，不落盘
./tools/run.sh --memory-import kb.jsonl            # 同 key 覆盖，逐行容错
```

- 行格式一行一条，可 `grep`、可 `git diff`、能手写：
  `{"k":"/agent/knowledge/lite/hand/edit","v":"纯文本","ttl":0}`，
  `v` 也可以是 `{"text":"...","tags":[...]}` 这样的表。
- 手写时 key 不带命名空间（直接写 `lite/hand/edit`）会自动补 `/agent/knowledge/`，
  否则落在根上，`recall` 和导出都扫不到。
- `ttl` 固定导 0：C 层没有剩余寿命查询，且值得搬的 fact 本来就该永久。
- 导入只写目标库，**不是**双向同步；`--dry-run` 报 `new/overwrite` 数，出错行进 stderr 不影响其余行。
- 语义回环稳定：导出 → 导入 → 再导出，内容一致（表内键序可能不同）。

上下文预算默认 `LITE_CONTEXT_CHARS=64000`：跨过触发线（预算 85%）就从最新往回装窗口、
更老的整条丢，`session.messages` 和记忆一条不删 —— 「压缩」在这里只是缩小发出去的窗口。
`LITE_COMPACT=1` 恢复三段式摘要（稳定前缀 / 结构化 digest / 近期原文尾巴）。
`/compact` 手动把窗口滑到 `budget*LITE_KEEP_RATIO`。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `DEEPSEEK_API_KEY` | — | 必需 |
| `DEEPSEEK_BASE_URL` | `https://api.deepseek.com` | API 地址 |
| `DEEPSEEK_MODEL` | `deepseek-flash` | 模型 |
| `LITE_ENV_FILE` | 自动探测 | `.env` 路径；`/dev/null` 全关。顺序：cwd 向上 12 级 → `~/.config/lite/.env` → `$ROOT/.env`，已设变量优先 |
| `LITE_CWD` | 当前目录 | workspace |
| `LITE_MAX_TURNS` | 256 | 单次循环上限 |
| `LITE_TEMPERATURE` | 0 | 采样温度 |
| `LITE_THINKING` / `LITE_REASONING_EFFORT` | — | thinking 开关 / `high`·`medium`·`low` |
| `LITE_MAX_RETRIES` | 2 | 429/5xx/网络错误重试次数 |
| `LITE_CONTEXT_CHARS` | 64000 | prompt 字符预算 |
| `LITE_CONTEXT_TURNS` | 16 | 摘要尾巴的 user 轮数上限 |
| `LITE_CONTEXT_WINDOW` | 64000 | 模型窗口 tokens（算触发线与 output limit） |
| `LITE_RESERVE_TOKENS` | 8192 | 预留输出 tokens |
| `LITE_MAX_OUTPUT_TOKENS` | 8192 | 单次输出上限；超限时工具参数 JSON 会被截断（报错里带 `finish_reason=length`，按截断处理而不是当成模型写错 JSON） |
| `LITE_TOKEN_BUDGET` | 0 | 会话 token 预算，0 不限 |
| `LITE_COMPACT` | 0 | `1` = 先摘要（有三段式 checkpoint），默认丢弃优先 |
| `LITE_KEEP_RATIO` | 0.6 | 丢窗口时保留比例（0.3~0.95） |
| `LITE_BUDGET_HINT` | — | `1` 在尾部块里播报剩余预算（默认关，纯噪声） |
| `LITE_AUTO_DIFF` | 1 | `edit`/`write` 改完文件自动弹两栏 diff（`0` 只留 Ctrl+G 手动看） |
| `LITE_TUI_MEM_NOTICE` | — | `1` = 召回命中在 transcript 里留一行 `memory: N hits · key, ...`（默认静音，状态栏也不再显示 `hit:N`） |
| `LITE_TUI_MEM_VERBOSE` | — | `1` = 上面那行再展开成 key + 正文摘要（要配合 `LITE_TUI_MEM_NOTICE`） |
| `LITE_MEMORY_MB` | 100 | `mem.bin` 容量 |
| `LITE_MEMORY_FLUSH` | 30 | 落盘间隔（秒） |
| `LITE_MEMORY_DIR` | — | 覆盖 `mem.bin` 所在目录 |
| `LITE_SESSION_RAW_KEEP` | 200 | 保留的最近非 user 原文条数 |
| `LITE_TOOL_RESULT_CHARS` | 8192 | tool 结果入库截断 |
| `LITE_INSTRUCTIONS_FILE` | 自动探测 | `AGENTS.md`/`CLAUDE.md`/`.lite/instructions.md`；`/dev/null` 禁用 |
| `LITE_INSTRUCTIONS_CHARS` | 16000 | 指令文件截断 |
| `LITE_READ_DIRS` | `$TMPDIR:/tmp:/var/tmp` | 额外允许只读图片的目录 |
| `LITE_JSON` | — | `1` 等价 `--json` |
| `LITE_APPROVAL` | auto | `auto` / `ask` / `deny` |
| `LITE_SANDBOX` / `LITE_SANDBOX_NET` | — / 1 | bwrap bash 沙箱 / 沙箱内网络 |
| `LITE_PLUGINS` | 1 | `0` 关闭插件与 hook |
| `LITE_DEBUG_LOG` | — | JSONL 调试日志 |
| `LITE_SERVE_PORT` | 8765 | serve/attach 默认端口 |
| `LITE_WAKE_SEC` / `LITE_WAKE_TASK` / `LITE_WAKE_TASK_FILE` / `LITE_WAKE_MAX` | — / — / `.lite/wake.md` / 0 | 定时唤醒 |
| `LITE_DISPLAY` / `LITE_SHOT_DIR` | `:0` / 临时目录 | X11 截图目标显示 / 落盘目录 |
| `LITE_OCR_LIB` / `LITE_OCR_MODELS` / `LITE_ORT` | `third_party/ocr/...` | OCR 库、模型、onnxruntime |
| `LITE_VOICE_MIC` / `TAIL` / `MIN` / `CHUNK` / `GATE` / `AUTO_SEND` | `default` / 1.5 / 2 / 20 / -38 / 1 | 语音：设备、尾静音秒、最短、最长、静音门限 dB、转写完是否自动发 |
| `SENSEVOICE_BIN` / `_MODEL` / `_LANG` / `_THREADS` | `/opt/SenseVoice.cpp/bin/sense-voice-main` / `/data/models/sense-voice-small-q4_k.gguf` / auto / 4 | ASR CLI 与权重（固定 CPU） |

## 依赖

**随包自带**：LuaJIT、cjson、`liblite_cache.so`（C KV cache）、`liblite_image.so`
（PNG/JPEG/WebP 解码+缩放）、`liblite_capture.so`（X11 截图）及它们的非 libc 依赖。

**需要系统提供**：`libcurl`（否则无法调 API）、`libX11`/`libxdo`（否则无截图与鼠标键盘）、
OpenMP 运行库（否则 KV cache 加载失败）。`./tools/check_deps.sh` 逐项检查。

**可选，默认不打包**：OCR 与语音输入，不装只影响对应工具，其余功能一行不少。

| 组件 | 体积 | 默认 | 拷到哪里 |
|---|---|---|---|
| PP-OCRv4 模型（det + rec + 字典） | 14.8 MB | ❌ | `dist/lite-linux-x64/models/ocr/` |
| onnxruntime CPU 版 | 22 MB | ❌ | `dist/lite-linux-x64/lib/` |
| onnxruntime GPU 版 | 26 MB | ❌ | 同上 |
| `libonnxruntime_providers_cuda.so` | 329 MB | ❌ | 同上（仅 GPU；永不打包） |
| `ffmpeg` + SenseVoice.cpp CPU + gguf | — | ❌ | 系统包 + `/opt`、`/data`，只调外部 CLI |

> CPU/GPU 核心库都这么大是因为 `.text` 里 17.4 MB 是 MLAS 算子 kernel 矩阵（每算子 × dtype
> × 指令集一份），跟 CUDA 无关；GPU 版只多 3.2 MB，真正的大头是 329 MB 的 CUDA provider。

```bash
# OCR：拷模型和 onnxruntime 进 dist（真拷贝，dist 可整体搬走）
cd dist/lite-linux-x64
./tools/ort_link.sh models /path/to/lite/third_party/ocr/models/ocr
LITE_ORT_PREFER=cpu ./tools/ort_link.sh copy
./tools/ort_link.sh status
# 单张小图 CPU 更快（0.80s vs GPU 2.41s，GPU 每次都要建 CUDA 上下文）；
# 想随包分发：LITE_DIST_WITH_OCR=1 LITE_DIST_WITH_ORT=1 ./tools/package.sh（包体 3.3M → 27M）

# 语音：系统装 ffmpeg + pulseaudio-utils，编 SenseVoice.cpp（CPU），下 gguf 模型
./tools/lua.sh -e 'local v=require("core.voice"); print(v.available())'
```

**构建期**：gcc / cmake / pkg-config / OpenMP、`libpng` `libjpeg` `libwebp` 开发包。

## 状态

P0 基础设施 · P1 无 UI agent · P1.5 上下文记忆 · P2 TUI · P3 serve/attach · 插件与自扩展 全部落地。
未做：无人值守下的完整审批/沙箱收口、上下文逐轮曲线落 KV。

设计取舍见 [design.md](design.md)；开发/测试规范与插件细节见 [AGENTS.md](AGENTS.md)。

## 参考

- Pi <https://github.com/badlogic/pi-mono> · Reasonix <https://github.com/esengine/reasonix>
  · opencode <https://github.com/anomalyco/opencode>
