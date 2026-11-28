# arm64.md — 交叉编译 / 打包 / 部署 / serve 集群

**一句话**：源码只有一份，在本机（x86_64）交叉编出 aarch64 产物 → 打包 → 灌进盒子 →
盒子常驻 `serve`，master 通过一条队列指挥它干活。

本文是**操作手册 + 原理账本**。规则约束看 `AGENTS.md`，设计取舍看 `design.md`。

---

## 0 目标机现状 [verified 2026-11-28]

| | 121 / `x96src` | 123 / `x98h\|x98\|h618`（hostname `armbian`） |
|---|---|---|
| 地址 | `192.168.1.121` | `192.168.1.123` |
| 系统 | Armbian 26.11.1 trixie | Armbian OS 26.11.0 trixie |
| 架构 | `aarch64` | `aarch64` |
| glibc | 2.41-12+deb13u4 | 2.41-12+deb13u4 |
| lite | `/root/.local/bin/lite` 0.1.1 | 同 |
| luajit | `/usr/local/bin/luajit` → `/opt/reader/bin/luajit`，2.1.1780076327 | 同（同版本同软链） |
| 开机自启 | `lite-serve`(8765) + `lite-setup`(8080)，均 `enabled` [verified 2026-11-28 整机 reboot] | 同（unit md5 一致） |

两台同发行版同 glibc → **一份 sysroot 能同时喂两台**，这是交叉能省事的前提。
ICMP 被上游封：`ping` 不通 ≠ 离线，判活一律用 `ssh` / `curl /health`。

---

## 1 为什么不直接在盒子上编

在盒子上原生编（`rsync` 整棵树 → `apt install` 一堆 dev 包 → `./tools/build.sh`）能跑通，
代价是每次改 C 都要传树、编、再传回来，一轮几分钟；而且盒子上缺 `jansson`/`ctags`/`codesearch`，
`tools/test.sh` 至今 **1138 ok / 5 fail**（5 条全是 x86 假设，见 §8）。

交叉编：本机改完立刻出 arm64 产物，盒子只负责**跑**。两条路并存，互不干扰：

| 命令 | 给谁编 | 产物目录 | 本机 `build/` |
|---|---|---|---|
| `./tools/build.sh` | 本机 | `build/` | 就地写 |
| `./tools/build_arm64.sh` | 盒子 | `build-arm64/` | **一字节不碰** |
| `./tools/build_arm64.sh --lua-only --deploy H` | 盒子 | 不编译，只送 `*.lua` | 一字节不碰 |

### 1.x `--lua-only`：纯 Lua 改动不走编译

改了 `lua/` 或 `helper/*.lua` 却端着一份 2GB sysroot 重走工具链，是纯浪费：`--lua-only` 跳过
工具链/sysroot/编译/打包，用 `tar` 走 ssh 把 `lua/` + `helper/` 的 `*.lua` 送进远端安装根，
再逐个 md5 对账（实测 131 个文件 **2.5s**，整包一轮是分钟级）。

三条硬约束，缺一条就踩坑：

- **只搬 `.lua`，绝不搬 `.so`/`.json`**。目标机 `helper/*.so` 是那块板子 `gcc -shared -fPIC` 现编的
  arm64 二进制，本机同名文件是 x86 的；整目录同步会得到「`ffi.load` 成功、一调用就
  `attempt to call field 'call' (a nil value)`」——加载期不查架构，调用期才炸。
- **`helper/lib/app_*_map.lua` 排除**。那是 `uimap` 在哪台机器上真点出来的坐标，属于那台机器。
- **重启 serve 才算生效**。工具 schema 启动时扫一次并 memo，`ls` 看到了不代表模型看得见。默认
  `/health` 报 `busy:true` 就**不**重启（免得打断派活中的那一轮），只打印手工命令。

安装根不写死：从远端 `~/.local/bin/lite` 软链 `readlink -f` 反推，换 `PREFIX` 的机器也不会打偏
（打偏的现象是插件「送过去了但没加载」，而 `--version` 一切正常）。

---

## 2 原理

