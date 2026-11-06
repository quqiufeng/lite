#!/usr/bin/env bash
# 把**系统里**的 onnxruntime 接入 lite 的 OCR（不随包分发）。
#
# 为什么需要它：libonnxruntime.so.1 有 25MB，占 dist 包一半；`tar -h` 还会
# 把软链解引用成实体。目标机一般已经装了 onnxruntime（onnxruntime-gpu 的
# pip 包、系统包、或别的 SDK 目录），直接复用即可。
#
# 关键约束：libocr_simple.so 是**针对特定 ORT 版本**编译的（当前 1.26），
# 版本不符会因缺版本符号/ABI 差异加载失败。所以本脚本：
#   1. 先探测 libocr_simple.so 需要哪个版本
#   2. 只在系统里找**版本一致**的那份
#   3. 链接后实测一次 OCR，确认真的能用才留下，否则回滚
#
# 用法:
#   ./tools/ort_link.sh status     # 默认
#   ./tools/ort_link.sh link [dir] # dir 可显式指定 onnxruntime 的 lib 目录
#   ./tools/ort_link.sh unlink
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 源码树里 ocr 库在 third_party/ocr/lib；dist 包内平铺在 lib/。
if [ -d "$ROOT/third_party/ocr/lib" ]; then
    LIBDIR="$ROOT/third_party/ocr/lib"
else
    LIBDIR="$ROOT/lib"
fi
OCRSO="$LIBDIR/libocr_simple.so"
CORE="$LIBDIR/libonnxruntime.so.1"
SHARED="$LIBDIR/libonnxruntime_providers_shared.so"

# 探测 ORT 版本，按可靠度依次：
#   1) LITE_ORT_VERSION 显式指定
#   2) 现有核心库 libonnxruntime.so.1 自带版本串
#   3) package.sh 打的 lib/ORT_VERSION 标记文件
# 不从 libocr_simple.so 里抓字符串——那里混着一堆无关版本号（实测抓到 1.3.9）。
want_version() {
    if [ -n "${LITE_ORT_VERSION:-}" ]; then echo "$LITE_ORT_VERSION"; return 0; fi
    if [ -f "$CORE" ]; then
        local v
        v="$(strings "$CORE" 2>/dev/null | grep -oE '^1\.[0-9]+\.[0-9]+$' | sort -u | tail -1)"
        [ -n "$v" ] && { echo "$v"; return 0; }
    fi
    local marker="$(dirname "$CORE")/ORT_VERSION"
    if [ -f "$marker" ]; then
        local v; v="$(tr -d '[:space:]' <"$marker")"
        [ -n "$v" ] && { echo "$v"; return 0; }
    fi
    return 1
}

file_version() {
    [ -f "$1" ] || return 1
    local v
    v="$(strings "$1" 2>/dev/null | grep -oE '^1\.[0-9]+\.[0-9]+$' | sort -u | tail -1)"
    [ -n "$v" ] && { echo "$v"; return 0; }
    return 1
}

# 候选 lib 目录（含核心库与 providers_shared 的）
candidate_dirs() {
    [ -n "${LITE_ORT_DIR:-}" ] && echo "$LITE_ORT_DIR"
    for base in /venv /data/venv "$HOME/venv" /opt /usr/local /usr; do
        for d in "$base"/onnxruntime-linux-x64-gpu-*/lib "$base"/onnxruntime-linux-x64-*/lib \
                 "$base"/lib/python3*/site-packages/onnxruntime/capi; do
            [ -f "$d/libonnxruntime.so.1" ] && echo "$d"
        done
    done
    for d in /usr/local/lib /usr/lib/x86_64-linux-gnu /usr/lib64; do
        [ -f "$d/libonnxruntime.so.1" ] && echo "$d"
    done
}

