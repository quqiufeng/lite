#!/usr/bin/env bash
# 把**系统里**的 onnxruntime 接入 lite 的 OCR（不随包分发）。
#
# 为什么需要它：libonnxruntime.so.1 有 22~25MB；`tar -h` 会把软链解引用成实体，
# 塞进 dist。目标机一般已经装了 onnxruntime —— **CPU 版就够**（pip 的
# onnxruntime 包、发行版包），不必依赖 GPU 版（onnxruntime-gpu）。
#
# 关键约束：libocr_simple.so 是**针对特定 ORT 版本**编译的（当前 1.26），
# 版本不符会因缺版本符号/ABI 差异加载失败。所以本脚本：
#   1. 先探测 libocr_simple.so 需要哪个版本
#   2. 只在系统里找**版本一致**的那份
#   3. 链接后实测一次 OCR，确认真的能用才留下，否则回滚
# 选哪一份：LITE_ORT_PREFER=auto|gpu|cpu（默认 auto）
#   auto —— 机器能跑 GPU 就用 GPU 版，否则 CPU 版
#           "能跑" 判定：nvidia-smi 可用 + 有**版本匹配**的 providers_cuda
#           + cudnn/cublas 能解析（GPU provider 依赖它们）
#   cpu  —— 强制 CPU（单张小图 CPU 更快，实测 0.75s vs 2.3s）
#   gpu  —— 强制 GPU（找不到就报错，不静默降级）
#
# 体积参考：CPU 版核心库 22MB、零 CUDA 依赖；GPU 版核心库 26MB +
# providers_cuda 329MB + 依赖 cublas/cudart/cudnn。
#
# 用法:
#   ./tools/ort_link.sh status     # 默认
#   ./tools/ort_link.sh link [dir] # 软链系统里那份（省空间，源目录不能删）
#   ./tools/ort_link.sh copy [dir] # 真拷进 lib/（可移动/分发；CPU 22MB，GPU +329MB）
#   ./tools/ort_link.sh models [dir] # 拷 OCR 模型到 models/ocr/（默认从源码树拷）
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
PROVIDER="$LIBDIR/libonnxruntime_providers_cuda.so"

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

# 判断一份 ORT 是 CPU 版还是 GPU 版：
# 核心库 libonnxruntime.so.1 在两种发布里内容几乎一致（CPU/GPU 差异主要在
# 随行的 providers_cuda.so）。所以按「同目录有没有 providers_cuda」判定运行形态：
# 有 → 会真的挂 CUDA EP；没有 → 纯 CPU 运行（ocr 需要的就是这个）。
# OCR 只需要 CPU：GPU 版会连带 cudart/cudnn 依赖，且每次初始化都去试 CUDA EP。
ort_variant() {
    local dir="$1"
    if [ -f "$dir/libonnxruntime_providers_cuda.so" ]; then
        echo gpu
    else
        echo cpu
    fi
}

# 目录里的核心库文件：优先精确 soname，其次带版本号的那种
# （pip 包的 onnxruntime/capi 只有 libonnxruntime.so.1.26.0，没有 .so.1 软链）
core_file() {
    local d="$1"
    if [ -f "$d/libonnxruntime.so.1" ]; then
        echo "$d/libonnxruntime.so.1"
        return 0
    fi
    # 取版本号最大的那个（相当于 libonnxruntime.so.1.<ver>）
    local f best=""
    for f in "$d"/libonnxruntime.so.1.*; do
        [ -f "$f" ] || continue
        if [ -z "$best" ] || [ "$f" \> "$best" ]; then best="$f"; fi
    done
    [ -n "$best" ] && { echo "$best"; return 0; }
    return 1
}

# GPU 能不能真的跑起来：驱动 + 版本匹配的 providers_cuda + cudnn/cublas 可解析
gpu_usable() {
    local ver="$1"
    command -v nvidia-smi >/dev/null 2>&1 || return 1
    nvidia-smi -L >/dev/null 2>&1 || return 1

    # 必须有版本匹配的 provider（ORT 对 provider 做版本校验）
    local found="" p
    for p in $(candidate_dirs gpu); do
        local src; src="$(core_file "$p")"
        [ -n "$src" ] || continue
        [ "$(file_version "$src" || true)" = "$ver" ] || continue
        [ -f "$p/libonnxruntime_providers_cuda.so" ] || continue
        found="$p"; break
    done
    [ -n "$found" ] || return 1

    # provider 依赖 cublas/cudart/cudnn，缺了也是白搭
    local missing
    missing="$(ldd "$found/libonnxruntime_providers_cuda.so" 2>/dev/null | grep -c 'not found')"
    [ "${missing:-0}" = "0" ] || return 1
    return 0
}