### 2.1 sysroot 是全部秘密

交叉编译 = 用 `aarch64-linux-gnu-gcc` + 一个「假装是目标机根目录」的目录树里找头文件和库。
那棵树就是 **sysroot**：`$SYSROOT/usr/include`、`$SYSROOT/usr/lib/aarch64-linux-gnu/*.so`。

它**不是仓库内容**（约 **2.0G**，含目标机系统库），默认落在仓库外 `~/arm64-sysroot`，
由 `LITE_SYSROOT` 覆盖。造法（`tools/build_arm64.sh:--fetch-sysroot`）：

```bash
./tools/build_arm64.sh --fetch-sysroot root@192.168.1.121
```

只拉 `/usr/` 与 `/opt/litehtml/`，**不拉 `/root` `/home`**——目标机私有数据进 sysroot
只会被误打进包里。三个必须知道的细节：

1. **绝对软链会断**。目标机上 `/opt/litehtml/include` 是指向 `/opt/litehtml/src/include`
   的绝对软链，`rsync` 后它指向宿主路径（不存在的 x86 树）→ 交叉编时报
   `litehtml/html.h not found`。脚本会自动重指：`ln -sfn src/include $SYSROOT/opt/litehtml/include`。
2. **判据用目录不用「能打开」**：`[ -d "$SYSROOT/usr/lib/$TRIPLE" ]`。
   空壳目录更像半途而废的 `rsync`，能让后续 cmake 报一堆莫名其妙的错。
3. 校验 `$TRIPLE` 是 `aarch64-linux-gnu`（armv7 是 `arm-linux-gnueabihf`）。
   拿错架构的 sysroot，cmake 依然会「成功」，只是链出来的东西跑不了。

**不装 arm64 multiarch 包**：`sudo dpkg --add-architecture arm64` 要改本机 apt 源
（arm64 得换 `ports.debian.org`），几百 MB，还会让本机 `apt upgrade` 变复杂。
rsync sysroot 是**只读**操作，本机 apt 一点不动。

### 2.2 cmake 怎么知道自己在交叉

`tools/cmake-aarch64.cmake`（armv7 版 `cmake-armv7.cmake`，由它 sed 生成，**未实测 [static]**）：

```cmake
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER   aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_SYSROOT      $ENV{SYSROOT})
# pkg-config 也要进 sysroot，否则它会拿宿主的 .pc → 链宿主库 → 产物混血
set(ENV{PKG_CONFIG_SYSROOT_DIR} ${CMAKE_SYSROOT})
set(ENV{PKG_CONFIG_LIBDIR} ${CMAKE_SYSROOT}/usr/lib/aarch64-linux-gnu/pkgconfig:...)
```

`LITEHTML_ROOT` 是个 `CACHE PATH`（`CMakeLists.txt:70-95`），默认 `/opt/litehtml`，
交叉时改成 `$SYSROOT/opt/litehtml`。原先散在各处的 `LITEHTML_GUMBO_DIR` 硬编码一并改成
`${LITEHTML_ROOT}` 派生——**这是 x86 假设清单里第一条被清掉的**。

### 2.3 架构判定一律读 ELF `e_machine`

不用 `file`，不用 `readelf`（两者输出格式随版本变，脚本里 grep 很脆）：

```bash
od -An -tu1 -j18 -N2 file.so | awk '{print $1}'
# 62=x86_64  183=aarch64  40=armv7  3=i386
```

字节 18-19 就是 ELF header 的 `e_machine`（LE 小端，取低位字节即可）。
`tools/cross.sh` **出口逐个验**，不是 183 就整条失败——不让「编成功了但跑不了」
漏到目标机上变成 `exec format error`。

### 2.4 跨架构不能用 `ldd`（这条坑最贵）

`package.sh` 要收集随包的 `liblitehtml.so.0` / `libgumbo.so.0`。同架构时用 `ldd`（它真把库
load 起来，最准）。**跨架构时 `ldd` 直接说 `not a dynamic executable`，依赖全空 →
两个 .so 静默漏掉 → 到目标机 html→png 才炸，现象是「md2png 报 dlopen 失败」**。

