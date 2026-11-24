# arm64 迁移指南

> 对象：把 lite 从 x86_64 搬到 aarch64（树莓派 4/5、RK3588、Jetson、鲲鹏、Apple 虚拟机里的
> Ubuntu arm64、云厂商 Graviton/倚天）。
> 标注：`[verified]` = 读代码/实测产物确认；`[static]` = 由代码结构推理，未在 arm64 上跑过；
> `需实测` = 知道自己不知道，必须上机验。
>
> **一句话**：Lua 层一行不用改，要动的只有三处二进制（LuaJIT、`build/liblite_*.so`、
> `helper/*.so`）加一圈系统库；另外有两个 x86 闭源件（OCR、codesearch 的 tokenizers 静态库）
> 在 arm64 上直接放弃。

---

## 0 一页清单

```bash
# 1 系统包（Debian/Ubuntu arm64）
sudo apt install -y build-essential cmake pkg-config libgomp1 \
  libcurl4-openssl-dev libx11-dev libxdo-dev \
  libpng-dev libjpeg-dev libwebp-dev \
  libcairo2-dev libfontconfig1-dev \
  fonts-dejavu-core fonts-droid-fallback

# 2 关掉 codesearch（x86 静态库链不上，早关省一次失败）
mv third_party/codesearch/lib third_party/codesearch/lib.x86-disabled

# 3 重编全部二进制（LuaJIT 自判架构、build/ 自清）
./tools/build.sh

# 4 补两件 build.sh 不管的：cjson（§3.2）、/opt/litehtml（§3.4）

# 5 装
./tools/release.sh

# 6 验
./tools/check_deps.sh && ./tools/test.sh
./tools/run.sh --once --json "reply ok"
./tools/run.sh --tui --snapshot /tmp/tui.txt
```

**不用做的**：不改任何 `.lua`；不改 `CMakeLists.txt`；不改 `tools/*.sh` 的架构逻辑（已内建）。

---

## 1 原理

### 1.1 lite 的二进制分三处

| 位置 | 谁生成 | arm64 上怎么办 |
|---|---|---|
| `third_party/luajit/src/luajit`、`third_party/cjson/lua/5.1/cjson.so` | 仓库自带**预编产物** | LuaJIT 由 `build.sh` 重编；cjson **没人管，必须手编**（§3.2） |
| `build/liblite_{cache,image,tui,capture,html}.so` | `cmake`（`src/**`） | `build.sh` 重编 |
| `helper/*.so`（`cgrep`、`perfprobe`） | `native build` / `cc -shared` | 重编（§3.7） |

再加一类**不在仓库里**的：运行期 `ffi.load` 的系统库——`libcurl`、`libX11`、`libxdo`、
`libpng/jpeg/webp`、`libgomp`、`onnxruntime`。这些由目标机提供，架构自然对。

### 1.2 「文件在、有执行位」≠「能跑」

ELF 头里 `e_machine` 决定它认不认这台机器。把 x86_64 树拷到 arm64：

- `luajit` 直接 `exec format error`；
- `.so` 不是报「格式错」，而是 `dlopen` 时报别的错，或被 `libfind.lua` 的候选链跳过，
  最后报一个和架构无关的「缺 `build/liblite_cache.so`」；
- `helper/*.so` 走进程内 `ffi.load`，错误更隐晦。

所以迁移第一步不是改代码，而是**制造一次不一致，让工具链自己暴露它**。

### 1.3 架构对账已经内建（不用你加）

`tools/build.sh` 里判据是 ELF 头 `e_machine`（偏移 18，小端 2 字节）：`3=i386 40=arm
62=x86-64 183=aarch64`，用 `od` 读，**不用 `file`**（最小系统常常没装 `file`）
`[verified: tools/build.sh:elf_machine]`。

三个闸门：

1. **LuaJIT**：产物 `e_machine` ≠ 本机 → 先 `make clean` 再 `make`。`clean` 不能省：`.o` 还在
   时 make 认为目标已最新、只重新链接，产物仍是旧架构（脚本注释里就记了这个踩坑形态）。
2. **`build/`**：任一 `liblite_*.so` 架构不符 → `rm -rf build` 重新 `cmake` 配置。不能只
   `cmake --build`：`CMakeCache.txt` 记的是旧平台编译器路径，且 cmake 对「目标比源码新」会跳过
   链接，配置成功、产物照旧是 x86。
3. **产物命名**：`tools/_arch.sh` 把 `aarch64|arm64 → arm64`，包名 `dist/lite-linux-arm64.tar.gz`；
   交叉编译用 `LITE_DIST_ARCH=arm64` 覆盖。

所以**原生**在 arm64 上编，什么都不用改，`./tools/build.sh` 会把 1、2 都处理掉。

### 1.4 架构无关的部分

Lua 全部源码、prompt、记忆（`mem.bin` 是纯字节流）、session、serve 协议、`tools/*.lua`：
全是 LuaJIT 字节码或纯数据，**跨架构通用，可直接拷**。