# 候选 lib 目录。$1 可显式指定 auto|gpu|cpu，缺省读 LITE_ORT_PREFER（默认 auto）
candidate_dirs() {
    local prefer="${1:-${LITE_ORT_PREFER:-auto}}"
    local cpu=() gpu=()

    add() {
        local d="$1"
        [ -n "$d" ] || return 0
        [ -n "$(core_file "$d")" ] || return 0
        if [ "$(ort_variant "$d")" = cpu ]; then
            cpu+=("$d")
        else
            gpu+=("$d")
        fi
    }

    [ -n "${LITE_ORT_DIR:-}" ] && add "$LITE_ORT_DIR"
    for base in /venv /data/venv "$HOME/venv" /opt /usr/local /usr; do
        for d in "$base"/onnxruntime-linux-x64-*/lib \
                 "$base"/lib/python3*/site-packages/onnxruntime/capi; do
            add "$d"
        done
    done
    for d in /usr/local/lib /usr/lib/x86_64-linux-gnu /usr/lib64; do
        add "$d"
    done

    case "$prefer" in
        cpu) printf '%s\n' "${cpu[@]}" "${gpu[@]}" 2>/dev/null ;;
        *)   printf '%s\n' "${gpu[@]}" "${cpu[@]}" 2>/dev/null ;;
    esac
}

# auto 的落点：GPU 可用就 gpu，否则 cpu
resolve_prefer() {
    local want="${LITE_ORT_PREFER:-auto}"
    case "$want" in
        cpu|gpu) echo "$want"; return 0 ;;
    esac
    local ver; ver="$(want_version || true)"
    if [ -n "$ver" ] && gpu_usable "$ver"; then
        echo gpu
    else
        echo cpu
    fi
}

# 探测只验证「动态库可加载」，不要求模型存在：
# dist 默认不带 OCR 模型，若这里要求 ready()，链接 ORT 会被误判失败。
probe() {
    cd "$ROOT"
    LITE_ROOT="$ROOT" ./tools/lite-lua -e '
local ok, m = pcall(require, "ffi.ocr")
if not ok then io.write("LOADFAIL\n"); os.exit(0) end
local good, err = m.loadable()
io.write(good and "READY\n" or ("NOTREADY " .. tostring(err) .. "\n"))
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
    echo "选择策略: LITE_ORT_PREFER=${LITE_ORT_PREFER:-auto} -> $(resolve_prefer)"
    local vnow; vnow="$(want_version || true)"
    if [ -n "$vnow" ] && gpu_usable "$vnow"; then
        echo "GPU 可用: 是（nvidia-smi + 版本匹配 provider + cudnn/cublas 齐全）"
    else
        echo "GPU 可用: 否（缺驱动 / 版本匹配的 providers_cuda / cudnn·cublas 之一）"
    fi
    if [ -f "$CORE" ]; then
        local d; d="$(dirname "$(readlink -f "$CORE" 2>/dev/null || echo "$CORE")")"
        case "$(ort_variant "$d")" in
            gpu) echo "当前形态: GPU（同目录有 providers_cuda，会尝试 CUDA EP）" ;;
            *)   echo "当前形态: CPU（同目录无 providers_cuda，纯 CPU 运行）" ;;
        esac
    fi
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
        echo "[OK]   OCR 动态库可加载"
    else
        echo "[WARN] OCR 动态库不可加载（缺 onnxruntime 或版本不匹配）"
    fi
    # 模型是另一回事：可选，不会随 dist 分发。候选顺序与 lua/ffi/ocr.lua 一致
    local models="${LITE_OCR_MODELS:-}"
    if [ -z "$models" ]; then
        for cand in "$ROOT/third_party/ocr/models/ocr" "$ROOT/models/ocr"; do
            if [ -f "$cand/ch_PP-OCRv4_det_infer.onnx" ]; then models="$cand"; break; fi
        done
    fi
    if [ -n "$models" ] && [ -f "$models/ch_PP-OCRv4_det_infer.onnx" ] \
        && [ -f "$models/ch_PP-OCRv4_rec_infer.onnx" ] \
        && [ -f "$models/ppocr_keys_v1.txt" ]; then
        echo "[OK]   模型齐备  $models"
    else
        echo "[INFO] 未安装模型（可选）：拷到 $ROOT/models/ocr/ 或设 LITE_OCR_MODELS"
    fi
}

