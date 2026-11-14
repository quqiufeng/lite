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
#   3. 把自带的 liblite_*.so、workspace 的 lib/build/helper 里的 .so 按绝对路径
#      预加载（RTLD_GLOBAL），`ffi.load("liblite_image.so")` 这种裸名从任意 cwd
#      都能命中，同目录的依赖库也靠 SONAME 一起解析到；预加载失败会打到 stderr
#      （LITE_PRELOAD_WARN=0 可静音），别再靠"库找不到"猜。
#   4. 读 .env 把 API Key 之类导进环境：脚本里 os.getenv("DEEPSEEK_API_KEY")
#      直接可用。顺序 = cwd → 上级目录 → ~/.config/lite/.env → ~/.env → $LITE_ROOT/.env，
#      近处优先；**已经存在的进程环境变量优先于任何 .env**（想全关：
#      LITE_ENV_FILE=/dev/null；想指定单文件：LITE_ENV_FILE=/path/to/.env）。
#      `sudo` 下 HOME 被换成 /root 且 env_reset 清掉进程环境，改用 SUDO_USER
#      补读 /home/<user>/.config/lite/.env 与 /home/<user>/.env。
# 不改 LD_LIBRARY_PATH（会污染 bash 子进程，见 lite-lua 注释）：自带 .so 靠
# $ORIGIN RUNPATH 找同目录依赖，workspace 依赖靠上面的预加载兜住。
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

# --- .env：KEY=VALUE 逐行读，不 eval（值里的 $ ` " 不会被展开）。
# 已存在的环境变量优先，所以近处的文件先读；语法错误/非 KEY= 行直接跳过。
_lite_dotenv() {
    local file="$1" line key val
    [ -f "$file" ] && [ -r "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
        key="${line%%=*}"
        val="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        if [ -z "${!key+x}" ]; then
            printf -v "$key" '%s' "$val"
            export "$key"
        fi
    done < "$file"
}

if [ "${LITE_ENV_FILE:-}" = "/dev/null" ]; then
    :
elif [ -n "${LITE_ENV_FILE:-}" ]; then
    case "$LITE_ENV_FILE" in
        /*) _lite_dotenv "$LITE_ENV_FILE" ;;
        *) _lite_dotenv "$WS/$LITE_ENV_FILE" ;;
    esac
else
    _d="$WS"
    _i=0
    while [ "$_i" -lt 12 ]; do
        _lite_dotenv "$_d/.env"
        _up="${_d%/*}"
        [ -n "$_up" ] && [ "$_up" != "$_d" ] || break
        _d="$_up"
        _i=$((_i + 1))
    done
    if [ -n "${HOME:-}" ]; then
        _lite_dotenv "$HOME/.config/lite/.env"
        _lite_dotenv "$HOME/.env"
    fi
    # sudo 换了 HOME 并清掉进程环境，但保留 SUDO_USER：补回调用者那两份。
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        _d="${LITE_HOME_ROOT:-/home}"; _d="${_d%/}"
        _lite_dotenv "$_d/$SUDO_USER/.config/lite/.env"
        _lite_dotenv "$_d/$SUDO_USER/.env"
    fi
    _lite_dotenv "$ROOT/.env"
fi

# workspace 条目排在最后：项目自带的模块和 .so 优先，插件不覆盖框架。
# $ROOT/third_party/luajit/src/?.lua 排最前：jit.* 的 Lua 模块（vmdef/v/dump/p）
# 必须与随包二进制同版本，否则 `;;` 展开到的系统 share 目录会报
# "LuaJIT core/library version mismatch"。
export LUA_PATH="\
$ROOT/third_party/luajit/src/?.lua;\
./?.lua;./lua/?.lua;./?/init.lua;./helper/?.lua;./helper/lib/?.lua;\
$WS/?.lua;$WS/lua/?.lua;$WS/?/init.lua;$WS/helper/?.lua;$WS/helper/lib/?.lua;;${LUA_PATH:-}"
export LUA_CPATH="\
./?.so;./build/?.so;./lib/?.so;./helper/?.so;\
$WS/?.so;$WS/build/?.so;$WS/lib/?.so;$WS/helper/?.so;;${LUA_CPATH:-}"

LITE_PRELOAD=""
PRE_PATS=("$ROOT"/build/liblite_*.so "$ROOT"/lib/liblite_*.so)
# WS=/ 时 /lib 是全系统库目录，逐个 dlopen 既慢又会撞上不可加载的怪文件
if [ "$WS" != "/" ]; then
    PRE_PATS+=("$WS"/build/*.so "$WS"/lib/*.so "$WS"/helper/*.so)
fi
for pat in "${PRE_PATS[@]}"; do
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
# 预加载失败默认可见：缺依赖 / 架构不符 / 撕过符号都在这里冒出来，别静默
export LITE_PRELOAD_WARN="${LITE_PRELOAD_WARN:-1}"

exec "$BASE" "$@"
