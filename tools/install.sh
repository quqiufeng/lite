#!/usr/bin/env bash
# 可选安装：~/.local/share/lite + ~/.local/bin/lite。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist/lite-linux-x64"
APP="${PREFIX:-$HOME/.local}/share/lite"
BIN="${PREFIX:-$HOME/.local}/bin"

if [ ! -x "$DIST/tools/lite" ]; then
    "$ROOT/tools/package.sh"
fi

rm -rf "$APP"
mkdir -p "$APP" "$BIN"
cp -r "$DIST/." "$APP/"
chmod +x "$APP/tools/lite" "$APP/tools/lite-lua" "$APP/tools/run.sh"

ln -sf "$APP/tools/lite" "$BIN/lite"
ln -sf "$APP/tools/lite-lua" "$BIN/lite-lua"

echo "installed: $BIN/lite"
echo "config:    ~/.config/lite/config.lua (not touched)"
