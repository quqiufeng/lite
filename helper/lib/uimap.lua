-- uimap: 图标/按钮视觉定位库 —— 从截图里找出「可点击元素」的位置，产出 map 文件。
--
-- 目标：不靠 OCR 猜坐标，也不用 xdotool 式固定坐标硬编码，而是
--   截图 → 找图标 → 悬停确认 → 读 tooltip 取名 → 落盘 app_name_map.lua
-- 之后 helper/wechat.lua 之类只要 `click({app="wechat", name="聊天记录"})` 即可。
--
-- 分工（本文件只做纯逻辑，不碰 FFI/窗口/鼠标，方便单测）：
--   helper/uimap.lua      动作层：找窗口、移鼠标、hover 停留、截图、diff、OCR、写盘
--   helper/lib/uimap.lua  算法层：像素 → 灰度 → 投影/连通域 → 合并/聚类 → 槽位 → 序列化
--   像素解码走 ImageMagick `convert`（lite 已有依赖），截图与鼠标由调用方注入。
--
-- 全流程（各步对应下面的函数）：
--   1. load_gray    PNG → {w,h,g} 灰度 8bit 行优先
--   2. project      逐行/逐列统计暗像素，得到投影曲线 → 图标带（band）区间
--   3. components   带内做连通域标记，得到候选图标的原始 bbox
--   4. merge/merge2 按 gap 把碎片拼回一个图标（描边、两段式图标会裂开）
--   5. cluster      按节距聚类，去掉孤立的文字/分隔线，只留等距排列的按钮
--   6. slots        沿 rail（竖排）或 toolbar（横排）排序并编号，得到稳定槽位
--   7. diff         悬停前后两帧同 rect 内做灰度差值，取 bbox 判断是否弹出 tooltip
--   8. rescale      基准图与当前窗口尺寸不一致时缩放 bbox，保证坐标对齐
--   9. label        用 OCR 文本给槽位取名（裁剪/扩边由动作层负责）
--  10. serialize    给出稳定字段序的 Lua 源码，写回 map 文件（可重复 diff）
--
-- 产出文件 helper/lib/app_name_map.lua 形如：
--   apps.wechat = { window = {...}, buttons = { [i] = { name, x, y, w, h,
--                 region = "rail"|"toolbar", verified = true|false,
--                 hover = true, hover_kind = "tip"|"panel"|"none", hover_text = "OCR 原文" } } }
-- verified=true 表示该槽位有 hover 反馈（tooltip 或面板变化），即确认可点击；
-- 无反馈的槽位保留 verified=false，不当作按钮使用。hover_text 保留 OCR 原始串，
-- 便于回溯 name 被人工订正前的识别结果。
--
-- 坐标只有两个来源，按控件类型分流：
--
--   A. 规则排列图标（rail 竖排 / toolbar 横排）
--      ── 全自动，agent 不用看图。投影 → 连通域 → 悬停 → diff 确认 → OCR 取名。
--   B. 特殊控件（搜索框、输入框、结果面板、聊天区这类大块区域）
--      ── 悬停没反应（无 tooltip、无面板变化），像素投影只会把它当一片色块，
--         别硬套 hover。走人工确认：截图 read + OCR 定坐标 → mark/click 一次
--         → 再截图 read 看结果（如搜索框点完出现绿框和下拉）→ verified=true。
--
-- ★ 真源规则（改坐标只改这一处）
--
--   真源 = 本文件的 STATIC_REGIONS[app]  ← agent 唯一该手写的坐标表
--   产物 = helper/lib/app_name_map.lua   ← learn/hover/save 用 serialize 整份重写
--
--   所以别直接改产物：下一次 learn 会把它覆盖，改动就没了（搜索框曾这样丢过）。
--   要调 B 类坐标，改 STATIC_REGIONS → 重跑生成脚本 → 产物自动带上。
--
--   生成流程：
--     1. agent 截图 read + OCR 确定 B 类的 x0,y0,x1,y1
--     2. 写进 STATIC_REGIONS（带 note，写明为什么不能靠 hover）
--     3. 跑 learn（全量发现）或 save（只重写文件）→ 生成 app_name_map.lua
--     4. 重跑 learn 应得到同一份产物（幂等），否则说明合并逻辑漏了键
--
--   合并规则 M.inject_static：只覆盖 `old == nil` 或 `old.static == true` 的键。
--     - B 类每次重跑都被脚本值刷写 → 幂等 ✅
--     - A 类实测出来的 rail/toolbar 无 static 标记 → 不被误伤 ✅
--     - learn 顺序：prev 补缺 → inject_static → args.regions（人工临时覆盖优先）
--   认错的名字直接改 map 或改 clean_name 规则，历史版本交给 git。
local M = {}

