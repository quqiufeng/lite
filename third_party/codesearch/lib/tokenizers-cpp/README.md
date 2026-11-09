# tokenizers-cpp 静态库

这里放的是 tokenizers-cpp 的**预编译静态库**，`CMakeLists.txt` 默认直接链接它们：

```
libtokenizers_c.a       # HuggingFace tokenizers Rust 核心
libtokenizers_cpp.a     # C++ 包装层
libsentencepiece.a      # SentencePiece
libonig.a               # Oniguruma（tokenizers 正则）
```

正常情况下**不需要源码，也不需要重新构建**；`liblite_codesearch.so` 已经静态链接它们。

## 需要重新构建时

源码已随仓库放在 `third_party/codesearch/tokenizers-cpp/`
（上游 + sentencepiece/msgpack 子模块，固定 commit 见其 `SOURCE.txt`）。
重新构建：

```bash
./third_party/codesearch/tools/build-tokenizers.sh
```

要求：

- `cmake >= 3.19`、C++17 编译器
- `Rust` / `cargo`（tokenizers 核心）
- 可选 `JOBS=N` 控制并行度
- `git` 只在用外部源码时才需要

脚本行为：

1. 默认使用仓库内 `third_party/codesearch/tokenizers-cpp/`
2. 在 `third_party/codesearch/.build/tokenizers-build/` 做 out-of-tree CMake 构建
3. 把 4 个 `.a` 复制回本目录，头文件复制到
   `third_party/codesearch/include/tokenizers-cpp/`
4. 写 `SOURCE.txt` 记录上游 commit / 构建时间

用外部源码副本（不修改仓库内源码）：

```bash
TOKENIZERS_CPP_SRC=/path/to/tokenizers-cpp \
  ./third_party/codesearch/tools/build-tokenizers.sh
```

`TOKENIZERS_CPP_REV` 只对“外部源码不存在、脚本临时 clone”的路径生效。

构建完重新编译 lite：

```bash
./tools/build.sh
```

## 与运行时依赖的边界

这些 `.a` 在链接时被并入 `build/liblite_codesearch.so`，**运行时不需要本目录**。
CUDA / ONNX Runtime / 模型仍走外部路径（`LITE_ORT_LIB`、`LITE_CS_MODEL_DIR`），
与本静态库无关。
