# lite codesearch

代码索引 / 调用图 / 数据流 / 语义检索模块。实现从 `/opt/my_db` 迁移而来，但在 lite 里
被改造成**一个共享库 + JSON API + LuaJIT FFI + helper 插件**：没有外部 CLI、没有子进程
流水线，所有入口都在同一进程内完成。

```
ctags 切块 ──► 词频 ──► 调用图 ──► 数据流 ──► KV 导入 ──► 向量化 ──► HNSW
   index      word_freq  callgraph  dataflow    import      vectorize   hnsw
```

- 词法 / 符号 / 调用图 / 数据流只依赖 `ctags` + `jansson`，不需要 GPU。
- 语义搜索额外依赖 ONNX Runtime、Jina 模型和 CUDA（或 CPU）。
- 数据按项目隔离，默认在 `~/.local/share/lite/codesearch/<project>/`，与 lite 的
  `mem.bin` 记忆库互不影响。
- **KV 导入直接用 lite 自带的 kvcache**（`src/cache/` 的 `cache_open` /
  `cache_batch_set`，落盘为 `kv/mem.bin` + `kv/mem.idx`），不是 `/opt/my_db` 的
  KV 实现；`symbol/context/exact` 查的也是这份 cache。

---

## 0. 快速开始（5 分钟）

### 0.1 它是什么

codesearch 把任意代码仓库变成可查询的索引：

- `build`：切块 → 词频 → 调用图 → 数据流 → KV → 向量/HNSW
- `search`：自然语言找实现（语义 + 关键词）
- `symbol`：按符号名精确找定义
- `context`：看 callers / callees / 调用链 / dataflow

索引默认在 `~/.local/share/lite/codesearch/<project>/`，不碰 lite 的会话记忆。

### 0.2 创建索引

agent 里最简单：

```text
codesearch action=build path=/path/to/repo
```

`project` 默认取仓库目录名；要自定义：

```text
codesearch action=build path=/path/to/repo project=myproj
```

shell 里（不经过模型）：

```bash
R=/home/quqiufeng/Desktop/lite
cd /path/to/repo
$R/tools/lua.sh -e '
local H = dofile(os.getenv("LITE_ROOT") .. "/helper/codesearch.lua")
print(H.run({ action = "build", path = "." }, { cwd = os.getenv("PWD") }))
'
```

默认值已经够用：FP16、batch 128、串行索引。常用加速：

```text
codesearch action=build path=. fork=true
```

- `fork=true`：多进程切块（fresh 进程更快；已加载 ORT 的会话慎用）
- `workers=N`：进程数，默认 1；`fork=true` 时默认 CPU 核数
- `vector=false`：只建索引/调用图/数据流，不做语义
- 大仓库：`excludes=node_modules,dist,build`；
  内核类仓库：`excludes=drivers,Documentation skip_kinds=header,file,enumerator,macro`
- TypeScript/JavaScript：`plugins=/绝对路径/third_party/codesearch/plugins/typescript-indexer/plugin.json`

重复 build 会走增量：源文件没变时跳过模型和 HNSW，通常几秒完成。
第一次大仓库 build 主要耗在 vectorize + HNSW；之后增量很快。

### 0.3 探索源码（最简流程）

1. **确认索引**

```text
codesearch action=status project=myproj
```

2. **架构扫描：自然语言找入口**

```text
codesearch action=search query="event loop request handling" max_results=5
codesearch action=search query="configuration parsing" max_results=5
```

3. **钉住符号：精确查定义**

```text
codesearch action=symbol query="schedule"
codesearch action=symbol query="vfs_read"
```

4. **看关系：callers / callees / 调用链 / dataflow**

```text
codesearch action=context query="vfs_read" depth=2
```

5. **读源码 + 验证**

拿到 `file:symbol` 后直接读文件；真正要下结论时，用 build/测试/断点验证。
`search/context` 都是静态证据，不要直接当运行时真相。

### 0.4 最简单的最佳实践

```text
status
  → search（2–5 条自然语言，找子系统入口）
  → symbol（把关键标识符钉成 file:symbol）
  → context depth=1..3（看主线 callers/callees）
  → 读源码 / 跑测试验证
```

- 先横向（架构入口），再纵向（一条调用链），不要一上来翻目录。
- `search` 是近似召回，会受同名/分片影响；**精确定位优先 `symbol`/`exact`**。
- 引用统一写 `file:symbol`，行号只作参考。
- 大项目先 `status` 确认 chunks/向量/KV 齐全，再开始探索。
- 同一进程内连续查询很快；每次新起 shell 进程是冷启动（内核索引首次约 4–10s）。

更详细的索引参数、依赖、性能数据和 Linux 内核实录见 §4、§5 和
`CODE_READING_REPORT.md`。

---

## 1. 目录与产物

实现全部在 `src/codesearch/`：

