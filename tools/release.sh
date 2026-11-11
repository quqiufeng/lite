#!/usr/bin/env bash
# lite 编译发布：build + package + install。
#
# 默认 prefix 必须与 tools/install.sh 一致（$HOME/.local），否则两份安装并存：
# PATH 里 ~/.local/bin 通常排在 /usr/local/bin 前，release 装的那份被遮蔽，
# 敲 lite 永远跑旧代码 —— 现象是「改了不生效」，且 --version 验证是假阳性。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL=1
PREFIX_EXPLICIT=0
if [ -n "${PREFIX:-}" ]; then
    PREFIX_EXPLICIT=1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --no-install)
            INSTALL=0
            shift
            ;;
        --prefix)
            PREFIX="${2:?--prefix requires a value}"
            PREFIX_EXPLICIT=1
            shift 2
            ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"
            PREFIX_EXPLICIT=1
            shift
            ;;
        -h|--help)
            cat <<EOF
usage: tools/release.sh [--no-install] [--prefix <dir>]

  build + package + install lite to <prefix>/bin
  default prefix: \$HOME/.local  (same as tools/install.sh)

  --no-install      only build and package
  --prefix DIR      install prefix (default: \$PREFIX or \$HOME/.local)
EOF
            exit 0
            ;;
        *)
            echo "release: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

"$ROOT/tools/build.sh"
"$ROOT/tools/package.sh"

if [ "$INSTALL" -eq 0 ]; then
    echo "package only: $ROOT/dist/lite-linux-x64.tar.gz"
    exit 0
fi

# 未显式指定时跟随 tools/install.sh 的默认（$HOME/.local）：两脚本默认值必须一致，
# 否则会在 ~/.local 与 /usr/local 各留一份，PATH 靠前的那份遮蔽新的那份。
if [ "$PREFIX_EXPLICIT" -eq 0 ]; then
    PREFIX="$HOME/.local"
fi

mkdir -p "$PREFIX/bin" 2>/dev/null || true

LITE_INSTALL_LINK_LUA="${LITE_INSTALL_LINK_LUA:-1}"
if [ "$(id -u)" -eq 0 ] || [ -w "$PREFIX/bin" ]; then
    # 始终传确定的 PREFIX：install.sh 会拿 $HOME 推默认目录，sudo 下 $HOME 变成 /root。
    PREFIX="$PREFIX" LITE_SKIP_PACKAGE=1 LITE_INSTALL_LINK_LUA="$LITE_INSTALL_LINK_LUA" "$ROOT/tools/install.sh"
else
    if ! command -v sudo >/dev/null 2>&1; then
        echo "release: $PREFIX/bin is not writable and sudo is missing" >&2
        exit 1
    fi
    sudo env PREFIX="$PREFIX" LITE_SKIP_PACKAGE=1 LITE_INSTALL_LINK_LUA="$LITE_INSTALL_LINK_LUA" "$ROOT/tools/install.sh"
fi

APP="$PREFIX/share/lite"
echo "installed: $PREFIX/bin/lite"

# HTML→PNG 三件套缺件不报错的话，装完一切正常、一调 md2png 才炸，所以这里顺手查。
if [ -f "$ROOT/build/liblite_html.so" ]; then
    missing=""
    for f in liblite_html.so liblitehtml.so.0 libgumbo.so.0; do
        [ -f "$APP/build/$f" ] || missing="$missing $f"
    done
    if [ -n "$missing" ]; then
        echo "release: [WARN] $APP/build 缺:$missing（md2png/web2png/trending 会不可用）" >&2
    fi
fi

"$PREFIX/bin/lite" --version

# 验证「PATH 里真正生效的那份」：绝对路径 --version 只证明刚装的这份是好的。
ACTIVE="$(command -v lite 2>/dev/null || true)"
if [ -n "$ACTIVE" ] && [ "$(readlink -f "$ACTIVE" 2>/dev/null)" != "$(readlink -f "$PREFIX/bin/lite")" ]; then
    echo "release: [WARN] PATH 里 $ACTIVE 排在前面，敲 lite 跑的是它而不是本次安装" >&2
    echo "release: [WARN] 要么删掉那份遮蔽的安装，要么也用 --prefix 给它装一次" >&2
fi
