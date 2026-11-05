#!/usr/bin/env bash
# 生成 dist/lite-linux-x64.tar.gz（LuaJIT + cjson + lua + tools）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist/lite-linux-x64"

rm -rf "$DIST"
mkdir -p "$DIST/lua" "$DIST/tools" "$DIST/third_party" "$DIST/automation" "$DIST/build"

cp -r "$ROOT/lua/." "$DIST/lua/"
cp -r "$ROOT/automation/." "$DIST/automation/"
cp "$ROOT/AGENTS.md" "$ROOT/design.md" "$DIST/"
if [ -f "$ROOT/build/liblite_cache.so" ]; then
    cp "$ROOT/build/liblite_cache.so" "$DIST/build/"
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

tar -czf "$ROOT/dist/lite-linux-x64.tar.gz" -C "$ROOT/dist" lite-linux-x64
echo "package: $ROOT/dist/lite-linux-x64.tar.gz"