唯一例外是 `mem.lock` 里的 pid——换机器后锁文件残留会报「被 pid N 占着」并以退出码 3 拒绝启动；
删 `mem.lock` 即可（`mem.bin`/`mem.idx` 不要删）。已装好的会话镜像
`~/.local/share/lite/sessions/*.jsonl` 也是纯文本，可直搬。

---

## 2 需要安装的系统包

### 2.1 必需（缺了编不过或跑不起来）

| 包（Debian/Ubuntu） | 用途 | 谁在检查 |
|---|---|---|
| `build-essential`（`gcc` `g++` `make`） | 编 LuaJIT / cjson / C 库 / helper | `build.sh`、`check_deps.sh` |
| `cmake` ≥3.16 | `build/liblite_*.so` | `build.sh` |
| `pkg-config` | cmake 找 png/jpeg/webp/X11 | `CMakeLists.txt` |
| `libgomp1` | **运行期**，`liblite_cache.so` 用 OpenMP | README「依赖」；缺了 KV cache 加载失败 |
| `libcurl4-openssl-dev`（或运行期 `libcurl4`） | 唯一出网通道 | `lua/core/deps.lua` |
| `libpng-dev` `libjpeg-dev` `libwebp-dev` | 三者都是 `REQUIRED`，缺一个 configure 就失败 | `CMakeLists.txt` |
| `libx11-dev` | `liblite_capture.so`、`lua/ffi/x11.lua` | `find_package(X11 REQUIRED)` `[verified]` |

⚠️ `CMakeLists.txt` 顶部的 `find_package(... REQUIRED)` 是**全局**的：即使你只想要 `lite_tui`，
缺 `libwebp-dev` 也会让整个 configure 失败。这是迁移时第一个报错。

### 2.2 可选但通常要装

| 包 | 功能 | 不装的后果 |
|---|---|---|
| `libjansson-dev` | 只有 codesearch 用 | 不装正好自动关闭 codesearch |
| `libxdo-dev` + 运行期 `libxdo3` | 键盘鼠标自动化（`xdo.lua`、`wechat`、`uimap`） | 相关工具全不可用 |
| `libcairo2-dev` `libfontconfig1-dev` | 编 `liblite_html.so` | HTML→PNG（`md2png`/`web2png`/`trending`/`pdf`/`charts`/`bizdeck`）全不可用 |
| `fonts-dejavu-core`、`fonts-droid-fallback` | cairo 无回退字体 | 图里中文和 `★` 变方框（§3.8） |
| `tmux` | `tools/test.sh` 的 TUI smoke | 跳过该用例 |
| `ffmpeg`、`pulseaudio-utils`（或 `pipewire-pulse`） | 语音模式 | 只影响 `#语音模式`（§5） |
| `sudo` NOPASSWD | `trace` 的 root 探针 | 非 root 只能看进程内 prof |

### 2.3 非 Debian 系

- **Fedora/RHEL**：`gcc-c++ cmake pkgconf-pkg-config libgomp libcurl-devel libX11-devel
  libxdo-devel libpng-devel libjpeg-turbo-devel libwebp-devel cairo-devel fontconfig-devel
  dejavu-sans-mono-fonts google-noto-sans-cjk-fonts`
- **Alpine/musl**：**没有捷径**。仓库自带的 `luajit`/`cjson.so`/`liblite_*.so` 全是 glibc 产物，
  musl 上必须全自编，`libxdo` 常要自己编。不推荐作为首个 arm64 目标。
- **无 X11 的板子**（headless server / 容器）：可以跳过 `libx11-dev`，但**要改
  `CMakeLists.txt`**（`find_package(X11 REQUIRED)` 与 `lite_capture` target 得去掉）。
  这时 `see`/`uimap`/`wechat`/截图类插件全不可用，核心 agent、`serve`、记忆、`cgrep` 照常。
  **先接受这一点再动手**，否则会在 cmake 上耗很久。

---

## 3 需要提前编译的组件

| 组件 | 谁管 | 验证 |
|---|---|---|
| LuaJIT 2.1（openresty `v2.1-agentzh`） | `build.sh` 自动（§3.1） | `./tools/lite-lua -e 'print(jit.arch)'` → `arm64` |
| cjson | **无脚本，手工**（§3.2） | `./tools/lite-lua -e 'print(require("cjson").encode({1}))'` |
| `liblite_cache/image/tui/capture` | `build.sh` 自动（§3.3） | `ls build/*.so` + `check_deps.sh` |
| `liblitehtml` + `libgumbo`（`/opt/litehtml`） | **手工，一次性**（§3.4） | `./tools/lite-lua tools/html_img_check.lua` |
| `helper/cgrep`、`helper/perfprobe` | `native build`（§3.7） | `lite plugins --json` 无加载错误 |
| 字体资源 | 无需编译，但要**在**（§3.8） | `check_deps.sh` 的 `font` 行 |
| OCR（`libocr_simple.so`） | **放弃**（§3.5） | —— |
| codesearch（tokenizers 静态库） | **放弃**（§3.6） | `cmake` 输出 `lite_codesearch disabled` |

