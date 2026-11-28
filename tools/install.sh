#!/usr/bin/env bash
# 安装：<prefix>/share/lite + <prefix>/bin/lite。
#
# 原则：装进去的必须由当前源码树现打，绝不复用旧 dist。
# 旧实现是「dist 存在就直接 cp」，改了 lua 却装上几天前的包，
# 现象是改的代码"不生效"，排查极浪费时间。package 只要 0.6s，不值得省。
# 唯一例外：解包安装（树里没有 src/，本来就是别人打好的产物），见 PREBUILT。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tools/_arch.sh"
DIST="$ROOT/dist/$LITE_DIST_NAME"
APP="${PREFIX:-$HOME/.local}/share/lite"
BIN="${PREFIX:-$HOME/.local}/bin"

# 判「这棵树是不是已经打好的包」：没有 src/（release tarball 不含 C 源码），
# 且 dist/ 或树根上已经有 tools/lite。tar 根目录就是 lite-linux-arm64/ 本身，
# 里面没有 dist/ 子目录，所以两个位置都要看。
PREBUILT=0
if [ ! -d "$ROOT/src" ] && { [ -x "$DIST/tools/lite" ] || [ -x "$ROOT/tools/lite" ]; }; then
    PREBUILT=1
fi

if [ "${LITE_SKIP_PACKAGE:-0}" = "1" ] || [ "$PREBUILT" = "1" ]; then
    # 逃生阀：release.sh 刚打完包，或明确知道自己要复用现成产物时用。
    #
    # 解包安装（release tarball）也走这条路：包里的树没有 src/ 和 CMakeLists.txt，
    # 在这儿重跑 package.sh 只会把**已经打好的产物再打包一次**，而它的输入
    # （build/*.so 之外的 lib/liblite_*.so、$LITE_SYSROOT 里的 liblitehtml/gumbo）
    # 在目标机上根本不存在 —— 实测在 123 上装完 lib/ 全空、build/ 只剩 2 个 .so，
    # html→png 与 tui/capture 一起失联。包是别人打好的，就照用。
    # 优先树根：$DIST 是 <root>/dist/<name>，只在「源码树刚被 release.sh 打好包、
    # 想复用那份产物」时才该选。反过来先选 $DIST 会中一个隐蔽的陷阱——目标机上
    # 若残留一个 <root>/dist/<name>（早先 LITE_SKIP_PACKAGE 手工摆的、或有人解包
    # 到 dist 下），它的 tools/lite 也是可执行的，于是整个安装源切到那份残树：
    # 装完 lib/ 全空、build/ 只剩 cache+html，tui/capture/image 与 html→png 一起
    # 失联，而 install.sh 一路不报错（2026-11-28 在 123 上实测踩到）。
    SRC="$ROOT"
    [ -x "$SRC/tools/lite" ] || SRC="$DIST"
    [ -x "$SRC/tools/lite" ] || {
        echo "install: skip-package 但既没有 $DIST 也没有 $ROOT/tools/lite" >&2
        exit 1
    }
    echo "install: reusing existing tree ($SRC)"
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
    SRC="$DIST"
fi

# $APP 既是安装目录，也是数据目录（sessions/ 会话镜像、codesearch/ 索引、老版本
# memdb/、wx-watch/ 微信守护的 state+日志）。直接 rm -rf 会连用户数据一起删：跑一次
# release 就丢全部 codesearch 索引和会话备份（2026-11-13 实测，dfproj 索引 +
# sessions/*.jsonl 一次 rm 全没）。
# 所以先把数据目录挪到临时区，装完再挪回来；KEEP 只列**数据**，装进去的东西照旧全删。
# 加新目录的判据：它是进程运行期自己写的、删了不可再生（wx-watch 丢了等于派发历史清零，
# same_after 去重和 last 指纹一起失忆）。dist 里同名目录属于程序本体，不在这个列表。
KEEP="sessions codesearch memdb wx-watch"
STASH="$(mktemp -d)"
for d in $KEEP; do
    [ -e "$APP/$d" ] && mv "$APP/$d" "$STASH/$d"
done
rm -rf "$APP"
mkdir -p "$APP" "$BIN"
cp -rL "$SRC/." "$APP/"
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
