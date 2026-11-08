-- wechat 插件：搜索联系人 → 打开聊天 → 输入/粘贴消息 → 回车发送。
-- 坐标全部来自设计空间（全屏 2560x1440）+ 实际窗口尺寸缩放；搜索框优先读
-- helper/lib/app_name_map.lua 里 mark 过的条目。每步都用 OCR 截图验收，
-- 失败时报出「哪一步 + 期望看到什么」，便于自修。
local ffi = require("ffi")

local D = {
    w = 2560, h = 1440,
    search = { x = 287, y = 50 },        -- 搜索输入框中心（实测：占位符 y≈45..60）
    panel = { x0 = 70, y0 = 80, x1 = 520, y1 = 300 }, -- 搜索候选面板
    row1 = { y = 143, pitch = 64 },      -- 首行结果中心 y、行距
    title = { x0 = 520, y0 = 28, x1 = 1400, y1 = 72 }, -- 会话标题栏
    input = { x = 1540, y = 1150 },      -- 输入框中心
    bubble = { x0 = 520, y0 = 100, x1 = 2560, y1 = 1040 }, -- 消息区
    zoom = 3,                            -- ocr 裁剪放大倍数（与 ocr_rect 的 300% 一致）
}

local M = {}

local _libs = {}

-- enter/leave：用完把微信收回后台、焦点还给原窗口（下面定义）
local enter, leave

local function lib(env)
    local root = (env and env.helper_dir) or "."
    if _libs[root] then return _libs[root] end
    local L = {}
    L.W = require("ffi.x11")
    L.xdo = require("ffi.xdo").new()
    L.OCR = require("ffi.ocr")
    L.map_path = root .. "/lib/app_name_map.lua"
    _libs[root] = L
    return L
end

local function load_map(L)
    local chunk = loadfile(L.map_path)
    if not chunk then return { apps = {} } end
    local ok, t = pcall(chunk)
    if not ok or type(t) ~= "table" then return { apps = {} } end
    t.apps = t.apps or {}
    return t
end

local function find_win(L, app)
    local p = ((load_map(L).apps[app] or {}).window) or {}
    local win = L.W.resolve({ name = p.title or app, class = p.class or app, pick = 1 })
    if not win then win = L.W.resolve({ class = p.class or app, pick = 1 }) end
    if not win then error("wechat 窗口没找到（先打开微信）") end
    L.last_win = win
    enter(L, win)
    return win
end

-- 设计空间 → 绝对屏幕坐标
local function abs(L, win, cx, cy)
    local g = L.xdo:geometry(win.id) or {}
    local gw, gh = g.w or D.w, g.h or D.h
    local sx, sy = gw / D.w, gh / D.h
    return math.floor((g.x or 0) + cx * sx), math.floor((g.y or 0) + cy * sy)
end

local function sleep(L, ms) ffi.C.usleep(ms * 1000) end

-- 激活微信前记住原焦点窗口；leave() 把焦点还回去并把微信最小化（= 再点一次图标进后台）
local focus_before = nil

enter = function(L, win)
    -- xdo:activate 内部已走 libxdo：xdo_map_window（去 iconify）→ 等 IsViewable
    -- → _NET_ACTIVE_WINDOW → xdo_raise_window（抬栈序）→ 等 active，返回是否可见。
    -- 不要自己再 XMapWindow：openbox 下和 iconify 状态打架，会卡在 unmapped。
    -- 注意 Win:refresh() 不更新 viewable，可见性一律实时查 map_state。
    if L.xdo:activate(win.id) then
        win.viewable = true
        return
    end
    L.xdo:activate(win.id)  -- 重试一次
    local a = L.xdo:_attrs(win.id)
    win.viewable = a and a.viewable or false
    if win.viewable then return end
    error(("微信窗口拉不到前台（viewable=%s active=%s vs win=%s）")
        :format(tostring(win.viewable), tostring(L.xdo:active()), tostring(win.id)))
end

