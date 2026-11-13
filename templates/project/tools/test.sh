#!/usr/bin/env bash
# test.sh — 一条命令跑完：依赖 → 单元 → 活体冒烟 → CLI 契约。全绿才能说"验过"。
# 退出码：0 全绿 / 1 有失败 / 2 用法错。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0
step() { printf '\n== %s ==\n' "$1"; }
bad()  { echo "FAIL: $1"; fail=1; }

step "deps"
for c in cmake cc; do command -v "$c" >/dev/null || bad "缺少 $c"; done
[ -x "$ROOT/build/lib@NAME@_core.so" ] || bad "缺 build/lib@NAME@_core.so（先跑 ./tools/build.sh）"
./tools/lua.sh -e 'assert(jit, "不是 LuaJIT")' || bad "不是 LuaJIT"

step "unit"
./tools/lua.sh tools/unit.lua || bad "unit"

step "smoke: cli"
out="$(./tools/lua.sh lua/app.lua --json ping 2>&1)" || bad "app.lua ping 退出码非 0"
case "$out" in *'"ok":true'*) ;; *) bad "app.lua --json ping 没有 ok:true：$out" ;; esac

step "smoke: x11"
if [ -n "${DISPLAY:-}" ]; then
    ./tools/lua.sh tools/see.lua --list >/dev/null 2>&1 || bad "see.lua --list（窗口枚举失败）"
else
    echo "skip: 无 DISPLAY"
fi

step "secret scan"
if grep -rIn --include='*.lua' --include='*.c' --include='*.sh' -E 'sk-[A-Za-z0-9]{16,}' lua src tools helper 2>/dev/null \
   | grep -v 'sk-test' >/dev/null; then
    bad "仓库里出现疑似密钥字面量（只允许放环境变量）"
fi

echo
[ "$fail" -eq 0 ] && echo "test: ALL GREEN" || echo "test: FAILED"
exit "$fail"