### 3.1 LuaJIT

`third_party/luajit` 是完整源码树（版本见 `luajit.md` 开头：openresty/luajit2
`v2.1-agentzh`，`2.1.1793955606`）`[static]`。aarch64 是上游一等公民，**不需要补丁**：

```bash
./tools/build.sh          # 检测到旧架构产物 → make clean && make -j$(nproc)
```

手工等价：

```bash
make -C third_party/luajit clean && make -C third_party/luajit -j"$(nproc)"
```

⚠️ **别只 `make`**：只重链接会得到「文件名对、架构错」的产物，运行报 `exec format error`。
⚠️ **别用系统 luajit 顶替**：`tools/lite-lua` 优先用仓库这份，`LUA_PATH` 里
`third_party/luajit/src/?.lua` 也排在系统 `share` 之前——版本不匹配会报
`LuaJIT core/library version mismatch`（见 `tools/lite-lua` 头注释）`[verified]`。

验证 JIT 在 arm64 上真的工作（有些发行版因 `mmap` 权限限制导致 mcode 分配失败）：

```bash
./tools/lite-lua -e 'print(jit.version, jit.arch)'      # 期望 ... arm64
./tools/lite-lua -jv -e 'local s=0 for i=1,1e6 do s=s+i end' 2>&1 | grep -c TRACE
```

第二条应 ≥1（有 `TRACE` 行）。全是 `NYI`/`abort` 说明 JIT 被禁。`需实测`：树莓派 64 位
内核默认 `vm.mmap_min_addr=65536`，不影响；但某些加固内核会拦 `PROT_EXEC` 匿名映射。

### 3.2 cjson（唯一没有构建脚本的必需件）

`third_party/cjson/lua/5.1/cjson.so` 是 **x86-64 预编产物**，且仓库里**没有对应构建脚本**
`[verified: third_party/cjson 下只有 lua/5.1/cjson.so；grep tools/*.sh 无编译逻辑]`。
`tools/package.sh` 直接 `cp` 它进包，`tools/lite-lua` 的 `LUA_CPATH` 期望它就在这个路径。

arm64 上必须自己编一份替换：

```bash
# 取 lua-cjson（2.1.x，LuaJIT 走 5.1 API）
curl -LO https://github.com/mpx/lua-cjson/archive/refs/tags/2.1.0.14.tar.gz
tar xf 2.1.0.14.tar.gz

cc -O2 -fPIC -shared \
   -I third_party/luajit/src \
   lua-cjson-2.1.0.14/{lua_cjson.c,strbuf.c,fpconv.c} \
   -o third_party/cjson/lua/5.1/cjson.so
```

验证：

```bash
file third_party/cjson/lua/5.1/cjson.so          # 期望 aarch64
./tools/lite-lua -e 'print(require("cjson").encode({ok=1}))'   # 期望 {"ok":1}
```

⚠️ 漏了这步的表现：`check_deps.sh` 报 `[FAIL] cjson`，然后**什么都跑不起来**——
`lua/core/deps.lua` 第一项就是它，而 API 请求/会话/记忆/工具参数全部走 JSON。

### 3.3 仓库 C 库（cmake，`build.sh` 负责）

五个 target 全是 `src/**` 的 C/C++，**没有任何 x86 专属指令集**
`[verified: grep 'immintrin|_mm_|__SSE|__AVX|cpuid|rdtsc|x86intrin' src/ include/ 零命中]`。
线程只用 `pthread`，`liblite_cache` 用 OpenMP（`-fopenmp`，aarch64 gcc 完整支持）。

| target | 依赖 | arm64 注意 |
|---|---|---|
| `lite_cache` | OpenMP、`m` | 运行期要 `libgomp.so.1`（不随包） |
| `lite_image` | png/jpeg/webp | `package.sh` 按 `ldd` 把它们拷进 `dist/lib` |
| `lite_tui` | 无 | 纯 C 文本内核，最稳 |
| `lite_capture` | X11、png | headless 板子上编了也用不上 |
| `lite_html` | `/opt/litehtml`、cairo、fontconfig、png/jpeg/webp | 见 §3.4 |

重编就是 `./tools/build.sh`（会先清 `build/`）。**注意**：清 `build/` 会连
`liblite_html.so` 一起删，所以 §3.4 必须在 `build.sh` **之前**完成，否则先失败一次。

### 3.4 HTML→PNG 后端：`/opt/litehtml` 三件套

迁移里**工作量最大、最容易漏**的一块。`CMakeLists.txt` 硬编码三个路径 `[verified]`：

```
/opt/litehtml/include                            # 头
/opt/litehtml/build-pic/liblitehtml.so           # 库
/opt/litehtml/build-pic/src/gumbo/libgumbo.so.0  # 解析器（LITEHTML_GUMBO_DIR）
```