所以交叉时静态读 `DT_NEEDED` 再在 sysroot 里按名解析（`package.sh:_needed_of` 分岔）：

| 模式 | 怎么找依赖 |
|---|---|
| `CROSS_PKG=0`（同架构） | `ldd` |
| `CROSS_PKG=1`（`WANT_MACHINE != HOST_MACHINE`） | `readelf -d` → `DT_NEEDED` 列表 → `_sysroot_find` 在 `$SYSROOT/usr/lib/<triple>/` 按 soname 找实路径 |

### 2.5 cjson 为什么要按架构校验

仓库里 `third_party/cjson/lua/5.1/cjson.so` 是**人肉拷进来的 x86 二进制**。
把它 rsync 到盒子 → `require "cjson"` 在 C 层炸 → 连 `lite --version` 都跑不了
（Lua 侧还没机会报错）。`package.sh:293-320` 的做法：

```bash
_got="$(_elf_machine "$_cjson")"
[ "$_got" = "$_want" ] || 退到系统副本 $SYSROOT/usr/lib/<triple>/lua/5.1/cjson.so
```

找不到合格副本就打包失败，宁可早失败。

---

## 3 过程：一条命令

```bash
# 首次：拉 sysroot（约 2GB，慢，只做一次）
./tools/build_arm64.sh --fetch-sysroot root@192.168.1.121

# 日常：编 + 打包 + 部署到 123
./tools/build_arm64.sh --clean --package --deploy root@192.168.1.123
```

分步等价（调试时用，看得到中间产物）：

```bash
./tools/cross.sh --clean                          # 只编 → build-arm64/，出口验 183
LITE_BUILD_DIR=build-arm64 LITE_DIST_ARCH=arm64 \
LITE_SYSROOT=$HOME/arm64-sysroot ./tools/package.sh   # → dist/lite-linux-arm64.tar.gz
scp dist/lite-linux-arm64.tar.gz root@192.168.1.123:/root/
ssh root@192.168.1.123 'cd /root && tar xzf lite-linux-arm64.tar.gz && ./lite-linux-arm64/tools/install.sh'
```

**`--clean` 不是可选项的洁癖**：cmake 缓存的旧编译器路径（`CMakeCache.txt` 里的
`CMAKE_C_COMPILER`）会让产物「绿着错架构」——脚本一路 OK，`e_machine` 还是 62。
`build_arm64.sh` 出口清点会当场揭穿：

```
build_arm64: 产物清点（e_machine 必须 = 183）
  liblite_cache.so   132K  e_machine=183
  ...
```

产物共 5 个：`liblite_{cache,capture,html,image,tui}.so`。`lite_html` 额外带
`liblitehtml.so.0` + `libgumbo.so.0`（`$ORIGIN` 同目录解析，**安装版不必有 `/opt/litehtml`
也能跑**；只有从源码树重编才需要它）。

---

## 4 部署：`install.sh` 的两条路

`tools/install.sh` 默认**从当前源码树现打包**（旧实现「dist 存在就 cp」导致改的代码不生效）。
但解包安装时树里没有 `src/`，走另一条：

```bash
PREBUILT=0
[ ! -d "$ROOT/src" ] && { [ -x "$DIST/tools/lite" ] || [ -x "$ROOT/tools/lite" ]; } && PREBUILT=1
```

**踩过的坑**：在 123 上直接跑 `LITE_SKIP_PACKAGE=1 ./install.sh` 会失败——
它要求 `$ROOT/dist/$LITE_DIST_NAME/tools/lite`。要么让解包目录落在
`<root>/dist/lite-linux-arm64/`，要么走上面 `build_arm64.sh --deploy` 的标准路径
（它 `rm -rf` 旧目录再解包，`PREBUILT` 自动为 1）。

装完必须验（**不要靠「install 没报错」**）：

```bash
ssh root@<box> '~/.local/bin/lite --version
                ~/.local/bin/lite plugins 2>&1 | tail -2
                ~/.local/bin/lite --once --json "回一个字：通"'
```

