#!/usr/bin/env bash
# 检查 lite 运行依赖：LuaJIT / cjson / libcurl / 构建工具。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

echo "== lite dependencies =="

if [ -x "$ROOT/third_party/luajit/src/luajit" ]; then
    echo "[OK]   luajit   bundled"
else
    if command -v luajit >/dev/null 2>&1; then
        echo "[OK]   luajit   $(luajit -v 2>&1 | head -1)"
    else
        echo "[FAIL] luajit   missing"
        fail=1
    fi
fi

"$ROOT/tools/lite-lua" -e '
local deps = require("core.deps")
local ok, rows = deps.check()
for _, r in ipairs(rows) do
  io.write(string.format("[%s]   %-8s %s\n", r.ok and "OK" or "FAIL", r.name, r.detail))
  if not r.ok then os.exit(1) end
end
' || fail=1

for c in gcc cmake pkg-config; do
    if command -v "$c" >/dev/null 2>&1; then
        echo "[OK]   $c"
    else
        echo "[WARN] $c missing (needed later for native launcher)"
    fi
done

if pkg-config --exists x11 2>/dev/null; then
    echo "[OK]   x11     $(pkg-config --modversion x11)"
else
    echo "[FAIL] x11     missing (X11 capture)"
    fail=1
fi

for p in libpng libjpeg libwebp; do
    if pkg-config --exists "$p" 2>/dev/null; then
        echo "[OK]   $p     $(pkg-config --modversion "$p")"
    else
        echo "[FAIL] $p     missing (native image resize)"
        fail=1
    fi
done

for c in cc c++; do
    if command -v "$c" >/dev/null 2>&1; then
        echo "[OK]   $c"
    else
        echo "[WARN] $c missing (native helper build)"
    fi
done

OCR_LIB="${LITE_OCR_LIB:-$ROOT/lib/libocr_simple.so}"
OCR_MODELS="${LITE_OCR_MODELS:-$ROOT/models/ocr/}"
[ -f "$OCR_LIB" ] || OCR_LIB="$ROOT/third_party/ocr/lib/libocr_simple.so"
[ -f "$OCR_MODELS/ch_PP-OCRv4_det_infer.onnx" ] || OCR_MODELS="$ROOT/third_party/ocr/models/ocr/"
if [ -f "$OCR_LIB" ] && [ -f "$OCR_MODELS/ch_PP-OCRv4_det_infer.onnx" ]; then
    echo "[OK]   OCR      PP-OCRv4 (optional)"
else
    echo "[WARN] OCR      missing lib/models (ocr tool disabled)"
fi

# 回归：lite 不得通过 LD_LIBRARY_PATH 注入自带 .so。
# 该变量会被子进程继承，随包附带的 libonnxruntime.so.1 会遮蔽系统同名库
# （缺 VERS_1.20.1 等版本符号），使依赖系统 onnxruntime 的外部工具静默失败。
if [ -f "$OCR_LIB" ] && [ -f "$OCR_MODELS/ch_PP-OCRv4_det_infer.onnx" ]; then
    if env -u LD_LIBRARY_PATH LITE_ROOT="$ROOT" "$ROOT/tools/lite-lua" -e '
local ok, m = pcall(require, "ffi.ocr")
local ready, err = ok and m.ready()
if not ready then io.stderr:write(tostring(err) .. "\n"); os.exit(1) end
' >/dev/null 2>&1; then
        echo "[OK]   ocr      self-contained (no LD_LIBRARY_PATH needed)"
    else
        echo "[FAIL] ocr      requires LD_LIBRARY_PATH (would shadow system libs)"
        fail=1
    fi
fi

if command -v tmux >/dev/null 2>&1; then
    echo "[OK]   tmux     $(tmux -V 2>/dev/null || echo present)"
else
    echo "[WARN] tmux missing (tui.smoke skipped)"
fi

if [ "$fail" -ne 0 ]; then
    echo "== dependencies missing =="
    exit 1
fi
echo "== deps ok =="
