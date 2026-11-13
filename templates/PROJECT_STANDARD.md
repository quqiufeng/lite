# PROJECT_STANDARD — LuaJIT FFI + Lua + C/C++ 体系规范

> 这份文件是**可整份拷给任何项目**的通用规范，不含 lite 内部路径。
> lite 自己是第一个遵守者；用 lite 开发的项目、以及被人接手后继续用 lite 迭代的项目，
> 一视同仁。`templates/project/` 是可跑的最小骨架，`tools/newproject.sh` 一键生成。

## 0 一句话

**Lua 做编排，C/C++ 做内核，FFI 做桥；能力优先来自进程内，而不是子进程。**

判据只有一条：**同样一件事，谁少一个进程、少一次序列化、少一个外部依赖，就用谁。**
`ss -x` / `ps` 里不该出现你为了看一眼 UI 而起的 `xdotool`、为了读一张图而起的 `convert`、
为了查一个符号而起的 `grep`。

## 1 四层，各管什么

| 层 | 目录 | 职责 | 禁止 |
|---|---|---|---|
| 编排 | `lua/` | 状态机、流程、错误恢复、CLI/TUI | 塞大循环热路径 |
| 桥 | `lua/ffi/` | `ffi.cdef` + 候选表 + 错误转 string | 塞业务逻辑 |
| 内核 | `src/` | 算法、编解码、索引、并发 | 依赖 Lua 头、`exit()` |
| 工具面 | `helper/`(插件) / `tools/`(人写) | 参数校验 + 编排 + 自述用法 | 各自重写候选表 |

分界线：**换一种语言也不会变的东西 → `src/`；只在某个流程里成立的决定 → `lua/`。**

## 2 三条不可让渡的约定

### 2.1 原生优先（no subprocess by default）

- 要窗口 → `libX11`/`libxdo` 直调，不是 `xdotool`
- 要截图 → `liblite_capture.so`（XGetImage/ZPixmap），不是 `import`/`scrot`
- 要读图 → `liblite_image.so`（libpng/libjpeg/libwebp），不是 `convert`
- 要搜代码 → `liblite_codesearch.so`，不是 `grep -r`
- 要查符号 → `dladdr` + `nm` 的解析结果落缓存，不是每次跑 `nm`

允许起子进程的三种情况，必须写注释说明：① 目标是另一个进程的行为（`ssh`、`adb`）；
② 一次性构建/安装；③ 系统库缺失时的降级路径，且**必须在 stderr 说明缺了什么**。

### 2.2 单一解析点（single loader）

`.so` 的查找顺序**只允许存在于一处**。lite 的实现是 `lua/ffi/libfind.lua`：

```
$LITE_ROOT/build → $LITE_ROOT/lib → <lua 模块所在树>/build|lib → ./build|lib → 裸名
```

规则：

- 命中后比较所有候选的**文件大小**，不一致就往 stderr 打一行警告（只打一次）。
  静默新旧混编是最贵的 bug：`symbol 查询返回空` 实际跑的是上周的 `.so`。
- 不要在插件里写第二份候选表。唯一的例外是「必须能整对拷走」的自包含文件
  （见 2.3），它内联候选表，并在注释里写明顺序与 libfind 一致。

### 2.3 自包含对（portable pair）

`lua/ffi/x11.lua` + `lua/ffi/xdo.lua` 是**自包含单文件对**：只用 LuaJIT `ffi` + 系统
`libX11`/`libxdo`，不 require 任何项目内模块，可整对拷进别的项目。

- 拷走时只改 `x11.lua` 顶部那一行 `require("ffi.xdo")`（换布局要同步）。
- 这对文件**不注册工具**，纯库；想变成工具用 `helper/see.lua` 那层包。
- 判断一个模块能不能进这个行列：`grep -n require <file>` 只允许 `ffi` 和自己这对同伴。

## 3 C/C++ 侧：ABI 与纪律

### 3.1 两种 ABI，别混

| 用途 | 签名 |
|---|---|
| 工具型（JSON in/out，给 `native`/插件调） | `char *lite_helper(const char *input)` + `void lite_helper_free(char *p)` |
| 库型（精细控制，给 FFI 直接 cdef） | 常规 C 函数，返回 `int` 状态码，错误走 `<name>_error(void)` |

规则：

- **返回堆字符串**的必须配套 `_free`；调用方 Lua 侧包一层 `pcall` + `ffi.gc`。
- 错误**不返回 NULL 了事**，返回 `""` 或 JSON `{"ok":false,"error":"..."}`，
  并保持 `<name>_error()` 里是最近一次的详细原因。
- 不 `exit()`、不 `abort()`、不 `printf` 到 stdout（stdout 是数据通道，日志走 stderr）。
- 不持有跨调用全局可变状态；需要缓存时按 handle/句柄封装，Lua 侧 `ffi.gc` 释放。
- 每次进 C 之前做参数校验（长度/范围/NULL），崩溃要崩在 C 里能打印，不要崩成
  Lua 的 `segmentation fault` 无声退出。

### 3.2 性能准则

- 热路径避免 `malloc` 抖动：批量接口（一次传整个数组/整份 JSON），不要把循环搬到 Lua 再逐条调。
- 大结果不复制两遍：能 mmap 就 mmap；`return` 一份堆字符串时，Lua 侧用完立刻 `free`。
- 编译：`-O2 -Wall -Wextra`，新增 warning 视为失败；CI 就是 `tools/build.sh`。
- 符号可见性默认隐藏（`-fvisibility=hidden`），只导出 ABI 面。

