#!/usr/bin/env bash
# CUDA provider 用软链接，不打包。
#
# libocr_simple.so 会尝试挂 CUDA EP，但 libonnxruntime_providers_cuda.so 有 329MB，
# 不适合随包分发。做法：只在系统里存在**版本匹配**的 provider 时，软链到
# third_party/ocr/lib/，让 ORT 按 soname 找到它；没有就保持 CPU。
#
# 注意：ONNX Runtime 对 provider 与核心库做版本校验，版本不符会加载失败。
# 所以本脚本链接后会**实测**一次 OCR 初始化，确认真的 "CUDA enabled" 才保留，
# 否则自动回滚。
#
# 用法:
#   ./tools/cuda_provider.sh status     # 看当前状态（默认）
#   ./tools/cuda_provider.sh link       # 找匹配版本并软链 + 实测
#   ./tools/cuda_provider.sh unlink     # 移除软链，回到 CPU
#
# 性能提示：单张小图 CUDA 反而更慢（初始化开销占主导，实测 2.4s vs 0.8s）。
# 只有批量/大图才值得开。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBDIR="$ROOT/third_party/ocr/lib"
ORT="$LIBDIR/libonnxruntime.so.1"
LINK="$LIBDIR/libonnxruntime_providers_cuda.so"

ort_version() {
    [ -f "$ORT" ] || return 1
    strings "$ORT" 2>/dev/null | grep -oE '^1\.[0-9]+\.[0-9]+$' | sort -u | tail -1
}

provider_version() {
    local p="$1"
    [ -f "$p" ] || return 1
    strings "$p" 2>/dev/null | grep -oE '^1\.[0-9]+\.[0-9]+$' | sort -u | tail -1
}

# 候选：显式覆盖 → 版本同名目录 → 常见安装位置
candidates() {
    local ver="$1"
    [ -n "${LITE_ORT_CUDA_PROVIDER:-}" ] && echo "$LITE_ORT_CUDA_PROVIDER"
    for base in /venv /data/venv "$HOME/venv" /opt /usr/local; do
        for d in "$base"/onnxruntime-linux-x64-gpu-"$ver"/lib \
                 "$base"/onnxruntime-linux-x64-gpu-*/lib; do
            [ -f "$d/libonnxruntime_providers_cuda.so" ] && echo "$d/libonnxruntime_providers_cuda.so"
        done
    done
    local p
    for p in /usr/local/lib/libonnxruntime_providers_cuda.so \
             /usr/lib/x86_64-linux-gnu/libonnxruntime_providers_cuda.so; do
        [ -f "$p" ] && echo "$p"
    done
}

# 实测：跑一次 OCR 初始化，看是否真的用上 CUDA
probe_cuda() {
    cd "$ROOT"
    LITE_ROOT="$ROOT" ./tools/lite-lua -e '
local ok, m = pcall(require, "ffi.ocr")
if not ok then io.write("LOADFAIL\n"); os.exit(0) end
local ready = m.ready()
io.write(ready and "READY\n" or "NOTREADY\n")
' >"/tmp/lite_cuda_probe.$$" 2>&1 || true
    local out; out="$(cat "/tmp/lite_cuda_probe.$$" 2>/dev/null || true)"
    rm -f "/tmp/lite_cuda_probe.$$"
    case "$out" in
        *"CUDA enabled"*) return 0 ;;
        *) return 1 ;;
    esac
}

status() {
    local ver; ver="$(ort_version || true)"
    echo "== lite OCR CUDA provider =="
    if [ -z "$ver" ]; then
        echo "[WARN] 找不到随包 onnxruntime（$ORT）"
        return 0
    fi
    echo "[OK]   随包 onnxruntime  $ver"
    if [ -L "$LINK" ]; then
        local tgt; tgt="$(readlink -f "$LINK" 2>/dev/null || true)"
        if [ -f "$tgt" ]; then
            echo "[OK]   CUDA provider 软链 -> $tgt"
            echo "       （单张小图 CUDA 更慢；批量/大图才值得）"
        else
            echo "[FAIL] CUDA provider 软链悬空 -> $(readlink "$LINK")"
            echo "       用 ./tools/cuda_provider.sh unlink 清理"
        fi
    elif [ -f "$LINK" ]; then
        echo "[WARN] CUDA provider 是实体文件（%s）" "$(du -h "$LINK" | cut -f1)"
        echo "       329MB 不该随包；建议 unlink 后改用软链"
    else
        echo "[INFO] 未链接 CUDA provider → OCR 走 CPU（默认，单图更快）"
    fi
}

link_provider() {
    local ver; ver="$(ort_version || true)"
    [ -z "$ver" ] && { echo "error: 找不到随包 onnxruntime" >&2; exit 1; }

    if [ -L "$LINK" ] && [ -f "$(readlink -f "$LINK" 2>/dev/null)" ]; then
        echo "already linked -> $(readlink -f "$LINK")"
        return 0
    fi

    local found="" p pver
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        pver="$(provider_version "$p" || true)"
        if [ "$pver" = "$ver" ]; then found="$p"; break; fi
        echo "skip (版本 $pver ≠ $ver): $p" >&2
    done < <(candidates "$ver")

    if [ -z "$found" ]; then
        echo "未找到版本匹配（$ver）的 libonnxruntime_providers_cuda.so" >&2
        echo "可用 LITE_ORT_CUDA_PROVIDER=/path/to/provider.so 显式指定" >&2
        exit 1
    fi

    rm -f "$LINK"
    ln -sfn "$found" "$LINK"
    echo "linked: $LINK -> $found"

    if probe_cuda; then
        echo "[OK] 实测 CUDA enabled"
    else
        rm -f "$LINK"
        echo "[FAIL] 实测未启用 CUDA（版本或符号不匹配），已回滚到 CPU" >&2
        exit 1
    fi
}

unlink_provider() {
    if [ -e "$LINK" ] || [ -L "$LINK" ]; then
        rm -f "$LINK"
        echo "unlinked: $LINK（OCR 回到 CPU）"
    else
        echo "本来就没有链接"
    fi
}

case "${1:-status}" in
    status)  status ;;
    link)    link_provider ;;
    unlink)  unlink_provider ;;
    *) echo "用法: $0 [status|link|unlink]" >&2; exit 2 ;;
esac