为什么是 `build-pic`：lite 要把 `liblitehtml` 链进自己的 `.so`，**必须 `-fPIC`**。aarch64 上
非 PIC 会报 `relocation R_AARCH64_ADR_PREL_PG_HI21 ... can not be used when making a shared
object`——比 x86 更早、更硬地失败。

```bash
sudo mkdir -p /opt/litehtml && sudo chown "$USER" /opt/litehtml
cd /opt/litehtml && git clone https://github.com/litehtml/litehtml.git src
git -C src submodule update --init --recursive        # gumbo-parser

# 1) gumbo：必须是 .so.0 且 PIC
cmake -S src/gumbo-parser -B build-pic/src/gumbo \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="-fPIC" -DBUILD_SHARED_LIBS=ON
cmake --build build-pic/src/gumbo -j"$(nproc)"

# 2) litehtml 本体
cmake -S src -B build-pic \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-fPIC" \
      -DBUILD_SHARED_LIBS=ON -DLITEHTML_BUILD_TESTING=OFF -DLITEHTML_UTF8=ON
cmake --build build-pic -j"$(nproc)"
```

关键点：

- **`-fPIC` 两处都要给**（gumbo 与 litehtml）。上游在 aarch64 上还多一条：`liblitehtml.so`
  里的 `R_AARCH64_...` 重定位要求所有被链对象同为 PIC，漏一处就整链失败。
- `libgumbo` 必须叫 `libgumbo.so.0` 且**在 gumbo 目录里**，否则 `CMakeLists.txt` 那段
  `if(EXISTS .../libgumbo.so.0)` 静默跳过，`--no-as-needed` 也就无从生效，安装机上
  `liblite_html.so` 的 `dlopen` 链会在 gumbo 上断掉。
- litehtml 自身依赖 `cairo`、`fontconfig`、`freetype`：**目标机必须自己有一份**，
  `package.sh` 明确跳过这些（理由在脚本里：fontconfig 依赖 `/etc/fonts` 与系统字体目录，
  硬塞一份只会更难查）`[verified]`。
- **不装在 `/opt/litehtml` 时必须设 `LITEHTML_PREFIX`**。`package.sh` 靠它判断哪些 `ldd`
  依赖算「私有、要随包」：

  ```bash
  LITEHTML_PREFIX=$HOME/litehtml ./tools/package.sh
  ```

  漏设的表现：包里只有 `liblite_html.so`，目标机一调 `md2png` 就报缺 `liblitehtml.so.0`。
  **这是最容易带进安装版的坑。** 最省事就是装在 `/opt/litehtml`——默认值就为它写的。

验证：

```bash
./tools/build.sh
ldd build/liblite_html.so | grep -E 'litehtml|gumbo|not found'   # 不能有 not found
./tools/lite-lua tools/html_img_check.lua                        # 仓库自带三件套自检
```

### 3.5 OCR：arm64 上放弃

`third_party/ocr/` 下**只有预编 `.so` 和模型，没有源码**
`[verified: find third_party/ocr -maxdepth 2 → lib/、models/，无 .c/.cpp]`。
其中 `libocr_simple.so`（PP-OCRv4 的 C 封装）是 x86-64 产物 `[verified: file]`，**没法重编**。

所以 arm64 上：

- `ocr` 工具不可用（`lua/ffi/ocr.lua` 的 `ready()` 返回 false）；
- 把 `libonnxruntime.so.1` 换成 arm64 版（`pip install onnxruntime` 在 aarch64 有 CPU wheel，
  或用发行版包）**也没用**——缺的是 `libocr_simple.so` 那层胶水；
- 影响面：只有 `ocr` 工具。图片理解、`see` 截图、`md2png` 都不依赖它。

想恢复只有一条路：按 `lua/ffi/ocr.lua` 的 cdef 重写一个 `char *lite_ocr(...)` 封装
（PP-OCRv4 det+rec 前后处理约 300 行），不值得为迁移做。**迁移时整个跳过 `third_party/ocr/`。**

### 3.6 codesearch：不用考虑（但要说清怎么绕开）

按需求本次不迁。技术上是**硬阻塞**：`CMakeLists.txt` 依赖
`third_party/codesearch/lib/tokenizers-cpp/` 下的 `libtokenizers_c.a`、`libtokenizers_cpp.a`、
`libsentencepiece.a`、`libonig.a`——静态库按目标架构编，arm64 链接必然报 architecture mismatch
`[verified: 四个 .a 均为 x86 预编]`。

`CMakeLists.txt` 自带优雅降级 `[verified]`：

```cmake
if(EXISTS "${LITE_CS_TOKENIZERS_DIR}/libtokenizers_c.a" AND LITE_CS_JANSSON_LIB)
```

两个条件都成立才编，否则打印 `lite_codesearch disabled` 并跳过 target——词法/符号/上下文查询
由 `lite_cache` + `helper/cgrep` 顶上（`lens` 的降级路径）。

两种绕法任选：