`plugins` 应报 `25 helper tool(s), 1 hook plugin(s), 0 error(s)`；`--once` 需要
`DEEPSEEK_API_KEY`（在 `~/.config/lite/.env`，**缺了只报变量名，不 print key**）。

### 4.1 目标机必须自带 luajit（交叉包里没有解释器）

lite 的入口 `tools/lite` 是个 shell wrapper，真正执行的是 `tools/lite-lua`；后者按两级找解释器
（`tools/lite-lua:9-11`）：

```bash
LUA="$ROOT/third_party/luajit/src/luajit"      # ① 随包自带的
[ -x "$LUA" ] || LUA="$(command -v luajit || true)"   # ② 退回系统 PATH 里的
[ -z "$LUA" ] && echo "lite: bundled luajit not found" >&2 && exit 1
```

**交叉包里 ① 永远不存在**：仓库那份 `third_party/luajit/src/luajit` 是宿主编的 x86 ELF，打进
arm64 包会让 `lite --version` 直接 exec format error，所以 `package.sh:279-289` 按 `e_machine`
比对后**主动删掉它**并打印提示：

```
package: bundled LuaJIT 是 e_machine=62、目标是 183 → 不进包
         目标机需自带解释器（apt install luajit），或 tools/cross.sh --luajit 交叉编一份
```

于是**盒子上的 `luajit` 是硬依赖**，缺了就退化成上面那句 `lite: bundled luajit not found`
（不是「插件没加载」，是**整个 lite 起不来**）。两台盒子都没有 apt 的 luajit 包（`dpkg -l` 只有
`liblua5.2-0`），现在靠的是 reader 那份：

```bash
# 当前状态 [verified 2026-11-28 两台]
ls -l /usr/local/bin/luajit          # -> /opt/reader/bin/luajit（2.1.1780076327）
/opt/reader/bin/luajit -v            # LuaJIT 2.1.1780076327

# 新机器装法（二选一，软链要落在 PATH 内的目录，/usr/local/bin 已在默认 PATH）
apt install -y luajit                # 首选：包管理器管版本，不依赖 /opt
# 或复用 reader 那份（省事，但 /opt/reader 被删/重装就跟着挂）：
ln -sfn /opt/reader/bin/luajit /usr/local/bin/luajit
```

验「解释器这条路真通」（别只看 `which`）：

```bash
env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  ~/.local/share/lite/tools/lite-lua -e 'print(jit.version)'   # 期望报 lite: bundled luajit not found
~/.local/share/lite/tools/lite-lua -e 'print(jit.version)'     # 期望 LuaJIT 2.1.x
```

**为什么软链而不是靠 `LD_LIBRARY_PATH`/改脚本**：`AGENTS.md` 禁止把 `$ROOT/lib` 塞进
`LD_LIBRARY_PATH`（会污染同机其他程序），而 `lite-lua` 的兜底是纯 `command -v`——只认 PATH。
**非交互 ssh 的 PATH 不含 `~/.local/bin`**，所以 `lite` 命令本身也要么写全路径
（`/root/.local/bin/lite`），要么把 `export PATH="$HOME/.local/bin:$PATH"` 写进 `/root/.bashrc`；
systemd unit 里用的是绝对路径，**服务不受这个影响**。

---

## 5 serve 模式：让盒子常驻「待命」

盒子不是给人敲命令的，是给 master 派活/远程接管的。手动拉起用 `tools/serve_up.sh`；
**开机自启交给 systemd**（见 §5.1，盒子断电没人守着，setsid 那套没有开机钩子）：

```bash
./serve_up.sh start|stop|restart|status|logs   # 临时/排错用
```

| 项 | 值 / 机制 |
|---|---|
| 默认地址 | `0.0.0.0:8765`（`LITE_SERVE_HOST/PORT` 可改） |
| workdir | `$HOME/.local/share/lite-serve`（`LITE_SERVE_DIR`）← **serve 持这个目录的 `mem.lock`**，日志/pid/`.stop` 也在这 |
| 自监督 | `setsid` 起循环，`LITE_SUPERVISED=1`；`rc=75`（`/reboot` 的退出码）立刻换进程，其他非零退 5s 重起 |
| stop | 写 `.stop` 标记 + 按 pidfile 收**进程组**（不用 `pkill -f`，不误杀同机 TUI） |

