#!/usr/bin/env bash
# 生成 dist/lite-linux-<arch>.tar.gz（LuaJIT + cjson + lua + tools）。
# 架构后缀见 tools/_arch.sh：x86_64 -> x64，aarch64 -> arm64，可用 LITE_DIST_ARCH 覆盖。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tools/_arch.sh"
DIST="$ROOT/dist/$LITE_DIST_NAME"

# ---------------- 产物目录与「包给谁」 ----------------
# BUILD_DIR 可覆盖：交叉编译（tools/cross.sh）把产物写进 build-arm64/，本机 build/
# 留给宿主自己的 lite —— 两份并存，互不覆盖。
BUILD_DIR="${LITE_BUILD_DIR:-$ROOT/build}"

_elf_machine() { od -An -tu1 -j18 -N2 "$1" 2>/dev/null | awk '{print $1}'; }
_target_machine() {
    case "$LITE_DIST_ARCH" in
        arm64) echo 183 ;;
        armv7|armv6) echo 40 ;;
        x86) echo 3 ;;
        *) echo 62 ;;
    esac
}
case "$(uname -m)" in
    x86_64|amd64)  HOST_MACHINE=62 ;;
    aarch64|arm64) HOST_MACHINE=183 ;;
    armv7l|armv6l) HOST_MACHINE=40 ;;
    i386|i686)     HOST_MACHINE=3 ;;
    *)             HOST_MACHINE=0 ;;
esac
WANT_MACHINE="$(_target_machine)"
CROSS_PKG=0
[ "$WANT_MACHINE" = "$HOST_MACHINE" ] || CROSS_PKG=1

# 一个 .so 的直接依赖 → "<soname>\t<实路径>"（解析不出时路径为空）。
# 同架构照旧用 ldd：它真的把库 load 起来，最准。
# 跨架构不能用 ldd —— ldd 是个「跑起来看」的脚本，foreign .so 它会直接说
# not a dynamic executable，依赖于是空着，随包的 liblitehtml/libgumbo 全漏，
# 到目标机上才炸 html→png。交叉时静态读 DT_NEEDED，再在 sysroot 里按名解析。
_sysroot_find() {
    local name="$1" d
    [ -n "${LITE_SYSROOT:-}" ] || return 0
    for d in "$LITE_SYSROOT/usr/lib/aarch64-linux-gnu" "$LITE_SYSROOT/lib/aarch64-linux-gnu" \
             "$LITE_SYSROOT/opt/litehtml/build-pic/src/gumbo" "$LITE_SYSROOT/opt/litehtml/build-pic" \
             "$LITE_SYSROOT/usr/lib"; do
        [ -e "$d/$name" ] && { realpath "$d/$name"; return 0; }
    done
    return 0
}
_needed_of() {
    local so="$1"
    if [ "$CROSS_PKG" = 0 ]; then
        ldd "$so" 2>/dev/null | awk '$2=="=>" {print $1"\t"$3}'
        return 0
    fi
    # readelf 输出跟着 locale 变（中文 "共享库：[libc.so.6]"），所以别按字段号取，
    # 直接抓行内第一对方括号 —— 早先 `$5` 在 zh_CN 下取到的是 "共享库：[…]" 整段，
    # 一头都没匹配上，随包的 liblitehtml/libgumbo 就这么静默漏掉了。
    LC_ALL=C readelf -d "$so" 2>/dev/null \
        | awk '/NEEDED/ { if (match($0, /\[[^]]*\]/)) print substr($0, RSTART+1, RLENGTH-2) }' \
        | while read -r n; do printf '%s\t%s\n' "$n" "$(_sysroot_find "$n")"; done
}


rm -rf "$DIST"
mkdir -p "$DIST/lua" "$DIST/tools" "$DIST/third_party" "$DIST/build" "$DIST/lib" "$DIST/helper" "$DIST/models"

