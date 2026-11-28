#!/usr/bin/env bash
# lite 本机交叉编译（x86_64 宿主 → aarch64 目标）。
#
# 为什么存在：盒子（x96 / Armbian trixie）与开发机是两套机器，但源码只有一份。
# 在盒子上原生编一次要 rsync 整棵树 + 装一堆 dev 包；本机交叉编只需要一份
# sysroot，改完立刻出 arm64 产物，盒子只负责跑。
#
# 与 build.sh 的分工（别混）：
#   build.sh  ← 给「当前机器」编，产物进 build/，本机 lite 直接用
#   cross.sh  ← 给「目标机器」编，产物进 build-arm64/（可用 --build-dir 改），
#               本机的 build/ 一个字节都不碰。打完包用 package.sh --build-dir 指向它。
#
# sysroot 不是仓库内容（几百 MB，且有目标机的系统库），放仓库外：
#   LITE_SYSROOT=~/arm64-sysroot（默认），造法见 README「交叉编译」。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tools/_arch.sh"
# _arch.sh 的 LITE_DIST_ARCH 跟着宿主 uname 走（uname → amp），交叉时得反着来。

usage() {
    cat <<'EOF'
用法: tools/cross.sh [选项]
  --arch arm64|armv7     目标架构（默认 arm64）
  --build-dir DIR        产物目录（默认 build-arm64/，可与 build.sh 并存）
  --sysroot DIR          arm64 系统库根（默认 $LITE_SYSROOT 或 ~/arm64-sysroot）
  --jobs N               并行度（默认 nproc）
  --clean                先删产物目录（cmake 缓存里的旧编译器会让产物「绿着错架构」）
  --luajit               顺带把 bundled LuaJIT 交叉编到 build-arm64/luajit（可选，慢）
  -h, --help
产物校验：出 .so 后逐个读 ELF e_machine，不是 183 就当场失败（不等目标机 exec format error）。
EOF
}

ARCH="arm64"
BUILD_DIR=""
SYSROOT="${LITE_SYSROOT:-$HOME/arm64-sysroot}"
JOBS="$(nproc)"
CLEAN=0
WITH_LUAJIT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)      ARCH="${2:-}"; shift 2 ;;
        --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
        --sysroot)   SYSROOT="${2:-}"; shift 2 ;;
        --jobs)      JOBS="${2:-}"; shift 2 ;;
        --clean)     CLEAN=1; shift ;;
        --luajit)    WITH_LUAJIT=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "cross: 未知参数 $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$ARCH" in
    arm64)   WANT_MACHINE=183; TOOLCHAIN="aarch64-linux-gnu"; DIST_ARCH=arm64; TCF="cmake-aarch64.cmake" ;;
    armv7)   WANT_MACHINE=40;  TOOLCHAIN="arm-linux-gnueabihf"; DIST_ARCH="armv7"; TCF="cmake-armv7.cmake" ;;
    *) echo "cross: 只支持 arm64 / armv7（当前 $ARCH）" >&2; exit 2 ;;
esac

[ -n "$BUILD_DIR" ] || BUILD_DIR="$ROOT/build-$ARCH"

miss=0
for t in "${TOOLCHAIN}-gcc" "${TOOLCHAIN}-g++" "${TOOLCHAIN}-strip" cmake pkg-config; do
    command -v "$t" >/dev/null 2>&1 || { echo "cross: [FAIL] 缺 $t" >&2; miss=1; }
done
[ "$miss" = 0 ] || { echo "cross: Ubuntu 上一条命令补齐：sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu cmake pkg-config" >&2; exit 1; }

if [ ! -d "$SYSROOT/usr/lib/aarch64-linux-gnu" ]; then
    echo "cross: [FAIL] sysroot 不可用：$SYSROOT（缺 usr/lib/aarch64-linux-gnu）" >&2
    echo "        造法见 README「交叉编译」，或用 --sysroot 指到已有的一份。" >&2
    exit 1
fi
SYSROOT="$(cd "$SYSROOT" && pwd)"
export LITE_SYSROOT="$SYSROOT"

echo "cross: 目标 $ARCH ($TOOLCHAIN)  sysroot=$SYSROOT"
echo "cross: 产物 $BUILD_DIR"

if [ "$CLEAN" = 1 ]; then
    echo "cross: --clean → 删 $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

# cmake 只认 sysroot 里的 litehtml 副本：--sysroot 不改写写死的绝对路径，
# 留着 /opt/litehtml 的话本机能编、但那是宿主自带的 x86 库。
LITEHTML_ROOT="$SYSROOT/opt/litehtml"
if [ ! -f "$LITEHTML_ROOT/build-pic/liblitehtml.so" ]; then
    echo "cross: [WARN] sysroot 里没有 litehtml（$LITEHTML_ROOT/build-pic），lite_html 会编不过" >&2
    echo "        目标机编过 lite 就有：rsync -a root@<box>:/opt/litehtml/ $SYSROOT/opt/litehtml/" >&2
