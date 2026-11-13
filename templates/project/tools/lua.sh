#!/usr/bin/env bash
# lua.sh — 唯一的 Lua 启动入口。所有脚本/插件都经由这里跑，保证同一个解释器 + 同一套路径。
#
#   ./tools/lua.sh -e 'print(_VERSION)'
#   ./tools/lua.sh lua/app.lua --json ping
#
# 解释器顺序：$LUAJIT → luajit → $ROOT/third_party/luajit/src/luajit → 报错退出(127)。
# 系统 lua(5.x) 不兼容本体系：ffi / bit / 4GB string 都没有。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# .env 注入（人写配置，脚本只读环境变量；不落盘、不回显）
for f in "$ROOT/.env" "$HOME/.config/@NAME@/.env" "$HOME/.env"; do
    [ -f "$f" ] || continue
    while IFS='=' read -r k v; do
        case "$k" in ''|\#*) continue ;; esac
        v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
        export "$k=$v"
    done < "$f"
done

LJ="${LUAJIT:-}"
if [ -z "$LJ" ]; then
    for c in "$ROOT/third_party/luajit/src/luajit" luajit; do
        if command -v "$c" >/dev/null 2>&1; then LJ="$c"; break; fi
    done
fi
if [ -z "$LJ" ]; then
    echo "lua.sh: 需要 LuaJIT（不是 lua 5.x）：装 luajit 或设 \$LUAJIT" >&2
    exit 127
fi

export ROOT
export LUA_PATH="$ROOT/lua/?.lua;$ROOT/lua/?/init.lua;;"
exec "$LJ" "$@"