cp -r "$ROOT/lua/." "$DIST/lua/"
if [ -d "$ROOT/helper" ]; then
    # 必须递归：helper/lib/*.lua 是插件共用的库（webdav/music/uimap/usb/adb/md4c…），
    # helper/assets/ 是字体与 CSS（md2png/trending 出图用）。早期这里只拷
    # `-maxdepth 1 -type f`，安装版于是缺整个 lib/ 与 assets/，插件在目标机上
    # 一 require 就炸（music 报 "cannot load webdav lib …"）。整目录 `cp -r` 一次到位。
    find "$ROOT/helper" -mindepth 1 -maxdepth 1 ! -name '.gitkeep' \
        -exec cp -r {} "$DIST/helper/" \;
fi

# helper/*.so 是 native 工具编出来的，每次 build 都留一份 <name>-<ts>[-<n>].so，
# 只有 <name>.json 清单里点名的那份是活的（_helper_so_abs 就按它找，见
# lua/core/tools.lua）。上面是无脑 `cp -r`，历次构建的旧副本会一起进包 ——
# 白涨体积，也让「装的到底是哪一版」没法一眼看出来。这里按清单剪一遍。
prune_stale_helper_so() {
    local dir="$1" f base stem name dropped=0 kept=0
    [ -d "$dir" ] || return 0
    for f in "$dir"/*.so; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        stem="${base%.so}"
        case "$stem" in
            *-[0-9]*) ;;                    # 只认带时间戳的历史副本
            *) continue ;;                  # 裸 <name>.so 是清单缺失时的兜底候选，留着
        esac
        name="${stem%%-[0-9]*}"
        if [ -f "$dir/$name.json" ] && grep -qF "\"$base\"" "$dir/$name.json"; then
            kept=$((kept + 1))
        else
            rm -f "$f"
            dropped=$((dropped + 1))
        fi
    done
    if [ "$dropped" -gt 0 ]; then
        echo "package: helper/ 剪掉 $dropped 个清单未点名的旧 .so（保留 $kept 个）"
    fi
}
prune_stale_helper_so "$DIST/helper"

# 交叉打包：helper/*.so 是 native 在**宿主**上编的，e_machine 与目标不符。
# 打进包里目标机 ffi.load 会失败（plugins 报 load error），而 Lua 插件本身
# 必须留着（真跨平台），所以只剪 .so 和它的 .json 清单，别的不动。
prune_foreign_helper_so() {
    local dir="$1" f base m n=0
    [ -d "$dir" ] || return 0
    for f in "$dir"/*.so; do
        [ -e "$f" ] || continue
        m="$(_elf_machine "$f" || true)"
        [ "$m" = "$WANT_MACHINE" ] && continue
        base="$(basename "$f")"
        rm -f "$f"
        n=$((n + 1))
        # 清单点名这份 .so 的插件一并退化成「只有 lua 逻辑」，别留悬空引用
        rm -f "$dir/$(basename "${base%.so}" | sed 's/-[0-9].*$//').json"
    done
    [ "$n" -gt 0 ] && echo "package: ${dir#$DIST/}/ 剪掉 $n 个非目标架构 .so（e_machine≠$WANT_MACHINE）"
    return 0
}
[ "$CROSS_PKG" = 1 ] && prune_foreign_helper_so "$DIST/helper"
cp "$ROOT/AGENTS.md" "$ROOT/design.md" "$ROOT/trace.md" "$DIST/"
if [ -f "$BUILD_DIR/liblite_cache.so" ]; then
    cp "$BUILD_DIR/liblite_cache.so" "$DIST/build/"
fi
if [ -f "$BUILD_DIR/liblite_codesearch.so" ]; then
    cp "$BUILD_DIR/liblite_codesearch.so" "$DIST/build/"
fi

if [ -f "$BUILD_DIR/liblite_capture.so" ]; then
    cp "$BUILD_DIR/liblite_capture.so" "$DIST/lib/"
fi
if [ -f "$BUILD_DIR/liblite_tui.so" ]; then
    cp "$BUILD_DIR/liblite_tui.so" "$DIST/lib/"
fi

# 随包的 ocr 库：只收「仓库内实体文件」。
# 任何指向仓库外的软链（典型：CUDA provider 329MB 接的是系统
# onnxruntime-gpu）都不打包 —— 下面的 `tar -h` 会解引用软链，把系统库
# 实体塞进 tarball。目标机需要 GPU 时用 tools/cuda_provider.sh link 自己接。
#
# 判断依据是 realpath 是否在 $ROOT 内，而不是文件名：这样以后接任何大块
# 系统库（TRT provider、cudnn…）都自动不会进包，不用逐条加黑名单。
EXTERNAL_LIBS=()
if [ -d "$ROOT/third_party/ocr/lib" ]; then
    for src in "$ROOT/third_party/ocr/lib/"*.so*; do
        [ -e "$src" ] || continue
        bn="$(basename "$src")"
        case "$bn" in
            *providers_cuda*) continue ;;   # 双保险：即便有人放成实体文件也不收
            # onnxruntime 核心库 25MB，占整个包一半。目标机一般已装
            # （onnxruntime-gpu 的 pip 包 / 系统包），用 tools/ort_link.sh 接。
            # 确实要随包分发时设 LITE_DIST_WITH_ORT=1。
            libonnxruntime.so.1)
                [ "${LITE_DIST_WITH_ORT:-0}" = "1" ] || { SKIP_ORT=1; continue; }
                ;;
        esac
        real="$(readlink -f "$src" 2>/dev/null || echo "$src")"
        case "$real" in
            "$ROOT"/*) ;;
            *)
                EXTERNAL_LIBS+=("$bn -> $real")
                continue
                ;;
        esac
        # 直接拷实体（libocr_simple 76KB）。不能用相对软链：
        # "../../../third_party/ocr/lib/xxx" 从 dist/lite-linux-<arch>/lib 往上
        # 三级正好回到源码树根，链会解析到 $ROOT 而不是 dist 内部 ——
        # 单拷 dist 出去就断链，install.sh 的 `cp -rL` 也依赖源树在。
        cp -f "$real" "$DIST/lib/$bn"
    done
fi
# 记下目标机需要哪个 ORT 版本，供 tools/ort_link.sh 精确匹配
ORT_VER=""
if [ -f "$ROOT/third_party/ocr/lib/libonnxruntime.so.1" ]; then
    ORT_VER="$(strings "$ROOT/third_party/ocr/lib/libonnxruntime.so.1" 2>/dev/null \
        | grep -oE '^1\.[0-9]+\.[0-9]+$' | sort -u | tail -1)"
fi
if [ -n "$ORT_VER" ]; then
    printf '%s\n' "$ORT_VER" >"$DIST/lib/ORT_VERSION"
fi
if [ "${SKIP_ORT:-0}" = "1" ]; then
    echo "package: 跳过 libonnxruntime.so.1（25MB，宿主机提供）"
    echo "         目标机执行 ./tools/ort_link.sh link 接入系统 onnxruntime"
    echo "         要随包分发则 LITE_DIST_WITH_ORT=1 ./tools/package.sh"
fi
if [ "${#EXTERNAL_LIBS[@]}" -gt 0 ]; then
    echo "package: 跳过仓库外的系统库（用 tools/cuda_provider.sh 在目标机按需接入）:"
    for i in "${EXTERNAL_LIBS[@]}"; do echo "  - $i"; done
fi
# lib/ 里的 libocr_simple.so / libonnxruntime_providers_shared.so 是 OCR 侧随仓库
# 存的宿主二进制，交叉包里它们加载必炸（ffi.load: invalid ELF header）。OCR 本就是
# 可选能力（默认连 ORT 都不带），非目标架构的直接剪掉。
[ "$CROSS_PKG" = 1 ] && prune_foreign_helper_so "$DIST/lib"
# OCR 模型 14.8MB（det 4.5 + rec 10.3），占解包体积六成。OCR 是可选能力，
# 默认不随包：目标机需要时把模型目录拷过去，或设 LITE_OCR_MODELS 指向既有副本。
# 要随包分发：LITE_DIST_WITH_OCR=1 ./tools/package.sh
if [ -d "$ROOT/third_party/ocr/models/ocr" ]; then
    if [ "${LITE_DIST_WITH_OCR:-0}" = "1" ]; then
        ln -sfn "../../../third_party/ocr/models/ocr" "$DIST/models/ocr"
    else
        rmdir "$DIST/models" 2>/dev/null || true
        echo "package: 跳过 OCR 模型（14.8MB，可选能力）"
        echo "         需要时: cp -r third_party/ocr/models/ocr \$DEST/models/"
        echo "                 或 LITE_OCR_MODELS=/path/to/models/ocr"
        echo "         随包分发: LITE_DIST_WITH_OCR=1 ./tools/package.sh"
    fi
fi

if [ -f "$BUILD_DIR/liblite_image.so" ]; then
    cp "$BUILD_DIR/liblite_image.so" "$DIST/lib/"
    while IFS=$'\t' read -r so path _; do
        [ -n "${so:-}" ] || continue
        case "$so" in
            libc.so.*|libm.so.*|libgcc_s.so.*|libpthread.so.*|libdl.so.*|librt.so.*|ld-linux*) continue ;;
        esac
        if [ -n "${path:-}" ] && [ -f "$path" ]; then
            cp -L "$path" "$DIST/lib/$so"
        fi
    done < <(_needed_of "$BUILD_DIR/liblite_image.so")
fi

# HTML→PNG 渲染后端：liblite_html.so + 它的私有依赖。
#
# 目标机没有 /opt/litehtml，而安装版的候选路径恰好是 $LITE_ROOT/build/liblite_html.so
# （helper/md2png.lua、web2png.lua、trending 都靠它），早先这里只打 cache/codesearch，
# 安装版一调 md2png 就报「缺 build/liblite_html.so，先跑 ./tools/build.sh」。
#
# 收谁：[ldd] 里真实解析路径落在 $LITEHTML_PREFIX（默认 /opt/litehtml）下的库 ——
# 那正是目标机不会自带的私有依赖（liblitehtml.so.0、libgumbo.so.0）。
# cairo/fontconfig/X11/freetype 这些一律跳过：它们必须用**目标机自己那份**
# （fontconfig 依赖 /etc/fonts 与系统字体目录，硬塞一份 2MB 的进包只会更难排查）。
#
# 三个 .so 摆同一目录自解析：liblite_html.so 已把 libgumbo 升成直接 NEEDED 且
# RUNPATH 是 $ORIGIN（见 CMakeLists.txt 的 lite_html 段），liblitehtml 的
# 绝对 RUNPATH 找不到 gumbo 时由本目录的 $ORIGIN 兜住。
LITEHTML_PREFIX="${LITEHTML_PREFIX:-${LITE_SYSROOT:+$LITE_SYSROOT}/opt/litehtml}"
LITEHTML_PREFIX="${LITEHTML_PREFIX:-/opt/litehtml}"
if [ -f "$BUILD_DIR/liblite_html.so" ]; then
    cp "$BUILD_DIR/liblite_html.so" "$DIST/build/"
    bundled=()
    while IFS=$'\t' read -r so path _; do
        [ -n "${so:-}" ] || continue
        [ -n "${path:-}" ] && [ -f "$path" ] || continue
        real="$(realpath "$path" 2>/dev/null || echo "$path")"
        case "$real" in
            "$LITEHTML_PREFIX"/*) ;;   # 私有依赖，随包
            *) continue ;;             # 系统库，用目标机自己的
        esac
        cp -L "$path" "$DIST/build/$so"
        bundled+=("$so")
    done < <(_needed_of "$BUILD_DIR/liblite_html.so")
    if [ ${#bundled[@]} -gt 0 ]; then
        echo "package: lite_html 随包私有依赖: ${bundled[*]}"
    else
        echo "package: [WARN] liblite_html.so 未解析出 $LITEHTML_PREFIX 下的依赖，" >&2
        echo "         目标机若缺 liblitehtml/libgumbo，html→png 起不来" >&2
    fi
fi

# _arch.sh 必须进包：install.sh / release.sh / package.sh 第一行就 source 它，
# 漏了它目标机解包后连装都装不上（报 tools/_arch.sh: No such file）。
for f in lite-lua lua.sh lite run.sh check_deps.sh build.sh test.sh install.sh package.sh release.sh launch.sh \
         ort_link.sh cuda_provider.sh see.lua cluster.sh _arch.sh serve_up.sh setup_service.sh serve_service.sh; do
    [ -f "$ROOT/tools/$f" ] && cp "$ROOT/tools/$f" "$DIST/tools/"
done
cp "$ROOT/tools/auto_unit.lua" "$DIST/tools/"

mkdir -p "$DIST/third_party/cjson/lua/5.1"
# 随包 LuaJIT：解释器是**二进制**，只在与目标同架构时才敢带上。
# 交叉打包时仓库里那份是宿主的 x86 ELF，打进 arm64 包后目标机 tools/lite-lua
# 会 exec 它 → exec format error，连 `lite --version` 都起不来。
# 处理：整棵树照拷（src/jit/*.lua 是可移植的，LUA_PATH 要用），只删掉那个二进制，
# 让 lite-lua 退到目标机的系统 luajit（tools/lite-lua:11 的兜底）。
LUAJIT_SRC="${LITE_LUAJIT_DIR:-$ROOT/third_party/luajit}"
if [ -d "$LUAJIT_SRC" ]; then
    cp -r "$LUAJIT_SRC" "$DIST/third_party/"
    _lj_bin="$DIST/third_party/$(basename "$LUAJIT_SRC")/src/luajit"
    _lj_m="$(_elf_machine "$_lj_bin" || true)"
    if [ -n "${_lj_m:-}" ] && [ "$_lj_m" != "$WANT_MACHINE" ]; then
        rm -f "$_lj_bin"
        echo "package: bundled LuaJIT 是 e_machine=$_lj_m、目标是 $WANT_MACHINE → 不进包"
        echo "         目标机需自带解释器（apt install luajit），或 tools/cross.sh --luajit 交叉编一份"
    fi
fi
# 同上：宿主编过的 luajit 树留满 src/*.o、src/host/、src/*.a。交叉包里这些既跑不了
# 也编不出（host/ 是宿主编出来的 buildvm 中间件），纯涨体积，只留 src/jit/*.lua 与头。
if [ "$CROSS_PKG" = 1 ]; then
    _ljd="$DIST/third_party/$(basename "$LUAJIT_SRC")"
    if [ -d "$_ljd/src" ]; then
        rm -rf "$_ljd/src/host"
        find "$_ljd/src" -maxdepth 1 -type f \( -name '*.o' -o -name '*.a' -o -name '*.so' \) -delete
    fi
fi

# cjson.so 必须与目标架构一致，否则目标机 require "cjson" 直接 C 层报错、
# 整个 lite 起不来（现象是 `lite --version` 都跑不了，只剩 stack traceback）。
# 仓库里的 cjson.so 是**人肉拷进去的二进制**（无源码），rsync 一次源码树就可能把
# x86 副本带到 arm 宿主、再打进 arm64 包 —— 实测踩过。所以按 ELF e_machine 校验，
# 不一致就退回系统装的同架构 lua-cjson（apt lua-cjson），sysroot 里的也算一份
# （交叉打包时宿主没装 arm64 的 lua-cjson，但目标机自己那份可以 rsync 进 sysroot）。
_cjson="${ROOT}/third_party/cjson/lua/5.1/cjson.so"
_want="$WANT_MACHINE"
_got="$(_elf_machine "$_cjson")"
if [ "$_got" = "$_want" ]; then
    cp "$_cjson" "$DIST/third_party/cjson/lua/5.1/"
else
    _sys=""
    for c in /usr/lib/*/lua/5.1/cjson.so /usr/lib/lua/5.1/cjson.so \
             ${LITE_SYSROOT:+$LITE_SYSROOT/usr/lib/lua/5.1/cjson.so} \
             ${LITE_SYSROOT:+$LITE_SYSROOT/usr/lib/*/lua/5.1/cjson.so}; do
        [ -f "$c" ] && [ "$(_elf_machine "$c")" = "$_want" ] && { _sys="$c"; break; }
    done
    if [ -n "$_sys" ]; then
        cp -L "$_sys" "$DIST/third_party/cjson/lua/5.1/cjson.so"
        echo "package: 仓库 cjson.so 架构为 ${_got:-?}（目标 ${_want}），改用系统 $_sys"
    else
        echo "package: [WARN] cjson.so 架构为 ${_got:-?}、目标是 ${_want}，且本机没有同架构副本" >&2
        echo "         目标机 apt install lua-cjson，或用工具链重编 cjson 再打包" >&2
        cp "$_cjson" "$DIST/third_party/cjson/lua/5.1/" || true
    fi
fi

# 逐个 chmod，缺文件只跳过。上面复制是 `[ -f ] && cp` 容错的，这里若一把 chmod 全集，
# 源码树没同步到后加的工具（serve_up.sh 这类）就整体失败：set -e 下脚本立即退出，
# 后面的 strip/tar 全不跑，dist 里的 tar.gz 停在上一次的旧产物 —— 看起来「打包成功」，
# 实际装出去的是旧代码。这个坑在 121 上真实踩到过一次。
for f in lite-lua lua.sh lite run.sh check_deps.sh build.sh test.sh install.sh package.sh \
         release.sh launch.sh ort_link.sh cuda_provider.sh cluster.sh serve_up.sh setup_service.sh serve_service.sh; do
    [ -f "$DIST/tools/$f" ] && chmod +x "$DIST/tools/$f"
done

if command -v strip >/dev/null 2>&1; then
    strip --strip-unneeded "$DIST/third_party/luajit/src/luajit" 2>/dev/null || true
fi

# 自检：tar -h 会解引用软链，万一混进系统库，包会瞬间膨胀。
# 这里给一个大文件闸门，超了就报错而不是静默产出胖包。
DIST_MAX_FILE_MB="${LITE_DIST_MAX_FILE_MB:-16}"
big="$(find "$DIST" -type f -size +"${DIST_MAX_FILE_MB}"M -printf '%s %p\n' 2>/dev/null | sort -rn | head -5)"
if [ -n "$big" ]; then
    echo "package: 以下文件超过 ${DIST_MAX_FILE_MB}MB，疑似误打包系统库：" >&2
    echo "$big" | while read -r sz f; do
        printf '  %6sMB  %s\n' "$((sz / 1024 / 1024))" "${f#"$DIST"/}" >&2
    done
    echo "  确认要打包就设 LITE_DIST_MAX_FILE_MB=<更大的值>" >&2
    exit 1
fi

tar -czhf "$ROOT/dist/$LITE_DIST_NAME.tar.gz" -C "$ROOT/dist" "$LITE_DIST_NAME"
echo "package: $ROOT/dist/$LITE_DIST_NAME.tar.gz ($(du -h "$ROOT/dist/$LITE_DIST_NAME.tar.gz" | cut -f1))"