# 找一份版本匹配的 onnxruntime 目录；$1 可显式指定目录
pick_dir() {
    local v="$1" explicit="${2:-}" prefer="$3" dir="" 
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        local src; src="$(core_file "$dir")"
        [ -n "$src" ] || continue
        local dv; dv="$(file_version "$src" || true)"
        if [ "$dv" != "$v" ]; then
            echo "skip (版本 ${dv:-?} ≠ $v): $dir" >&2
            continue
        fi
        echo "$dir"; return 0
    done < <(if [ -n "$explicit" ]; then echo "$explicit"; else candidate_dirs "$prefer"; fi)
    return 1
}

# deploy_missing: install 失败提示
_no_ort_helper() {
    local v="$1" prefer="$2"
    if [ "$prefer" = gpu ]; then
        echo "LITE_ORT_PREFER=gpu 但没找到可用的 GPU 版 onnxruntime" >&2
        echo "（需要版本匹配的 providers_cuda + cudnn/cublas；可改用 auto/cpu）" >&2
    fi
    echo "未找到版本 $v 的 onnxruntime（CPU/GPU 都可以）" >&2
    echo "" >&2
    echo "自己下载部署（任选其一）:" >&2
    echo "  1) pip 安装 CPU 版（推荐，22MB，零 CUDA 依赖）:" >&2
    echo "       python3 -m pip install onnxruntime==$v --target /tmp/ort" >&2
    echo "       ./tools/ort_link.sh copy /tmp/ort/onnxruntime/capi" >&2
    echo "  2) 下载官方预编译包，解压后指定 lib 目录:" >&2
    echo "       curl -LO https://github.com/microsoft/onnxruntime/releases/download/v$v/onnxruntime-linux-x64-$v.tgz" >&2
    echo "       tar xf onnxruntime-linux-x64-$v.tgz" >&2
    echo "       ./tools/ort_link.sh copy onnxruntime-linux-x64-$v/lib" >&2
    echo "  3) 已经装在别处: LITE_ORT_DIR=/path/to/lib ./tools/ort_link.sh copy" >&2
    echo "" >&2
    echo "copy 会把 .so 实际拷进 $(basename "$LIBDIR")/（不依赖源路径）；" >&2
    echo "link 只做软链（省空间，但源目录不能删）。" >&2
}