同一个端口靠**首包嗅探**分流两种协议：

- `GET /health` — 探活，**不排队**，用来判「活着没 / 忙不忙」
- `POST /prompt` — `{"prompt":"…"}`（也收裸文本）→ `{"ok":true,"text":…}`，超时 900s 回 504
- 其余按 JSONL 走 attach 协议

**HTTP 与 attach 复用同一条队列、同一个 agent**：谁先来谁先答，后到的排队。
所以 serve 实例是「单通道」的——想并行就多起几台/多目录（见 §6 的 `mem.lock` 约束）。

**没有鉴权**。暴露面全靠 `--host`：默认 `127.0.0.1`，盒子上要局域网可达才 `0.0.0.0`。
现在两台都开在 `0.0.0.0:8765` —— 即局域网内任何人都能让盒子跑任意工具调用（含 `bash`）。
收回：`LITE_SERVE_HOST=127.0.0.1 ./serve_up.sh restart`。

### 5.1 开机自启：两个 systemd unit [verified 2026-11-28 整机 reboot]

盒子断电后没人 ssh 进去拉，所以**必须** systemd 级自启（`systemd --user` 被禁，也不顶用：
要登录会话才活）。两台各有两个 unit，缺一个就少一半能力：

| unit | 干什么 | 端口 | 缺了会怎样 |
|---|---|---|---|
| `lite-serve.service` | `serve_up.sh --loop` → 常驻 agent | `0.0.0.0:8765` | master 派不了活、`/health` 空，等于盒子离线 |
| `lite-setup.service` | `lite setup` → API Key 初始化页 | `0.0.0.0:8080` | 换 key 只能 ssh 手改 `~/.config/lite/.env` |

装（**unit 是脚本生成的，别手写/别 cp**）：

```bash
sudo ./tools/serve_service.sh install [--user root --host 0.0.0.0 --port 8765 --dir D]
sudo ./tools/setup_service.sh install [--user root --host 0.0.0.0 --port 8080]
sudo ./tools/serve_service.sh dry-run      # 只看文本，不碰系统
```

**两层职责不重叠**：外层 systemd 只兜「内层循环自己死了」（OOM/脚本 bug，`Restart=always`），
内层 `serve_up.sh --loop` 管「serve 死了 5s 退避」和「`/reboot` 的 exit 75 立刻换进程 0.3s」
——后者的语义 systemd 的单一 `RestartSec` 表达不了，硬塞会把 75 和真崩溃混为一谈。

**判「真自启」只认 enabled + wants 软链**，`is-active` 不算数（手工 start 的也 active）：

```bash
systemctl is-enabled lite-serve lite-setup                                  # 都要 enabled
ls -l /etc/systemd/system/multi-user.target.wants/lite-*.service            # 软链齐
systemd-analyze verify /etc/systemd/system/lite-{serve,setup}.service       # 无 Condition/Assert 命中
sudo reboot && sleep 80 && systemctl is-active lite-serve lite-setup        # 终审
```

**踩过的坑（121）**：unit 建了但 `disabled` —— 等于手动开关，断电重启 8765 空着没回来。
install 脚本本来就有 `enable --now`，出现 `disabled` 是人为 `systemctl stop && disable` 之后没补回。
另：`stop` 之后别用 `serve_up.sh stop` 停（写 `.stop` + 收进程组会被 `Restart=always` 立刻拉回，看着像停不掉）。

**仓库里的实测快照**：`tools/units/lite-serve.service`、`tools/units/lite-setup.service`
（与两台机器上的原件逐字节一致，md5 相同，仅供审计/`diff` 对照；路径/用户/端口以脚本参数为准）。

---

## 6 master 指挥 slave

两条路，选一条：