### 3.3 换 .so 后必须重启进程

FFI 加载的 `.so` 在进程内**不会热更**。改了 C 就：`tools/build.sh` → 重启宿主进程。
lite 里对应 `<reboot>`；别的项目里就是重跑主程序。别在原地怀疑"为什么改了没生效"。

## 4 Lua 侧：五条硬规则

1. **cdef 一律 `pcall`**：`pcall(ffi.cdef, [[...]])`，避免同进程多模块重复声明直接报错。
2. **错误不抛字符串**：库函数返回 `nil, err` 或 `false, err`；只有明确是编程错误才 `error()`。
3. **插件形态统一**：`helper/<name>.lua` 必须 `return { run = function(args, env) ... end }`，
   `args` 是已解析的表，`env` 有 `cwd`/`helper_dir`/`load`/`call`。参数 schema 用 JSON 描述
   （`required` 标必填），工具失败时错误里**回带原参数 + required 项 + 退出码语义**。
4. **package.path 自举**：可执行脚本第一行按 `arg[0]` 推根目录，别依赖 `cd` 到项目根。
5. **`os.getenv` 读配置**：密钥只活在环境变量；仓库里不出现字面量、不 `print`、不拼进命令行
   （`ps` 可见）。

## 5 看见 UI：闭环固定四步

```
locate(唯一定位) → activate(确认拿到焦点) → capture(PNG) → read/ocr(验收)
```

**为什么必须定位**：桌面同时跑几十个进程时全屏截图会截到遮挡窗口，于是"验收"变成看别人的界面。
`--list` 先摊开窗口清单（id/name/class/pid/viewable/z），再按 class/pid/name 唯一命中；
命中不唯一就报候选让调用方补条件，**绝不静默选一个**。

验收要点：

- 缩放到目标宽度（默认 1280）再读，原图 2560 宽纯烧 token。
- 文字类用 OCR 复核，布局类看图；**像素级回归靠单测/像素 diff**，人眼（模型眼）只做终判。
- 点击类操作要能自证：操作前后各截一张做 `diff`，变化落在预期盒子里才算成功
  （lite 的 `uimap learn/verify` 是这套的参考实现）。
- 每一步都打印定位信息（id/class/pid/geom）到 stderr，失败时不用猜点错了哪个窗口。

## 6 测试：三层，缺一层就别叫"验过"

| 层 | 形态 | 例子 |
|---|---|---|
| 单元 | `tools/test.sh` 里的纯逻辑断言（无网、无显示） | JSON 解析、状态机、像素 prepass |
| 活体 | 起真实进程/真实窗口，断言输出 | 起 TUI 出快照、起服务 curl 端点 |
| 端到端 | 真点真看 | 点击 → 截图 diff → OCR 断言 |

纪律：

- **FAIL 先行**：修 bug 前先让测试红一次并提交，再改到绿，否则无法证明修的是它。
- 一条命令跑完：`tools/test.sh` = 依赖检查 + 单元 + 活体 + CLI 契约（JSON 字段级断言）。
- 退出码有语义并在文档里写死：`0` 成功 / `1` 业务失败 / `2` 用法错 / `124` 超时 /
  `126` 不可执行 / `127` 未找到。脚本化调用方只认这些。
- 拿 `--json` 输出做断言，不要去 `grep` 人类可读日志的措辞。

## 7 密钥与配置

- 只从环境变量读；`.env` 给人写（`~/.config/<proj>/.env` → `~/.env` → workspace `.env`），
  启动脚本注入进程环境。
- 仓库里机械检查 `sk-` 等字面量（放 `auto_unit` 里当一条测试）。
- `sudo` 下 HOME 会变，靠 `SUDO_USER` 补读原用户配置。

## 8 新项目 checklist

```bash
./tools/newproject.sh /path/to/proj --name proj [--x11] [--c] [--git]
cd /path/to/proj && ./tools/build.sh && ./tools/test.sh
```

生成后立刻应满足：

- [ ] `tools/lua.sh -e 'print(_VERSION)'` 能跑（LuaJIT，不是系统 lua）
- [ ] `tools/build.sh` 至少编出 `build/lib<name>_core.so`
- [ ] `tools/test.sh` 全绿（依赖 + 单元 + 活体冒烟）
- [ ] `./tools/see.lua --list` 能列出窗口（有 `--x11` 时）
- [ ] `AGENTS.md` 写了**本项目**的代码地图、命令、铁律、记忆约定，且 ≤16000 字节
      （超了每次进 prompt 都被截断，等于没写）
- [ ] 没有为"看一眼"而起的子进程（`ps` 自检）

## 9 反模式（见到就改）

| 症状 | 病根 | 改法 |
|---|---|---|
| 满屏 `os.execute("xdotool ...")` | 把 shell 当 API | FFI 直调，见 §2.1 |
| 插件各自维护 `.so` 候选表 | 无单一解析点 | 统一走 `libfind` |
| 改了 C 没生效，靠重启机器 | 不知 FFI 不热更 | §3.3，重启宿主进程 |
| 全屏截图验收 | 没定位窗口 | §5 四步 |
| 测试断言日志措辞 | 契约没定义 | 断言 `--json` 字段 |
| 报错只说 "failed" | 调用方无法自修 | 回带原参数 + required + 退出码 |
| `AGENTS.md` 写成设计文档 | 混了"每次都要遵守"与"原理" | 原理进 `README`/`design.md`/代码头注释 |