# mode=link 建软链（原行为）；mode=copy 真拷贝（便于分发/移动）
install_ort() {
    local mode="$1" explicit="${2:-}"
    local v; v="$(want_version || true)"
    [ -z "$v" ] && { echo "error: 无法探测 ORT 版本（先放一份 libonnxruntime.so.1）" >&2; exit 1; }

    local prefer; prefer="$(resolve_prefer)"
    echo "选择策略: LITE_ORT_PREFER=${LITE_ORT_PREFER:-auto} -> $prefer" >&2

    local ok; ok="$(pick_dir "$v" "$explicit" "$prefer")" || {
        _no_ort_helper "$v" "$prefer"
        exit 1
    }

    local variant; variant="$(ort_variant "$ok")"
    local src; src="$(core_file "$ok")"
    rm -f "$CORE" "$SHARED" "$PROVIDER"

    if [ "$mode" = copy ]; then
        cp -f "$src" "$CORE"
        [ -f "$ok/libonnxruntime_providers_shared.so" ] \
            && cp -f "$ok/libonnxruntime_providers_shared.so" "$SHARED"
        echo "copied: $CORE <- $src  ($variant)"
    else
        ln -sfn "$src" "$CORE"
        [ -f "$ok/libonnxruntime_providers_shared.so" ] \
            && ln -sfn "$ok/libonnxruntime_providers_shared.so" "$SHARED"
        echo "linked: $CORE -> $src  ($variant)"
    fi

    # 变体决定是否接 CUDA provider：只换核心库不接 provider，运行时依旧是 CPU
    case "$variant" in
        gpu)
            if [ -f "$ok/libonnxruntime_providers_cuda.so" ]; then
                if [ "$mode" = copy ]; then
                    cp -f "$ok/libonnxruntime_providers_cuda.so" "$PROVIDER"
                    echo "copied: $PROVIDER <- $ok/libonnxruntime_providers_cuda.so (329MB)"
                else
                    ln -sfn "$ok/libonnxruntime_providers_cuda.so" "$PROVIDER"
                    echo "linked: $PROVIDER -> $ok/libonnxruntime_providers_cuda.so"
                fi
            else
                echo "warn: $ok 没有 providers_cuda，运行时会退化为 CPU" >&2
            fi
            ;;
        *)
            # 选 CPU 就要彻底摘掉 provider，否则仍会尝试挂 CUDA EP
            rm -f "$PROVIDER"
            ;;
    esac

    if probe; then
        echo "[OK] 实测 OCR 可用"
    else
        rm -f "$CORE" "$SHARED" "$PROVIDER"
        echo "[FAIL] 实测 OCR 加载失败，已回滚（版本/ABI 可能不匹配）" >&2
        exit 1
    fi
}

# OCR 模型（PP-OCRv4）同样不随包：从源码树或下载目录拷到 models/ocr/
install_models() {
    local src="${1:-}"
    local dst="$ROOT/models/ocr"

    if [ -z "$src" ]; then
        # 默认从源码树里的那份拷（dist 场景常见：先解包，再从 clone 拷）
        for cand in "$ROOT/third_party/ocr/models/ocr" "$HOME/lite/third_party/ocr/models/ocr"; do
            if [ -f "$cand/ch_PP-OCRv4_det_infer.onnx" ]; then src="$cand"; break; fi
        done
    fi
    if [ -z "$src" ] || [ ! -f "$src/ch_PP-OCRv4_det_infer.onnx" ]; then
        echo "未找到 PP-OCRv4 模型" >&2
        echo "" >&2
        echo "自己下载部署:" >&2
        echo "  官方模型（det/rec + 字典）:" >&2
        echo "    https://paddleocr.bj.bcebos.com/PP-OCRv4/chinese/ch_PP-OCRv4_det_infer.tar" >&2
        echo "    https://paddleocr.bj.bcebos.com/PP-OCRv4/chinese/ch_PP-OCRv4_rec_infer.tar" >&2
        echo "    https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/main/ppocr/utils/ppocr_keys_v1.txt" >&2
        echo "  解压/改名后应为（.tar 里是 inference.pdmodel 时需先转 onnx）:" >&2
        echo "    $dst/ch_PP-OCRv4_det_infer.onnx" >&2
        echo "    $dst/ch_PP-OCRv4_rec_infer.onnx" >&2
        echo "    $dst/ppocr_keys_v1.txt" >&2
        echo "" >&2
        echo "有现成目录则: ./tools/ort_link.sh models /path/to/models/ocr" >&2
        exit 1
    fi

    mkdir -p "$dst"
    cp -f "$src/ch_PP-OCRv4_det_infer.onnx" "$src/ch_PP-OCRv4_rec_infer.onnx" \
          "$src/ppocr_keys_v1.txt" "$dst/" 2>/dev/null
    echo "copied models -> $dst"
    ls -lh "$dst"
}

unlink_libs() {
    for f in "$CORE" "$SHARED" "$PROVIDER"; do
        if [ -L "$f" ]; then rm -f "$f"; echo "unlinked: $f"; fi
    done
}

case "${1:-status}" in
    status) status ;;
    link)   shift || true; install_ort link "${1:-}" ;;
    copy)   shift || true; install_ort copy "${1:-}" ;;
    models) shift || true; install_models "${1:-}" ;;
    unlink) unlink_libs ;;
    *) echo "用法: $0 [status|link [dir]|copy [dir]|models [dir]|unlink]" >&2; exit 2 ;;
esac