```bash
# a) 推荐：直接挪走静态库目录，让默认配置自然跳过
mv third_party/codesearch/lib third_party/codesearch/lib.x86-disabled
./tools/build.sh

# b) 或不装 libjansson-dev（find_library 找不到 → 条件为假）
# c) 或显式：cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DLITE_CS_TOKENIZERS_DIR=/nonexistent
```

⚠️ `package.sh` 只在文件存在时才拷 `liblite_codesearch.so`，跳过 codesearch 后包里自然没有它。
⚠️ 旧的 `.codesearch`/`analysis` 索引是 x86 HNSW 二进制格式，**跨架构不保证可读**，
建议直接删除重建（`lens build`）。

### 3.7 `helper/*.so`（native 插件）

现有两个，都是纯 C、无第三方库：

| 插件 | 源 | 系统依赖 | arm64 注意 |
|---|---|---|---|
| `cgrep` | `helper/cgrep.c` | glibc `regex.h`、`pthread` | 无 |
| `perfprobe` | `helper/perfprobe.c` | `perf_event_open`、`pthread` | 见 §4 |

```bash
# 会话内
native action=build name=cgrep
native action=build name=perfprobe

# 手工等价
cc -O2 -fPIC -shared helper/cgrep.c -o helper/cgrep-$(date +%s).so -lpthread
cc -O2 -fPIC -shared helper/perfprobe.c -o helper/perfprobe-$(date +%s).so -lpthread
```

机制要点（`AGENTS.md` §5、`design.md:D5`，迁移时最容易忘）：

- `native build` 每次出新的 `<name>-<ts>.so` 并更新 `<name>.json` 的 `"so"` 字段；
  **只有 json 点名的那份是活的**，多版本共存无害。
- 执行侧每次读盘 `ffi.load`，编完**立刻可用**；要进 API `tools` 清单才需要 `/reboot`。
- 手工编就必须**自己改 `<name>.json` 的 `so` 字段**，否则 `_helper_so_abs` 找的是不存在的
  x86 文件 → 报 `helper not found`。
- 旧 x86 `.so` 不必手删：`package.sh` 的 `prune_stale_helper_so` 只保留清单点名的那份。

验证：

```bash
lite plugins --json | grep -i error          # 期望无输出
./tools/lite-lua -e 'print(pcall(require("ffi").load, "helper/cgrep-<ts>.so"))'
```

### 3.8 字体（不编译，但会「静默坏」）

`helper/assets/` 有 `DroidSansFallbackFull.ttf`、`DejaVuSansMono.ttf`，`check_deps.sh` 末尾逐项
检查并警告「中文/★ 渲染成方框」。cairo **不做字体回退**，fontconfig 也需要缓存里有对应族名。

arm64 精简镜像（`debian:bookworm-slim`、树莓派 Lite）默认**没有中文字体**：

```bash
sudo apt install -y fonts-droid-fallback fonts-dejavu-core
fc-cache -f
fc-match "Droid Sans Fallback"     # 应指向 .ttf，而不是 DejaVu
```

---

## 4 trace 兼容验证

`trace` 是 lite 里**对平台最敏感**的子系统：它直接向内核要 `perf_event_open` 和 tracefs。
Lua 层与 `helper/perfprobe` 里的采样器跨架构可移植；内核侧差异必须逐项验。

### 4.1 五个闸门

```bash
./tools/lite-lua tools/trace_check.lua     # 仓库自带自检（status + render 两条链）
```

| 闸门 | 检查 | arm64 常见坑 |
|---|---|---|
| 权限 | `id -u`、`capsh --print \| grep perfmon` | `CAP_PERFMON` 需内核 ≥5.8；更老的 arm64 板子只有 `CAP_SYS_ADMIN`，需 `sudo -n` |
| `perf_event_paranoid` | `cat /proc/sys/kernel/perf_event_paranoid` | ≤1 才能非 root 采样。云 arm64 实例与 Ubuntu 默认是 4 → 必须 root |
| tracefs | `mount \| grep tracefs`，`ls /sys/kernel/tracing` | 目录 `0700 root`：非 root **读不到 ≠ 没挂载**，`status` 会分开报 |
| 内核 config | `zcat /proc/config.gz \| grep -E 'FTRACE\|UPROBES\|KPROBES'` | 树莓派/嵌入式内核常裁掉 `CONFIG_UPROBES`；`latency`/`folded` 的 uprobe 探针直接失败 |
| 符号 | `./tools/lite-lua lua/trace/engine.lua --ksym` | 需 `/boot/System.map-$(uname -r)` 或 `kptr_restrict=0` |

### 4.2 arm64 特有的四点差异 `[static]` + `需实测`

1. **采样事件本身是架构无关的**。lite 的 `oncpu` 用 `PERF_COUNT_SW_CPU_CLOCK`（软件时钟），
   不依赖 PMU 事件名（x86 的 `cycles`/`instructions` 在 arm64 上叫 `cpu-cycles`，
   且不同 SoC 的 PMU 版本不同）。这点**不用改**。