local function sh(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return nil end
    local out = p:read("*a")
    p:close()
    return out
end

-- PNG → {w=,h=,g=<byte 数组字符串>}（灰度 8bit，行优先）
function M.load_gray(path)
    local info = sh(string.format('identify -format "%%w %%h" "%s"', path))
    if not info then return nil, "identify failed: " .. tostring(path) end
    local w, h = info:match("(%d+)%s+(%d+)")
    if not w then return nil, "cannot read size: " .. info end
    w, h = tonumber(w), tonumber(h)
    local raw = os.tmpname()
    local ok = sh(string.format('convert "%s" -colorspace Gray -depth 8 gray:"%s" && echo ok', path, raw))
    if not ok or not ok:find("ok") then os.remove(raw); return nil, "convert failed" end
    local f = io.open(raw, "rb")
    if not f then os.remove(raw); return nil, "cannot open raw" end
    local g = f:read("*a")
    f:close()
    os.remove(raw)
    if #g < w * h then return nil, "short raw buffer" end
    return { w = w, h = h, g = g }
end

-- 一维/二维暗像素投影：返回候选框 {x0,x1,y0,y1,cx,cy,w,h,pixels}
-- o = {x0,x1,y0,y1,th=235,min_len=4,min_peak=2,axis="x"}
function M.project(img, o)
    o = o or {}
    local W = img.w
    local TH = o.th or 235
    local x0 = math.max(0, o.x0 or 0)
    local x1 = math.min(img.w - 1, o.x1 or (img.w - 1))
    local y0 = math.max(0, o.y0 or 0)
    local y1 = math.min(img.h - 1, o.y1 or (img.h - 1))
    local min_len = o.min_len or 4
    local min_peak = o.min_peak or 2
    local axis = o.axis or "x"
    local g = img.g
    local along_lo, along_hi, cross_lo, cross_hi
    if axis == "x" then
        along_lo, along_hi, cross_lo, cross_hi = x0, x1, y0, y1
    else
        along_lo, along_hi, cross_lo, cross_hi = y0, y1, x0, x1
    end
    local segs, cur = {}, nil
    for i = along_lo, along_hi do
        local n = 0
        for j = cross_lo, cross_hi do
            local x, y = (axis == "x") and i or j, (axis == "x") and j or i
            local b = g:byte(y * W + x + 1)
            if b and b < TH then n = n + 1 end
        end
        if n >= min_peak then
            cur = cur or { a = i, b = i }
            cur.b = i
        elseif cur then
            if cur.b - cur.a + 1 >= min_len then segs[#segs + 1] = cur end
            cur = nil
        end
    end
    if cur and cur.b - cur.a + 1 >= min_len then segs[#segs + 1] = cur end
    local out = {}
    for _, s in ipairs(segs) do
        local bx0, bx1, by0, by1 = 1e9, -1, 1e9, -1
        for j = cross_lo, cross_hi do
            for i = s.a, s.b do
                local x, y = (axis == "x") and i or j, (axis == "x") and j or i
                local b = g:byte(y * W + x + 1)
                if b and b < TH then
                    if x < bx0 then bx0 = x end
                    if x > bx1 then bx1 = x end
                    if y < by0 then by0 = y end
                    if y > by1 then by1 = y end
                end
            end
        end
        out[#out + 1] = {
            x0 = bx0, x1 = bx1, y0 = by0, y1 = by1, w = bx1 - bx0 + 1, h = by1 - by0 + 1,
            cx = math.floor((bx0 + bx1) / 2), cy = math.floor((by0 + by1) / 2),
        }
    end
    return out
end

-- 把碎片合并成图标（间距 < gap_max 视为同一颗）
function M.merge(boxes, gap_max)
    gap_max = gap_max or 4
    local out = {}
    for _, b in ipairs(boxes) do
        local last = out[#out]
        local joined = false
        if last then
            local vgap = b.y0 - last.y1 - 1
            local hgap = b.x0 - last.x1 - 1
            local xoverlap = b.x0 <= last.x1 and last.x0 <= b.x1
            local yoverlap = b.y0 <= last.y1 and last.y0 <= b.y1
            if xoverlap and vgap <= gap_max then
                last.y1 = math.max(last.y1, b.y1)
                last.x0 = math.min(last.x0, b.x0)
                last.x1 = math.max(last.x1, b.x1)
                joined = true
            elseif yoverlap and hgap <= gap_max then
                last.x1 = math.max(last.x1, b.x1)
                last.y0 = math.min(last.y0, b.y0)
                last.y1 = math.max(last.y1, b.y1)
                joined = true
            end
        end
        if not joined then
            out[#out + 1] = { x0 = b.x0, x1 = b.x1, y0 = b.y0, y1 = b.y1 }
        end
    end
    for _, b in ipairs(out) do
        b.w, b.h = b.x1 - b.x0 + 1, b.y1 - b.y0 + 1
        b.cx, b.cy = math.floor((b.x0 + b.x1) / 2), math.floor((b.y0 + b.y1) / 2)
    end
    return out
end

-- 槽位：按拍数聚类，返回每颗图标的槽位序号 + 归一化位置（0..1 相对 rails 顶/左）
function M.slots(boxes, axis)
    axis = axis or "y"
    local key0, key1 = (axis == "y") and "y0" or "x0", (axis == "y") and "y1" or "x1"
    local sorted = {}
    for _, b in ipairs(boxes) do sorted[#sorted + 1] = b end
    table.sort(sorted, function(a, b) return a[key0] < b[key0] end)
    local pitches = {}
    for i = 2, #sorted do
        local p = sorted[i][key0] - sorted[i - 1][key1] - 1
        if p > 0 then pitches[#pitches + 1] = p end
    end
    table.sort(pitches)
    local pitch = #pitches > 0 and pitches[math.ceil(#pitches / 2)] or 0
    for i, b in ipairs(sorted) do b.slot = i; b.gap = pitch end
    return sorted, pitch
end

-- 两图在 rect 内的差异比例；任一像素 |a-b| > tol 记为变化
function M.diff(a, b, rect, tol)
    tol = tol or 12
    if a.w ~= b.w or a.h ~= b.h then return nil, "size mismatch" end
    local x0 = math.max(0, rect and rect.x0 or 0)
    local x1 = math.min(a.w - 1, rect and rect.x1 or (a.w - 1))
    local y0 = math.max(0, rect and rect.y0 or 0)
    local y1 = math.min(a.h - 1, rect and rect.y1 or (a.h - 1))
    local n, changed = 0, 0
    for y = y0, y1 do
        for x = x0, x1 do
            local i = y * a.w + x + 1
            local p, q = a.g:byte(i), b.g:byte(i)
            n = n + 1
            if p and q and math.abs(p - q) > tol then changed = changed + 1 end
        end
    end
    if n == 0 then return 0 end
    return changed / n
end

-- 稳定序列化：便于 diff 和人工 review
function M.serialize(t, indent, order)
    indent = indent or 0
    order = order or {}
    local pad = string.rep("  ", indent)
    local lines = { "{" }
    local seen, keys = {}, {}
    for _, k in ipairs(order) do
        if t[k] ~= nil then keys[#keys + 1] = k; seen[k] = true end
    end
    local n = #t
    for i = 1, n do keys[#keys + 1] = i; seen[i] = true end
    local rest = {}
    for k in pairs(t) do if not seen[k] and type(k) == "string" then rest[#rest + 1] = k end end
    table.sort(rest)
    for _, k in ipairs(rest) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do
        local v = t[k]
        local key = type(k) == "number" and ("[" .. k .. "]") or
            (k:match("^[%a_][%w_]*$") and k or string.format("[%q]", k))
        local val
        if type(v) == "table" then
            val = M.serialize(v, indent + 1, order)
        elseif type(v) == "string" then
            val = string.format("%q", v)
        else
            val = tostring(v)
        end
        lines[#lines + 1] = pad .. "  " .. key .. " = " .. val .. ","
    end
    lines[#lines + 1] = pad .. "}"
    return table.concat(lines, "\n")
end

-- 2D 连通域：step 降采样后挖深色块，返回真实坐标 bbox（图标 = 一颗连通域或几颗近距离碎片）
function M.components(img, o)
    o = o or {}
    local st, TH = o.step or 2, o.th or 235
    local W, H, g = img.w, img.h, img.g
    local gw, gh = math.floor(W / st), math.floor(H / st)
    local dark, seen = {}, {}
    for gy = 0, gh - 1 do
        local row, base = {}, gy * st * W
        for gx = 0, gw - 1 do
            local p = g:byte(base + gx * st + 1)
            row[gx] = (p and p < TH) and 1 or 0
        end
        dark[gy] = row
    end
    local min_len, max_size = o.min_len or 8, o.max_size or 128
    local out = {}
    for gy = 0, gh - 1 do
        for gx = 0, gw - 1 do
            local k0 = gy * gw + gx
            if dark[gy][gx] == 1 and not seen[k0] then
                seen[k0] = true
                local stack = { { gx, gy } }
                local x0, x1, y0, y1, n = gx, gx, gy, gy, 0
                while #stack > 0 do
                    local c = table.remove(stack)
                    local cx, cy = c[1], c[2]
                    n = n + 1
                    if cx < x0 then x0 = cx end
                    if cx > x1 then x1 = cx end
                    if cy < y0 then y0 = cy end
                    if cy > y1 then y1 = cy end
                    local nb = { { cx - 1, cy }, { cx + 1, cy }, { cx, cy - 1 }, { cx, cy + 1 } }
                    for i = 1, 4 do
                        local nx, ny = nb[i][1], nb[i][2]
                        if nx >= 0 and nx < gw and ny >= 0 and ny < gh and dark[ny][nx] == 1
                            and not seen[ny * gw + nx] then
                            seen[ny * gw + nx] = true
                            stack[#stack + 1] = { nx, ny }
                        end
                    end
                end
                local bx0, by0 = x0 * st, y0 * st
                local bw, bh = (x1 - x0 + 1) * st, (y1 - y0 + 1) * st
                if bw >= min_len and bh >= min_len and bw <= max_size and bh <= max_size then
                    out[#out + 1] = { x0 = bx0, y0 = by0, x1 = bx0 + bw - 1, y1 = by0 + bh - 1,
                        w = bw, h = bh, cx = bx0 + math.floor(bw / 2), cy = by0 + math.floor(bh / 2), n = n }
                end
            end
        end
    end
    return out
end

-- 2D 合并：外扩 gap 后相交的框归为同一颗（同一图标的碎块）
function M.merge2(boxes, gap)
    gap = gap or 2
    local out = {}
    for _, b in ipairs(boxes) do out[#out + 1] = { x0 = b.x0, x1 = b.x1, y0 = b.y0, y1 = b.y1 } end
    local changed = true
    while changed do
        changed = false
        for i = 1, #out do
            for j = i + 1, #out do
                local a, b = out[i], out[j]
                if a.x0 - gap <= b.x1 and b.x0 - gap <= a.x1 and a.y0 - gap <= b.y1 and b.y0 - gap <= a.y1 then
                    a.x0, a.x1 = math.min(a.x0, b.x0), math.max(a.x1, b.x1)
                    a.y0, a.y1 = math.min(a.y0, b.y0), math.max(a.y1, b.y1)
                    table.remove(out, j)
                    changed = true
                    break
                end
            end
            if changed then break end
        end
    end
    for _, b in ipairs(out) do
        b.w, b.h = b.x1 - b.x0 + 1, b.y1 - b.y0 + 1
        b.cx, b.cy = math.floor((b.x0 + b.x1) / 2), math.floor((b.y0 + b.y1) / 2)
    end
    return out
end

local function cluster(boxes, key, tol)
    local sorted = {}
    for _, b in ipairs(boxes) do sorted[#sorted + 1] = b end
    table.sort(sorted, function(a, b)
        if a[key] ~= b[key] then return a[key] < b[key] end
        return a.cx + a.cy < b.cx + b.cy
    end)
    local cl = {}
    for _, b in ipairs(sorted) do
        local hit
        for _, c in ipairs(cl) do
            if math.abs(c.k - b[key]) <= tol then hit = c break end
        end
        if hit then
            hit.k = (hit.k * #hit.boxes + b[key]) / (#hit.boxes + 1)
            hit.boxes[#hit.boxes + 1] = b
        else
            cl[#cl + 1] = { k = b[key], boxes = { b } }
        end
    end
    return cl
end

local function finalize(g, axis)
    local a0, a1 = (axis == "y") and "cy" or "cx", (axis == "y") and "y0" or "x0"
    local b1 = (axis == "y") and "y1" or "x1"
    table.sort(g.boxes, function(p, q) return p[a0] < q[a0] end)
    local gaps = {}
    for i = 2, #g.boxes do gaps[#gaps + 1] = g.boxes[i][a1] - g.boxes[i - 1][b1] - 1 end
    table.sort(gaps)
    g.axis = axis
    g.count = #g.boxes
    g.pitch = (#gaps > 0) and gaps[math.ceil(#gaps / 2)] or 0
    g.key0 = (axis == "y") and "cy" or "cx"
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, b in ipairs(g.boxes) do
        x0, y0 = math.min(x0, b.x0), math.min(y0, b.y0)
        x1, y1 = math.max(x1, b.x1), math.max(y1, b.y1)
    end
    g.rect = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, w = x1 - x0 + 1, h = y1 - y0 + 1 }
    for i, b in ipairs(g.boxes) do b.slot = i; b.gap = g.pitch end
    return g
end

-- 自动发现：把散框按「共线 + 等间距」聚成 rail（纵向）/ toolbar（横向），无需预置区域
function M.groups(boxes, o)
    o = o or {}
    local tol, minc = o.tol or 8, o.min_count or 3
    local out, used = {}, {}
    for axis, key in pairs({ y = "cx", x = "cy" }) do
        for _, c in ipairs(cluster(boxes, key, tol)) do
            if #c.boxes >= minc then
                local g = finalize({ boxes = c.boxes }, axis)
                local ok = g.pitch >= 0
                if ok and o.max_pitch then
                    for i = 2, #g.boxes do
                        local d = g.boxes[i][g.key0] - g.boxes[i - 1][g.key0]
                        if d > o.max_pitch then ok = false break end
                    end
                end
                if ok then
                    out[#out + 1] = g
                    for _, b in ipairs(g.boxes) do used[b] = true end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.count > b.count end)
    return out, used
end

-- 窗口尺寸变了就按比例换算（同一 app 换分辨率/缩放后仍可用）
function M.rescale(b, from, to)
    if not (from and to and from.w and from.h and to.w and to.h) then return b end
    local sx, sy = to.w / from.w, to.h / from.h
    if math.abs(sx - 1) < 1e-6 and math.abs(sy - 1) < 1e-6 then return b end
    local f = function(v, s) return math.floor(v * s + 0.5) end
    local n = {
        x0 = f(b.x0, sx), y0 = f(b.y0, sy),
        w = math.max(1, f(b.w, sx)), h = math.max(1, f(b.h, sy)),
    }
    n.x1, n.y1 = n.x0 + n.w - 1, n.y0 + n.h - 1
    n.cx, n.cy = f(b.cx or (b.x0 + b.w / 2), sx), f(b.cy or (b.y0 + b.h / 2), sy)
    return n
end

-- 固定区域：discover 只测「成排等距的图标」，搜索框、结果面板、输入框、气泡区
-- 这类单控件或大块矩形永远测不到。所以按 class 写在这里，由生成脚本 learn/save
-- 一并落盘（真源只有这一处），调用方（helper/wechat.lua）再从 map 读，不硬编码。
-- ★ 坐标真源：B 类（悬停无反馈的大块控件）只写这里，重跑生成脚本才不会被覆盖。
--   新加 app 就加一个 STATIC_REGIONS[class]，键名与 helper/<app>.lua 里取的一致。
local STATIC_REGIONS = {
    wechat = {
        search = { x0 = 90, y0 = 28, x1 = 486, y1 = 74,
            note = "左栏顶部搜索框（标题栏下方，需真实点击而非 ctrl+f）" },
        panel  = { x0 = 70, y0 = 80, x1 = 520, y1 = 1040,
            note = "左栏搜索结果面板" },
        input  = { x0 = 760, y0 = 1105, x1 = 2500, y1 = 1235,
            note = "聊天输入框" },
        bubble = { x0 = 520, y0 = 100, x1 = 2560, y1 = 1040,
            note = "聊天区（气泡）" },
    },
}

-- 把 static region 注入 regs：脚本是静态区的真源（覆盖旧的 static/手工项），
-- discover 实测出来的 rail/toolbar 等不同名，互不影响。
function M.inject_static(regs, class)
    regs = regs or {}
    for k, v in pairs(STATIC_REGIONS[class or "wechat"] or {}) do
        local old = regs[k]
        if old == nil or old.static then
            local c = {}
            for kk, vv in pairs(v) do c[kk] = vv end
            c.static = true
            regs[k] = c
        end
    end
    return regs
end

-- 给一个框找最近的 OCR 文字（同行优先），用作名字候选
function M.label(texts, b, o)
    o = o or {}
    local maxd = o.max_dist or 420
    local best, bestd
    for _, t in ipairs(texts or {}) do
        local tw, th = t.w or 0, t.h or 0
        local tx, ty = t.cx or (t.x + tw / 2), t.cy or (t.y + th / 2)
        local dy, dx = math.abs(ty - b.cy), math.abs(tx - b.cx)
        if dy <= math.max(b.h, th) * 1.2 and dx <= maxd then
            if not bestd or dx < bestd then best, bestd = t, dx end
        end
    end
    return best, bestd
end
return M
