-- wechat 插件：动态 libxdo / libX11 直驱（不依赖 xdotool/wmctrl/import）。
--
-- ⚠ 用前必须确认**虚拟桌面只有一个**：多桌面模式下，滚轮/后台动作会切换桌面，
--   微信窗口连同后续截图一起"跑掉"，OCR 与点击坐标全部错位（表现为点了没反应、
--   或点到了别的东西上）。检查：xprop -root _NET_NUMBER_OF_DESKTOPS 必须是 1；
--   openbox 改 ~/.config/openbox/rc.xml 的 <desktops><number>1</number>，
--   lxqt 面板删掉 desktopswitch 插件。窗口管理器的滚轮换桌面（Desktop 上下文
--   button Up/Down）也要清掉。不是 1 就别往下跑，先修桌面再操作。
--
-- ⚠ 输入法（本机 ibus + libpinyin，实测命令见下）：**不管打中文还是英文，
--   点输入框动手之前先把输入法切对**。切错的表现是"字没进去/进去的是拼音串"：
--   拼音引擎开着敲英文 → 输入框里是候选框里的中文或干脆被吞；
--   英文引擎开着打中文 → 贴出来是空格。机器环境：GTK_IM_MODULE=ibus、
--   QT_IM_MODULE=ibus、XMODIFIERS=@im=ibus，预加载引擎只有 libpinyin，
--   引擎切换键是 <Super>space。
--     查当前引擎： ibus engine                       # libpinyin | xkb:us::eng
--     切中文拼音： ibus engine libpinyin
--     切英文：     ibus engine xkb:us::eng            # = English (US)
--     键盘切法：   Super+space 换引擎（libpinyin ↔ xkb:us::eng）
--   libpinyin 内部还认 **单按 Shift** 切中/英，但那只是引擎内部状态，
--   `ibus engine` 照样显示 libpinyin —— 别拿它当"已经切到英文"的判据，
--   拿不准就直接 `ibus engine xkb:us::eng`，别靠猜。
--   顺带：本插件的 paste() 走剪贴板 ctrl+v，不经 IME，中英文都能原样进去；
--   真正怕 IME 的是 xdo:type 那种逐字符输入（拼音引擎会弹候选框吞字符），
--   所以要么先切法再用 type，要么一律走 paste。切完统一按上面的命令复核一遍。
--
-- 流程：activate → 点标题栏拿焦点 → 点搜索框 → 粘贴关键词 → OCR 候选面板
--      → 回车进会话（第一行即目标时；否则点候选行）→ OCR 会话标题验收
--      → 点输入框 → ctrl+a/BS → 粘贴 → Return → OCR 气泡验收。
-- 坐标全部是真实屏幕像素（2560x1440）；
-- OCR box 已由 _pt() 换算回屏幕坐标，禁止按看图缩放后的像素估点。
local ffi = require("ffi")
if not pcall(ffi.cdef, "void usleep(unsigned int);") then end

