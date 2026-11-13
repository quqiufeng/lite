#!/usr/bin/env bash
# newproject.sh — 从 templates/project 生成一个遵守「LuaJIT FFI + Lua + C/C++」体系的新项目。
#
#   ./tools/newproject.sh /path/to/proj --name proj [--git] [--force] [--dry-run]
#   ./tools/newproject.sh --refresh-ffi        # 把 lite 最新 x11/xdo 同步进模板
#
# 生成的东西必须当场可跑：build.sh + test.sh 全绿，see.lua --list 能列窗口。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/templates/project"

die() { echo "newproject: $*" >&2; exit 2; }

# 模板里的自包含对永不过期：从 lite 的权威副本刷进模板
if [ "${1:-}" = "--refresh-ffi" ]; then
    mkdir -p "$SRC/lua/ffi"
    cp "$ROOT/lua/ffi/x11.lua" "$ROOT/lua/ffi/xdo.lua" "$SRC/lua/ffi/"
    echo "refreshed: templates/project/lua/ffi/{x11,xdo}.lua ← lua/ffi/"
    exit 0
fi

DST="${1:-}"; shift || true
[ -n "$DST" ] || die "用法: newproject.sh <目标目录> [--name X] [--git] [--force] [--dry-run]"
NAME=""; GIT=0; FORCE=0; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="${2:-}"; shift 2 ;;
        --git) GIT=1; shift ;;
        --force) FORCE=1; shift ;;
        --dry-run) DRY=1; shift ;;
        *) die "未知参数: $1" ;;
    esac
done
[ -n "$NAME" ] || NAME="$(basename "$DST")"
NAME="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_' '_')"
while [ "${NAME%_}" != "$NAME" ]; do NAME="${NAME%_}"; done
while [ "${NAME#_}" != "$NAME" ]; do NAME="${NAME#_}"; done
[ -n "$NAME" ] || die "无法推导项目名，用 --name 指定"

if [ -e "$DST" ] && [ "$FORCE" -ne 1 ]; then
    die "目标已存在：$DST（加 --force 覆盖）"
fi
[ "$DRY" -eq 1 ] && { echo "would create: $DST  name=$NAME  from=$SRC"; exit 0; }

mkdir -p "$DST"
cp -r "$SRC/." "$DST/"

# 占位符替换：@NAME@ → 项目名。只碰模板文件，不碰二进制。
"$ROOT/tools/lua.sh" - "$DST" "$NAME" <<'LUA'
local dst, name = arg[1], arg[2]
local function walk(dir, out)
    local p = io.popen("find '" .. dir .. "' -type f 2>/dev/null")
    for line in p:lines() do out[#out + 1] = line end
    p:close()
end
local files = {}
walk(dst, files)
local n = 0
for _, f in ipairs(files) do
    local rel = f:sub(#dst + 2)
    -- 自包含对与二进制不替换
    if not rel:match("^lua/ffi/(x11|xdo)%.lua$") then
        local h = io.open(f, "rb")
        if h then
            local data = h:read("*a"); h:close()
            local new = data:gsub("@NAME@", name)
            if new ~= data then
                local w = io.open(f, "wb"); w:write(new); w:close(); n = n + 1
            end
        end
    end
    if rel:match("%.in$") then
        local target = f:gsub("%.in$", "")
        os.rename(f, target)
        n = n + 1
    end
end
print(string.format("newproject: %d files written, name=%s", n, name))
LUA

# 规范 + 模板 AGENTS 的落地位置
cp "$ROOT/templates/PROJECT_STANDARD.md" "$DST/PROJECT_STANDARD.md"

chmod +x "$DST"/tools/*.sh "$DST/tools"/*.lua 2>/dev/null || true
# see.lua/unit.lua 要能直接执行
[ -f "$DST/tools/see.lua" ] && chmod +x "$DST/tools/see.lua"

if [ "$GIT" -eq 1 ]; then
    ( cd "$DST" && git init -q && git add -A && git commit -qm "chore: bootstrap from lite templates" ) || true
fi

cat <<EOF

$DST 就绪（name=$NAME）。下一步：
  cd $DST
  ./tools/build.sh      # 出 build/lib${NAME}_core.so
  ./tools/test.sh       # 依赖 + 单元 + 活体 + CLI 契约
  ./tools/see.lua --list
体系规范：$DST/PROJECT_STANDARD.md
EOF
