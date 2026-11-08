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

for p in sdl2 SDL2_ttf; do
    if pkg-config --exists "$p" 2>/dev/null; then
        echo "[OK]   $p     $(pkg-config --modversion "$p")"
    else
        echo "[WARN] $p     missing (optional, ./tools/run.sh --gui)"
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
elif [ -f "$OCR_LIB" ]; then
    # lib 在、模型不在：OCR 是可选项，dist 默认不带模型，这不算失败
    echo "[INFO] OCR      lib 就绪，未装模型（可选：拷 models 或设 LITE_OCR_MODELS）"
else
    echo "[WARN] OCR      missing lib (ocr tool disabled)"
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

# onnxruntime 核心库：不打包（25MB），靠 ort_link.sh 接系统库
ORT_CORE="$ROOT/third_party/ocr/lib/libonnxruntime.so.1"
[ -f "$ORT_CORE" ] || ORT_CORE="$ROOT/lib/libonnxruntime.so.1"
if [ -f "$ORT_CORE" ]; then
    echo "[OK]   ocr-core $(du -h "$ORT_CORE" | cut -f1)  $(readlink -f "$ORT_CORE")"
else
    echo "[INFO] ocr-core missing (./tools/ort_link.sh link 接入系统 onnxruntime)"
fi

# CUDA provider：不打包，靠软链接接入系统里版本匹配的那份
CUDA_LINK="$ROOT/third_party/ocr/lib/libonnxruntime_providers_cuda.so"
if [ -L "$CUDA_LINK" ]; then
    if [ -f "$(readlink -f "$CUDA_LINK" 2>/dev/null)" ]; then
        echo "[OK]   ocr-cuda linked -> $(readlink "$CUDA_LINK")"
    else
        echo "[WARN] ocr-cuda dangling link（./tools/cuda_provider.sh unlink）"
    fi
elif [ -f "$CUDA_LINK" ]; then
    echo "[WARN] ocr-cuda 实体文件 $(du -h "$CUDA_LINK" | cut -f1)，不应随包：改用 --link"
else
    echo "[INFO] ocr-cuda not linked (CPU only; 单图更快)"
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