probe() {
    cd "$ROOT"
    LITE_ROOT="$ROOT" ./tools/lite-lua -e '
local ok, m = pcall(require, "ffi.ocr")
if not ok then io.write("LOADFAIL\n"); os.exit(0) end
local ready, err = m.ready()
io.write(ready and "READY\n" or ("NOTREADY " .. tostring(err) .. "\n"))
' 2>&1 | tail -3 >"/tmp/lite_ort_probe.$$" || true
    local out; out="$(cat "/tmp/lite_ort_probe.$$" 2>/dev/null || true)"
    rm -f "/tmp/lite_ort_probe.$$"
    # 必须整行匹配：`*READY*` 会把 "NOTREADY" 也算成功（踩过）
    case "$out" in
        READY|READY[[:space:]]*|*$'\n'READY) return 0 ;;
    esac
    printf '%s\n' "$out" | grep -qx 'READY' && return 0
    return 1
}

status() {
    local v; v="$(want_version || true)"
    echo "== lite onnxruntime（OCR）=="
    echo "需要版本: ${v:-未知}"
    for pair in "core:$CORE" "shared:$SHARED"; do
        local name="${pair%%:*}" path="${pair#*:}"
        if [ -f "$path" ]; then
            local rv; rv="$(file_version "$path" || echo '')"
            if [ -z "$rv" ]; then
                # providers_shared 这类小 shim 不带版本串，无从比较，直接接受
                echo "[OK]   $name  (无版本串)  $(readlink -f "$path")"
            elif [ "$rv" = "$v" ]; then
                echo "[OK]   $name  $rv  $(readlink -f "$path")"
            else
                echo "[WARN] $name  版本 $rv ≠ $v"
            fi
        else
            echo "[INFO] $name  未提供（./tools/ort_link.sh link 接入系统库）"
        fi
    done
    if probe >/dev/null 2>&1; then
        echo "[OK]   OCR 可用"
    else
        echo "[WARN] OCR 当前不可用（缺 onnxruntime 或版本不匹配）"
    fi
}

link_libs() {
    local v; v="$(want_version || true)"
    [ -z "$v" ] && { echo "error: 无法探测 ORT 版本（先放一份 libonnxruntime.so.1）" >&2; exit 1; }

    local explicit="${1:-}" dir="" ok=""
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        [ -f "$dir/libonnxruntime.so.1" ] || continue
        local dv; dv="$(file_version "$dir/libonnxruntime.so.1" || true)"
        if [ "$dv" != "$v" ]; then
            echo "skip (版本 ${dv:-?} ≠ $v): $dir" >&2
            continue
        fi
        ok="$dir"; break
    done < <(if [ -n "$explicit" ]; then echo "$explicit"; else candidate_dirs; fi)

    [ -z "$ok" ] && {
        echo "未找到版本 $v 的系统 onnxruntime" >&2
        echo "可用 LITE_ORT_DIR=/path/to/lib ./tools/ort_link.sh link 显式指定" >&2
        exit 1
    }

    rm -f "$CORE" "$SHARED"
    ln -sfn "$ok/libonnxruntime.so.1" "$CORE"
    [ -f "$ok/libonnxruntime_providers_shared.so" ] \
        && ln -sfn "$ok/libonnxruntime_providers_shared.so" "$SHARED"
    echo "linked: $CORE -> $ok/libonnxruntime.so.1"

    if probe; then
        echo "[OK] 实测 OCR 可用"
    else
        rm -f "$CORE" "$SHARED"
        echo "[FAIL] 实测 OCR 加载失败，已回滚（版本/ABI 可能不匹配）" >&2
        exit 1
    fi
}

unlink_libs() {
    for f in "$CORE" "$SHARED"; do
        if [ -L "$f" ]; then rm -f "$f"; echo "unlinked: $f"; fi
    done
}

case "${1:-status}" in
    status) status ;;
    link)   shift || true; link_libs "${1:-}" ;;
    unlink) unlink_libs ;;
    *) echo "用法: $0 [status|link [dir]|unlink]" >&2; exit 2 ;;
esac
