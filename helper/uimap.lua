-- uimap 工具：视觉定位 → 真实点击 → 截图 diff 确认 → 写入 app_name_map.lua。
-- 与 agent 同进程，窗口操作走 lua/ffi/x11.lua + xdo。
local U, X, seen = nil, nil, {}

local function lib(env)
    if U then return U end
    local dir = (env and env.helper_dir) or "helper"
    dir = dir:gsub("/+$", "")
    local chunk, err = loadfile(dir .. "/lib/uimap.lua")
    if not chunk then error("cannot load uimap.lua: " .. tostring(err)) end
    U = chunk()
    U.map_path = dir .. "/lib/app_name_map.lua"
    return U
end

local function winlib()
    if X then return X end
    X = require("ffi.x11")
    return X
end

local function load_map(U)
    local chunk = loadfile(U.map_path)
    if not chunk then return { apps = {} } end
    local ok, t = pcall(chunk)
    if not ok or type(t) ~= "table" then return { apps = {} } end
    t.apps = t.apps or {}
    return t
end

local function save_map(U, map)
    local body = "-- 自动生成：helper/lib/uimap.lua learn 产出，勿手改坐标注释以外内容。\n"
        .. "return " .. U.serialize(map) .. "\n"
    local f, err = io.open(U.map_path, "w")
    if not f then return false, err end
    f:write(body)
    f:close()
    return true
end

local function find_win(U, app)
    local m = load_map(U)
    local p = (m.apps[app] or {}).window or {}
    local W = winlib()
    -- 主窗口：标题 + class 同时限定；同名/同 class 的其它窗口（如「朋友圈」）用 pick=1 取候选里最大的
    local w = W.resolve({ name = p.title or app, class = p.class or app, pick = 1, viewable = p.viewable })
    if not w then w = W.resolve({ class = p.class or app, pick = 1 }) end
    if not w then error("window not found for app: " .. tostring(app)) end
    w:activate()
    return w, m
end

