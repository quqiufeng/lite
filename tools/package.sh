#!/usr/bin/env bash
# 生成 dist/lite-linux-x64.tar.gz（LuaJIT + cjson + lua + tools）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist/lite-linux-x64"

rm -rf "$DIST"
mkdir -p "$DIST/lua" "$DIST/tools" "$DIST/third_party" "$DIST/automation" "$DIST/build" "$DIST/lib" "$DIST/helper" "$DIST/models"

cp -r "$ROOT/lua/." "$DIST/lua/"
cp -r "$ROOT/automation/." "$DIST/automation/"
if [ -d "$ROOT/helper" ]; then
    find "$ROOT/helper" -maxdepth 1 -type f ! -name '.gitkeep' -exec cp {} "$DIST/helper/" \;
fi
cp "$ROOT/AGENTS.md" "$ROOT/design.md" "$DIST/"
if [ -f "$ROOT/build/liblite_cache.so" ]; then
    cp "$ROOT/build/liblite_cache.so" "$DIST/build/"
fi

if [ -f "$ROOT/build/liblite_capture.so" ]; then
    cp "$ROOT/build/liblite_capture.so" "$DIST/lib/"
fi

if [ -d "$ROOT/third_party/ocr/lib" ]; then
    for src in "$ROOT/third_party/ocr/lib/"*.so*; do
        [ -e "$src" ] || continue
        bn="$(basename "$src")"
        # CUDA provider 是 329MB 的系统库软链，绝不打包：
        # 下面的 tar -h 会解引用软链，把 329MB 实体塞进 tarball。
        # 目标机需要 GPU 时用 tools/cuda_provider.sh link 自己接。
        case "$bn" in
            *providers_cuda*) continue ;;
        esac
        ln -sfn "../../../third_party/ocr/lib/$bn" "$DIST/lib/$bn"
    done
fi
if [ -d "$ROOT/third_party/ocr/models/ocr" ]; then
    ln -sfn "../../../third_party/ocr/models/ocr" "$DIST/models/ocr"
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

for f in lite-lua lite run.sh check_deps.sh build.sh test.sh install.sh package.sh release.sh launch.sh; do
    [ -f "$ROOT/tools/$f" ] && cp "$ROOT/tools/$f" "$DIST/tools/"
done
cp "$ROOT/tools/auto_unit.lua" "$DIST/tools/"

mkdir -p "$DIST/third_party/cjson/lua/5.1"
cp -r "$ROOT/third_party/luajit" "$DIST/third_party/"
cp "$ROOT/third_party/cjson/lua/5.1/cjson.so" "$DIST/third_party/cjson/lua/5.1/"

chmod +x "$DIST/tools/lite-lua" "$DIST/tools/lite" "$DIST/tools/run.sh" \
    "$DIST/tools/check_deps.sh" "$DIST/tools/build.sh" "$DIST/tools/test.sh" \
    "$DIST/tools/install.sh" "$DIST/tools/package.sh" "$DIST/tools/release.sh" \
    "$DIST/tools/launch.sh"

if command -v strip >/dev/null 2>&1; then
    strip --strip-unneeded "$DIST/third_party/luajit/src/luajit" 2>/dev/null || true
fi

tar -czhf "$ROOT/dist/lite-linux-x64.tar.gz" -C "$ROOT/dist" lite-linux-x64
echo "package: $ROOT/dist/lite-linux-x64.tar.gz"
