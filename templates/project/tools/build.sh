#!/usr/bin/env bash
# build.sh — 构建全部 .so。改完 C/C++ 必须跑这个，然后重启宿主进程（FFI 不热更）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"

need() { command -v "$1" >/dev/null 2>&1 || { echo "build.sh: 缺少 $1" >&2; exit 127; }; }
need cmake
need cc

cmake -S "$ROOT" -B "$ROOT/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$ROOT/build" -j"$(nproc)"

echo "@NAME@: native build complete → $ROOT/build"
ls -1 "$ROOT"/build/lib*.so 2>/dev/null || true
