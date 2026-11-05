# lite

一个**精简的 native coding agent**：基于 [Pi](https://github.com/badlogic/pi-mono) 的极简 harness 思路，并借鉴 [Reasonix](https://github.com/esengine/reasonix) 的 DeepSeek 原生与缓存优先设计，用 **LuaJIT + libcurl + C** 重新实现，不依赖 Node/Python 运行时。

当前是 **无 UI 阶段**：`--once` 跑通 provider、工具循环与本地记忆；TUI 后续加。

---

## 设计目标

- **性能**：LuaJIT + C KV cache；mmap 零拷贝；有界 prompt；缓存优先。
- **轻量**：无 Node / Python / WebView / Electron；依赖只有 LuaJIT、cjson、libcurl。
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

- **DeepSeek 流式对话**：OpenAI 兼容 `/chat/completions` + SSE。
- **工具循环**：`bash / read / write / edit`，自动执行，文件工具限制在 workspace。
- **本地上下文记忆**：
  - 每个项目目录生成 `mem.bin` + `mem.idx`；
  - C 引擎 mmap 零拷贝载入，约 30 秒落盘一次；
  - 前缀 / 范围 / 正则 / 模糊 / 标签搜索；
  - 旧轮次不进 prompt，需要时用 `recall` 查回。
- **有界上下文**：system + 最近 2 轮 + 相关记忆块（默认 8k 字符预算）。
- **纯 native**：LuaJIT + C KV cache；无 Node / WebView / Electron。

---

## 快速开始

```bash
# 构建（LuaJIT 缺失时会构建；同时编译 C KV cache）
./tools/build.sh

export DEEPSEEK_API_KEY="sk-..."

# 无 UI 执行一轮（流式输出 + 工具循环）
./tools/run.sh --once "看一下当前目录，解释这个项目"

# 查询当前目录的本地记忆
./tools/run.sh --recall "关键词"

# AI agent 驱动：JSONL 事件（delta / tool / assistant / done）
./tools/run.sh --once --json "解释这个项目"

# 依赖 / 单元测试
./tools/check_deps.sh
./tools/test.sh
```

配置也可写入 `~/.config/lite/config.lua`：

```lua
return {
  api_key = "sk-...",
  base_url = "https://api.deepseek.com",
  model = "deepseek-chat",
  max_turns = 16,
}
```

---

## 上下文记忆怎么工作

```
项目目录/
├── mem.bin        # mmap 数据（对话轮次/事实/工作记忆）
└── mem.idx        # 索引（hash/sorted/tag/vector）
```

- 命名空间：`/agent/knowledge/*`、`/agent/working/*`、`/agent/session/<id>/turn/<n>`。
- 启动时载入 `mem.bin`；运行中按 `LITE_MEMORY_FLUSH`（默认 30s）`sync`，退出强制落盘。
- 每次请求前按当前输入搜索相关记忆，组装成小块 `system` 消息；最近 2 轮之外的消息只从记忆召回。
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
lua/core/tools.lua      bash/read/write/edit + remember/recall
lua/core/agent.lua      messages → model → tools → messages
lua/core/memory.lua     命名空间/TTL/召回/上下文组装
lua/core/session.lua    JSONL 会话
lua/ffi/cache.lua       KV cache FFI
src/cache/*.c           C KV cache（mmap / hash / sorted / tag / vector / hnsw）
src/storage/mmap.c      db_pool_t
build/liblite_cache.so  C 共享库
```

更细的对比与设计取舍见 [design.md](design.md)；开发/测试规范见 [AGENTS.md](AGENTS.md)。

---

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `DEEPSEEK_API_KEY` | — | 必需 |
| `DEEPSEEK_BASE_URL` | `https://api.deepseek.com` | API 地址 |
| `DEEPSEEK_MODEL` | `deepseek-chat` | 模型 |
| `LITE_CWD` | 当前目录 | workspace |
| `LITE_MAX_TURNS` | 16 | 单次 agent 循环上限 |
| `LITE_MEMORY_MB` | 100 | mem.bin 容量 |
| `LITE_MEMORY_FLUSH` | 30 | 自动落盘间隔（秒） |
| `LITE_CONTEXT_CHARS` | 8000 | prompt 字符预算 |
| `LITE_CONTEXT_TURNS` | 2 | 保留最近轮数 |
| `LITE_JSON` | — | 设为 `1` 等价 `--json` |

---

## 依赖

- LuaJIT（`third_party/luajit`，缺失时 `tools/build.sh` 构建）
- cjson（`third_party/cjson`）
- libcurl（系统）
- gcc / cmake / OpenMP（编译 C KV cache）

---

## 状态

- [x] P0 基础设施 / 依赖 / 工具链
- [x] P1 无 UI Agent（provider / tools / agent loop / `--once`）
- [x] P1.5 上下文记忆（C KV cache + FFI + Lua + agent 注入）
- [ ] P2 TUI（对话 / 输入 / 流式 / 滚动）
- [ ] P3 自动化客户端 / 工具审批

## 参考

- Pi: <https://github.com/badlogic/pi-mono>
- Reasonix: <https://github.com/esengine/reasonix>
- 本仓库 `design.md`：两个项目的源码架构与 code search 探索流程
