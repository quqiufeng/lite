#!/usr/bin/env bash
# lite 回归：依赖 + 单元测试（无 UI）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== deps =="
"$ROOT/tools/check_deps.sh"

[ -f "$ROOT/build/liblite_cache.so" ] || "$ROOT/tools/build.sh"

echo "== unit =="
"$ROOT/tools/lite-lua" "$ROOT/tools/auto_unit.lua"

echo "== cli =="
OUT="$("$ROOT/tools/run.sh" --check --json || true)"
if ! echo "$OUT" | grep -q '"type":"check"'; then
    echo "FAIL cli.check.json" >&2; exit 1
fi
TMPD="$(mktemp -d)"
OUT="$( cd "$TMPD" && "$ROOT/tools/run.sh" --recall --json anything || true )"
rm -rf "$TMPD"
if ! echo "$OUT" | grep -q '"type":"memory"'; then
    echo "FAIL cli.recall.json" >&2; exit 1
fi
OUT="$(env -u DEEPSEEK_API_KEY HOME=/tmp "$ROOT/tools/run.sh" --once --json hi || true)"
if ! echo "$OUT" | grep -q '"type":"error"'; then
    echo "FAIL cli.once.no-key.json" >&2; exit 1
fi
echo "OK cli.json"

echo "== done =="
