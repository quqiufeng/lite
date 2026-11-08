-- wechat 插件：动态 libxdo / libX11 直驱（不依赖 xdotool/wmctrl/import）。
-- 流程：activate → 点标题栏拿焦点 → 点搜索框 → 粘贴关键词 → OCR 候选面板
--      → 点候选 → OCR 会话标题验收 → 点输入框 → ctrl+a/BS → 粘贴 → Return
--      → OCR 气泡验收。坐标全部是真实屏幕像素（2560x1440）；
-- OCR box 已由 _pt() 换算回屏幕坐标，禁止按看图缩放后的像素估点。
local ffi = require("ffi")
if not pcall(ffi.cdef, "void usleep(unsigned int);") then end

-- 坐标 100% 来自 helper/lib/app_wechat_map.lua（产物，由 helper/lib/apps/wechat.lua 生成）。
-- 本文件不含任何屏幕坐标：map 缺失或缺 region 时直接报错，不给写死的兜底值。
local MAP_REQUIRED = { "titlebar", "search", "title", "candidates", "input", "bubble" }

local function map_candidates()
    local here = (debug.getinfo(1, "S") or {}).source or ""
    here = here:gsub("^@", "")
    local dir = here:match("^(.*)[/\\][^/\\]*$") or "."
    local cwd = os.getenv("LITE_CWD") or "."
    return { dir .. "/lib/app_wechat_map.lua", cwd .. "/helper/lib/app_wechat_map.lua" }
end

local D = { min_sim = 0.5 }   -- min_sim 是 OCR 阈值，不是坐标（拍照常把手认成丰）

local function load_map()
    local tried = map_candidates()
    for _, p in ipairs(tried) do
        local ok, m = pcall(dofile, p)
        if ok and type(m) == "table" and type(m.regions) == "table" then
            D.map_path, D.map = p, m
            return m
        end
    end
    D.map_error = string.format(
        "wechat map 读不到： %s\n重新生成： ./tools/lua.sh helper/lib/apps/wechat.lua",
        table.concat(tried, " | "))
    return nil
end

local function region(name)
    local m = D.map or load_map()
    if not m then error(D.map_error) end
    local g = m.regions[name]
    if type(g) ~= "table" or not g.x0 then
        error(string.format("wechat map 缺 region %q（%s）；把坐标写进 helper/lib/apps/wechat.lua 后重跑生成脚本",
            name, D.map_path))
    end
    return g
end

local function crop(name)
    local g = region(name)
    return { g.x0, g.y0, g.x1, g.y1 }
end

local function point(name)
    local g = region(name)
    return math.floor((g.x0 + g.x1) / 2), math.floor((g.y0 + g.y1) / 2)
end