2. **栈展开依赖帧指针**。aarch64 没有 x86_64 的 ORC 展开表；`perf` 的 callchain 在用户态
   完全靠 FP 链（`x29`/`x30`）。所以：
   - 想看有意义的 `folded`/`oncpu` 栈，被采样的程序必须 **`-fno-omit-frame-pointer`** 编译
     （`-O2` 默认会省帧指针，栈就只有 1~2 帧）；
   - lite 自己的采样器（`perfprobe.c` 走 `.eh_frame` 兜底）不受影响，它是按 FDE 解析而非
     FP 遍历 `[verified: perfprobe.c 头注释]`。
3. **指针认证 / 内存标记（PAC、BTI、MTE）**：aarch64 上 IP 的高位字节可能带 PAC 签名位或
   MTE tag。`perfprobe` 的 `off2va` 用 `ip - map.start + map.off` 做地址换算，若 IP 带 tag
   会算到错误偏移、符号化成 `[nosym]`。**`需实测`**：先跑
   `./trace ... --sym` 看命中率，若大量 `[nosym]` 而 `nm` 明明有符号，就是这个原因；
   兜底办法是采 IP 后掩掉顶字节（`ip & 0x00ffffffffffffff`）。
4. **32 位 ARM（armv7）不在支持范围**：`tools/build.sh` 认 `e_machine=40`，但 LuaJIT 2.1 在
   armv7 上要额外 `-DLUAJIT_NO_UNWIND` 之类的开关，且 lite 未验证。只支持 arm64。

### 4.3 验证序列（照抄可跑）

```bash
# 1 环境自检：权限 / tracefs / 渲染依赖
./tools/lite-lua tools/trace_check.lua

# 2 最便宜的探针（count），先证 perf_event_open 通
sudo -n ./tools/run.sh --once --json "trace action=run mode=count probe=tracepoint:sched:sched_switch duration=2"

# 3 on-CPU 采样 + 火焰图（验证栈深度是否够）
sudo -n ./tools/run.sh --once --json "trace action=run mode=oncpu duration=3 flame=/tmp/f.svg"
ls -l /tmp/f.svg

# 4 LuaJIT 帧符号化（perfmap 生效则显示 file:line [TRACE]）
#    注意 trace 是**会话内工具**，没有独立可执行文件：shell 里只能走 run.sh --once，
#    或者干脆在 TUI 里直接说「用 trace 采 2 秒 oncpu」
./tools/run.sh --once --json "trace action=perfmap"
PID=$(pgrep -n -f 'tools/run.sh|lite')   # 采自己：pid 给这个进程
./tools/run.sh --once --json "trace action=run mode=oncpu duration=2 pid=$PID flame=/tmp/g.svg"
# 图上若只有 0x7f... 地址 → perfmap 没开或 LuaJIT 未写 /tmp/perf-<pid>.map

# 5 进程内账本（不要 root，验证 prof 链）
./tools/run.sh --once --json "trace action=prof"
```

判据：`samples > 0` 且 `anon_pct` 不接近 100%（后者说明符号表全丢，典型是 strip + 缺
`.eh_frame`）。

---

## 5 语音模式依赖检查

语音是**纯外部 CLI** 组合，不编进 lite：`ffmpeg` 录音 → `SenseVoice.cpp` 转写 → `inbox.txt` 行。
代码在 `lua/core/voice.lua`，**三件套缺一不可** `[verified]`：

| 件 | 默认路径 / 变量 | 检查位置 |
|---|---|---|
| ASR 可执行 | `SENSEVOICE_BIN`，默认 `/opt/SenseVoice.cpp/bin/sense-voice-main` | `voice.available()` |
| gguf 模型 | `SENSEVOICE_MODEL`，默认 `/data/models/sense-voice-small-q4_k.gguf` | `voice.available()` |
| `ffmpeg` | **硬编码 `/usr/bin/ffmpeg`** | `voice.available()` |

⚠️ **arm64 上最常踩的两个坑**：

1. **`ffmpeg` 路径是硬编码的 `/usr/bin/ffmpeg`** `[verified: voice.lua:available]`。
   用 snap/brew/NixOS/`/usr/local/bin` 装的 ffmpeg，`available()` 直接返回
   「缺少 ffmpeg」，**但 `check_deps.sh` 用 `command -v ffmpeg` 会报 `[OK]`**——两边判据不一致。
   要么 `ln -s $(command -v ffmpeg) /usr/bin/ffmpeg`，要么把这条判断改成 `command -v`
   （改的话顺手同步 `check_deps.sh`）。
2. **录音链固定 `ffmpeg -f pulse`** `[verified: voice.lua:script 里的 `-f pulse -i "%s"`]`。
   纯 ALSA（无 PulseAudio/PipeWire）的 arm64 板子上会报 `Cannot connect to server socket`。
   装 `pipewire-pulse` 或 `pulseaudio` 起一个用户实例；`LITE_VOICE_MIC` 里的设备名是
   **pulse 源名**（`pactl list short sources` 查），不是 ALSA 的 `hw:1,0`。