-- 事情做完 = 再点一次任务栏图标 → 最小化回后台（openbox 认 XIconifyWindow）
leave = function(L, win)
    win = win or L.last_win
    focus_before = nil
    if not win then return end
    L.xdo:minimize(win.id)
    L.xdo:sync()
    sleep(L, 200)
end

-- openbox 会在点击事件后把"曾最小化"的窗口重新 iconify：每步交互前先确保可见
local function ensure(L, win)
    win = win or L.last_win
    if not win then return end
    local a = L.xdo:_attrs(win.id)
    if not a or not a.viewable or L.xdo:active() ~= win.id then
        L.xdo:activate(win.id)
        L.xdo:sync()
        sleep(L, 200)
    end
end

local function click(L, win, cx, cy)
    ensure(L, win)
    local ax, ay = abs(L, win, cx, cy)
    L.xdo:move_abs(ax, ay)
    L.xdo:sync()
    sleep(L, 120)
    L.xdo:click_abs(ax, ay)
    L.xdo:sync()
    sleep(L, 300)
    ensure(L, win)  -- 点击本身可能触发 openbox 重新 iconify，点完立刻恢复
    return ax, ay
end

local function shot(L, win, path)
    ensure(L, win)
    if win and win.raise then win:raise() end  -- 终端可能盖在微信上面，先抬窗再截
    L.xdo:sync()
    sleep(L, 250)
    os.remove(path)                                     -- 先删：截图失败时不能吃到旧图
    local ok, err = L.W.capture_screen(path)
    if not ok then error("截图失败: " .. tostring(err)) end
    return path
end

-- 绝对屏幕矩形 → 预处理放大裁剪 → OCR 文本
local function ocr_rect(L, win, x0, y0, x1, y1, tag)
    local ax0, ay0 = abs(L, win, x0, y0)
    local ax1, ay1 = abs(L, win, x1, y1)
    local w, h = math.max(ax1 - ax0, 8), math.max(ay1 - ay0, 8)
    local src = shot(L, win, "/tmp/wechat-shot-" .. (tag or "x") .. ".png")
    local out = "/tmp/wechat-ocr-" .. (tag or "x") .. ".png"
    local cmd = string.format(
        "convert %q -crop %dx%d+%d+%d +repage -colorspace Gray -level 25%%,85%% -sharpen 0x1 -resize 300%% %q"
        .. " >/dev/null 2>&1", src, w, h, ax0, ay0, out)
    os.remove(out)  -- 同上：convert 失败时不能读旧图
    os.execute(cmd)
    local probe = io.open(out)
    if not probe then error(("裁剪失败: %dx%d+%d+%d src=%s"):format(w, h, ax0, ay0, src)) end
    probe:close()
    return (L.OCR.text(out))
end

