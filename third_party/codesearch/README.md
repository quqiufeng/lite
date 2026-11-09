# third_party/codesearch

从 `/opt/my_db` 迁入、现在由 lite 自己维护的第三方/预编译资产。
目的是让 `src/codesearch/` **不再依赖 `/opt/my_db` 目录**。

## 内容

| 路径 | 来源 | 说明 |
|---|---|---|
| `include/onnxruntime_c_api.h` | ONNX Runtime 1.20.1 | 编译期头文件；运行期仍 `dlopen` `LITE_ORT_LIB` |
| `include/tokenizers-cpp/tokenizers_c.h` | tokenizers-cpp | tokenizer C API 头文件 |
| `include/tokenizers-cpp/tokenizers_cpp.h` | tokenizers-cpp | C++ API 头文件 |
| `lib/tokenizers-cpp/libtokenizers_c.a` | tokenizers-cpp（预编译） | Rust tokenizers 静态库 |
| `lib/tokenizers-cpp/libtokenizers_cpp.a` | 同上 | C++ 封装 |
| `lib/tokenizers-cpp/libsentencepiece.a` | 同上 | SentencePiece |
| `lib/tokenizers-cpp/libonig.a` | 同上 | Oniguruma（tokenizers 正则） |
| `lib/tokenizers-cpp/LICENSE` | tokenizers-cpp | 上游许可证 |
| `tokenizers-cpp/` | 上游固定 commit | 完整源码 + sentencepiece/msgpack 子模块（可离线重建） |
| `tools/build-tokenizers.sh` | 本仓库脚本 | 从仓库内源码重建上述 `.a` |
| `plugins/typescript-indexer/` | `/opt/my_db/plugins/typescript-indexer/` | tree-sitter TS/JS 切块插件；二进制已预编译，`plugin.json` 用相对 `command` |

这些 `.a` 在链接时被静态并入 `build/liblite_codesearch.so`，所以**运行时不需要**
`third_party/codesearch/lib/`，也不需要 `/opt/my_db`；保留它们只是为了重新构建。
普通构建直接用预编译 `.a`；要升级/换架构时运行 `tools/build-tokenizers.sh`，
默认从仓库内 `tokenizers-cpp/` 源码做 out-of-tree 构建（`.build/` 已 gitignore）。

## 不在这里的依赖

以下仍是机器级外部依赖，不随仓库携带：

- ONNX Runtime：`LITE_ORT_LIB` 指向 `libonnxruntime.so.1`（默认 `/data/venv/.../1.20.1/`）
- 模型：`LITE_CS_MODEL_DIR`（默认 `/opt/models`，Jina / MPNet）
- CUDA / cuDNN：`/data/cuda/lib64`、`/data/venv/lib/python3.12/site-packages/nvidia/cudnn/lib`
- `ctags`：系统 `Universal Ctags`

不使用 TensorRT。

## 更新

- tokenizers 静态库：`./third_party/codesearch/tools/build-tokenizers.sh`
  （默认用仓库内源码；也可 `TOKENIZERS_CPP_SRC=外部源码`），完成后重新 `./tools/build.sh`。
- TypeScript 插件：在 `plugins/typescript-indexer/` 下 `make`（需要
  `/opt/tree-sitter` 与 `/opt/tree-sitter-typescript`），或直接替换
  `bin/typescript-indexer`。

各上游项目的许可证见其原始项目；这里只保留构建/运行所需的二进制与头文件。