编译 `SenseVoice.cpp`（CPU 推理，`-ng` 关 GPU）：

```bash
sudo apt install -y build-essential cmake libsndfile1-dev ffmpeg pulseaudio-utils
git clone https://github.com/lovemefan/SenseVoice.cpp /opt/SenseVoice.cpp
cd /opt/SenseVoice.cpp && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j"$(nproc)"
# 模型（q4_k 量化，CPU 上 0.3~0.5s/段）
mkdir -p /data/models && cd /data/models
# 从 HuggingFace/ModelScope 取 sense-voice-small-q4_k.gguf 放到这里
```

arm64 注意：

- ggml 的 NEON 后端在 aarch64 上是默认启用的，**不需要**额外 `-DGGML_NATIVE=ON`；
  `需实测`：树莓派 4 上 q4_k 约 0.6s/段（x86 桌面约 0.35s），`LITE_VOICE_CHUNK` 别设太小。
- `-t 4` 线程由 `SENSEVOICE_THREADS` 控制，4 核板子上设 4 会占满，可用 `2`。
- 别用 CUDA 版：Jetson 之外没有 CUDA；`-ng` 是硬编码在 `asr_cmd()` 里的。

验证：

```bash
./tools/lua.sh -e 'local v=require("core.voice"); print(v.available())'
# 期望 true；false 时第二个返回值就是缺哪件
pactl list short sources | head          # 确认有可录音源
echo "测试" | ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -f pulse default   # 出声测试
```

TUI 里 `#语音模式` 开/关；状态栏亮 `V`；失败原因在 `/tmp/lite-voice-<ts>/err.log`。

---

## 6 打包、安装与验收

### 6.1 原生编译 vs 交叉编译

- **原生**（推荐）：在 arm64 机器上跑 `./tools/release.sh`，`_arch.sh` 自动出
  `dist/lite-linux-arm64.tar.gz`，`build.sh` 自动判架构。
- **交叉**：`LITE_DIST_ARCH=arm64 ./tools/package.sh` 只改**包名**，不改编译器。
  真正的交叉编译需要自备工具链并改 cmake 的 `CMAKE_C_COMPILER`/`CMAKE_CXX_COMPILER`，
  且 `third_party/luajit` 的 `HOST_CC`/`CROSS` 要手工设。**没有现成脚本**，
  所以除非必须在 x86 上出 arm64 包，否则别走这条路。

### 6.2 三个打包闸门

| 闸门 | 值 | 迁移时的影响 |
|---|---|---|
| `LITEHTML_PREFIX` | 默认 `/opt/litehtml` | 装别处就必须设，否则三件套不进包（§3.4） |
| `LITE_DIST_MAX_FILE_MB` | 默认 16 | arm64 `.so` 体积相近；若误装系统库会在这里报错拦住 |
| `LITE_DIST_WITH_ORT` | 默认 0 | arm64 上保持 0（OCR 反正不用） |

`package.sh` 还会按 `ldd` 把 `liblite_image.so` 的 png/jpeg/webp 拷进 `dist/lib`。如果目标机的
`libpng` 版本与编译机不同，**优先让目标机用自己的**（`check_deps.sh` 会亮 `libpng` 行），
不要指望包里的那份。`需实测`：跨发行版（如 Debian 编、Ubuntu 跑）时这三个 `.so` 可能
因符号版本冲突反而不如系统自带。

### 6.3 验收清单（按顺序，前一步不过不要往下走）

```bash
# 1 依赖自检：每行都该是 [OK] 或可解释的 [INFO]
./tools/check_deps.sh

# 2 架构确认（不是 x86）
file third_party/luajit/src/luajit third_party/cjson/lua/5.1/cjson.so build/liblite_cache.so

# 3 全量回归（契约级；编 C 后必跑）
./tools/test.sh

# 4 单轮真实请求（验证 API + cjson + 记忆 + 工具派发）
./tools/run.sh --once --json "用 cgrep 搜 'agent' 并回一行总结"

# 5 TUI 文本快照（UI 验收标准）
./tools/run.sh --tui --snapshot /tmp/tui.txt && less /tmp/tui.txt

# 6 插件清单无加载错误
lite plugins --json | grep -i error

# 7 HTML→PNG（可选能力里最容易坏的一条）
./tools/lite-lua tools/html_img_check.lua
./tools/run.sh --once --json "md2png path=README.md out=/tmp/r.png"
# 然后 read /tmp/r.png：中文变方框 = 缺字体（§3.8），报缺 .so = §3.4

# 8 trace（§4）
./tools/lite-lua tools/trace_check.lua

# 9 安装版与源码树一致（C 改过就必须走 release，不能只 build）
ls -l build/liblite_cache.so ~/.local/share/lite/build/liblite_cache.so
```