-- OCR 容错：按 UTF-8 字符切片比较，允许 1 字错（如 手→丰），
-- 或命中 ≥4 字前缀（长名尾部常被截断/认错）。空 want 视为「只看有没有文字」。
local function chars(s)
    local t = {}
    for c in (s or ""):gsub("%s+", ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        t[#t + 1] = c
    end
    return t
end

local function near(h, i, w, m, tol) -- 从 h[i] 起与 w 比 m 个字符，容忍 tol 字错
    local bad = 0
    for j = 1, m do
        if h[i + j - 1] ~= w[j] then
            bad = bad + 1
            if bad > tol then return false end
        end
    end
    return true
end

local function hit(hay, want)
    local h, w = chars(hay), chars(want)
    local n = #w
    if n == 0 then return false end
    local tol = n >= 4 and 1 or 0   -- 短词(<=3字)不容错，否则 2 字窗 1 错=乱命中
    for i = 1, #h - n + 1 do
        if near(h, i, w, n, tol) then return true end
    end
    return false
end

-- OCR 粗糙相似度：probe 的字符有多少比例出现在 hay 里（中文小字常错 1-2 个，如 后→合）
local function like(hay, want)
    local h, w = chars(hay), chars(want)
    if #w == 0 then return 0 end
    local pool = {}
    for _, c in ipairs(h) do pool[c] = (pool[c] or 0) + 1 end
    local n = 0
    for _, c in ipairs(w) do
        if (pool[c] or 0) > 0 then pool[c] = pool[c] - 1; n = n + 1 end
    end
    return n / #w
end

-- 绝对矩形 → OCR 文本 + boxes（boxes 坐标在放大 3 倍后的裁剪图内）
local function ocr_area(L, win, rect, tag)
    local ax0, ay0 = abs(L, win, rect.x0, rect.y0)
    local ax1, ay1 = abs(L, win, rect.x1, rect.y1)
    local w, h = math.max(ax1 - ax0, 8), math.max(ay1 - ay0, 8)
    local src = shot(L, win, "/tmp/wechat-shot-" .. (tag or "a") .. ".png")
    local out = "/tmp/wechat-area-" .. (tag or "a") .. ".png"
    os.execute(string.format(
        "convert %q -crop %dx%d+%d+%d +repage -colorspace Gray -level 25%%,85%% -sharpen 0x1 -resize 300%% %q >/dev/null 2>&1",
        src, w, h, ax0, ay0, out))
    local text, boxes = L.OCR.text(out)
    return text, boxes or {}, ax0, ay0
end

-- 候选面板里按名字定位那一行，返回设计空间坐标（box 中心反算回窗口坐标）
local function row_pt(L, win, rect, name, tag)
    local text, boxes, ax0, ay0 = ocr_area(L, win, rect, tag)
    local g = L.xdo:geometry(win.id) or {}
    local sx, sy = (g.w or D.w) / D.w, (g.h or D.h) / D.h
    local best
    for _, b in ipairs(boxes) do
        if hit(tostring(b.text or ""), name) then
            local cx = ax0 + (tonumber(b.x) or 0) / 3 + (tonumber(b.w) or 0) / 6
            local cy = ay0 + (tonumber(b.y) or 0) / 3 + (tonumber(b.h) or 0) / 6
            local dx = math.floor((cx - (g.x or 0)) / sx)
            local dy = math.floor((cy - (g.y or 0)) / sy)
            if not best or dy < best.y then best = { x = dx, y = dy, text = b.text } end
        end
    end
    return best, text
end

local function wait_text(L, win, rect, want, tag, tries, step)
    tries, step = tries or 8, step or 350
    local text
    for _ = 1, tries do
        text = ocr_rect(L, win, rect.x0, rect.y0, rect.x1, rect.y1, tag)
        if not want then
            if #text > 0 then return text end
        elseif hit(text, want) then
            return text
        end
        sleep(L, step)
    end
    return text
end

local function set_clipboard(text)
    local f = assert(io.open("/tmp/wechat-clip.txt", "wb"))
    f:write(text)
    f:close()
    -- xclip 读到 EOF 后会 fork 常驻剪贴板属主，父进程会一直等 -> 丢到后台再释放
    local ok = os.execute("sh -c 'xclip -selection clipboard -i < /tmp/wechat-clip.txt >/dev/null 2>&1 &'")
    return ok == 0 or ok == true
end

local function key(L, win, seq)
    win:key(seq)          -- Win:key(seq) 是 x11 的窗口方法（display():key(0,seq)）
    L.xdo:sync()
    sleep(L, 200)
end

-- 输入法切换：Shift 切中英文。纯 ASCII 先切英文再打，打完切回中文。
local function ime_ascii(L, win, on)
    key(L, win, "Shift_L")
    sleep(L, 250)
end

local function type_text(L, win, text)
    local ascii = not text:find("[\128-\255]")
    if ascii then ime_ascii(L, win, true) end
    win:type(text)
    L.xdo:sync()
    sleep(L, 400)
    if ascii then ime_ascii(L, win, false) end
end

-- 搜索框坐标：map 里 region=="search" 的条目优先
local function search_pt(L, app)
    for _, b in ipairs(((load_map(L).apps[app] or {}).buttons) or {}) do
        if b.region == "search" and tonumber(b.x) then
            return tonumber(b.x), tonumber(b.y)
        end
    end
    return D.search.x, D.search.y
end

local function do_search(L, win, app, name, no_clear)
    local sx, sy = search_pt(L, app)
    click(L, win, sx, sy)
    if not no_clear then
        key(L, win, "ctrl+a")
        key(L, win, "BackSpace")
    end
    if not set_clipboard(name) then error("xclip 写剪贴板失败") end
    key(L, win, "ctrl+v")
    sleep(L, 800)
    local text = wait_text(L, win, D.panel, name, "panel", 10, 350)
    if not hit(text, name) then
        error(string.format("搜索 %q 后候选面板没看到该名字（OCR=%q）", name, text or ""))
    end
    return text
end

-- ---- 动作 -------------------------------------------------------------

-- search: 只搜索，返回候选面板 OCR 文本
function M.search(args, env)
    local L = lib(env)
    local app = args.app or "wechat"
    local win = find_win(L, app)
    local text = do_search(L, win, app, assert(args.name, "required: name"))
    return { step = "search", name = args.name, panel_ocr = text }
end

-- open: 搜索 → 点第 index 行结果 → OCR 标题栏确认进了会话
function M.open(args, env)
    local L = lib(env)
    local app = args.app or "wechat"
    local win = find_win(L, app)
    local name = assert(args.name, "required: name")
    do_search(L, win, app, name)
    local idx = tonumber(args.index) or 1
    -- 第一条候选点一下就进会话，直接点固定行坐标，不再多跑一次 OCR 定位
    local rx, ry = args.rx or D.search.x, D.row1.y + (idx - 1) * (args.pitch or D.row1.pitch)
    click(L, win, rx, ry)
    local title = wait_text(L, win, D.title, name, "title", 6, 250)
    if not hit(title, name) then
        -- 兜底：固定行没点中时，用 OCR 反算那一行的位置再点一次
        local rp = row_pt(L, win, D.panel, name, "row")
        if rp then
            click(L, win, rp.x, rp.y)
            title = wait_text(L, win, D.title, name, "title", 8, 300)
        end
    end
    if not hit(title, name) then
        error(string.format("点第 %d 行后标题栏没变成 %q（OCR=%q）", idx, name, title or ""))
    end
    return { step = "open", name = name, index = idx, title_ocr = title }
end

-- send: 点输入框 → 粘贴/输入 → OCR 确认文字在输入框 → 回车 → 确认输入框已空
function M.send(args, env)
    local L = lib(env)
    local app = args.app or "wechat"
    local win = find_win(L, app)
    local text = assert(args.text, "required: text")
    local ipt = D.input
    if args.ix and args.iy then ipt = { x = args.ix, y = args.iy } end
    click(L, win, ipt.x, ipt.y)
    if args.clear ~= false then
        key(L, win, "ctrl+a")
        key(L, win, "BackSpace")
    end
    if args.paste == false then
        type_text(L, win, text)
    else
        if not set_clipboard(text) then error("xclip 写剪贴板失败") end
        key(L, win, "ctrl+v")
    end
    sleep(L, 500)
    local input_rect = { x0 = 520, y0 = 1000, x1 = 2500, y1 = 1300 }
    local probe = text:sub(1, math.min(#text, 6))
    local seen = wait_text(L, win, input_rect, probe, "input", 8, 300)
    local inratio = hit(seen, probe) and 1 or like(seen, probe)
    if (seen or "") == "" or inratio < 0.6 then
        error(string.format("粘贴后输入框没看到文本（期望 %q，OCR=%q）", probe, seen or ""))
    end
    key(L, win, "Return")
    sleep(L, 900)
    local after = wait_text(L, win, input_rect, nil, "sent", 4, 400)
    if after:find(probe, 1, true) then
        error(string.format("回车后输入框仍有文本，可能没发出去（OCR=%q）", after))
    end
    -- 消息区最后一屏 OCR，确认气泡里出现同一串字
    local bubbles = wait_text(L, win, D.bubble, probe, "bubble", 5, 400)
    local bratio = hit(bubbles, probe) and 1 or like(bubbles, probe)
    return { step = "send", text = text, sent = bratio >= 0.6, bubble_seen = hit(bubbles, probe),
        input_ratio = inratio, bubble_ratio = bratio, input_after = after, bubble_ocr = bubbles }
end

-- 一次跑全链路：搜名字 → 进会话 → 发消息（args.text 可省，仅进会话）
function M.run(args, env)
    local L = lib(env)
    local app = args.app or "wechat"
    local name = assert(args.name, "required: name")
    local out = {}
    local win = find_win(L, app)
    do_search(L, win, app, name)
    out[#out + 1] = "searched: " .. name
    local rp = row_pt(L, win, D.panel, name, "row")
    if rp then
        click(L, win, rp.x, rp.y)
    else
        click(L, win, args.rx or D.search.x, D.row1.y + ((tonumber(args.index) or 1) - 1) * D.row1.pitch)
    end
    sleep(L, 700)
    local title = wait_text(L, win, D.title, name, "title", 10, 350)
    if not hit(title, name) then
        error(string.format("进会话失败：标题栏 OCR=%q，期望含 %q", title or "", name))
    end
    out[#out + 1] = "opened: " .. title
    if args.text and args.text ~= "" then
        local r = M.send({ app = app, text = args.text }, env)
        out[#out + 1] = string.format("sent: %s (bubble_seen=%s)", args.text, tostring(r.sent))
    end
    return table.concat(out, "\n")
end

return {
    schema = {
        name = "wechat",
        description = "操作微信：搜索联系人/群、进入聊天框、输入或粘贴消息并回车发送。每步都截图 OCR 验收。",
        parameters = {
            type = "object",
            properties = {
                action = { type = "string", enum = { "run", "search", "open", "send" },
                    description = "run=全链路；search=只搜；open=搜索并进会话；send=往当前会话发消息" },
                app = { type = "string", description = "窗口 app 名，默认 wechat" },
                name = { type = "string", description = "联系人/群名（search/open/run 必填）" },
                index = { type = "number", description = "点第几行候选，默认 1" },
                pitch = { type = "number", description = "候选行距（设计空间），默认 64" },
                text = { type = "string", description = "要发送的消息" },
                paste = { type = "boolean", description = "true=剪贴板 ctrl+v（默认，支持中英混排），false=直接键入" },
                clear = { type = "boolean", description = "发前是否 ctrl+a 清空输入框，默认 true" },
                background = { type = "boolean", description = "做完把微信收到后台并还焦点给原窗口，默认 true" },
            },
            required = { "action" },
        },
    },
    run = function(args, env)
        local act = args.action or "run"
        local fn = M[act]
        if not fn then error("unknown action: " .. tostring(act) .. " (required: run|search|open|send)") end
        local sub = { helper_dir = env and env.helper_dir }
        local ok, r = pcall(fn, args, sub)
        if args.background ~= false then
            local L2 = lib(sub)
            local ok2, err2 = pcall(leave, L2, L2.last_win)
            if not ok2 then
                local le = "leave failed: " .. tostring(err2)
                if type(r) == "string" then r = r .. " (" .. le .. ")" else r = r or le end
            end
        end
        if not ok then error(r, 0) end
        if type(r) == "table" then
            local parts = {}
            for _, k in ipairs({ "step", "name", "index", "title_ocr", "panel_ocr", "text", "sent", "input_after", "bubble_ocr" }) do
                if r[k] ~= nil then parts[#parts + 1] = k .. "=" .. tostring(r[k]) end
            end
            return table.concat(parts, " | ")
        end
        return r
    end,
}
