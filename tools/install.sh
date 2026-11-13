#!/usr/bin/env bash
# 安装：<prefix>/share/lite + <prefix>/bin/lite。
#
# 原则：装进去的必须由当前源码树现打，绝不复用旧 dist。
# 旧实现是「dist 存在就直接 cp」，改了 lua 却装上几天前的包，
# 现象是改的代码"不生效"，排查极浪费时间。package 只要 0.6s，不值得省。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist/lite-linux-x64"
APP="${PREFIX:-$HOME/.local}/share/lite"
BIN="${PREFIX:-$HOME/.local}/bin"

if [ "${LITE_SKIP_PACKAGE:-0}" = "1" ]; then
    # 逃生阀：release.sh 刚打完包，或明确知道自己要复用现成产物时用。
    [ -x "$DIST/tools/lite" ] || {
        echo "install: LITE_SKIP_PACKAGE=1 but dist is missing" >&2
        exit 1
    }
    echo "install: reusing existing dist (LITE_SKIP_PACKAGE=1)"
else
    # 原生库若比 C 源码旧，先重建；否则 dist 里的 .so 仍是老二进制。
    if [ -f "$ROOT/CMakeLists.txt" ] && [ -d "$ROOT/src" ]; then
        newest="$(ls -t "$ROOT"/build/*.so 2>/dev/null | head -1 || true)"
        if [ -z "$newest" ] || [ -n "$(find "$ROOT/src" "$ROOT/CMakeLists.txt" \
                -newer "$newest" -print -quit 2>/dev/null)" ]; then
            echo "install: C sources newer than build/*.so -> rebuilding"
            "$ROOT/tools/build.sh"
        fi
    fi
    "$ROOT/tools/package.sh"
fi

# $APP 既是安装目录，也是数据目录（sessions/ 会话镜像、codesearch/ 索引、老版本
# memdb/）。直接 rm -rf 会连用户数据一起删：跑一次 release 就丢全部 codesearch
# 索引和会话备份（2026-11-13 实测，dfproj 索引 + sessions/*.jsonl 一次 rm 全没）。
# 所以先把数据目录挪到临时区，装完再挪回来；KEEP 只列**数据**，装进去的东西照旧全删。
KEEP="sessions codesearch memdb"
STASH="$(mktemp -d)"
for d in $KEEP; do
    [ -e "$APP/$d" ] && mv "$APP/$d" "$STASH/$d"
done
rm -rf "$APP"
mkdir -p "$APP" "$BIN"
cp -rL "$DIST/." "$APP/"
for d in $KEEP; do
    [ -e "$STASH/$d" ] && mv "$STASH/$d" "$APP/$d"
done
rmdir "$STASH"
# 源码树安装时默认把 lua/ 做成软链：改 Lua 后重启即生效，不再出现
# “源码改了但 /usr/local 还是旧副本”。dist 独立部署仍保持实体拷贝。
if [ "${LITE_INSTALL_LINK_LUA:-0}" = "1" ] && [ "$ROOT" != "$APP" ] && [ -d "$ROOT/lua" ]; then
    rm -rf "$APP/lua"
    ln -s "$ROOT/lua" "$APP/lua"
    echo "install: lua -> $ROOT/lua (symlink)"
fi
chmod +x "$APP/tools/lite" "$APP/tools/lite-lua" "$APP/tools/run.sh"

ln -sf "$APP/tools/lite" "$BIN/lite"
ln -sf "$APP/tools/lite-lua" "$BIN/lite-lua"

echo "installed: $BIN/lite"
echo "config:    ~/.config/lite/config.lua (not touched)"
echo "note:      已在运行的 lite 仍用旧代码，需退出重启才生效"
