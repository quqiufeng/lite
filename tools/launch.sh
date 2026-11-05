#!/usr/bin/env bash
# lite 是终端应用；launch 直接进入 run.sh。
set -euo pipefail
SELF="$(readlink -f "$0")"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
exec "$ROOT/tools/run.sh" "$@"