| 文件 | 作用 |
|---|---|
| `api.c` | 公共 JSON API：`lite_cs_*`；参数整理、目录创建、stdout 捕获 |
| `indexer.c` | ctags 扫描 / 切块；串行或 fork 多进程 |
| `word_freq.c` | TF-IDF 词频 |
| `callgraph.c` | 调用图 |
| `dataflow.c` | 变量 / 字段级数据流 |
| `import.c` | 把 chunks / 符号 / 调用图 / 数据流写入 lite KV |
| `embedder.c` | ONNX Runtime、tokenizer、CUDA / CPU EP、FP16 输出 |
| `batch_embedder.c` | 长度分桶批量向量化、增量缓存、HNSW 构建编排 |
| `vector_engine.c` | 查询侧向量引擎 |
| `query.c` | 符号 / 上下文 / 语义 / 精确 key 查询 |
| `hnsw_build.c` | HNSW 建图 |
| `codesearch.h` | 对外 C API |
| `cs_internal.h` / `cs_compat.h` | 内部入口声明；把原 CLI 的 stdout 日志改到 stderr |

Lua 侧：

- `lua/ffi/codesearch.lua`：FFI 封装，JSON → Lua 表。
- `helper/codesearch.lua`：agent 工具 `codesearch`，负责路径、编排和文本摘要。

构建产物：`build/liblite_codesearch.so`。

### 每个项目的目录

```
$LITE_CS_HOME/<project>/                 # 默认 ~/.local/share/lite/codesearch/<project>
├── chunks_meta.jsonl                    # 每个 chunk 的 name/file/kind/line/signature/content
├── chunks_text.txt                      # 与 meta 行对齐的纯文本（向量化输入）
├── word_freq.json
├── call_graph.json
├── dataflow.json
├── plugin_output.jsonl                  # 使用 --plugins 时可能产生
├── kv/                                  # lite 自带 kvcache：mem.bin / mem.idx
└── vectors/
    ├── code_local_<project>.jina.bin    # 向量（header + name + float[768]）
    ├── code_local_<project>.jina.idx    # name -> offset
    ├── code_local_<project>.jina.hash   # 增量缓存：name + 文本哈希（sidecar）
    └── code_local_<project>.jina.bin.hnsw
```

`$LITE_CS_HOME` 可覆盖根目录；`analysis_dir` / `kv_dir` 也可在工具参数里单独覆盖。
namespace 默认是 `/code/<project>`。

`import.c` 的 `cache_open/cache_batch_set/cache_get` 全部链接仓库里的 `lite_cache`
（`src/cache/`），所以 `kv/` 就是 lite kvcache 的一个普通数据库目录，
和 lite 会话记忆用的是同一套存储实现，只是目录和 namespace 不同。
每次 import 默认以 8 GiB 逻辑内存上限 `cache_open`（`LITE_CS_KV_MAX_GB` 可调），
批量写入后 `cache_sync` 落盘。

---

## 2. 依赖全景

### 2.1 编译依赖

| 依赖 | 当前机器路径 | 说明 |
|---|---|---|
| C/C++ 工具链 + CMake | 系统 | `.so` 用 C++ 链接（tokenizers 静态库需要） |
| `jansson` | 系统 `libjansson`，2.14 | JSON 解析；缺失则跳过整个 target |
| `tokenizers-cpp` 静态库 | `third_party/codesearch/lib/tokenizers-cpp/` | `libtokenizers_c.a`、`libtokenizers_cpp.a`、`libsentencepiece.a`、`libonig.a`，随仓库自带 |
| `tokenizers-cpp` 源码 | `third_party/codesearch/tokenizers-cpp/` | 固定 commit + sentencepiece/msgpack 子模块；`tools/build-tokenizers.sh` 可离线重建上述 `.a` |
| TypeScript 插件（可选） | `third_party/codesearch/plugins/typescript-indexer/` | 预编译二进制 + 源码；`plugin.json` 用相对 `command` |
| ONNX Runtime 头文件 | `third_party/codesearch/include/onnxruntime_c_api.h` | 已 vendor，编译期不依赖 ORT 安装 |
| tokenizers 头文件 | `third_party/codesearch/include/tokenizers-cpp/tokenizers_c.h` | 已 vendor |
| `lite_cache` | 仓库内 `include/` + CMake target | KV 写入 / 查询 |

普通构建只用预编译 `.a`，**不需要 tokenizers 源码**；升级/换架构时运行
`./third_party/codesearch/tools/build-tokenizers.sh`（默认用仓库内源码做 out-of-tree 构建）。
CMake 默认从 `third_party/codesearch/lib/tokenizers-cpp` 找静态库；找不到会打印

```
lite_codesearch disabled: tokenizers static lib or jansson not found
```

并跳过该 target，其余 lite 功能不受影响。换路径：

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
      -DLITE_CS_TOKENIZERS_DIR=/path/to/tokenizers-cpp