### 6.1 一次性派活：`tools/cluster.sh`（够快、够土、结果落盘）

```bash
cat > tasks.tsv <<'EOF'
# box            dir                      prompt                      task
local            ~/w/a                    "跑 tools/test.sh 报结论"    t1
root@192.168.1.121  ~/w/b                 "查 5 条失败的原因"          t2
root@192.168.1.123  ~/w/c                 "编 arm64 产物并验 e_machine" t3
EOF
./tools/cluster.sh --jobs 3 --out cluster-out tasks.tsv
```

- 一行一**槽** = 一台机器上的一个 work dir；`local` / `-` 跑本机。
- 每槽一条 `ssh`（或本地 `bash`），prompt **base64 过 ssh**（避开引号地狱）。
- 每任务落 `out/<task>.{jsonl,rc,sec}` + `out/tasks.tsv` 清单；汇总表由 `lite-lua` 解析 JSONL。
- 退出码：`0` 全 ok / `1` 有失败 / `2` 用法错。
- **并发度 = 槽数，不是进程数**：同目录第二个 lite 抢不到 `mem.lock`，**以退出码 3 拒绝启动**。

典型用法：改完 C 想在两台盒子上同时验，就给每台写一个不同 dir 的槽。

### 6.2 长驻派活：serve + `/prompt`（远端一直在线，随时插话）

```bash
# 探活 + 判闲置（单次采样不当判决）
lite serve --probe 192.168.1.123:8765      # rc 0=wake 3=busy 4=unreachable 5=unstable

# 派一条
curl -s -X POST http://192.168.1.123:8765/prompt \
     -H 'Content-Type: application/json' -d '{"prompt":"报一下 uname -m 和磁盘占用"}'

# 人接管：把远端 TUI 拉到本地终端
lite attach --port 8765 --host 192.168.1.123          # 当前终端
lite attach --port 8765 --host 192.168.1.123 --tmux   # 新 tmux 窗口
```

`--probe` 采样 3 次、间隔 2s：`active_proc:alive()` 语义是「尽快」不是瞬时，
单次读到 idle 可能是 agent 正在两次工具调用之间。**只认 3 次一致的结果**。

自动化判闲置 → 派活的标准环：

```
probe rc=0 (wake)         → 直接 POST /prompt
probe rc=3 (busy)         → 等一会儿再 probe，别硬塞（会排队占住超时）
probe rc=4 (unreachable)  → ssh 上去 serve_up.sh status / logs 看日志
probe rc=5 (unstable)     → 再采一轮
```

### 6.3 谁编谁跑（重要）

**C/ABI 硬验证放远端实例，本机只做小改与文本级验证**（`design.md:D10`）：

1. 本机 `./tools/build_arm64.sh --clean` 编 → 交叉链路本身在本机验
2. `--deploy` 灌到盒子 → 在盒子上跑 `./tools/test.sh` + 真实用例
3. 盒子绿了才 `git commit`；master 侧只 `git pull` + 重编 + `/reboot`

改过 C 就必须重编再 `/reboot`（reboot 只重启进程不编译；同路径 `ffi.load` 换不掉）。

---

## 7 验收清单

```bash
# 1 交叉产物架构
od -An -tu1 -j18 -N2 build-arm64/liblite_html.so      # 183
# 2 包内没混宿主 x86
tar tzf dist/lite-linux-arm64.tar.gz | grep -c 'liblite_.*\.so'
# 2b 包内没有解释器（应该是 0，有的话说明交叉包混进了宿主 x86 luajit）
tar tzf dist/lite-linux-arm64.tar.gz | grep -c 'luajit/src/luajit$'
# 3 目标机（非交互 ssh 的 PATH 不含 ~/.local/bin，用绝对路径，别写裸 lite）
ssh root@<box> '~/.local/bin/lite --version
                ~/.local/bin/lite plugins 2>&1 | tail -1
                ls -l $(command -v luajit)'          # 解释器必须在（§4.1）
# 4 真跑一轮
curl -s -X POST http://<box>:8765/prompt -d '{"prompt":"回两个字：在线"}'
# 5 本机回归（改过 shell/lua 必跑）
./tools/test.sh
```