-- 开跑前一次性把需要的 region 全查一遍，缺哪个直接列名字（fail fast，不半途炸）
local function check()
    local m = D.map or load_map()
    if not m then return nil, D.map_error end
    local miss = {}
    for _, n in ipairs(MAP_REQUIRED) do
        local g = m.regions[n]
        if type(g) ~= "table" or not g.x0 then miss[#miss + 1] = n end
    end
    if #miss > 0 then
        return nil, string.format("wechat map 缺 region: %s（%s）；坐标写进 helper/lib/apps/wechat.lua 后重跑生成脚本",
            table.concat(miss, ","), D.map_path)
    end
    return m
end

local M = {}
M.schema = {
    name = "wechat",
    description = "操作微信：搜索联系人/群、进入会话、输入并发送消息（动态 libxdo 驱动，每步 OCR 验收）",
    parameters = {
        type = "object",
        properties = {
            action = { type = "string", enum = { "run", "search", "open", "send" } },
            name = { type = "string", description = "联系人/群名（search/open/run 必填）" },
            text = { type = "string", description = "要发送的消息" },
            index = { type = "integer", description = "第几行候选，默认 1" },
            background = { type = "boolean", description = "做完最小化微信，默认 true" },
        },
        required = { "action" },
    },
}

local W, xdo, OCR
local win

local function sleep(ms) ffi.C.usleep(ms * 1000); if xdo then xdo:sync() end end

local function libs()
    if not W then
        W = require("ffi.x11")
        xdo = require("ffi.xdo").new()
        OCR = require("ffi.ocr")
    end
end

local function find_win()
    libs()
    local ok, r = pcall(W.resolve, { name = "微信", class = "wechat", pick = 1 })
    local id = ok and r and (r.id or r.win) or (ok and type(r) == "number" and r)
    if not id then error("wechat 窗口没找到（先打开微信，并确保不在最小化状态）") end
    return id
end

-- 每步前都重新激活：任何键盘事件都可能让 openbox 把微信收回后台
local function ensure()
    local cur = xdo.active and xdo:active() or nil
    if cur ~= win then pcall(function() xdo:activate(win) end) end
    sleep(250)
end

local function click(x, y)
    ensure()
    xdo:move_abs(x, y); sleep(160)
    xdo:click_abs(x, y, 1); sleep(420)
    ensure()
end

local function key(seq)
    ensure(); xdo:key(0, seq, 15000); sleep(200)
end

local function paste(text)
    local f = assert(io.open("/tmp/wechat-clip.txt", "w")); f:write(text); f:close()
    -- xclip -i 在本机同步退出（3ms），可安全接力
    local ok = os.execute("xclip -selection clipboard -i /tmp/wechat-clip.txt >/dev/null 2>&1")
    if ok ~= 0 and ok ~= true then error("写剪贴板失败：xclip 不可用") end
    sleep(250); key("ctrl+v"); sleep(800)
end

local function norm(s)
    return (tostring(s or ""):gsub("[%s%p]", ""):gsub("[,。，、]", ""))
end

-- 编辑距离相似度：OCR 常把同形字认错（手/丰、记/讠己…）
local function sim(a, b)
    a, b = norm(a), norm(b)
    if a == "" or b == "" then return 0 end
    if a:find(b, 1, true) or b:find(a, 1, true) then return 1 end
    local prev = {}
    for j = 0, #b do prev[j] = j end
    for i = 1, #a do
        local cur = { [0] = i }
        for j = 1, #b do
            local c = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
            cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + c)
        end
        prev = cur
    end
    return 1 - prev[#b] / math.max(#a, #b)
end

-- 截屏 + 裁剪 + OCR，返回 boxes（坐标已换回屏幕像素）和全文
local function ocr_area(tag, r)
    ensure(); sleep(200)
    local shot = "/tmp/wechat-shot.png"
    W.capture_screen(shot)
    local x0, y0, x1, y1 = r[1], r[2], r[3], r[4]
    local crop = "/tmp/wechat-ocr-" .. tag .. ".png"
    os.execute(string.format(
        "convert %s -crop %dx%d+%d+%d +repage -colorspace Gray -level 25%%,85%% -sharpen 0x1 %s",
        shot, x1 - x0, y1 - y0, x0, y0, crop))
    local boxes = OCR.run(crop) or {}
    for _, b in ipairs(boxes) do
        b.cx = x0 + (b.x or 0) + (b.w or 0) / 2
        b.cy = y0 + (b.y or 0) + (b.h or 0) / 2
    end
    return boxes, OCR.text(crop) or ""
end

local function best_hit(boxes, name)
    local best, score = nil, 0
    for _, b in ipairs(boxes) do
        local s = sim(b.text, name)
        if s > score then best, score = b, s end
    end
    return best, score
end

local function do_search(name, index)
    ensure()
    click(point("titlebar"))                   -- 关键：ctrl+f 无效，必须先点标题栏
    click(point("search"))
    key("ctrl+a"); key("BackSpace")
    paste(name); sleep(600)

    local boxes, text = ocr_area("candidates", crop("candidates"))
    local want, k = {}, tonumber(index) or 1
    for _, b in ipairs(boxes) do
        if sim(b.text, name) >= D.min_sim and norm(b.text) ~= "" then want[#want + 1] = b end
    end
    if #want == 0 then
        error(string.format("搜索 %q 后候选面板没看到该名字（OCR=%q，required: name）",
            name, norm(text):sub(1, 120)))
    end
    return want[math.min(k, #want)]
end

local function do_open(name, index)
    local b = do_search(name, index)
    click(math.floor(b.cx), math.floor(b.cy)); sleep(900)
    for i = 1, 8 do
        local _, text = ocr_area("title", crop("title"))
        if sim(text, name) >= D.min_sim then return true end
        sleep(300)
    end
    error(string.format("点了候选 %q 但会话标题没变（OCR=%q）", name, norm(OCR.text("/tmp/wechat-ocr-title.png"))))
end

local function do_send(text, name)
    ensure()
    click(point("input"))
    key("ctrl+a"); key("BackSpace")
    paste(text); sleep(300)
    key("Return"); sleep(1200)
    -- 只 OCR 聊天区底部条带：整块聊天区太大，det 会漏掉最新那条小气泡
    local strip = crop("bubble")
    strip[2] = strip[4] - 420
    local seen = ""
    for _ = 1, 3 do
        seen = select(2, ocr_area("bubble", strip))
        if not name or sim(seen, name) >= D.min_sim then return true end
        sleep(600)
    end
    error(string.format("发送后气泡里没看到 %q（OCR=%q）", text, norm(seen):sub(1, 120)))
end

local function leave(bg)
    if bg == false then return end
    pcall(function() xdo:minimize(win) end); sleep(200)
end

function M.run(args, env)
    libs()
    win = find_win()
    local action = args.action or "run"
    local bg = args.background
    local ok, err = check()
    if not ok then return "error: " .. err end
    if action == "search" then
        local b = do_search(assert(args.name, "required: name"), args.index)
        leave(bg)
        return string.format("searched: %s (candidate %q @ %d,%d)",
            args.name, norm(b.text), math.floor(b.cx), math.floor(b.cy))
    elseif action == "open" then
        do_open(assert(args.name, "required: name"), args.index)
        leave(bg)
        return "opened: " .. args.name
    elseif action == "send" then
        do_send(assert(args.text, "required: text"), args.name)
        leave(bg)
        return "sent: " .. args.text
    elseif action == "run" then
        local name = assert(args.name, "required: name")
        local text = assert(args.text, "required: text")
        local b = do_search(name, args.index)
        local head = string.format("searched: %s (%q @ %d,%d)", name, norm(b.text),
            math.floor(b.cx), math.floor(b.cy))
        click(math.floor(b.cx), math.floor(b.cy)); sleep(900)
        local opened = false
        for _ = 1, 8 do
            local _, t = ocr_area("title", crop("title"))
            if sim(t, name) >= D.min_sim then opened = true break end
            sleep(300)
        end
        if not opened then error("进入会话失败：标题未匹配 " .. name) end
        do_send(text, text)
        leave(bg)
        return head .. "\nopened: " .. name .. "\nsent: " .. text .. " (bubble_seen=true)"
    end
    error("未知 action: " .. tostring(action) .. "（run|search|open|send）")
end

return M