cmake --build build -j"$(nproc)"
```

普通构建直接 `./tools/build.sh`；依赖检查 `./tools/check_deps.sh`。

### 2.2 索引期依赖

| 依赖 | 作用 | 缺失后果 |
|---|---|---|
| `ctags` / Universal Ctags | 切函数 / 结构体 / 宏 / typedef | `index` 不可用 |
| `jansson` | 输出和 KV 导入 | 链接失败 |
| 可选 `--plugins plugin.json` | TypeScript 等自定义切块 | 只用默认切块 |

本机：`Universal Ctags 5.9.0`。默认会跳过这些目录：
`thirdparty/3rdparty/third_party/external/deps/vendor/build/out/obj/test/tests/
examples/docs/scripts/tools/utils/benchmark/node_modules/.git/__pycache__` 等。
注意 **`tools/`、`tests/` 默认不索引**；`--exclude-dir` 只能继续加，不能减。
要索引这些目录，需要改 `indexer.c` 的 `noise[]`，或单独把子目录当仓库索引。

### 2.3 语义检索依赖

| 依赖 | 当前机器路径 | 说明 |
|---|---|---|
| ONNX Runtime GPU | `/data/venv/onnxruntime-linux-x64-gpu-1.20.1/lib/libonnxruntime.so.1` | 运行期 `dlopen`，**不链接** |
| 备选 ONNX Runtime | `/data/venv/onnxruntime-linux-x64-gpu-1.26.0/lib/libonnxruntime.so.1` | 可用；`LITE_ORT_LIB` 指定 |
| CUDA Runtime / cuBLAS / cuRAND / cuFFT / NVRTC | `/data/cuda/lib64`（CUDA 12.6） | ORT CUDA EP 依赖 |
| cuDNN 9 | `/data/venv/lib/python3.12/site-packages/nvidia/cudnn/lib` | 启动时由 embedder 预加载 |
| Jina 模型 | `/opt/models/jina-embeddings-v2-base-code/` | 默认 768 维、最大 512 token |
| MPNet（可选） | `/opt/models/all-mpnet-base-v2/` | 备选 768 维、最大 128 token |

CUDA 库是否齐，看：

```bash
nvidia-smi
ls /data/cuda/lib64/libcudart.so.12 /data/cuda/lib64/libcublas.so.12
ls /data/venv/lib/python3.12/site-packages/nvidia/cudnn/lib/libcudnn.so.9
```

embedder 启动时会用 `RTLD_GLOBAL` 预加载：

- `/data/venv/lib/python3.12/site-packages/nvidia/cudnn/lib`
- 额外的 `LITE_CS_PRELOAD_DIRS`（冒号分隔，只给高级调试用）

ORT 自己的 provider `.so` 不预加载，交给 ORT 按需加载，避免单独 `dlopen` 时构造顺序崩溃。

如果 CUDA 报 `not found`，让进程能找到 CUDA 运行库（本机 CUDA 12.6）：

```bash
export LD_LIBRARY_PATH=/data/cuda/lib64:$LD_LIBRARY_PATH
export LITE_ORT_LIB=/data/venv/onnxruntime-linux-x64-gpu-1.20.1/lib/libonnxruntime.so.1
```

cuDNN 库由 embedder 自己预加载，一般不需要再写进 `LD_LIBRARY_PATH`。

### 2.4 模型

默认模型目录 `/opt/models`，可用 `LITE_CS_MODEL_DIR` 覆盖。

**Jina v2 code（默认，推荐）**

```
/opt/models/jina-embeddings-v2-base-code/
├── model.onnx      -> /opt/jina-embeddings-v2-base-code/onnx/model.onnx        (~640 MB, FP32)
├── vocab.json      -> /opt/jina-embeddings-v2-base-code/vocab.json
└── merges.txt      -> /opt/jina-embeddings-v2-base-code/merges.txt
```

真实目录里还有：

| 文件 | 大小 | 说明 |
|---|---|---|
| `model.onnx` | ~640 MB | FP32；FP16 不可用时回退 |
| `model_fp16.onnx` | ~320 MB | FP16；建索引和查询默认用它，GPU 约快 1.5x，向量与 FP32 cosine ≈ 0.999998 |
| `model_quantized.onnx` | ~160 MB | INT8；在 CUDA 上大量算子回落 CPU，实测比 FP32 慢几十倍，**不推荐** |

**FP16 建索引和查询编码都默认开启**（`LITE_CS_FP16=0` 或 `fp16=false` 关闭；
`LITE_CS_MODEL_FILE` 可显式指定模型文件）。代码先找
`<model_dir>/jina-embeddings-v2-base-code/model_fp16.onnx`；若不存在，会沿
`model.onnx` 的软链 `realpath` 到真实目录，再找同目录的 `model_fp16.onnx`。
所以本机不用手工建软链；模型缺失时自动回退 `model.onnx`。

**MPNet（可选）**

`LITE_CS_MODEL_DIR/all-mpnet-base-v2/model.onnx` + `vocab.txt`，768 维、最大 128 token。
本机当前未安装，默认不用。

模型切换（Jina ↔ MPNet、FP32 ↔ FP16）会自动让增量缓存失效：cache tag 由
模型路径 + 文件大小 + mtime 计算。

### 2.5 TensorRT / flash-attention

**不使用 TensorRT，也不加载 flash-attention。** GPU 只走 CUDA + FP16；
不预加载 `/opt/TensorRT-10/lib`，没有 `libnvinfer*` 运行时依赖。
TensorRT 之前实测在该工作负载下比 CUDA 慢且版本耦合严重，代码路径已移除。

### 2.6 环境变量速查

| 变量 | 默认 | 作用 |
|---|---|---|
| `LITE_CS_HOME` | `~/.local/share/lite/codesearch` | 项目数据根目录（helper 使用） |
| `LITE_CS_MODEL_DIR` | `/opt/models` | 模型根目录 |
| `LITE_CS_MODEL_FILE` | 空 | 覆盖模型文件名；绝对路径可直接指定 |
| `LITE_CS_FP16` | 开 | `0` = 关闭 FP16，用 `model.onnx` |
| `LITE_CS_BATCH` | `128` | 向量化 batch 大小 |
| `LITE_CS_FORK` | 关 | `1` = index 用 fork 多进程 |
| `LITE_CS_HNSW_THREADS` | `8` | HNSW 建图线程数 |
| `LITE_CS_HNSW_EF` | `200` | HNSW `ef_construction`；降到 100 建图约快一倍 |
| `LITE_CS_HNSW_M` | `16` | HNSW `M` |
| `LITE_CS_DISABLE_VECTOR` | 关 | helper `build` 时跳过向量化 |
| `LITE_CS_KV_MAX_GB` | `8` | import 时 KV 逻辑内存上限（大仓库可调） |
| `LITE_ORT_LIB` | ORT 1.20.1 路径 | 指定 ONNX Runtime `.so.1` |
| `LITE_CS_PRELOAD_DIRS` | 空 | 额外预加载目录，冒号分隔（高级调试） |

---

## 3. 构建与自检

```bash
./tools/build.sh             # 构建 build/liblite_codesearch.so（以及 cache/image 等）
./tools/check_deps.sh        # 看 tokenizers / jansson / ctags / 模型 / ORT
./tools/run.sh plugins       # 确认 codesearch 插件已加载、无 schema 错误
```

如果只想快速验证库：

```bash
./tools/lua.sh -e 'local CS=require("ffi.codesearch"); print(CS.available, CS.path)'
```

`cs.check(path)` / `action=status` 会报告 chunks、词频、调用图、数据流、向量文件和模型状态。

---

## 4. 创建索引

### 4.1 一条命令：`build`

agent 会话里：

```text
codesearch action=build path=/path/to/project
```

等价 shell（不经过模型）：

```bash
R=/home/quqiufeng/Desktop/lite
cd /path/to/project
$R/tools/lua.sh -e '
local H = dofile(os.getenv("LITE_ROOT") .. "/helper/codesearch.lua")
print(H.run({ action = "build", path = "." }, { cwd = os.getenv("PWD") }))
'
```

`build` 依次执行：

1. `index`：ctags 切块 → `chunks_meta.jsonl` / `chunks_text.txt`
2. `word_freq`：TF-IDF → `word_freq.json`
3. `callgraph`：`call_graph.json`
4. `dataflow`：`dataflow.json`
5. `import`：符号 / 调用图 / 数据流 / chunks 写入 `kv/`
6. `vectorize`：Jina 向量 → `.bin/.idx/.hash`，然后建 HNSW
7. 最后打印 `status`

常用参数：

| 参数 | 说明 |
|---|---|
| `path` | 仓库路径，默认当前目录 |
| `project` | 项目名；默认取目录名；决定数据目录和 `/code/<project>` |
| `workers` | index 进程/分片数；默认 1；`fork=true` 时默认 CPU 核数 |
| `fork` | 多进程切块；fresh 进程更快（见下方注意） |
| `excludes` | 追加跳过目录，逗号分隔 |
| `skip_kinds` | 按 ctags kind 过滤，如 `header,file,enumerator,macro` |
| `include_dirs` | 把默认 noise 目录重新纳入，如 `tools,utils` |
| `plugins` | ctags 插件 registry JSON 路径（可选） |
| `model` | `jina`（默认）或 `mpnet` |
| `fp16` | 用 `model_fp16.onnx`；默认开，`false` 关闭 |
| `batch` | 向量化 batch，默认 128 |
| `vector` | `false` = 只建索引/调用图/数据流，不向量化 |
| `analysis_dir` / `kv_dir` | 覆盖数据目录 |

示例：

```text
codesearch action=build path=/opt/nginx project=nginx fork=true fp16=true
codesearch action=build path=. project=demo vector=false
```

TypeScript / JavaScript 项目可加 tree-sitter 插件（已随仓库自带）：

```text
codesearch action=build path=/path/to/ts-project \
  plugins=/home/quqiufeng/Desktop/lite/third_party/codesearch/plugins/typescript-indexer/plugin.json
