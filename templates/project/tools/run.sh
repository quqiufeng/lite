#!/usr/bin/env bash
# run.sh — 主入口。--json 时输出机器可读结果（脚本/集群只认这个）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/tools/lua.sh" "$ROOT/lua/app.lua" "$@"
