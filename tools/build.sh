#!/usr/bin/env bash
# lite 构建：LuaJIT（缺失时）+ 原生 KV cache。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"

"$ROOT/tools/check_deps.sh"

if [ ! -x "$ROOT/third_party/luajit/src/luajit" ]; then
    echo "lite: building bundled LuaJIT..."
    make -C "$ROOT/third_party/luajit" -j"$(nproc)"
fi

if [ -f "$ROOT/CMakeLists.txt" ] && [ -d "$ROOT/src" ]; then
    cmake -S "$ROOT" -B "$ROOT/build" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$ROOT/build" -j"$(nproc)"
    echo "lite: native build complete"
else
    echo "lite: Lua-only build (no src/CMakeLists.txt yet)"
fi
