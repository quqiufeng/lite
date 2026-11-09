# third_party/codesearch

从 `/opt/my_db` 迁入、现在由 lite 自己维护的第三方/预编译资产。
目的是让 `src/codesearch/` **不再依赖 `/opt/my_db` 目录**。

## 内容

| 路径 | 来源 | 说明 |
|---|---|---|
| `include/onnxruntime_c_api.h` | ONNX Runtime 1.20.1 | 编译期头文件；运行期仍 `dlopen` `LITE_ORT_LIB` |
| `include/tokenizers-cpp/tokenizers_c.h` | tokenizers-cpp | tokenizer C API 头文件 |
| `lib/tokenizers-cpp/libtokenizers_c.a` | `/opt/my_db/lib/tokenizers-cpp/` | Rust tokenizers 静态库 |
| `lib/tokenizers-cpp/libtokenizers_cpp.a` | 同上 | C++ 封装 |
| `lib/tokenizers-cpp/libsentencepiece.a` | 同上 | SentencePiece |
| `lib/tokenizers-cpp/libonig.a` | 同上 | Oniguruma（tokenizers 正则） |
| `plugins/typescript-indexer/` | `/opt/my_db/plugins/typescript-indexer/` | tree-sitter TS/JS 切块插件；二进制已预编译，`plugin.json` 用相对 `command` |

这些 `.a` 在链接时被静态并入 `build/liblite_codesearch.so`，所以**运行时不需要**
`third_party/codesearch/lib/`，也不需要 `/opt/my_db`；保留它们只是为了重新构建。

## 不在这里的依赖

以下仍是机器级外部依赖，不随仓库携带：

- ONNX Runtime：`LITE_ORT_LIB` 指向 `libonnxruntime.so.1`（默认 `/data/venv/.../1.20.1/`）
- 模型：`LITE_CS_MODEL_DIR`（默认 `/opt/models`，Jina / MPNet）
- CUDA / cuDNN：`/data/cuda/lib64`、`/data/venv/lib/python3.12/site-packages/nvidia/cudnn/lib`
- TensorRT：`/opt/TensorRT-10/lib`（默认关闭，版本不兼容）
- `ctags`：系统 `Universal Ctags`

## 更新

- tokenizers 静态库：替换 `lib/tokenizers-cpp/*.a` 后重新
  `./tools/build.sh`（或 `cmake --build build`）。
- TypeScript 插件：在 `plugins/typescript-indexer/` 下 `make`（需要
  `/opt/tree-sitter` 与 `/opt/tree-sitter-typescript`），或直接替换
  `bin/typescript-indexer`。

各上游项目的许可证见其原始项目；这里只保留构建/运行所需的二进制与头文件。