第 9 条的理由（`AGENTS.md` §5 记过）：`lua/` 是软链、`build/liblite_*.so` 是 install 时的实体
拷贝。只 `build.sh` 会得到「新源码配旧二进制」，现象是改了 C 却不生效。

### 6.4 迁移后必做的两件事

1. **删 `mem.lock`**（若拷了目录）：否则报「被 pid N 占着」、退出码 3。
2. **重建索引**：`lens build`（codesearch 关闭时是 `lite_cache` 索引）、旧的 `analysis/` 与
   `.codesearch/` 都是 x86 产物，跨架构读不保证。

---

## 7 故障对照表

| 现象 | 根因 | 处理 |
|---|---|---|
| `exec format error` | LuaJIT 是 x86 产物 | `make -C third_party/luajit clean && ./tools/build.sh`（**必须 clean**） |
| `[FAIL] cjson` | `third_party/cjson/lua/5.1/cjson.so` 是 x86 | §3.2 重编 |
| `cmake` 报找不到 `libpng/libjpeg/libwebp/X11` | 缺 `-dev` 包，或 `find_package REQUIRED` 全局生效 | §2.1 装齐 |
| `liblite_cache.so` 加载失败 | 缺 `libgomp.so.1` | `apt install libgomp1` |
| 加载 `.so` 报「找不到」但文件在 | 旧架构产物被 `libfind.lua` 跳过 | `file` 验架构 → `rm -rf build && ./tools/build.sh` |
| `md2png` 报缺 `build/liblite_html.so` | `liblitehtml`/`libgumbo` 没编或不在 `/opt/litehtml` | §3.4；`cmake` 时必须 `-fPIC` |
| 安装版缺 `liblitehtml.so.0` | 打包时 `LITEHTML_PREFIX` 不对 | `LITEHTML_PREFIX=... ./tools/package.sh` |
| 图上中文/★ 是方框 | 缺中文字体 | §3.8 `fc-cache -f` |
| `relocation R_AARCH64_... shared object` | 非 PIC 目标链进 `.so` | 加 `-fPIC` 重编 litehtml/gumbo |
| codesearch 链接 `architecture ... mismatch` | tokenizers 静态库是 x86 | §3.6 挪走目录 |
| `helper not found` | `<name>.json` 指向不存在的 x86 `.so` | 重编 + 更新 `so` 字段（§3.7） |
| `#语音模式` 说缺 ffmpeg，但 `check_deps` 报 OK | `voice.lua` 硬编码 `/usr/bin/ffmpeg` | §5 建软链 |
| 语音报 `Cannot connect to server socket` | 无 PulseAudio/PipeWire | 起 `pipewire-pulse`，或改 `-f alsa` |
| `trace` 全是 `[nosym]` | strip 无符号，或 IP 带 PAC/MTE tag | `.eh_frame` 兜底；`需实测` 掩顶字节 |
| `trace` 栈只有 1~2 帧 | aarch64 无 ORC，靠 FP；`-O2` 省了帧指针 | 目标程序加 `-fno-omit-frame-pointer` |
| `trace` 直接 `permission denied` | `perf_event_paranoid=4` 且非 root | `sudo -n` 或放宽 `perf_event_paranoid` |
| 启动报「被 pid N 占着」、退出码 3 | 拷来的 `mem.lock` | `rm mem.lock`（保留 `mem.bin`/`mem.idx`） |

---

## 8 已知未验证项（诚实清单）

上机时优先验这几条，别当成已经成立：

1. **LuaJIT JIT 是否真的编译**（不只是解释执行）：§3.1 的三条命令。
   `需实测`：某些加固内核 + `PROT_EXEC` 限制会让 mcode 分配失败，表现为 `jit.status()` 里
   JIT 为 off。
2. **aarch64 上 `perfprobe` 的符号化命中率**：PAC/MTE tag 是唯一可能让地址换算失准的地方
   （§4.2 第 3 点）。判据是 `--sym` 后 `[nosym]` 占比。
3. **`liblite_html.so` 在目标机上的 cairo/fontconfig 版本兼容**：编机与目标机跨发行版时，
   cairo 的 ABI 差异会让 `dlopen` 成功但渲染崩。
4. **`libgomp` 版本**：`liblite_cache.so` 由编机 gcc 的 libgomp 服务；目标机 gcc 版本更老时
   可能缺 `GOMP_5.0` 符号。以目标机自己的 `libgomp1` 为准，且**不要**把 libgomp 拷进包。
5. **SenseVoice.cpp 在 arm64 上的实际延迟**：决定 `LITE_VOICE_CHUNK`/`TAIL` 的取值。
6. **32 位 armv7**：未支持、未验证（§4.2 第 4 点）。

---

## 附：与既有文档的分工

- 为什么这么设计（D1–D10）→ `design.md`
- 用法与环境变量 → `README.md`
- JIT 加热/`-jv` 读法 → `luajit.md`
- trace 五个环与探针语法 → `trace.md`
- **跨架构迁移（本文）→ `arm64.md`**
