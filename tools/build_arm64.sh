#!/usr/bin/env bash
# lite arm64 交叉编译一键入口（x86_64 宿主编 → aarch64 目标跑）。
#
# 定位：这是「门面」，重活仍在 tools/cross.sh（cmake + 产物架构对账）。
# 为什么要多一层：
#   交叉编译的失败模式几乎都在「前置」和「出口」两端 —— sysroot 没造、造错断链、
#   编出来是 x86、打包时 BUILD_DIR 忘指导致包里混宿主 .so。这些都不是 cmake 的
#   职责，每次手敲一遍环境变量必然漏一项，所以钉成一个脚本。
#
# 与本机编译的分工（别混）：
#   tools/build.sh       ← 给当前机器编，产物 build/，本机 lite 直接用
#   tools/build_arm64.sh ← 给盒子编，产物 build-arm64/，本机 build/ 一字节不碰
#
# sysroot 不是仓库内容（约 2GB，含目标机系统库），放仓库外，默认 ~/arm64-sysroot。
# 没有就 --fetch-sysroot <host> 从目标机 rsync 一份（只读远端，只写本机目录）。
#
# 用法: ./tools/build_arm64.sh [选项]
set -euo pipefail

# 根目录那个 build_arm64.sh 是软链，$0 指向软链本身 → dirname 是仓库根，
# 再 /.. 就跑到上一级了（曾报 tools/cross.sh 不存在）。先解软链再取仓库根。
SELF="$(readlink -f "$0")"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"

