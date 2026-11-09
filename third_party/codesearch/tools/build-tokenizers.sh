#!/usr/bin/env bash
# 重新构建 third_party/codesearch/lib/tokenizers-cpp/*.a
#
# 仓库里已经有预编译静态库；只有升级 tokenizers-cpp / 换架构时才需要跑本脚本。
# 需要：git、cmake >= 3.19、C++17 编译器、Rust/cargo。
#
# 用法：
#   third_party/codesearch/tools/build-tokenizers.sh
#   TOKENIZERS_CPP_SRC=/path/to/existing/clone third_party/codesearch/tools/build-tokenizers.sh
#   TOKENIZERS_CPP_REV=<commit> third_party/codesearch/tools/build-tokenizers.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEST_LIB="$ROOT/third_party/codesearch/lib/tokenizers-cpp"
DEST_INC="$ROOT/third_party/codesearch/include/tokenizers-cpp"
SRC="${TOKENIZERS_CPP_SRC:-$ROOT/third_party/codesearch/.build/tokenizers-cpp}"
REV="${TOKENIZERS_CPP_REV:-c586c52f93f7b060753bd2388eb96a105cb7374d}"
JOBS="${JOBS:-$(nproc)}"

mkdir -p "$DEST_LIB" "$DEST_INC" "$(dirname "$SRC")"

if [ ! -d "$SRC/.git" ]; then
    echo "== clone tokenizers-cpp -> $SRC"
    git clone --recursive https://github.com/mlc-ai/tokenizers-cpp.git "$SRC"
fi

echo "== checkout $REV + submodules"
git -C "$SRC" fetch --tags origin
git -C "$SRC" checkout "$REV"
git -C "$SRC" submodule update --init --recursive

echo "== cmake build (-j$JOBS)"
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$SRC/build" -j"$JOBS"

TOK_C="$SRC/build/libtokenizers_c.a"
TOK_CPP="$SRC/build/libtokenizers_cpp.a"
SP="$(find "$SRC/build" -path '*/sentencepiece/src/libsentencepiece.a' | head -n1)"
ONIG="$(find "$SRC/build" -path '*onig_sys*/out/libonig.a' | head -n1)"

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