`md2png` 是 arm64 上最容易漏的一环（它同时依赖 `liblite_html` + `liblitehtml.so.0` +
`libgumbo.so.0` + `$ORIGIN`）。装完在盒子上出一次图确认字节数正常，别只看 `--version`。

---

## 8 踩坑账本

| 现象 | 根因 | 修法 |
|---|---|---|
| `litehtml/html.h: No such file` | sysroot 里 `include` 是绝对软链，rsync 后断 | `ln -sfn src/include $SYSROOT/opt/litehtml/include` |
| 盒子 `require "cjson"` C 层炸，`--version` 都挂 | 仓库 `third_party/cjson/.../cjson.so` 是人肉拷的 x86 | 打包时按 `e_machine` 校验，不符退系统副本 |
| 商品 `e_machine=183` 但 html→png 报 dlopen 失败 | 跨架构 `ldd` 返回空 → `liblitehtml`/`libgumbo` 漏进包 | 静态读 `DT_NEEDED` + sysroot 解析 |
| cmake 一路成功，产物还是 x86 | `CMakeCache.txt` 留着旧编译器 | `--clean` |
| `install.sh: .../_arch.sh: No such file` | `_arch.sh` 没进包复制列表 | 已加进 `package.sh` 复制列表 |
| 123 上 `LITE_SKIP_PACKAGE=1 ./install.sh` 报「既没有 dist 也没有 tools/lite」 | 解包目录层级不对 | 用 `build_arm64.sh --deploy`，别手敲 |
| 盒子上 `test.sh` 5 条 FAIL | 3 条 libfind 外架构、ocr 提示文案、`lua.sh` 预加载 bundled .so | 已知，**未改**；都不是真 bug |
| 盒子上 `lite: bundled luajit not found`，`--version` 都跑不了 | 交叉包按 `e_machine` 删了宿主 luajit，目标机 PATH 里又没有（§4.1） | `apt install luajit`，或 `ln -sfn /opt/reader/bin/luajit /usr/local/bin/luajit` |
| `ssh <box> 'lite --version'` → `command not found`，但 systemd 服务正常 | 非交互 ssh 的 PATH 不含 `~/.local/bin` | 写全路径 `~/.local/bin/lite`；unit 用绝对路径所以服务不受影响 |
| 交叉编 armv7 没验过 | `cmake-armv7.cmake` 由 aarch64 版 sed 生成 | **未实测 [static]**，用时先 `--clean` 验 `e_machine=40` |

---

## 附：相关文件

| 文件 | 作用 |
|---|---|
| `build_arm64.sh`（软链 → `tools/build_arm64.sh`） | 门面：前置检查 + 编 + 包 + 部署 |
| `tools/cross.sh` | 重活：cmake 交叉编 + 出口验 `e_machine` |
| `tools/cmake-{aarch64,armv7}.cmake` | toolchain 文件（sysroot / pkg-config 重定向） |
| `tools/package.sh` | 打 `dist/lite-linux-<arch>.tar.gz`；`CROSS_PKG` 决定依赖解析路径 |
| `tools/_arch.sh` | `LITE_DIST_ARCH` / `LITE_DIST_NAME`（宿主 `uname` 推导，交叉时覆盖） |
| `tools/install.sh` | 装到 `~/.local/{bin,share/lite}`；`PREBUILT` 区分解包安装 |
| `tools/serve_up.sh` | `start\|stop\|restart\|status\|logs`，setsid 自监督 |
| `tools/serve_service.sh` | 装 `lite-serve.service`（8765 开机自启）；`install\|uninstall\|dry-run` |
| `tools/setup_service.sh` | 装 `lite-setup.service`（8080 key 初始化页）；`install\|uninstall\|dry-run` |
| `tools/units/*.service` | 两台盒子实测 unit 快照（逐字节一致，**权威源是上面两个脚本**） |
| `tools/cluster.sh` | TSV → 并行 ssh → 每任务 JSONL/rc/sec |