usage() {
    cat <<'EOF'
用法: tools/build_arm64.sh [选项]
只管「编 arm64 的二进制和 .so」，下面是全部选项，不给就只编不打包不部署。

  --arch arm64|armv7     目标架构（默认 arm64）
  --sysroot DIR          系统库根（默认 $LITE_SYSROOT 或 ~/arm64-sysroot）
  --fetch-sysroot HOST   先从目标机 rsync 一份 sysroot（约 2GB，断链软链会重指）
  --jobs N               并行度（默认 nproc）
  --clean                先删产物目录（cmake 缓存残留是「绿着错架构」的头号原因）
  --luajit               顺带交叉编 LuaJIT 到 build-arm64/luajit（慢，包要自带解释器才需要）
  --package              编完顺带打包成 dist/lite-linux-<arch>.tar.gz
  --deploy HOST          打包后 scp + 远端 tools/install.sh 覆盖安装（会动目标机）
  --lua-only             跳过编译与打包，只把本机 lua/ 和 helper/ 里的 *.lua 送到
                         --deploy 指定的机器（纯 Lua 改动这么走，省一次全量交叉编）
  -h, --help

产物：build-arm64/liblite_{cache,html,image,tui,capture}.so 等，出口逐个验 ELF
      e_machine（arm64=183 / armv7=40），不对就整条失败，不留「编成功了但跑不了」。

--lua-only 只搬 .lua，绝不搬 .so 和 .json：目标机上 helper/*.so 是那块板子自己用
gcc 编的 arm64 二进制，本机同名文件是 x86 的，整目录同步过去会覆盖成「加载成功、
一调用就 attempt to call field 'call' (a nil value)」。.json 是 native 给本地 .so
配的描述，同理不能过去。搬完逐个 md5 对账，再按需重启 serve（serve 不重启就看不到
新工具 schema —— 清单启动时扫一次并 memo）。
EOF
}

ARCH="arm64"
SYSROOT="${LITE_SYSROOT:-$HOME/arm64-sysroot}"
JOBS="$(nproc)"
CLEAN=0
WITH_LUAJIT=0
DO_PACKAGE=0
LUA_ONLY=0
FETCH_HOST=""
DEPLOY_HOST=""

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)         ARCH="${2:-}"; shift 2 ;;
        --sysroot)      SYSROOT="${2:-}"; shift 2 ;;
        --fetch-sysroot) FETCH_HOST="${2:-}"; shift 2 ;;
        --jobs)         JOBS="${2:-}"; shift 2 ;;
        --clean)        CLEAN=1; shift ;;
        --luajit)       WITH_LUAJIT=1; shift ;;
        --package)      DO_PACKAGE=1; shift ;;
        --deploy)       DEPLOY_HOST="${2:-}"; shift 2 ;;
        --lua-only)     LUA_ONLY=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "build_arm64: 未知参数 $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$ARCH" in
    arm64) DIST_ARCH=arm64; TRIPLE=aarch64-linux-gnu; WANT_MACHINE=183 ;;
    armv7) DIST_ARCH=armv7; TRIPLE=arm-linux-gnueabihf; WANT_MACHINE=40 ;;
    *) echo "build_arm64: 只支持 arm64 / armv7（当前 $ARCH）" >&2; exit 2 ;;
esac
BUILD_DIR="$ROOT/build-$ARCH"

# ---------------- --lua-only：只搬 *.lua ----------------
# 纯 Lua 改动不必重走工具链/sysroot/打包，所以这条分支必须放在下面那堆前置检查
# **之前**就返回：否则「只想送两个插件」还得先备齐 2GB sysroot。
if [ "$LUA_ONLY" = 1 ]; then
    [ -n "$DEPLOY_HOST" ] || {
        echo "build_arm64: --lua-only 要和 --deploy HOST 一起用（它不编译，只送文件）" >&2
        exit 2
    }
    echo "build_arm64: --lua-only → $DEPLOY_HOST（跳过工具链/sysroot/编译/打包）"
    ssh -o BatchMode=yes "$DEPLOY_HOST" true 2>/dev/null || {
        echo "build_arm64: [FAIL] ssh $DEPLOY_HOST 不通（免密/主机密钥先确认）" >&2
        exit 1
    }
    # 安装根从远端 ~/.local/bin/lite 软链反推，不写死 ~/.local/share/lite：
    # 换了 PREFIX 的机器上写死就会往一个空目录里放插件，而 --version 一路正常。
    RAPP="$(ssh -o BatchMode=yes "$DEPLOY_HOST" 'readlink -f "$HOME/.local/bin/lite" 2>/dev/null' || true)"
    case "$RAPP" in
        */tools/lite) RDIR="${RAPP%/tools/lite}" ;;
        *)  echo "build_arm64: [FAIL] 远端没有已装的 lite（$DEPLOY_HOST:~/.local/bin/lite → ${RAPP:-空}）" >&2
            echo "        先跑一次整包：./build_arm64.sh --deploy $DEPLOY_HOST" >&2
            exit 1 ;;
    esac
    echo "build_arm64: 远端安装根 $RDIR"

    # 只挑 *.lua。目标机的 helper/*.so 是那块板子自己 gcc 编的 arm64 二进制，本机
    # 同名文件是 x86 的，整目录同步 = 覆盖成「加载成功、一调用就 nil」；.json 是
    # native 给本地 .so 配的描述，同理不过去。app_*_map.lua 是 uimap 在哪台机器上
    # 学出来的坐标，属于那台机器，不跨机覆盖。
    listf="$(mktemp)"
    trap 'rm -f "$listf"' EXIT
    ( cd "$ROOT" && find lua helper -type f -name '*.lua' ! -name 'app_*_map.lua' | sort ) > "$listf"
    nfiles="$(wc -l < "$listf")"
    [ "$nfiles" -gt 0 ] || { echo "build_arm64: [FAIL] lua/ 和 helper/ 下一个 .lua 都没有" >&2; exit 1; }
    echo "build_arm64: $nfiles 个 .lua（.so/.json 留给目标机）"

    tar -cf - -C "$ROOT" -T "$listf" | ssh -o BatchMode=yes "$DEPLOY_HOST" "tar -xf - -C '$RDIR'"

    # md5 逐个对账：tar 成功只说明字节送到了，不代表落对了路径。
    lmd5="$( cd "$ROOT" && tr '\n' '\0' < "$listf" | xargs -0 md5sum | sort -k2 )"
    rmd5="$( ssh -o BatchMode=yes "$DEPLOY_HOST" "cd '$RDIR' && tr '\n' '\0' | xargs -0 md5sum" < "$listf" | sort -k2 )"
    if [ "$lmd5" = "$rmd5" ]; then
        echo "build_arm64: md5 $nfiles/$nfiles 一致"
    else
        echo "build_arm64: [FAIL] md5 对不上，差异（< 本机 / > 远端）：" >&2
        diff <(printf '%s\n' "$lmd5") <(printf '%s\n' "$rmd5") | head -20 >&2
        exit 1
    fi

    # serve 的工具清单是启动时扫一次并 memo 的：不重启，新插件进了盘也进不了模型。
    # 只在真闲着时重启 —— 派活途中重启会把那一轮打断。
    health="$(ssh -o BatchMode=yes "$DEPLOY_HOST" 'curl -sS -m 3 http://127.0.0.1:8765/health' 2>/dev/null || true)"
    if ! printf '%s' "$health" | grep -q '"live":true'; then
        echo "build_arm64: serve 没在跑（/health 无应答），新工具下次启动即生效"
    elif printf '%s' "$health" | grep -q '"busy":true'; then
        echo "build_arm64: serve 正忙，没重启；闲了自己刷新 schema："
        echo "        ssh $DEPLOY_HOST 'cd $RDIR && ./tools/serve_up.sh restart'"
    else
        echo "build_arm64: serve 空闲 → 重启刷新 schema"
        # 归 systemd 管的机器必须走 systemctl：`serve_up.sh restart` 会 setsid 一个
        # 不归 unit 的看护循环，systemd 随后按 Restart=always 又拉起自己的，两个 loop
        # 抢同一个 mem.lock，输的那个每 5s 往日志刷 "memory is locked by pid N"。
        if ssh -o BatchMode=yes "$DEPLOY_HOST" 'systemctl is-active --quiet lite-serve' 2>/dev/null; then
            ssh -o BatchMode=yes "$DEPLOY_HOST" 'systemctl restart lite-serve'
        else
            ssh -o BatchMode=yes "$DEPLOY_HOST" "cd '$RDIR' && ./tools/serve_up.sh restart" | tail -2
        fi
        echo -n "        /health: "
        ssh -o BatchMode=yes "$DEPLOY_HOST" 'curl -sS -m 5 http://127.0.0.1:8765/health' || echo "（无应答）"
        echo
    fi

    echo "build_arm64: 完成（lua-only）。没编任何 C，目标机 .so 原样保留。"
    exit 0
