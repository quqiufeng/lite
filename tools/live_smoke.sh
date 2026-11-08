#!/usr/bin/env bash
# 真实 API 冒烟：最小请求必须拿到 done。没有 key 时 SKIP，不算通过。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

OUT="$(
    cd "$TMPD"
    LITE_CWD="$TMPD" LITE_MEMORY_DIR="$TMPD" LITE_INSTRUCTIONS_FILE=/dev/null \
        timeout 60 "$ROOT/tools/run.sh" --once --json "回复ok即可" 2>&1 || true
)"

if echo "$OUT" | grep -q 'missing DEEPSEEK_API_KEY'; then
    echo "SKIP live (no DEEPSEEK_API_KEY)"
    exit 0
fi

if ! echo "$OUT" | grep -q '"type":"done"'; then
    echo "FAIL live.api" >&2
    echo "$OUT" | tail -20 >&2
    exit 1
fi

if ! echo "$OUT" | grep -q '"type":"assistant"'; then
    echo "FAIL live.api.no-assistant" >&2
    echo "$OUT" | tail -20 >&2
    exit 1
fi

echo "OK live.api"
