#!/usr/bin/env bash
set -euo pipefail

SELF="$(readlink -f "$0")"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"

export LITE_ROOT="$ROOT"
exec "$ROOT/tools/lite-lua" "$ROOT/lua/main.lua" "$@"