fi

# ---------------- 前置：工具链 ----------------
miss=0
for t in "${TRIPLE}-gcc" "${TRIPLE}-g++" "${TRIPLE}-strip" cmake pkg-config; do
    command -v "$t" >/dev/null 2>&1 || { echo "build_arm64: [FAIL] 缺 $t" >&2; miss=1; }
done
if [ "$miss" = 1 ]; then
    echo "        补齐：sudo apt install gcc-${TRIPLE} g++-${TRIPLE} cmake pkg-config" >&2
    exit 1
fi

# ---------------- 前置：sysroot ----------------
# 判据用 usr/lib/<triple> 目录存在，不用「目录能打开」：空壳目录更像半途而废的 rsync。
if [ ! -d "$SYSROOT/usr/lib/$TRIPLE" ] && [ -z "$FETCH_HOST" ]; then
    echo "build_arm64: [FAIL] sysroot 不可用：$SYSROOT（缺 usr/lib/$TRIPLE）" >&2
    echo "        造一份：./tools/build_arm64.sh --fetch-sysroot root@<盒子>" >&2
    exit 1
fi

if [ -n "$FETCH_HOST" ]; then
    command -v rsync >/dev/null 2>&1 || { echo "build_arm64: [FAIL] 缺 rsync" >&2; exit 1; }
    echo "build_arm64: 从 $FETCH_HOST 拉 sysroot → $SYSROOT（约 2GB，慢）"
    mkdir -p "$SYSROOT/usr" "$SYSROOT/opt"
    # 只拉运行/链接需要的东西：/usr 全量 + litehtml 源码树。不拉 /root /home，
    # 那是目标机的私有数据，进 sysroot 只会被误打进包里。
    rsync -a --delete "$FETCH_HOST:/usr/" "$SYSROOT/usr/"
    rsync -a "$FETCH_HOST:/opt/litehtml/" "$SYSROOT/opt/litehtml/" 2>/dev/null || \
        echo "build_arm64: [WARN] 目标机没有 /opt/litehtml，lite_html 会编不过" >&2
    # rsync 保不住绝对软链：目标机的 include -> /opt/litehtml/src/include 在 sysroot 里
    # 指向的是宿主路径（不存在的 x86 树），必须重指成相对路径，否则交叉编找不到 html.h。
    if [ -d "$SYSROOT/opt/litehtml/src/include" ]; then
        ln -sfn src/include "$SYSROOT/opt/litehtml/include"
    fi
    if [ ! -d "$SYSROOT/usr/lib/$TRIPLE" ]; then
        echo "build_arm64: [FAIL] 拉完仍缺 usr/lib/$TRIPLE，检查 $FETCH_HOST 是不是 $ARCH" >&2
        exit 1
    fi