-- 扫一个区域，返回候选按钮；region = {x0,x1,y0,y1,th,axis,min_len,min_peak}
local function probe_region(U, img, region)
    local boxes = U.project(img, region)
    local gaps = {}
    for _, b in ipairs(boxes) do gaps[#gaps + 1] = b end
    return boxes
end

local run

local actions = {}

function actions.probe(args, env)
    local U = lib(env)
    local m = load_map(U)
    local app = assert(args.app, "required: app")
    local w, _ = find_win(U, app)
    local shot = (args.shot or "/tmp/uimap-" .. app .. ".png")
    local ok, err = w:capture(shot)
    if not ok then error("capture failed: " .. tostring(err)) end
    local img, derr = U.load_gray(shot)
    if not img then error("decode failed: " .. tostring(derr)) end
    local prof = (m.apps[app] or {}).regions or {}
    local out = {}
    for rname, r in pairs(args.regions and { [args.region or "all"] = args.regions } or prof) do
        if type(r) == "table" and r.x1 then
            out[rname] = probe_region(U, img, r)
        end
    end
    local lines = { string.format("%s %s %dx%d shot=%s", app, tostring(w.id), img.w, img.h, shot) }
    for rname, boxes in pairs(out) do
        lines[#lines + 1] = string.format("[%s] %d candidate(s)", rname, #boxes)
        for i, b in ipairs(boxes) do
            lines[#lines + 1] = string.format("  %d cx=%d cy=%d %dx%d", i, b.cx, b.cy, b.w, b.h)
        end
    end
    return table.concat(lines, "\n")
end

-- 点击 + diff 确认：返回变化比例，用来证明“这个按钮点得动、而且有效果”
function actions.verify(args, env)
    local U = lib(env)
    local app, x, y = assert(args.app, "required: app"), assert(args.x, "required: x"), assert(args.y, "required: y")
    local w = find_win(U, app)
    local pad = args.pad or 60
    local rect = { x0 = x - pad, x1 = x + pad, y0 = y - pad, y1 = y + pad }
    local before = "/tmp/uimap-before.png"
    local after = "/tmp/uimap-after.png"
    w:capture(before); w:refresh()
    w:click(x, y); require("ffi.xdo").sync(require("ffi.xdo"))
    require("ffi.x11").display():usleep(300000)
    w:refresh(); w:capture(after)
    local a, b = U.load_gray(before), U.load_gray(after)
    local ratio, derr = U.diff(a, b, rect, args.tol)
    if args.escape ~= false then w:key("Escape") end
    return string.format("app=%s click=(%d,%d) changed=%.4f%s", app, x, y, ratio or -1,
        derr and (" err=" .. derr) or "")
end

-- hover 确认：只移鼠标不点击（点击会弹窗）。图标 hover 会高亮 + 弹 tooltip，
-- 用「基准图 vs hover 图」的差异 bbox 定位 tooltip，再 OCR 取名。
-- 差异 bbox：纯 Lua 扫灰度像素（不依赖 compare），tol=18 忽略抗锯齿抖动。
local function diff_bbox(ga, gb, tol, rect)
    tol = tol or 18
    if not ga or not gb or ga.w ~= gb.w or ga.h ~= gb.h then return nil end
    local W, H = ga.w, ga.h
    local sx0 = math.max(0, rect and rect.x0 or 0)
    local sx1 = math.min(W - 1, rect and rect.x1 or (W - 1))
    local sy0 = math.max(0, rect and rect.y0 or 0)
    local sy1 = math.min(H - 1, rect and rect.y1 or (H - 1))
    local x0, y0, x1, y1, n = W, H, -1, -1, 0
    for y = sy0, sy1 do
        local row = y * W + 1
        for x = sx0, sx1 do
            local i = row + x
            local p, q = ga.g:byte(i), gb.g:byte(i)
            if p and q and math.abs(p - q) > tol then
                n = n + 1
                if x < x0 then x0 = x end
                if x > x1 then x1 = x end
                if y < y0 then y0 = y end
                if y > y1 then y1 = y end
            end
        end
    end
    if n < 20 then return nil end
    return { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1, px = n }
end

local function clean_name(s)
    s = (s or ""):gsub("[%[（(][^%]）)]*[%]）)]?%s*$", "") -- 去掉 "[Alt+A)"/"（Ctrl+X）" 快捷键尾巴
    s = (s or ""):gsub("%s+", "")
    if #s == 0 or #s > 16 then return nil end
    if s:find("[%d%.%-,:;%[%]{}]") and #s <= 3 then return nil end
    return s
end

function actions.hover(args, env)
    local ffi = require("ffi")
    local U = lib(env)
    local app = assert(args.app, "required: app")
    local w, m = find_win(U, app)
    local A = m.apps[app] or {}
    local d = require("ffi.xdo").new()
    local dwell = args.dwell or 1400
    local ww, wh = (A.window and A.window.w) or 1200, (A.window and A.window.h) or 800
    -- 停靠点：右下角空白，保证基准图里没有高亮/tooltip
    local park = { x = ww - 120, y = wh - 160 }
    local pts = args.items or args.points or A.buttons or {}
    if args.region then
        local keep = {}
        for _, p in ipairs(pts) do
            local r = p.region or "toolbar" -- 老条目无 region 视为工具栏
            if r == args.region then keep[#keep + 1] = p end
        end
        pts = keep
    end
    if #pts == 0 then error("required: items (map 里没有 buttons)") end
    local X11 = winlib()
    local base, shot = "/tmp/uimap-hover-base.png", "/tmp/uimap-hover-%d.png"
    d:move_abs(park.x, park.y)
    pcall(require("ffi.xdo").sync, d)
    -- activate 会触发淡入/重排动画：连拍两张，用第二张当基准，避免满屏假 diff
    ffi.C.usleep(1500000)
    -- 基准图必须「双拍为空」：连拍到两帧 diff 为空才收（否则把淡入/滚动/mtime 刷新当基准，后面满屏假 diff）
    local gbase
    for attempt = 1, 4 do
        X11.capture_screen(base)
        ffi.C.usleep(900000)
        X11.capture_screen(base)
        gbase = assert(U.load_gray(base), "decode base failed")
        local still = string.format("/tmp/uimap-hover-base-%d.png", attempt)
        X11.capture_screen(still)
        local g2 = U.load_gray(still)
        if g2 and not diff_bbox(gbase, g2) then break end
        if attempt == 4 then
            return string.format("app=%s hovered=0 reacted=0 wrote=false\nwindow not stable: base frames keep changing (park=%d,%d)", app, park.x, park.y)
        end
        ffi.C.usleep(700000)
    end
    local row, hits = {}, 0
    for i, p in ipairs(pts) do
        local cx, cy = p.x or p[1], p.y or p[2]
        assert(cx and cy, "item " .. i .. " 缺 x/y")
        d:move_abs(cx, cy)
        pcall(require("ffi.xdo").sync, d)
        ffi.C.usleep(dwell * 1000)
        local sp = string.format(shot, i)
        X11.capture_screen(sp)
        local g = U.load_gray(sp)
        -- 只比图标右侧条带：整窗重绘/滚动不再污染判断
        local bb = diff_bbox(gbase, g, nil, {
            x0 = cx - 40, x1 = cx + 320, y0 = cy - 70, y1 = cy + 70,
        })
        local name, text, kind = p.name, "", "none"
        if bb then
            hits = hits + 1
            -- 超过窗口 40% = 整窗重绘（失焦/滚动/淡入），不是这个槽位触发的面板
            local huge = bb.w * bb.h > ww * wh * 0.4
            local big = bb.w > 320 or bb.h > 320
            kind = huge and "redraw" or (big and "panel" or "tip")
            local dcx = bb.x + bb.w / 2 - p.x
            local dcy = bb.y + bb.h / 2 - p.y
            if not big and dcx * dcx + dcy * dcy > 90 * 90 then kind = "far" end
        end
        if kind == "tip" then
            -- tooltip 跟图标右侧同高（实测），diff bbox 常只圈住部分，所以按图标几何裁固定窗口
            local OCR = require("ffi.ocr")
            -- diff bbox 只圈住变化的一部分，但位置是可信的：以 bbox 中心为锚，裁 ±100x±45 再 OCR，
            -- 取离锚点最近的那条文字（tooltip 一定压在 rail 上/紧贴图标）
            local cx = bb and (bb.x + bb.w / 2) or p.x
            local cy = bb and (bb.y + bb.h / 2) or p.y
            -- 优先紧贴 diff bbox 裁（tooltip 就是那一行，扩 10x6 足够），只有 bbox 缺失/异常才退回锚点大窗：
            -- 窗口一大就把旁边会话列表的文字 OCR 进来（搜一搜被认成「理一理」就是这么来的）
            local cx0, cy0, cw, ch
            if bb and bb.w >= 8 and bb.h >= 6 and bb.w <= 320 and bb.h <= 120 then
                cx0 = math.max(0, bb.x - 10)
                cy0 = math.max(0, bb.y - 6)
                cw = math.min(ww - cx0, bb.w + 20)
                ch = math.min(wh - cy0, bb.h + 12)
            else
                cx0 = math.max(0, math.floor(math.min(p.x - 30, cx - 40)))
                cy0 = math.max(0, math.floor(cy - 28))
                cw = math.min(ww - cx0, 160)
                ch = math.min(wh - cy0, 56)
            end
            local crop = string.format("/tmp/uimap-hover-ocr-%d.png", i)
            -- 15px 细灰字直认会错（搜一搜→理一理）：灰度 + 拉对比 + 锐化后再放大
            os.execute(string.format(
                "convert %q -crop %dx%d+%d+%d +repage -colorspace Gray -level 25%%,85%% -sharpen 0x1 -resize 400%% %q",
                sp, cw, ch, cx0, cy0, crop))
            local t2, boxes = OCR.text(crop)
            text = tostring(t2 or "")
            local best, bestd
            for _, b in ipairs(boxes or {}) do
                local nm = clean_name(b.text)
                if nm then
                    local bx = cx0 + (b.x + b.w / 2) / 4
                    local by = cy0 + (b.y + b.h / 2) / 4
                    -- 横向距离权重高：tooltip 左缘贴图标，右边隔一段才是会话列表
                    local d2 = ((by - cy) ^ 2) + ((bx - cx) * 3) ^ 2
                    if not bestd or d2 < bestd then best, bestd = nm, d2 end
                end
            end
            if best then name = best end
        end
        row[#row + 1] = string.format("%d (%d,%d) %s %s name=%s", i, cx, cy, kind,
            bb and string.format("%dx%d+%d+%d/%dpx", bb.w, bb.h, bb.x, bb.y, bb.px) or "-",
            tostring(name or "?"))
        if p.name ~= nil or args.write then
            p.name = name or p.name
            p.hover = kind ~= "none"
            p.hover_kind = kind
            p.hover_bbox = bb and string.format("%dx%d+%d+%d", bb.w, bb.h, bb.x, bb.y) or nil
            p.hover_text = (text:gsub("%s+", " ")):sub(1, 40)
            p.verified = (kind ~= "none") and (name ~= nil) or false
        end
    end
    d:move_abs(park.x, park.y)
    pcall(require("ffi.xdo").sync, d)
    d:close()
    local ok = args.write and save_map(U, m)
    return string.format("app=%s hovered=%d reacted=%d wrote=%s\n%s", app, #pts, hits,
        tostring(ok == true or ok == nil), table.concat(row, "\n"))
end

function actions.click(args, env)
    local U = lib(env)
    local app, name = assert(args.app, "required: app"), assert(args.name, "required: name")
    local m = load_map(U)
    local rec
    for _, b in ipairs(((m.apps[app] or {}).buttons) or {}) do
        if b.name == name then rec = b break end
    end
    if not rec then error("no mapped button: " .. app .. "/" .. name) end
    local w = find_win(U, app)
    w:click(rec.x, rec.y)
    return string.format("clicked %s/%s at (%d,%d) verified=%s", app, name, rec.x, rec.y, tostring(rec.verified))
end

function actions.show(args, env)
    local U = lib(env)
    local m = load_map(U)
    local lines = {}
    for app, conf in pairs(m.apps) do
        lines[#lines + 1] = app .. " window=" .. tostring(conf.window and conf.window.title)
        for _, b in ipairs(conf.buttons or {}) do
            lines[#lines + 1] = string.format("  %-14s (%4d,%4d) %dx%d verified=%s changed=%s",
                b.name, b.x, b.y, b.w or 0, b.h or 0, tostring(b.verified), tostring(b.changed or "-"))
        end
    end
    table.sort(lines)
    return #lines > 0 and table.concat(lines, "\n") or "(empty)"
end

function actions.save(args, env)
    local U = lib(env)
    local m = load_map(U)
    local app = assert(args.app, "required: app")
    m.apps[app] = m.apps[app] or {}
    m.apps[app].buttons = args.buttons or m.apps[app].buttons
    if args.window then m.apps[app].window = args.window end
    if args.regions then m.apps[app].regions = args.regions end
    local ok, err = save_map(U, m)
    if not ok then error("save failed: " .. tostring(err)) end
    return "saved " .. U.map_path
end

-- ---- 通用发现：不依赖预置区域，纯图像 + 几何聚类 ----
local function region_name(rect, img)
    local cx, cy = (rect.x0 + rect.x1) / 2, (rect.y0 + rect.y1) / 2
    local vx = cx < img.w * 0.33 and "left" or (cx > img.w * 0.67 and "right" or "center")
    local vy = cy < img.h * 0.2 and "top" or (cy > img.h * 0.83 and "bottom" or "mid")
    return vx .. "_" .. vy
end

-- 图标 vs 文字：图标近方形、边长 8..64、同组尺寸相近；文字行宽高比大且长短不一
local function icon_like(g)
    local n, ws, hs, sq = #g.boxes, 0, 0, 0
    if n == 0 then return false end
    for _, b in ipairs(g.boxes) do
        local s = math.max(b.w, b.h)
        if s < 8 or s > 64 then return false end
        if math.min(b.w, b.h) < 10 then return false end
        local ar = b.w / math.max(b.h, 1)
        if ar < 0.6 or ar > 1.5 then return false end
        ws, hs, sq = ws + b.w, hs + b.h, sq + s * s
    end
    -- 尺寸方差过大 = 同一行里既有字又有标点
    local mean = math.sqrt(sq / n)
    local var = 0
    for _, b in ipairs(g.boxes) do
        local d = math.max(b.w, b.h) - mean
        var = var + d * d
    end
    if math.sqrt(var / n) > mean * 0.45 then return false end
    -- 节距与图标尺寸相当（工具条/侧栏），文字行节距远小于字高
    if g.pitch and g.pitch > 0 and g.pitch < mean * 0.7 then return false end
    return true
end

local function discover(U, img, args)
    local raw = U.components(img, { step = args.step or 2, th = args.th or 235,
        min_len = args.min_len or 8, max_size = args.max_size or 128 })
    local boxes = U.merge2(raw, args.gap or 3)
    local all = U.groups(boxes, { tol = args.tol or 8, min_count = args.min_count or 3 })
    if args.raw then return all end
    local out = {}
    for _, g in ipairs(all) do
        if icon_like(g) then out[#out + 1] = g end
    end
    return out, #all
end

function actions.discover(args, env)
    local U = lib(env)
    local app = assert(args.app, "required: app")
    local w = find_win(U, app)
    local shot = args.shot or ("/tmp/uimap-" .. app .. ".png")
    local ok, err = w:capture(shot)
    if not ok then error("capture failed: " .. tostring(err)) end
    local img, derr = U.load_gray(shot)
    if not img then error("decode failed: " .. tostring(derr)) end
    local groups, all_n = discover(U, img, args)
    local lines = { string.format("%s win=%dx%d shot=%s groups=%d (all=%s)", app, img.w, img.h, shot,
        #groups, tostring(all_n or #groups)) }
    for i, g in ipairs(groups) do
        local name = region_name(g.rect, img)
        lines[#lines + 1] = string.format("[%d] %s axis=%s n=%d pitch=%d rect=%d,%d %dx%d",
            i, name, g.axis, g.count, g.pitch, g.rect.x0, g.rect.y0, g.rect.w, g.rect.h)
        local parts = {}
        for _, b in ipairs(g.boxes) do
            parts[#parts + 1] = string.format("%d:(%d,%d)%dx%d", b.slot, b.cx, b.cy, b.w, b.h)
        end
        lines[#lines + 1] = "    " .. table.concat(parts, " ")
    end
    return table.concat(lines, "\n")
end

-- 学习：hover 出 tooltip 取名 → 真点击 → 截图 diff 确认 → 落盘
function actions.learn(args, env)
    local U = lib(env)
    local app = assert(args.app, "required: app")
    local w = find_win(U, app)
    local X = winlib()
    local xdo = require("ffi.xdo").new()
    local D = require("ffi.x11").display()
    local function shot(p) xdo:sync(); D.usleep(args.settle or 300000); w:refresh(); w:capture(p) end
    local base = "/tmp/uimap-base.png"
    shot(base)
    local img = assert(U.load_gray(base), "decode failed")
    local groups = discover(U, img, args)
    local geo = xdo:geometry(w.id) or {}
    local ox, oy = geo.x or 0, geo.y or 0
    local OCR = require("ffi.ocr")
    local buttons = {}
    local maxg = args.groups or #groups
    for gi = 1, math.min(maxg, #groups) do
        local g = groups[gi]
        local rname = region_name(g.rect, img)
        for _, b in ipairs(g.boxes) do
            -- 1) hover 取名
            xdo:move_abs(ox + b.cx, oy + b.cy)
            shot("/tmp/uimap-hover.png")
            local text, tb = OCR.text("/tmp/uimap-hover.png")
            local name
            if text and #(tb or {}) > 0 then
                local norm = {}
                for _, t in ipairs(tb) do
                    local x, y = tonumber(t.x), tonumber(t.y)
                    local w2, h2 = tonumber(t.w) or 0, tonumber(t.h) or 0
                    if x and y then
                        norm[#norm + 1] = { text = t.text, x = x, y = y, w = w2, h = h2,
                            cx = x + w2 / 2, cy = y + h2 / 2 }
                    end
                end
                local hit = U.label(norm, { cx = b.cx, cy = b.cy, h = b.h }, { max_dist = 260 })
                if hit and #(hit.text or "") >= 1 then name = hit.text end
            end
            -- 2) 真点击 + diff
            xdo:move_abs(ox + b.cx, oy + b.cy)
            local before, after = "/tmp/uimap-b.png", "/tmp/uimap-a.png"
            shot(before)
            w:click(b.cx, b.cy)
            shot(after)
            local a1, a2 = U.load_gray(before), U.load_gray(after)
            local ratio = U.diff(a1, a2, nil, args.tol) or 0
            if ratio > 0.002 then w:key("Escape"); D.usleep(150000) end
            buttons[#buttons + 1] = { x = b.cx, y = b.cy, w = b.w, h = b.h, region = rname,
                slot = b.slot, name = name or (rname .. "_" .. b.slot),
                changed = math.floor(ratio * 10000) / 10000, verified = ratio > 0.002 }
        end
    end
    local map = load_map(U)
    local regs = {}
    for i, g in ipairs(groups) do
        local rname = region_name(g.rect, img)
        regs[rname] = { axis = g.axis, count = g.count, pitch = g.pitch,
            x0 = g.rect.x0, y0 = g.rect.y0, x1 = g.rect.x1, y1 = g.rect.y1 }
    end
    map.apps[app] = { window = { title = w:name(), class = args.class, w = img.w, h = img.h },
        regions = regs, buttons = buttons }
    assert(save_map(U, map))
    local okn = 0
    for _, b in ipairs(buttons) do if b.verified then okn = okn + 1 end end
    return string.format("learned %s: %d buttons (%d verified) %dx%d -> %s",
        app, #buttons, okn, img.w, img.h, U.map_path)
end

-- ---- 剩下 ~20% 靠眼睛：放大裁剪 + 坐标网格，read 看图后手工补录 ----
-- 窗口坐标 (wx,wy) ↔ 图片坐标: ix=(wx-x0)*zoom, iy=(wy-y0)*zoom
function actions.crop(args, env)
    local U = lib(env)
    local app = assert(args.app, "required: app")
    local w = find_win(U, app)
    local src = args.shot or ("/tmp/uimap-crop-src-" .. app .. ".png")
    local ok, err = w:capture(src)
    if not ok then error("capture failed: " .. tostring(err)) end
    local img = assert(U.load_gray(src), "decode failed")
    local x0, y0 = math.max(0, args.x0 or 0), math.max(0, args.y0 or 0)
    local x1, y1 = math.min(img.w, args.x1 or img.w), math.min(img.h, args.y1 or img.h)
    local cw, ch = x1 - x0, y1 - y0
    if cw < 4 or ch < 4 then error(string.format("bad region %d,%d %dx%d", x0, y0, cw, ch)) end
    local zoom = args.zoom or math.max(1, math.floor(math.min(1400 / cw, 1400 / ch) + 0.5))
    local grid = args.grid or 20
    local out = args.out or ("/tmp/uimap-crop-" .. app .. ".png")
    local cmd = { string.format("convert %q -crop %dx%d+%d+%d +repage -filter point -resize %d00%%",
        src, cw, ch, x0, y0, zoom) }
    for gx = 0, cw, grid do
        local major = (x0 + gx) % (grid * 5) == 0
        cmd[#cmd + 1] = string.format("-stroke %s -strokewidth 1 -draw 'line %d,0 %d,%d'",
            major and "red" or "gray75", gx * zoom, gx * zoom, ch * zoom)
    end
    for gy = 0, ch, grid do
        local major = (y0 + gy) % (grid * 5) == 0
        cmd[#cmd + 1] = string.format("-stroke %s -strokewidth 1 -draw 'line 0,%d %d,%d'",
            major and "red" or "gray75", gy * zoom, cw * zoom, gy * zoom)
    end
    cmd[#cmd + 1] = "-stroke none -fill red -pointsize 11"
    for gx = 0, cw, grid * 5 do
        cmd[#cmd + 1] = string.format("-annotate +%d+11 '%d'", gx * zoom + 1, x0 + gx)
    end
    for gy = 0, ch, grid * 5 do
        cmd[#cmd + 1] = string.format("-annotate +1+%d '%d'", gy * zoom + 20, y0 + gy)
    end
    cmd[#cmd + 1] = string.format("%q", out)
    local rc = os.execute(table.concat(cmd, " "))
    if rc ~= 0 and rc ~= true then error("convert failed: " .. tostring(rc)) end
    return string.format("%s region=%d,%d %dx%d zoom=%d grid=%d win=%dx%d\n" ..
        "read %s ；红色线 = %dpx 刻度(x 标注在上、y 标注在左)，窗口坐标 = 标注值 + 偏移",
        out, x0, y0, cw, ch, zoom, grid, img.w, img.h, out, grid * 5)
end

-- 手工补录（看图后给窗口坐标）：items={{name="moments",x=37,y=473,w=26,h=26},...}
function actions.mark(args, env)
    local U = lib(env)
    local app = assert(args.app, "required: app")
    local items = args.items
    if type(items) ~= "table" or #items == 0 then error("required: items = {{name,x,y,w,h},...}") end
    local m = load_map(U)
    local conf = m.apps[app] or {}
    m.apps[app] = conf
    conf.buttons = conf.buttons or {}
    local idx, added, upd = {}, 0, 0
    for i, b in ipairs(conf.buttons) do idx[b.name] = i end
    for _, it in ipairs(items) do
        if not (it.name and it.x and it.y) then error("item needs name,x,y: " .. tostring(it.name)) end
        local rec = { name = it.name, x = math.floor(it.x), y = math.floor(it.y),
            w = it.w or 0, h = it.h or 0, region = it.region or "manual",
            slot = it.slot, source = "manual", verified = it.verified or false }
        if idx[it.name] then conf.buttons[idx[it.name]] = rec; upd = upd + 1
        else conf.buttons[#conf.buttons + 1] = rec; idx[it.name] = #conf.buttons; added = added + 1 end
    end
    assert(save_map(U, m))
    return string.format("marked %s: +%d new, %d updated -> %s (total %d)",
        app, added, upd, U.map_path, #conf.buttons)
end

function run(args, env)
    local a = actions[args.action or "show"]
    if not a then return "unknown action: " .. tostring(args.action) end
    return a(args, env)
end

return {
    schema = {
        name = "uimap",
        description = "视觉定位 + 真实点击确认的可点击按钮映射。action=discover 自动发现全部图标组（纯截图，不点）；learn 逐组 hover 取名 + 真点击 + diff 确认并落盘；probe 扫预置区域；verify 点击并 diff 确认；click 按名字点击；show 看映射；save 落盘 app_name_map.lua。",
        parameters = {
            type = "object",
            properties = {
                action = { type = "string", enum = { "discover", "learn", "probe", "verify", "hover", "click", "show", "save", "crop", "mark" } },
                app = { type = "string", description = "应用名，如 wechat" },
                name = { type = "string", description = "click 时按钮名" },
                x = { type = "number" }, y = { type = "number" },
                x0 = { type = "number", description = "crop 区域左上 (窗口坐标)" },
                y0 = { type = "number" },
                x1 = { type = "number", description = "crop 区域右下" },
                y1 = { type = "number" },
                zoom = { type = "number", description = "crop 放大倍数，默认按 1400px 自动" },
                grid = { type = "number", description = "crop 网格步长，默认 20（红线=5 倍步长）" },
                out = { type = "string" },
                items = { type = "array", description = "mark 手工补录：[{name,x,y,w,h}]，x/y 为中心点窗口坐标" },
                pad = { type = "number", description = "diff 区域半径，默认 60" },
                shot = { type = "string" },
                buttons = { type = "array" },
                window = { type = "object" },
                regions = { type = "object" },
            },
            required = { "action" },
        },
    },
    run = run,
}
