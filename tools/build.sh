#!/usr/bin/env bash
# lite 构建：LuaJIT（缺失或架构不符时）+ 原生 KV cache。
#
# 迁移到别的平台（x86_64 ↔ aarch64）后「跑 lite 之前」的拦截点就是这个脚本：
# 文件在、可执行位在，都不等于「是给这台机器编的」。见下方「架构对账」。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"

# macOS 没有 nproc（那是 coreutils）：取不到就退化，别让 `-j""` 把构建打空。
JOBS="${LITE_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"

# ---------------- 架构对账 ----------------
# 判据是 ELF 头 e_machine（偏移 18，小端 2 字节），不依赖 readelf/file/objdump：
#   3=i386  40=arm  62=x86-64  183=aarch64
# 为什么不用 `file`：最小安装的目标机常常没有它；od 是 coreutils，必然有。
elf_machine() {
    local f="$1" magic lo hi
    [ -f "$f" ] || return 1
    # 先认 magic：不校验的话，随便一个非 ELF 文件（脚本、空文件、被截断的 .so）
    # 也会「读出」一个 e_machine，把正常树误判成混架构而清空 build/。
    read -r magic < <(od -An -j0 -N4 -tx1 -v "$f" 2>/dev/null | tr -d ' ') || return 1
    [ "${magic:-}" = "7f454c46" ] || return 1
    read -r lo hi < <(od -An -j18 -N2 -tu1 -v "$f" 2>/dev/null) || return 1
    [ -n "${hi:-}" ] || return 1
    echo $(( lo + hi * 256 ))
}

host_machine() {
    case "$(uname -m)" in
        x86_64|amd64)  echo 62 ;;
        aarch64|arm64) echo 183 ;;
        armv7l|armv6l) echo 40 ;;
        i386|i686)     echo 3 ;;
        *)             echo 0 ;;
    esac
}

machine_name() {
    case "$1" in
        62)  echo x86-64 ;;
        183) echo aarch64 ;;
        40)  echo arm ;;
        3)   echo i386 ;;
        *)   echo "unknown($1)" ;;
    esac
}

HOST_ARCH="$(host_machine)"
LUAJIT_DIR="$ROOT/third_party/luajit"
LUAJIT_BIN="$LUAJIT_DIR/src/luajit"

# macOS 的可执行文件是 Mach-O，不是 ELF：elf_machine 在上面一律返回 1（「读不出架构」），
# 于是下面那段「架构不符就重编」永远不触发 —— 从 Linux 树拷来的 luajit 会被当成好的，
# 一跑就是 exec format error。所以 Darwin 单独判：magic 不是 Mach-O（0xfeedfacf 小端 /
# 0xcffaedfe 大端读取）就算 stale。
is_macho() {
    local magic
    [ -f "$1" ] || return 1
    read -r magic < <(od -An -j0 -N4 -tx1 -v "$1" 2>/dev/null | tr -d ' ') || return 1
    [ "${magic:-}" = "cffaedfe" ] || [ "${magic:-}" = "feedfacf" ]
}

# ---------------- LuaJIT ----------------
# 必须在 check_deps 之前：check_deps 自己要用 lite-lua 跑 lua（tools/check_deps.sh:21），
# 而 lite-lua 只用 bundled 这份（tools/lite-lua:9）。旧顺序在「新平台且没装系统 luajit」
# 时会先炸在 check_deps 上（[FAIL] luajit missing → exit 1），报错离根因很远。
luajit_stale=0
if [ ! -x "$LUAJIT_BIN" ]; then
    luajit_stale=1
    echo "lite: building bundled LuaJIT..."
elif [ "$(uname -s)" = Darwin ]; then
    if ! is_macho "$LUAJIT_BIN"; then
        luajit_stale=1
        echo "lite: bundled LuaJIT 不是 Mach-O（多半是 Linux 树带来的）→ 重编"
    fi
else
    bin_arch="$(elf_machine "$LUAJIT_BIN" || true)"
    if [ -n "${bin_arch:-}" ] && [ "$bin_arch" != "$HOST_ARCH" ]; then
        luajit_stale=1
        echo "lite: bundled LuaJIT 是 $(machine_name "$bin_arch") 的，本机 $(machine_name "$HOST_ARCH") → 重编"
    fi
fi

if [ "$luajit_stale" = 1 ]; then
    # 必须先 clean：.o 还在的话 make 认为目标已最新、只重新链接，产物仍是旧架构。
    # （踩过的形态：拷贝整棵树后 make 秒过，然后 exec format error。）
    make -C "$LUAJIT_DIR" clean >/dev/null 2>&1 || true
    make -C "$LUAJIT_DIR" -j"$JOBS"
fi

"$ROOT/tools/check_deps.sh"

# ---------------- 原生库 ----------------
# build/CMakeCache.txt 记的是旧平台的编译器路径，liblite_*.so 也是旧架构。cmake 对
# 「目标比源码新」会直接跳过链接，于是配置成功、产物却是 x86 的，运行期才在
# lua/ffi/libfind.lua 命中坏 .so 处炸。这里先证伪再清。
if [ -f "$ROOT/build/CMakeCache.txt" ]; then
    stale_so=""
    for so in "$ROOT"/build/liblite_*.so; do
        [ -f "$so" ] || continue
        so_arch="$(elf_machine "$so" || true)"
        if [ -n "${so_arch:-}" ] && [ "$so_arch" != "$HOST_ARCH" ]; then
            stale_so="$so"; break
        fi
    done
    if [ -n "$stale_so" ]; then
        echo "lite: build/ 里是 $(machine_name "$(elf_machine "$stale_so")") 产物（$(basename "$stale_so")），"
        echo "      与本机 $(machine_name "$HOST_ARCH") 不符 → 清空 build/ 重新配置"
        rm -rf "$ROOT/build"
        mkdir -p "$ROOT/build"
    fi
fi

if [ -f "$ROOT/CMakeLists.txt" ] && [ -d "$ROOT/src" ]; then
    cmake -S "$ROOT" -B "$ROOT/build" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$ROOT/build" -j"$JOBS"
    echo "lite: native build complete"
else
    echo "lite: Lua-only build (no src/CMakeLists.txt yet)"
fi
