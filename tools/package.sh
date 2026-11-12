#!/usr/bin/env bash
# 生成 dist/lite-linux-x64.tar.gz（LuaJIT + cjson + lua + tools）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist/lite-linux-x64"

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
cp "$ROOT/AGENTS.md" "$ROOT/design.md" "$DIST/"
if [ -f "$ROOT/build/liblite_cache.so" ]; then
    cp "$ROOT/build/liblite_cache.so" "$DIST/build/"
fi
if [ -f "$ROOT/build/liblite_codesearch.so" ]; then
    cp "$ROOT/build/liblite_codesearch.so" "$DIST/build/"
fi

if [ -f "$ROOT/build/liblite_capture.so" ]; then
    cp "$ROOT/build/liblite_capture.so" "$DIST/lib/"
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
        # "../../../third_party/ocr/lib/xxx" 从 dist/lite-linux-x64/lib 往上
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

if [ -f "$ROOT/build/liblite_image.so" ]; then
    cp "$ROOT/build/liblite_image.so" "$DIST/lib/"
    LDD_TMP="$(mktemp)"
    ldd "$ROOT/build/liblite_image.so" >"$LDD_TMP" 2>/dev/null || true
    while read -r so arrow path _; do
        [ "$arrow" = "=>" ] || continue
        case "$so" in
            libc.so.*|libm.so.*|libgcc_s.so.*|libpthread.so.*|libdl.so.*|librt.so.*|ld-linux*) continue ;;
        esac
        if [ -n "$path" ] && [ -f "$path" ]; then
            cp -L "$path" "$DIST/lib/$so"
        fi
    done <"$LDD_TMP"
    rm -f "$LDD_TMP"
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
LITEHTML_PREFIX="${LITEHTML_PREFIX:-/opt/litehtml}"
if [ -f "$ROOT/build/liblite_html.so" ]; then
    cp "$ROOT/build/liblite_html.so" "$DIST/build/"
    LDD_TMP="$(mktemp)"
    ldd "$ROOT/build/liblite_html.so" >"$LDD_TMP" 2>/dev/null || true
    bundled=()
    while read -r so arrow path _; do
        [ "$arrow" = "=>" ] || continue
        [ -n "$path" ] && [ -f "$path" ] || continue
        real="$(realpath "$path" 2>/dev/null || echo "$path")"
        case "$real" in
            "$LITEHTML_PREFIX"/*) ;;   # 私有依赖，随包
            *) continue ;;             # 系统库，用目标机自己的
        esac
        cp -L "$path" "$DIST/build/$so"
        bundled+=("$so")
    done <"$LDD_TMP"
    rm -f "$LDD_TMP"
    if [ ${#bundled[@]} -gt 0 ]; then
        echo "package: lite_html 随包私有依赖: ${bundled[*]}"
    else
        echo "package: [WARN] liblite_html.so 未解析出 $LITEHTML_PREFIX 下的依赖，" >&2
        echo "         目标机若缺 liblitehtml/libgumbo，html→png 起不来" >&2
    fi
fi

for f in lite-lua lua.sh lite run.sh check_deps.sh build.sh test.sh install.sh package.sh release.sh launch.sh \
         ort_link.sh cuda_provider.sh see.lua cluster.sh; do
    [ -f "$ROOT/tools/$f" ] && cp "$ROOT/tools/$f" "$DIST/tools/"
done
cp "$ROOT/tools/auto_unit.lua" "$DIST/tools/"

mkdir -p "$DIST/third_party/cjson/lua/5.1"
cp -r "$ROOT/third_party/luajit" "$DIST/third_party/"
cp "$ROOT/third_party/cjson/lua/5.1/cjson.so" "$DIST/third_party/cjson/lua/5.1/"

chmod +x "$DIST/tools/lite-lua" "$DIST/tools/lua.sh" "$DIST/tools/lite" "$DIST/tools/run.sh" \
    "$DIST/tools/check_deps.sh" "$DIST/tools/build.sh" "$DIST/tools/test.sh" \
    "$DIST/tools/install.sh" "$DIST/tools/package.sh" "$DIST/tools/release.sh" \
    "$DIST/tools/launch.sh" "$DIST/tools/ort_link.sh" "$DIST/tools/cuda_provider.sh" \
    "$DIST/tools/cluster.sh"

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

tar -czhf "$ROOT/dist/lite-linux-x64.tar.gz" -C "$ROOT/dist" lite-linux-x64
echo "package: $ROOT/dist/lite-linux-x64.tar.gz ($(du -h "$ROOT/dist/lite-linux-x64.tar.gz" | cut -f1))"
