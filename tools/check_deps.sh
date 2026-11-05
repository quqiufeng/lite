#!/usr/bin/env bash
# 检查 lite 运行依赖：LuaJIT / cjson / libcurl / 构建工具。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

echo "== lite dependencies =="

if [ -x "$ROOT/third_party/luajit/src/luajit" ]; then
    echo "[OK]   luajit   bundled"
else
    if command -v luajit >/dev/null 2>&1; then
        echo "[OK]   luajit   $(luajit -v 2>&1 | head -1)"
    else
        echo "[FAIL] luajit   missing"
        fail=1
    fi
fi

"$ROOT/tools/lite-lua" -e '
local deps = require("core.deps")
local ok, rows = deps.check()
for _, r in ipairs(rows) do
  io.write(string.format("[%s]   %-8s %s\n", r.ok and "OK" or "FAIL", r.name, r.detail))
  if not r.ok then os.exit(1) end
end
' || fail=1

for c in gcc cmake pkg-config; do
    if command -v "$c" >/dev/null 2>&1; then
        echo "[OK]   $c"
    else
        echo "[WARN] $c missing (needed later for native launcher)"
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "== dependencies missing =="
    exit 1
fi
echo "== deps ok =="
