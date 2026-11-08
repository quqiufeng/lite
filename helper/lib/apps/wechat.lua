-- helper/lib/apps/wechat.lua — 微信的 map 生成脚本（一个 app 一个可执行脚本）
--
-- 一份文件两种用法：
--   1) 直接执行 → 生成本 app 的 map（写回 helper/lib/app_wechat_map.lua）
--        ./tools/lua.sh helper/lib/apps/wechat.lua            # 只灌 static 区（幂等，不用开窗口）
--        ./tools/lua.sh helper/lib/apps/wechat.lua --learn    # 全量 discover + 真点击验收（需微信在前台）
--   参数（都可省，省了就用本文件里的默认值）：
--        --app "微信"       xdotool 能识别的窗口名（xdotool search --name），写进 map.window
--        --class wechat     map 里的 app 键
--        --buttons 'return { 搜索 = { x=287, y=51, w=392, h=35 } }'
--                          特殊按钮（中心点 + 尺寸）→ map.buttons
--        --window 'return { title="微信", class="wechat" }'   完整窗口描述，优先于 --app
--   2) 被引擎 loadfile → 返回 { class, static } 数据表（uimap.lua:M.static_regions 用）
--
-- ★真源规则（B 类控件）
--   B 类 = 悬停无反馈的大块控件（搜索框、结果面板、输入框、气泡区）。discover 只测
--   成排等距图标（A 类：rail/toolbar），这几个永远测不到，所以坐标只写在本文件里，
--   由本脚本落盘到 app_wechat_map.lua 的 regions（带 static=true）。
--   流程：agent 截图 read + ocr 定坐标 → 只改这个脚本 → 重跑本脚本 → map 更新。
--   不要手改 app_wechat_map.lua（那是产物）。引擎/工具本身不含任何 app 坐标。
--
-- 坐标是真实屏幕像素（微信全屏 2560x1440，窗口 2560x1408 @0,0）。
local M = {
    class = "wechat",
    -- 覆盖已有 static/手工 region；discover 实测的 rail/toolbar 不同名，互不影响。
    static = {
        titlebar = { x0 = 0, y0 = 0, x1 = 200, y1 = 40,
            note = "窗口左上标题区（先点它拿焦点，ctrl+f 无效）" },
        search = { x0 = 90, y0 = 28, x1 = 486, y1 = 74,
            note = "左栏顶部搜索框（标题栏下方，需真实点击而非 ctrl+f）" },
        title  = { x0 = 300, y0 = 20, x1 = 1200, y1 = 80,
            note = "会话标题（OCR 验收对方名字）" },
        candidates = { x0 = 160, y0 = 105, x1 = 950, y1 = 400,
            note = "搜索下拉候选面板（OCR 候选行）" },
        panel  = { x0 = 70, y0 = 80, x1 = 520, y1 = 1040,
            note = "左栏会话列表整列" },
        input  = { x0 = 760, y0 = 1105, x1 = 2500, y1 = 1235,
            note = "聊天输入框" },
        bubble = { x0 = 520, y0 = 100, x1 = 2560, y1 = 1040,
            note = "聊天区（气泡），发完只验底部 420px" },
    },
}

-- ---- 执行入口：仅当本文件被当作脚本跑时才生成 map ----
local src = (debug.getinfo(1, "S") or {}).source or ""
local me = src:gsub("^@", "")
local argv0 = os.getenv("LITE_MAPGEN_SELF") or (arg and arg[0]) or ""
local direct = false
if argv0 ~= "" and (argv0 == me or me:sub(-#argv0) == argv0) then direct = true end
if os.getenv("LITE_MAPGEN") == "1" then direct = true end

if not direct then return M end
-- 防递归：生成流程里 tool.run → inject_static → loadfile(本文件) 会回到这里（同一进程）。
-- busy 时只把自己当数据表返回，绝不重复执行生成。
if rawget(_G, "__LITE_MAPGEN_BUSY") then return M end
rawset(_G, "__LITE_MAPGEN_BUSY", true)

local dir = me:match("^(.*)[/\\][^/\\]*$") or "."
local helper = dir:gsub("/+$", ""):gsub("/lib/apps$", "")
local chunk, err = loadfile(helper .. "/uimap.lua")
if not chunk then
    io.stderr:write("cannot load " .. helper .. "/uimap.lua: " .. tostring(err) .. "\n")
    os.exit(1)
end
local tool = chunk()
local env = { helper_dir = helper, cwd = os.getenv("LITE_CWD") }
-- 参数：--app <xdotool 窗口名> / --class <map 键> / --buttons '<lua table>' / --learn
local o = tool.mapgen_args(arg, { app = M.class, class = M.class })
local req = { app = o.class, class = o.class, regions = M.static }
if o.window then req.window = o.window end
if o.buttons then req.buttons = o.buttons end

local out
if o.mode == "learn" then
    req.action = "learn"
    out = tool.run(req, env)
else
    -- 默认：只把 static 区灌进 map（不截图、不点击、幂等）
    req.action = "save"
    out = tool.run(req, env)
end
print(out)
rawset(_G, "__LITE_MAPGEN_BUSY", nil)
