#!/usr/bin/env bash
# 重新构建 third_party/codesearch/lib/tokenizers-cpp/*.a
#
# 源码已随仓库放在 third_party/codesearch/tokenizers-cpp/（含 sentencepiece/msgpack）。
# 只有升级 tokenizers-cpp / 换架构时才需要跑本脚本。
# 需要：cmake >= 3.19、C++17 编译器、Rust/cargo（git 仅外部源码时需要）。
#
# 用法：
#   third_party/codesearch/tools/build-tokenizers.sh
#   TOKENIZERS_CPP_SRC=/path/to/external/clone third_party/codesearch/tools/build-tokenizers.sh
#   TOKENIZERS_CPP_REV=<sha> third_party/codesearch/tools/build-tokenizers.sh   # 仅外部 clone 生效
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEST_LIB="$ROOT/third_party/codesearch/lib/tokenizers-cpp"
DEST_INC="$ROOT/third_party/codesearch/include/tokenizers-cpp"
SRC="${TOKENIZERS_CPP_SRC:-$ROOT/third_party/codesearch/tokenizers-cpp}"
BUILD="${TOKENIZERS_CPP_BUILD:-$ROOT/third_party/codesearch/.build/tokenizers-build}"
REV="${TOKENIZERS_CPP_REV:-c586c52f93f7b060753bd2388eb96a105cb7374d}"
JOBS="${JOBS:-$(nproc)}"

mkdir -p "$DEST_LIB" "$DEST_INC" "$BUILD" "$(dirname "$SRC")"

if [ ! -f "$SRC/CMakeLists.txt" ]; then
    echo "== no vendored source at $SRC; clone $REV"
    if [ ! -d "$SRC/.git" ]; then
        git clone --recursive https://github.com/mlc-ai/tokenizers-cpp.git "$SRC"
    fi
    git -C "$SRC" fetch --tags origin
    git -C "$SRC" checkout "$REV"
    git -C "$SRC" submodule update --init --recursive
else
    echo "== using source at $SRC"
fi

echo "== cmake build (-j$JOBS) -> $BUILD"
cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD" -j"$JOBS"

TOK_C="$BUILD/libtokenizers_c.a"
TOK_CPP="$BUILD/libtokenizers_cpp.a"
SP="$(find "$BUILD" -path '*/sentencepiece/src/libsentencepiece.a' | head -n1)"
ONIG="$(find "$BUILD" -path '*onig_sys*/out/libonig.a' | head -n1)"

for f in "$TOK_C" "$TOK_CPP" "$SP" "$ONIG"; do
    if [ -z "$f" ] || [ ! -f "$f" ]; then
        echo "ERROR: build output not found (TOK_C=$TOK_C TOK_CPP=$TOK_CPP SP=$SP ONIG=$ONIG)" >&2
        exit 1
    fi
done

echo "== install static libs"
cp "$TOK_C" "$TOK_CPP" "$SP" "$ONIG" "$DEST_LIB/"
cp "$SRC/include/tokenizers_c.h" "$SRC/include/tokenizers_cpp.h" "$DEST_INC/"
if [ -f "$SRC/LICENSE" ]; then cp "$SRC/LICENSE" "$DEST_LIB/LICENSE"; fi

cat > "$DEST_LIB/SOURCE.txt" <<EOF
tokenizers-cpp
repo: https://github.com/mlc-ai/tokenizers-cpp
commit: $REV
built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
host: $(uname -m)
EOF

echo "== done"
ls -lh "$DEST_LIB"/*.a "$DEST_INC"/*.h
