#!/usr/bin/env bash
# lite 回归：依赖 + 单元 + CLI + TUI 冒烟。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== deps =="
"$ROOT/tools/check_deps.sh"

[ -f "$ROOT/build/liblite_cache.so" ] || "$ROOT/tools/build.sh"

echo "== unit =="
"$ROOT/tools/lite-lua" "$ROOT/tools/auto_unit.lua"

echo "== live =="
"$ROOT/tools/live_smoke.sh"

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
OUT="$(env -u DEEPSEEK_API_KEY HOME=/tmp LITE_ENV_FILE=/dev/null "$ROOT/tools/run.sh" --once --json hi || true)"
if ! echo "$OUT" | grep -q '"type":"error"'; then
    echo "FAIL cli.once.no-key.json" >&2; exit 1
fi

TMPD="$(mktemp -d)"
OUT="$( cd "$TMPD" && env -u DEEPSEEK_API_KEY LITE_CWD="$TMPD" LITE_MEMORY_DIR="$TMPD" \
    "$ROOT/tools/run.sh" --tui --snapshot "$TMPD/snap.txt" --snapshot-text "snapshot text" || true )"
if ! grep -q "lite TUI" "$TMPD/snap.txt" 2>/dev/null; then
    echo "FAIL cli.tui.snapshot" >&2; rm -rf "$TMPD"; exit 1
fi
if ! grep -q "snapshot text" "$TMPD/snap.txt"; then
    echo "FAIL cli.tui.snapshot.text" >&2; rm -rf "$TMPD"; exit 1
fi
OUT="$( cd "$TMPD" && LITE_CWD="$TMPD" LITE_MEMORY_DIR="$TMPD" "$ROOT/tools/run.sh" state --json || true )"
if ! echo "$OUT" | grep -q '"type":"state"'; then
    echo "FAIL cli.state.json" >&2; rm -rf "$TMPD"; exit 1
fi
OUT="$( cd "$TMPD" && LITE_CWD="$TMPD" LITE_MEMORY_DIR="$TMPD" "$ROOT/tools/run.sh" sessions --json || true )"
if ! echo "$OUT" | grep -q '"type":"sessions"'; then
    echo "FAIL cli.sessions.json" >&2; rm -rf "$TMPD"; exit 1
fi
rm -rf "$TMPD"
echo "OK cli.json"

echo "== plugins =="
OUT="$("$ROOT/tools/run.sh" plugins --json || true)"
if ! echo "$OUT" | grep -q '"name":"codesearch"'; then
    echo "FAIL plugins.codesearch (helper/codesearch.lua not loaded)" >&2
    exit 1
fi
echo "OK plugins.json"

echo "== tui =="
"$ROOT/tools/tui_smoke.sh"

echo "== serve =="
"$ROOT/tools/serve_smoke.sh"

echo "== done =="
