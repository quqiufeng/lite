#!/usr/bin/env bash
# 插件 / 脚本专用 LuaJIT 入口：在 workspace 上下文里跑一段 lua。
#
#   tools/lua.sh -e 'print(require("mymod").v)'
#   LITE_CWD=/path/to/ws tools/lua.sh script.lua
#
# 与仓库内部的 tools/lite-lua 的区别（那个保持 clean，不带任何 workspace 状态）：
#   1. 先 cd 到 LITE_CWD（缺省 $PWD），`io.open("data.txt")` 这类相对路径跟着走；
#   2. 把 workspace 的 ./?.lua、./lua/?.lua、./helper/?.lua、./?.so、./build/?.so、
#      ./lib/?.so、./helper/?.so 追加进 LUA_PATH / LUA_CPATH；
#   3. 把自带的 liblite_*.so 按绝对路径预加载，`ffi.load("liblite_image.so")`
#      这种裸名从任意 cwd 都能命中。
# 不改 LD_LIBRARY_PATH（会污染 bash 子进程，见 lite-lua 注释）。
set -euo pipefail

SELF="$(readlink -f "$0")"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
BASE="$ROOT/tools/lite-lua"
WS="${LITE_CWD:-$PWD}"
if [ ! -d "$WS" ]; then
    echo "lite: workspace not found: $WS" >&2
    exit 1
fi
cd "$WS"

export LITE_ROOT="${LITE_ROOT:-$ROOT}"

# workspace 条目排在最后：项目自带的模块和 .so 优先，插件不覆盖框架。
export LUA_PATH="\
./?.lua;./lua/?.lua;./?/init.lua;./helper/?.lua;\
$WS/?.lua;$WS/lua/?.lua;$WS/?/init.lua;$WS/helper/?.lua;;${LUA_PATH:-}"
export LUA_CPATH="\
./?.so;./build/?.so;./lib/?.so;./helper/?.so;\
$WS/?.so;$WS/build/?.so;$WS/lib/?.so;$WS/helper/?.so;;${LUA_CPATH:-}"

LITE_PRELOAD=""
for pat in "$ROOT"/build/liblite_*.so "$ROOT"/lib/liblite_*.so \
           "$WS"/build/liblite_*.so "$WS"/lib/liblite_*.so "$WS"/helper/*.so; do
    for f in $pat; do
        [ -f "$f" ] || continue
        f="$(readlink -f "$f")"
        case ":$LITE_PRELOAD" in
            *":$f:"*) ;;
            *) LITE_PRELOAD="$LITE_PRELOAD$f:" ;;
        esac
    done
done
export LITE_PRELOAD

exec "$BASE" "$@"
