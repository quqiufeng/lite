#!/usr/bin/env bash
# 真实 API 连通性冒烟：独立构造最小上下文，只发一次请求。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/tools/lite-lua" "$ROOT/tools/live_api_smoke.lua"
