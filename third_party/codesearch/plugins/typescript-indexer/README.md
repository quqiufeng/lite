# TypeScript/Node.js Indexer Plugin

C implementation using tree-sitter. No Node.js / npm dependency.

## Dependencies

- tree-sitter core static library: `/opt/tree-sitter/libtree-sitter.a`
- tree-sitter-typescript parsers: `/opt/tree-sitter-typescript`
- jansson: JSON output library (`libjansson-dev`)

## Build

```bash
cd third_party/codesearch/plugins/typescript-indexer
make
```

The Makefile statically links `libtree-sitter.a`, so the resulting binary only needs `libjansson.so.4` and `libc` at runtime:

```bash
ldd bin/typescript-indexer
# linux-vdso.so.1
# libjansson.so.4 => /lib/x86_64-linux-gnu/libjansson.so.4
# libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6
```

## Usage

```bash
./bin/typescript-indexer --file /opt/opencode/packages/core/src/session/message.ts --project /opt/opencode
```

Output is JSON Lines to stdout.

## Integration with code_indexer

The plugin is registered via `plugin.json`. `code_indexer` will:

1. Match files by extension (`.ts`, `.tsx`, `.js`, `.jsx`)
2. Spawn the plugin binary with `--file` and `--project`
3. Read JSON Lines output
4. Fall back to ctags if the plugin fails

## Integration with lite codesearch

`plugin.json` 里的 `command` 是相对路径，解析时以 registry 文件所在目录为基准，
所以仓库自带插件不依赖 `/opt` 绝对路径。index/build 时传：

```bash
./tools/lua.sh -e '
local H = dofile(os.getenv("LITE_ROOT") .. "/helper/codesearch.lua")
print(H.run({
  action = "index",
  path = "/path/to/ts-project",
  plugins = "third_party/codesearch/plugins/typescript-indexer/plugin.json",
  fork = true,
}, { cwd = os.getenv("LITE_ROOT") }))
'
```

`plugin.json` 只按扩展名匹配 `.ts/.tsx/.js/.jsx`；插件失败时 indexer 会回退到 ctags。

## Output Records

- `chunk`: extracted symbol (function, class, interface, type alias, enum, variable, namespace)
- `call_edge`: function call relationship
- `import_edge`: import/export relationship
- `metadata`: file-level stats

## Recent Optimizations

- Fixed `export const` incorrectly marked as non-export.
- Reduced noise from anonymous inline lambdas.
- Deduplicated arrow functions that were also emitted as variable chunks.
- Static-linked tree-sitter core to avoid runtime `libtree-sitter.so` dependency.

## Development

```bash
# Rebuild after source changes
make clean && make

# Test on a single file
./bin/typescript-indexer --file test.ts --project .

# Verify runtime dependencies
ldd bin/typescript-indexer
```