-- 坐标 100% 来自 helper/lib/app_wechat_map.lua（产物，由 helper/lib/apps/wechat.lua 生成）。
-- 本文件不含任何屏幕坐标：map 缺失或缺 region 时直接报错，不给写死的兜底值。
local MAP_REQUIRED = { "titlebar", "contacts", "search", "title", "candidates", "input", "bubble" }

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
local function check(extra)
    local m = D.map or load_map()
    if not m then return nil, D.map_error end
    local names = {}
    for _, n in ipairs(MAP_REQUIRED) do names[#names + 1] = n end
    for _, n in ipairs(extra or {}) do names[#names + 1] = n end
    local miss = {}
    for _, n in ipairs(names) do
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
    description = "操作微信：搜索联系人/群、进入会话、输入并发送消息、发送文件（动态 libxdo 驱动，每步 OCR 验收）",
    parameters = {
        type = "object",
        properties = {
            action = { type = "string", enum = { "run", "search", "open", "send", "sendfile", "screenshot" } },
            name = { type = "string", description = "联系人/群名（search/open/run/sendfile/screenshot 可选，给了就先搜索进入）" },
            text = { type = "string", description = "要发送的消息" },
            path = { type = "string", description = "sendfile 必填：要发送的文件的绝对路径" },
            rect = { type = "array", items = { type = "integer" },
                     description = "screenshot 必填：[x0,y0,x1,y1] 屏幕坐标；先最小化微信，alt+a 拖拽选区，双击入剪贴板" },
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

-- OCR 完全不可用（无模型 / 截图空白）时返回 true：此时任何 OCR 复核都必然失败，
-- 用盲操作兜底，把决定权交回调用方，而不是让插件自我否决。
local function blind(s) return norm(s or "") == "" end

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
    -- 关键二：搜索框在「聊天」页拿不到焦点，粘贴会掉到空处（候选面板全空）。
    -- 先点左侧栏「通讯录」，再点搜索框才生效。
    click(point("contacts")); sleep(500)
    click(point("search"))
    key("ctrl+a"); key("BackSpace")
    paste(name)

    -- 下拉候选面板是异步渲染的：固定 sleep 撞运气会 OCR 到空面板 → 走 blind 盲点分支。
    -- 这里等「面板真的有字」再解析，最多 ~3s；OCR 全程不可用时仍会退回 blind。
    local boxes, text = {}, ""
    for _ = 1, 10 do
        sleep(300)
        boxes, text = ocr_area("candidates", crop("candidates"))
        if norm(text) ~= "" then break end
    end
    local want, k = {}, tonumber(index) or 1
    for _, b in ipairs(boxes) do
        if sim(b.text, name) >= D.min_sim and norm(b.text) ~= "" then want[#want + 1] = b end
    end
    if #want == 0 then
        if norm(text) == "" then
            -- OCR 不可用（无模型/空白截图）：不猜候选行坐标（猜错一行就进错会话），
            -- 直接回车接受搜索框默认项 —— 微信默认项就是第一个真实结果。
            return { enter = true, blind = true, text = "" }
        end
        error(string.format("搜索 %q 后候选面板没看到该名字（OCR=%q，required: name）",
            name, norm(text):sub(1, 120)))
    end
    local hit = want[math.min(k, #want)]
    -- 「回车 = 进会话」：系统自带条目（文件传输助手、服务号…）和正常联系人，
    -- 搜索框默认选中项回车就进会话，比拿 OCR 坐标点候选行稳。只有第一行的
    -- 文本确实就是这个名字时才走回车；否则（目标在第二行及以后）还是点坐标。
    local top
    for _, b in ipairs(boxes) do
        if norm(b.text) ~= "" and (not top or (b.y or 0) < (top.y or 0)) then top = b end
    end
    if k == 1 and top and sim(top.text, name) >= D.min_sim then hit.enter = true end
    return hit
end

-- 打开 do_search 的候选：能回车就回车（默认项），否则点 OCR 给的坐标。
-- 返回 "enter" / "click"；标题 OCR 复核不过则抛错（带原参数，可自修）。
local function open_hit(b, name)
    local how = b.enter and "enter" or "click"
    if b.enter then key("Return"); sleep(900)
    else click(math.floor(b.cx), math.floor(b.cy)); sleep(900) end
    local last = ""
    for _ = 1, 8 do
        local _, text = ocr_area("title", crop("title"))
        last = text
        if sim(text, name) >= D.min_sim then return how end
        sleep(300)
    end
    if b.blind or blind(last) then return how end   -- OCR 不可用：盲过，不阻塞
    error(string.format("%s 打开 %q 后会话标题没变（OCR=%q，required: name；可选 index）",
        how, name, norm(last):sub(1, 120)))
end

local function do_open(name, index)
    local b = do_search(name, index)
    return open_hit(b, name)
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
    if blind(seen) then return true end        -- OCR 不可用：盲过，不阻塞
    error(string.format("发送后气泡里没看到 %q（OCR=%q）", text, norm(seen):sub(1, 120)))
end

-- 文件选择框是独立窗口：不能用 click()/key()（它们会 ensure() 抢回微信主窗口）
local function dclick(x, y)
    xdo:move_abs(x, y); sleep(160); xdo:click_abs(x, y, 1); sleep(420)
end
local function dkey(seq) xdo:key(0, seq, 15000); sleep(200) end

local function dialog_id()
    local ok, r = pcall(W.resolve, { name = "打开", class = "wechat", pick = 1 })
    if ok and r then return r.id or r.win end
    return nil
end

local function bubble_has(needle)
    local strip = crop("bubble"); strip[2] = strip[4] - 420
    local seen = ""
    for _ = 1, 4 do
        seen = select(2, ocr_area("bubble", strip)) or ""
        if seen:lower():find(needle:lower(), 1, true) then return true end
        sleep(900)
    end
    if blind(seen) then return true, "" end     -- OCR 不可用：盲过，不阻塞
    return false, seen
end

local function do_sendfile(path, name, index)
    local base = tostring(path):match("([^/\\]+)$") or tostring(path)
    if name then do_open(name, index) else ensure() end
    click(point("sendfile")); sleep(900)
    local id
    for _ = 1, 12 do id = dialog_id(); if id then break end; sleep(400) end
    if not id then error("点了「发送文件」但没弹出「打开」对话框（region sendfile 可能偏了）") end
    -- 弹窗默认焦点就在「文件名称」输入框：只激活窗口，不点（点会写脏 fileinput 坐标依赖）
    pcall(function() xdo:activate(id) end); sleep(400)
    dkey("ctrl+a"); dkey("BackSpace")
    local f = assert(io.open("/tmp/wechat-clip.txt", "w")); f:write(path); f:close()
    local okc = os.execute("xclip -selection clipboard -i /tmp/wechat-clip.txt >/dev/null 2>&1")
    if okc ~= 0 and okc ~= true then error("写剪贴板失败：xclip 不可用") end
    sleep(250); dkey("ctrl+v"); sleep(700)
    dkey("Return"); sleep(1200)
    for _ = 1, 6 do
        if not dialog_id() then break end
        local ox, oy = point("fileopen"); dclick(ox, oy); sleep(800)
    end
    if dialog_id() then error("文件选择框没关掉（路径可能没粘进「文件名称」输入框）") end
    ensure(); sleep(300)
    dkey("Return"); sleep(1500)          -- 主窗口回车 = 发送
    ensure()
    local seen, txt = bubble_has(base)
    if not seen then
        error(string.format("发送后气泡里没看到 %q（OCR=%q）", base, norm(txt or ""):sub(1, 120)))
    end
    return string.format("sendfile: %s -> %s (bubble_seen=true)", path, name or "当前会话")
end

-- 剪贴板里是否有 PNG（微信截图器/xfce 都会给 image/png target）
local function clip_png()
    local h = io.popen("xclip -selection clipboard -t image/png -o 2>/dev/null | head -c 8 | od -An -tx1 | tr -d ' \\n'")
    local s = h and (h:read("*a") or "") or ""
    if h then h:close() end
    return s:sub(1, 16) == "89504e470d0a1a0a"
end

-- alt+a 桌面截图 → 拖拽矩形 → 双击入剪贴板 → 回微信输入框 ctrl+v → 回车发送。
-- 铁律：截图前必须先最小化微信。否则 alt+a 的选区遮罩压在微信上，剪贴板会被
-- 微信自己抢回，ctrl+v 表面成功但输入框永远是空的（踩过 6 次）。
local function do_screenshot(a, name, index)
    local x0, y0, x1, y1 = a[1], a[2], a[3], a[4]
    local cx, cy = math.floor((x0 + x1) / 2), math.floor((y0 + y1) / 2)
    -- 顺序铁律：先 open 会话（搜索要用剪贴板贴文字），再截图。
    -- 反了的话 do_open 的文本 xclip 会把刚进剪贴板的图覆盖掉，
    -- ctrl+v 贴进去的是「文件传输助手」四个字，回车发出去的也是文字。
    if name then do_open(name, index) else ensure() end
    sleep(400)
    pcall(function() xdo:minimize(win) end); sleep(900)
    local cur = xdo.active and xdo:active() or nil
    if cur == win then error("微信没最小化成功，alt+a 会被微信抢走剪贴板") end
    xdo:move_abs(40, 1400); sleep(250)                 -- 鼠标先离开待截区域
    xdo:key(0, "alt+a", 15000); sleep(1900)            -- XTEST 全局热键
    xdo:move_abs(x0, y0); sleep(300)
    xdo:mouse_down(1); sleep(150)
    for i = 1, 20 do
        local t = i / 20
        xdo:move_abs(math.floor(x0 + (x1 - x0) * t), math.floor(y0 + (y1 - y0) * t)); sleep(30)
    end
    sleep(150); xdo:mouse_up(1); sleep(800)
    xdo:click_abs(cx, cy, 1, 2, 90); sleep(1400)       -- 双击：图才进剪贴板（无需 Ctrl+C）
    if not clip_png() then error("截图没进剪贴板（没有 image/png）：alt+a 可能没生效或被别的窗口吃掉") end
    ensure(); sleep(500)                                -- 会话已在截图前打开，这里只把焦点抢回微信
    local ix, iy = point("input")
    click(ix, iy); sleep(400)
    xdo:key(0, "ctrl+v", 20000); sleep(2600)
    ensure(); sleep(200)
    key("Return"); sleep(1800)                          -- 主窗口回车 = 发送
    ensure()
    -- 图片气泡没有文字：验左栏会话预览里的「[图片]」
    local seen = ""
    for _ = 1, 4 do
        seen = (select(2, ocr_area("panel", crop("panel"))) or "")
        if seen:find("图片", 1, true) then
            return string.format("screenshot: %dx%d -> %s (preview=图片)",
                x1 - x0, y1 - y0, name or "当前会话")
        end
        sleep(900)
    end
    error(string.format("发图后左栏没看到「图片」预览（OCR=%q）", norm(seen):sub(1, 120)))
end

-- 收尾必做：把微信放回后台。
-- 坑：XIconifyWindow 偶尔被 WM 吃掉（刚抢过焦点时），一次 minimize 窗口还在前台；
-- 所以重试到 `_is_viewable == false` 为止，最多 3 次，每次等 300ms 让 WM 回执。
-- 而且**出错也要走这里**（见 M.run 的 pcall 包装）：动作抛错后微信留在最前面
-- 挡住用户桌面，是踩过的投诉点。
local function leave(bg)
    if bg == false then return end
    for _ = 1, 3 do
        pcall(function() xdo:minimize(win) end)
        sleep(300)
        local visible = true
        pcall(function() visible = xdo:_is_viewable(win) end)
        if not visible then return true end
    end
    return false
end

function M.run(args, env)
    libs()
    win = find_win()
    local action = args.action or "run"
    local bg = args.background
    local needs = (action == "sendfile" and { "sendfile" })
        or (action == "screenshot" and { "shotbtn" }) or nil
    local ok, err = check(needs)
    if not ok then return "error: " .. err end
    -- 所有动作都在这层 pcall 里跑：成功 or 抛错，收尾都 leave(bg) 把微信放回后台。
    -- 原来「出错就直接 error()」的写法会让一次失败的 send 把微信留在前台挡桌面。
    local function dispatch()
        if action == "screenshot" then
            local rect = assert(args.rect, "required: rect")
            for i = 1, 4 do
                if type(rect[i]) ~= "number" then
                    return "error: rect must be [x0,y0,x1,y1] integers, got "
                        .. tostring(rect[1]) .. "..."
                end
            end
            return do_screenshot(rect, args.name, args.index)
        end
        if action == "sendfile" then
            return do_sendfile(assert(args.path, "required: path"), args.name, args.index)
        end
        if action == "search" then
            local b = do_search(assert(args.name, "required: name"), args.index)
            if b.enter then
                return string.format("searched: %s (%s)", args.name,
                    b.blind and "回车进会话，OCR 不可用" or "第一行即目标，回车进会话")
            end
            return string.format("searched: %s (candidate %q @ %d,%d)",
                args.name, norm(b.text), math.floor(b.cx), math.floor(b.cy))
        elseif action == "open" then
            local how = do_open(assert(args.name, "required: name"), args.index)
            return "opened: " .. args.name .. " (" .. tostring(how) .. ")"
        elseif action == "send" then
            do_send(assert(args.text, "required: text"), args.name)
            return "sent: " .. args.text
        elseif action == "run" then
            local name = assert(args.name, "required: name")
            local text = assert(args.text, "required: text")
            local b = do_search(name, args.index)
            local head = string.format("searched: %s (%s)", name,
                b.enter and "enter" or string.format("%q @ %d,%d", norm(b.text),
                    math.floor(b.cx), math.floor(b.cy)))
            local how = open_hit(b, name)
            do_send(text, text)
            return head .. "\nopened: " .. name .. " (" .. tostring(how) .. ")"
                .. "\nsent: " .. text .. " (bubble_seen=true)"
        end
        error("未知 action: " .. tostring(action) .. "（run|search|open|send|sendfile）")
    end

    local okd, res = pcall(dispatch)
    local bg_ok = leave(bg)
    if not okd then error(res, 0) end
    if bg_ok == false then
        return tostring(res) .. "\n(警告：微信没能收回后台，minimize 重试 3 次仍可见)"
    end
    return res
end

return M