```

`plugin.json` 里的 `command` 是相对路径，indexer 会按 JSON 所在目录解析，不写死
`/opt` 绝对路径。

### 4.2 分步执行

只想切块：

```text
codesearch action=index path=. fork=true
```

只想更新 KV：

```text
codesearch action=import project=demo
```

### 4.3 增量与缓存

向量化带**增量缓存**：

- 每条向量在 `vectors/*.jina.hash` 里记录 `name + 文本哈希`。
- 下次 `build` 时，同名且文本哈希一致的 chunk 直接复用旧向量；
  只有新增/修改的 chunk 才进模型。
- 如果所有 chunk 都没变，且记录数与旧索引一致：**不加载模型、不重写 bin、不重建 HNSW**，
  直接返回。
- 有任意改动时会重建 HNSW（当前没有图级增量插入）。

因此：

- 重复索引同一个未修改项目，通常 < 1 秒。
- 改几个文件只重嵌那几个 chunk，但 HNSW 仍会整体重建。
- 想强制全量：删 `analysis/vectors/`，或删整个项目目录。
- `.bin/.idx/.hash` 先写 `.tmp.<pid>`，成功后 `rename`；中断不会破坏旧索引。
- 注意：如果删掉了源文件，当前 chunk 集合变少，`old_count != total_processed`，
  会走重写路径并重建 HNSW，避免留下已删除代码的旧向量。

### 4.4 fork 注意事项

`fork=true` / `LITE_CS_FORK=1` 用的是**原始 `fork()`**，不是 `fork+exec`。

- 刚启动的 CLI / `tools/lua.sh` 进程里通常安全，切块几乎线性加速。
- 如果当前进程已经加载过 ORT（例如 TUI 里先做过语义搜索），子进程只继承调用线程，
  有死锁风险。此时用默认串行，或换一个新进程执行。
- `workers=N` 只是分片数；没有 `fork=true` 时仍然是串行处理这些分片。

### 4.5 实测

RTX 3080 20GB / 6 核：

| 场景 | 耗时 |
|---|---|
| 54,946 chunks，index 串行 | 1.47s |
| 54,946 chunks，index fork 6 进程 | 0.39s |
| 920 chunks，FP32 batch 128 向量化 | ~0.8s 编码 |
| 920 chunks，FP16 batch 128 向量化 | ~0.6s 编码（约 1.5x） |
| 55k chunks，FP16 首次向量化 | ~33s 编码 + HNSW 建图 |
| 55k chunks，源文件未变再次 build | ~0.3s（跳过模型和 HNSW） |
| 920 chunks，完整 build 首次 / 再次 | 2.1s / 0.03s |

首次大项目的主要成本通常在 HNSW 建图；可用 `LITE_CS_HNSW_EF=100` 换速度。

### 4.6 Linux 内核 7.2.12 索引过程记录

#### 目标与环境

- 源码：`/opt/linux/src/linux-7.2.12`（Linux 7.2.12）
- 旧索引：`/opt/code_caches/linux_723_cache`（7.2.3，5.2GB，不含 drivers）已删除
- 新索引：`/opt/code_caches/linux_7212_cache`
- 机器：RTX 3080 20GB / 6 核 / 23GB 内存 / CUDA 12.6
- 模型：Jina v2 code，FP16；batch 128；HNSW `ef_construction=100`、6 线程
- KV：`LITE_CS_KV_MAX_GB=8`

#### 第一次尝试：不要索引 drivers

先按完整源码索引，结果：

- 58,832 files
- **7,975,692 chunks**
- index 1472s（约 24.5 分钟）
- callgraph 跑了很久仍未结束，最终中止

原因是 `drivers/gpu/drm/amd/include/asic_reg/*_sh_mask.h` 这类自动生成的寄存器头，
单个文件就能产生十几万 chunk：

```text
194,933  dcn_3_2_0_sh_mask.h
137,502  nbio_7_7_0_sh_mask.h
134,340  nbio_7_2_0_sh_mask.h
...
```

这些内容对代码探索几乎没有价值，**内核索引必须排除 `drivers`**（至少排除 `asic_reg`）。

#### 第二次：排除 drivers + Documentation

```text
excludes = drivers,Documentation
```

结果：

- 24,898 files
- 1,286,106 chunks
- index（fork 6）：8s

但其中 669,410 个 macro、139,554 个 header、99,950 个 enumerator、24,898 个 file，
对语义探索价值很低，还让向量化/HNSW 慢了数倍。

#### 第三次：过滤低价值 kind（最终索引）

```text
excludes  = drivers,Documentation
skip_kinds = header,file,enumerator,macro
```

结果：

- **352,294 chunks**
- 数据约 **7.7GB**（旧索引 17GB）
- index 6s、word_freq 2s、callgraph 5s、dataflow 16s、import 34s、
  vectorize+HNSW 1067s
- 总耗时约 **19 分钟**（旧流程 55 分钟）

callgraph 从 509–613s 降到 **5s**：`get_func_node` 原来是线性扫全部函数节点
（O(edges×functions)），现在改成开放寻址哈希表；参数解析也从“每个 callee 重扫
整个 body”改成从当前调用点直接解析。

HNSW 构建期间每 1 万条打印一次：

```text
  HNSW 352294/352294 (100.0%, 435s)
  Inserted 352294/352294
  Saved HNSW index: .../code_local_linux_7212.jina.bin.hnsw (1.2GB)
```

#### 增量复跑

同一份源码、同一模型再跑一次 `vectorize`：

```text
Incremental cache: 352294 vectors available
Unchanged: 352294 vectors reused; skip rewrite and HNSW rebuild
```

约 **2.8s**，**不加载模型、不重建 HNSW**。

#### 验证

```bash
R=/home/quqiufeng/Desktop/lite
$R/tools/lua.sh -e '
local H = dofile(os.getenv("LITE_ROOT") .. "/helper/codesearch.lua")
local base = { project = "linux_7212",
               analysis_dir = "/opt/code_caches/linux_7212_cache" }
print(H.run({ action = "symbol", query = "vfs_read", max_results = 1,
              project = base.project, analysis_dir = base.analysis_dir }, { cwd = "/opt" }))
print(H.run({ action = "context", query = "vfs_read", depth = 2,
              project = base.project, analysis_dir = base.analysis_dir }, { cwd = "/opt" }))
print(H.run({ action = "search", query = "scheduler pick next task", max_results = 5,
              project = base.project, analysis_dir = base.analysis_dir }, { cwd = "/opt" }))
'
```

实测：

- `symbol vfs_read` → `fs/read_write.c:554`；首次约 6s（加载 KV），后续 0.2s
- `context vfs_read depth=2` → callers `ksys_read/ksys_pread64`，callees
  `new_sync_read/access_ok/read/rw_verify_area`，后续约 0.2s
- `search "scheduler pick next task"` → `pick_next_task`、`__pick_next_task`、
  `pick_next_pushable_task`；冷启动 4–10s，后续 0.2–1.1s

内存：`symbol/context` 冷启动约 **215MB**；`search` 稳态约 **3GB**（1.2GB HNSW +
metadata），峰值约 **4.2GB**。之前 KV 打开会扫描整个 mem.bin，内核查询能到 10GB；
现在 query 走 `CACHE_OPEN_FAST_READ`，跳过 tag/vector 重建和全量 offset/usage 校验。
同一进程内 KV / vector engine / HNSW 都会复用，后续 query 约 0.2–1.1s。
跨进程仍然是冷启动。探索报告见 `src/codesearch/CODE_READING_REPORT.md`。

#### 复现命令

```bash
R=/home/quqiufeng/Desktop/lite
LITE_CS_KV_MAX_GB=8 LITE_CS_HNSW_THREADS=6 LITE_CS_HNSW_EF=100 \
$R/tools/lua.sh -e '
local H = dofile(os.getenv("LITE_ROOT") .. "/helper/codesearch.lua")
print(H.run({
  action = "build",
  path = "/opt/linux/src/linux-7.2.12",
  project = "linux_7212",
  analysis_dir = "/opt/code_caches/linux_7212_cache",
  excludes = "drivers,Documentation",
  skip_kinds = "header,file,enumerator,macro",
  fork = true, workers = 6, batch = 128,
}, { cwd = "/opt" }))
'
```

之后查询要带 `project=linux_7212` 和 `analysis_dir=/opt/code_caches/linux_7212_cache`；
也可以把该目录软链到 `~/.local/share/lite/codesearch/linux_7212` 使用默认路径。

#### 经验

- 内核只索引 `drivers` 之外的代码；需要驱动时单独按子系统索引，并排除 `asic_reg`。
- 内核这种仓库用 `skip_kinds=header,file,enumerator,macro`：chunks 1.29M → 352k，
  数据 17G → 7.7G，构建 55min → 约 19min。需要查宏时再单独索引。
- callgraph 已从 O(edges×functions) 改成哈希查找节点，内核从 ~10 分钟降到 **5s**。
- 大仓库一定保留 `vectors/*.hash`；增量复跑从 55 分钟降到 **2.8s**。
- 本次 HNSW 用 `ef=100`（默认 200 更慢、召回略高）；对代码搜索足够。

### 4.7 参考项目索引（Pi / Reasonix / opencode）

旧索引已删除，用 lite 新流程重建（TS/JS 走 tree-sitter 插件，Go 走 ctags）：

| 项目 | 源码 | 索引目录 | chunks | 大小 |
|---|---|---|---|---|
| Pi | `/opt/pi-mono` | `/opt/code_caches/pi-mono_cache` | 16,977 | 245MB |
| Reasonix | `/opt/reasonix` | `/opt/code_caches/reasonix_cache` | 58,356 | 580MB |
| opencode | `/opt/opencode` | `/opt/code_caches/opencode_cache` | 27,111 | 361MB |

统一参数：

```text
excludes = node_modules,dist,build,.next,out
skip_kinds = header,file,enumerator,macro,package,unknown
plugins = third_party/codesearch/plugins/typescript-indexer/plugin.json
fork = true, workers = 6, batch = 128
```

实测：Pi 全量 build ~40s；Reasonix index 8s、callgraph 3s、dataflow 0.7s、
import 1.8s、vectorize+HNSW 142s；opencode index 3s、vectorize+HNSW 58s。
命名空间分别为 `/code/pi-mono`、`/code/reasonix`、`/code/opencode`。

---

## 5. 探索项目

### 5.1 前置检查

```text
codesearch action=status project=nginx
```

或：

```bash
R=/home/quqiufeng/Desktop/lite
$R/tools/lua.sh -e '
local CS = require("ffi.codesearch")
print(CS.check("/home/quqiufeng/.local/share/lite/codesearch/nginx"))
'
```

必须看到 `chunks_meta.jsonl` 和 `kv/mem.bin`；否则先 `build`。

### 5.2 语义搜索：`search`

自然语言描述功能，返回 `name / file:line / kind / score / 代码摘要`。

```text
codesearch action=search query="事件循环怎么处理 epoll" max_results=8
codesearch action=search query="配置解析入口" kind=function lang=c
codesearch action=search query="连接池分配" file=pool max_results=5
```

参数：

| 参数 | 说明 |
|---|---|
| `query` | 自然语言或关键词 |
| `max_results` | 默认 10，上限 100 |
| `kind` | `function/struct/macro/...` |
| `lang` | `c/cpp/python/javascript/go/rust` 等 |
| `file` | 文件名子串 |
| `no_boost` | 关闭词频 / 调用者 boost |
| `json` | 返回原始 JSON |

`search` 会加载向量引擎（ONNX）；第一次查询有模型初始化成本。
其余结构化查询不会加载模型。

### 5.3 精确符号：`symbol`

按符号名走 KV，不走向量、不加载模型：

```text
codesearch action=symbol query=ngx_http_init_connection
codesearch action=symbol query=compute_total max_results=20
```

返回完整 chunk 内容（可能被工具输出上限截断，`json=true` 可拿原始结构）。

### 5.4 上下文：`context`

看符号定义 + callers + callees + 调用链 + dataflow：

```text
codesearch action=context query=vfs_read depth=2
codesearch action=context query=compute_total depth=3
```

参数：

| 参数 | 说明 |
|---|---|
| `query` | 符号名 |
| `depth` | 调用链向上展开深度，0–5，默认 0 |

输出字段：

- `callers`：谁调用它
- `callees`：它调用谁
- `call_paths`：调用路径
- `dataflow`：变量/字段的 def/use

### 5.5 数据流：`dataflow`

问「这个函数读写了哪些变量」「这个变量流过哪些函数」。走 import 时写好的
`dataflow/funcs/<func>`（每函数一条）和 `dataflow/vars/<var>`，`cache_get` 直取，
不会去读几百 MB 的 `dataflow.json` / `_func_index`：

```text
codesearch action=dataflow query=import_dataflow max_results=20
codesearch action=dataflow query=namespace
```

输出三种 `kind`：

| kind | 含义 |
|---|---|
| `function` | 函数精确命中：`vars` 里每个变量的行号 + 本函数内的 occurrence（`occurrences_in_func` 是总数） |
| `variable` | 变量命中：按函数聚合的出现次数与行号 |
| `candidates` | 都没命中时给前缀相近的函数名，免得凭空猜拼写 |

注意：查询只能命中**重新 import 过**的 KV —— 旧索引里没有 `funcs/` 键，
先跑一次 `codesearch action=import`（或 `build`）。

### 5.6 精确 KV key：`exact`

高级用法，按完整 KV key 取原始记录：

```text
codesearch action=exact query=/code/nginx/chunks/ngx_http_init_connection
```

### 5.7 推荐探索流程

1. **摸底**：`status` 确认索引完整。
2. **架构扫描**：用几条自然语言 `search` 找子系统入口（调度器、VFS、网络、配置、缓存……）。
3. **钉住符号**：对入口函数做 `symbol`，拿完整实现。
4. **看关系**：`context depth=1..3` 看 callers/callees，判断主线和旁路。
5. **追数据**：`context` 的 dataflow，或直接看 `dataflow.json`。
6. **验证**：静态结果标 `[static]`；真正结论要 build / 测试 / 断点验证后标 `[verified]`。
7. 引用统一 `file:symbol`，行号只作参考。

示例：

```text
codesearch action=search query="scheduler pick next task" max_results=5
codesearch action=symbol query=pick_next_task
codesearch action=context query=pick_next_task depth=2
codesearch action=search query="socket 接收数据路径" max_results=8
```

### 5.7 从 shell 查询

```bash
R=/home/quqiufeng/Desktop/lite
$R/tools/lua.sh -e '
local H = dofile(os.getenv("LITE_ROOT") .. "/helper/codesearch.lua")
print(H.run({
  action = "search",
  query = "compact 怎么触发",
  max_results = 5,
}, { cwd = os.getenv("PWD") }))
'
```

把 `action` 换成 `symbol` / `context` / `exact` / `status` 即可。

---

## 6. 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| `liblite_codesearch.so not found` | tokenizers 静态库或 jansson 缺失；看 `./tools/check_deps.sh`，用 `-DLITE_CS_TOKENIZERS_DIR=` 重配 |
| `cannot dlopen libonnxruntime.so.1` | 设 `LITE_ORT_LIB` 指向真实 `libonnxruntime.so.1` |
| `CUDA not available, falling back to CPU` | 检查 `/data/cuda/lib64`、cuDNN 目录、`nvidia-smi`；CPU 会慢几十倍 |
| `ctags: command not found` | 安装 Universal Ctags；语义/符号仍可用，但无法建索引 |
| `index not found for this project` | 先 `action=build` |
| `KV import missing` | 跑 `action=build` 或 `action=import` |
| 语义搜索很慢 / 占用高 | 用 `fp16=true`；`batch` 降到 64；确认 `Using CUDA GPU acceleration` |
| 显存不足 | 降低 `batch`（128 → 64/32） |
| 重复 build 仍然很慢 | 确认没有删 `vectors/*.hash`；确认模型/FP16 没变；大改动会重建 HNSW |
| 想确认是否走了增量 | 看输出：`Incremental cache: N vectors available`、`reused N`、`Unchanged: ...` |
| 怀疑向量/索引损坏 | 删 `analysis/vectors/` 重新 `build` |
| fork 后卡死 | 进程已加载过 ORT；改用串行或新进程 |

日志说明：

- `Done in ... (reused X, embedded Y)`：向量化结果。
- `Unchanged: ... skip rewrite and HNSW rebuild`：完全命中增量缓存。
- `Using CUDA GPU acceleration` / `retrying on CPU`：执行后端。
- 所有库内日志走 stderr，stdout 只留 query 的 JSON。

---

## 7. C API / FFI 速查

公共入口全部是 JSON 字符串进、JSON 字符串出，返回串用 `lite_cs_free` 释放。

```c
char* lite_cs_index_ex(const char* repo, const char* out_dir, int workers,
                       const char* excludes, const char* plugins, int use_fork);
char* lite_cs_word_freq(const char* analysis_dir);
char* lite_cs_callgraph(const char* analysis_dir);
char* lite_cs_dataflow(const char* analysis_dir);
char* lite_cs_dataflow_query(const char* query, const char* kv_dir, const char* ns,
                             int max_results);
char* lite_cs_import(const char* analysis_dir, const char* ns,
                     const char* kv_dir, int only_dataflow);
char* lite_cs_vectorize_ex(const char* analysis_dir, const char* model,
                           const char* name, int batch, int fp16);
char* lite_cs_query(const char* query, const char* repo, const char* type,
                    const char* kv_dir, const char* analysis_dir, const char* model,
                    int max_results, int depth, int no_boost,
                    const char* kind, const char* lang, const char* file);
char* lite_cs_check(const char* analysis_dir);
char* lite_cs_capabilities(void);
const char* lite_cs_error(void);
```

`lite_cs_index` / `lite_cs_vectorize` 是兼容旧签名的包装，分别转调 `_ex`。
`use_fork = -1` 表示跟随 `LITE_CS_FORK`；`fp16 = -1` 表示跟随环境变量。

Lua 侧：

```lua
local CS = require("ffi.codesearch")
CS.index({ repo = "/path", analysis_dir = dir, workers = 6, fork = true })
CS.vectorize(dir, "jina", "project", { batch = 128, fp16 = true })
CS.query({ query = "epoll", repo = "/code/project", type = "search",
           kv_dir = dir .. "/kv", analysis_dir = dir, max_results = 5 })
```

---

## 8. 与 /opt/my_db 的差异

| 项 | /opt/my_db | lite codesearch |
|---|---|---|
| 形态 | 多个 CLI + shell 脚本 | 一个 `.so` + JSON API |
| 调用 | `ai_code_search.sh` / `tools/*` | `helper/codesearch.lua` / FFI |
| 日志 | stdout / stderr 混用 | 库内日志统一 stderr |
| 索引并行 | 默认多进程 | 库内默认串行，`fork=true` 显式开 |
| 临时文件 | 固定 `/tmp` 名 | 带父进程 pid，支持多实例 |
| 向量化 | 全量 | 增量缓存 + 未变化跳过 HNSW |
| 模型 | FP32 为主 | 建索引和查询都默认 FP16，自动找 `model_fp16.onnx` |
| TensorRT | 视为主要加速 | 不使用；GPU 只走 CUDA + FP16 |
| KV 实现 | my_db 自己的 cache | **lite 自带 kvcache（`src/cache/`）**，落在 `kv/mem.bin` |
| 数据目录 | `/memory` / `$LITE_CS_HOME` | `$LITE_CS_HOME/<project>`，KV 在子目录 |

更完整的原始方法论（证据分级、报告模板、大项目分治）见
`src/codesearch/code_search_best_practices.md`；
其中部分命令是 my_db 时代写法，实际使用以本文件为准。
