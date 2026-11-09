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

仓库**不携带** tokenizers-cpp 源码（上游源码 + sentencepiece/msgpack 子模块约 60MB）。
用脚本按固定 commit 拉取并构建：

```bash
./third_party/codesearch/tools/build-tokenizers.sh
```

要求：

- `git`、`cmake >= 3.19`、C++17 编译器
- `Rust` / `cargo`（tokenizers 核心）
- 能访问 `https://github.com/mlc-ai/tokenizers-cpp`
- 可选 `JOBS=N` 控制并行度

脚本行为：

1. clone 到 `third_party/codesearch/.build/tokenizers-cpp`（已 gitignore）
2. checkout 固定 commit + 初始化 sentencepiece/msgpack 子模块
3. `cmake -DCMAKE_BUILD_TYPE=Release` 构建
4. 把 4 个 `.a` 复制回本目录，头文件复制到
   `third_party/codesearch/include/tokenizers-cpp/`
5. 写 `SOURCE.txt` 记录上游 commit / 构建时间

已有源码副本时：

```bash
TOKENIZERS_CPP_SRC=/path/to/tokenizers-cpp \
  ./third_party/codesearch/tools/build-tokenizers.sh
```

换 commit：

```bash
TOKENIZERS_CPP_REV=<sha> ./third_party/codesearch/tools/build-tokenizers.sh
```

构建完重新编译 lite：

```bash
./tools/build.sh
```

## 与运行时依赖的边界

这些 `.a` 在链接时被并入 `build/liblite_codesearch.so`，**运行时不需要本目录**。
CUDA / ONNX Runtime / 模型仍走外部路径（`LITE_ORT_LIB`、`LITE_CS_MODEL_DIR`），
与本静态库无关。