fi

# pkg-config 指到 sysroot：.pc 里写的是 prefix=/usr，PKG_CONFIG_SYSROOT_DIR 负责改写到 sysroot。
# 不设它，pkg_check_modules(PNG) 会返回宿主的 /usr/include/libpng16 → 编出来是 x86 头 + x86 库。
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/aarch64-linux-gnu/pkgconfig:$SYSROOT/usr/share/pkgconfig"

cmake -S "$ROOT" -B "$BUILD_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE="$ROOT/tools/$TCF" \
      -DLITEHTML_ROOT="$LITEHTML_ROOT"
cmake --build "$BUILD_DIR" -j"$JOBS"

# ---------------- 产物架构对账 ----------------
# 交叉编译最贵的错是「编出来了、跑不了」：cmake 缓存里残留宿主编译器、或某个 .so
# 落回 x86 目录，都会让它安静地成功。出口处逐个读 e_machine，不看扩展名不看大小。
elf_machine() {
    local f="$1" magic lo hi
    [ -f "$f" ] || return 1
    read -r magic < <(od -An -j0 -N4 -tx1 -v "$f" 2>/dev/null | tr -d ' ') || return 1
    [ "${magic:-}" = "7f454c46" ] || return 1
    read -r lo hi < <(od -An -j18 -N2 -tu1 -v "$f" 2>/dev/null) || return 1
    [ -n "${hi:-}" ] || return 1
    echo $(( lo + hi * 256 ))
}

bad=0; n=0
for so in "$BUILD_DIR"/liblite_*.so; do
    [ -f "$so" ] || continue
    n=$((n + 1))
    m="$(elf_machine "$so" || true)"
    if [ "$m" = "$WANT_MACHINE" ]; then
        printf 'cross:   ok   %-22s e_machine=%s\n' "$(basename "$so")" "$m"
    else
        printf 'cross:   BAD  %-22s e_machine=%s（要 %s）\n' "$(basename "$so")" "${m:-?}" "$WANT_MACHINE"
        bad=$((bad + 1))
    fi
done
if [ "$n" = 0 ]; then
    echo "cross: [FAIL] $BUILD_DIR 里没有任何 liblite_*.so" >&2
    exit 1
fi
[ "$bad" = 0 ] || { echo "cross: [FAIL] $bad 个产物架构不对（多半是 cmake 缓存残留，重跑加 --clean）" >&2; exit 1; }

# ---------------- 可选：交叉编 LuaJIT ----------------
# 随包要自带解释器就得编；编出来放 build-arm64/luajit，由 package.sh --luajit 收进去。
# 不编也能用：目标机装系统 luajit，tools/lite-lua 会自动退到 PATH 上的那份。
if [ "$WITH_LUAJIT" = 1 ]; then
    LJ_SRC="$ROOT/third_party/luajit"
    LJ_OUT="$BUILD_DIR/luajit"
    if [ ! -f "$LJ_SRC/Makefile" ]; then
        echo "cross: [WARN] 没有 $LJ_SRC，跳过 LuaJIT" >&2
    else
        echo "cross: 交叉编 LuaJIT → $LJ_OUT"
        rm -rf "$LJ_OUT"
        cp -a "$LJ_SRC" "$LJ_OUT"
        make -C "$LJ_OUT" clean >/dev/null 2>&1 || true
        # CROSS 是 LuaJIT Makefile 认的工具前缀；TARGET_SYS 决定 jit 目标，
        # HOST_CC 编 buildvm 这种要在宿主上跑的工具，两者不能混（混了 buildvm 就跑不动）。
        make -C "$LJ_OUT" -j"$JOBS" \
             HOST_CC="gcc" CC="${TOOLCHAIN}-gcc" CROSS="${TOOLCHAIN}-" \
             TARGET_SYS=Linux TARGET_FLAGS="-DLUAJIT_TARGET=LUAJIT_ARCH_${ARCH}"
        m="$(elf_machine "$LJ_OUT/src/luajit" || true)"
        if [ "$m" = "$WANT_MACHINE" ]; then
            echo "cross:   ok   luajit e_machine=$m"
        else
            echo "cross: [FAIL] luajit e_machine=${m:-?}（要 $WANT_MACHINE）" >&2
            exit 1
        fi
    fi
fi

cat <<EOF
cross: 完成。下一步打包（产物目录与架构都要显式给，否则包里混 x86）：
  LITE_BUILD_DIR=$BUILD_DIR LITE_DIST_ARCH=$DIST_ARCH ./tools/package.sh
EOF