fi

SYSROOT="$(cd "$SYSROOT" && pwd)"

# ---------------- 编（重活在 cross.sh） ----------------
cross_args=(--arch "$ARCH" --build-dir "$BUILD_DIR" --sysroot "$SYSROOT" --jobs "$JOBS")
[ "$CLEAN" = 1 ] && cross_args+=(--clean)
[ "$WITH_LUAJIT" = 1 ] && cross_args+=(--luajit)
"$ROOT/tools/cross.sh" "${cross_args[@]}"

# ---------------- 出口：清点产物 ----------------
echo "build_arm64: 产物清点（e_machine 必须 = $WANT_MACHINE）"
n_so=0
for so in "$BUILD_DIR"/liblite_*.so "$BUILD_DIR"/*/liblite_*.so; do
    [ -f "$so" ] || continue
    printf '  %-40s %8s  e_machine=%s\n' "${so#"$BUILD_DIR"/}" \
        "$(du -h "$so" | cut -f1)" \
        "$(od -An -tu1 -j18 -N2 "$so" | awk '{print $1}')"
    n_so=$((n_so + 1))
done
[ "$n_so" -gt 0 ] || { echo "build_arm64: [FAIL] 没有产物" >&2; exit 1; }
echo "build_arm64: $n_so 个 .so → $BUILD_DIR"
if [ "$WITH_LUAJIT" = 1 ] && [ -x "$BUILD_DIR/luajit/src/luajit" ]; then
    echo "build_arm64: luajit → $BUILD_DIR/luajit/src/luajit"
fi

# ---------------- 可选尾巴：打包 / 部署 ----------------
PKG="$ROOT/dist/lite-linux-$DIST_ARCH.tar.gz"
if [ "$DO_PACKAGE" = 1 ] || [ -n "$DEPLOY_HOST" ]; then
    echo "build_arm64: 打包（BUILD_DIR=$BUILD_DIR DIST_ARCH=$DIST_ARCH）"
    # LITE_LUAJIT_DIR 只在 --luajit 时指向交叉编的那棵树（里面 src/luajit 才是 arm64）；
    # 不给就沿用仓库默认，package.sh 会自己发现宿主 x86 二进制并剔掉。
    if [ "$WITH_LUAJIT" = 1 ]; then
        LITE_BUILD_DIR="$BUILD_DIR" LITE_DIST_ARCH="$DIST_ARCH" \
        LITE_SYSROOT="$SYSROOT" LITE_LUAJIT_DIR="$BUILD_DIR/luajit" \
            "$ROOT/tools/package.sh"
    else
        LITE_BUILD_DIR="$BUILD_DIR" LITE_DIST_ARCH="$DIST_ARCH" \
        LITE_SYSROOT="$SYSROOT" "$ROOT/tools/package.sh"
    fi
    echo "build_arm64: 包 → $PKG（$(du -h "$PKG" | cut -f1)）"
fi

if [ -n "$DEPLOY_HOST" ]; then
    echo "build_arm64: 部署到 $DEPLOY_HOST（覆盖安装，会重启才生效）"
    scp -q "$PKG" "$DEPLOY_HOST:/root/" 
    ssh "$DEPLOY_HOST" "set -e; cd /root
        rm -rf lite-linux-$DIST_ARCH
        tar xzf lite-linux-$DIST_ARCH.tar.gz
        ./lite-linux-$DIST_ARCH/tools/install.sh | tail -3
        ~/.local/bin/lite --version"
fi

echo "build_arm64: 完成。"
echo "  .so       $BUILD_DIR"
echo "  sysroot   $SYSROOT"
if [ -f "$PKG" ]; then echo "  包        $PKG（$(du -h "$PKG" | cut -f1)）"; fi
exit 0
