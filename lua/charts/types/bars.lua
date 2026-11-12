-- lua/charts/types/bars.lua —— 「长短比较」这一族：
-- bar / lollipop / waterfall / gauge / slope / spectrum / calendar / quad / scatter / bubble / radar
local P = require('charts.pen')
local K = require('charts.kit')
local L = require('charts.types.lib')
local M = {}

local sin, cos, pi, sqrt, floor, abs = math.sin, math.cos, math.pi, math.sqrt, math.floor, math.abs
local function rows(spec) return spec.rows or {} end

-- ---------------------------------------------------------------------------
M.bar = {
  label = '柱状图',
  demo = {
    title = '一周卖掉的巧克力棒', note = '一格是十根，从柜台上数上去。榛子的卖得最多。',
    rows = { { label = '一', value = 34 }, { label = '二', value = 27 }, { label = '三', value = 41 },
             { label = '四', value = 36 }, { label = '五', value = 48 }, { label = '六', value = 44 },
             { label = '日', value = 22 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local b = K.boxPlot({ y0 = 70, y1 = 322 })
    local top = K.top(K.maxv(rs))
    K.ticksY(b, top, 4)
    local n = #rs
    local slot = (b.x1 - b.x0 - 8) / n
    local bw = math.min(slot * .6, 38)
    for i, r in ipairs(rs) do
      local cx = b.x0 + slot * (i - .5)
      local v = K.vof(r)
      local yt = K.scale(v, 0, top, b.y1, b.y0)
      local col = r.col or K.col(i)
      L.vbar(cx - bw / 2, cx + bw / 2, b.y1, yt, col)
      P.hatch({ { cx - bw / 2, b.y1 }, { cx + bw / 2, b.y1 }, { cx + bw / 2, yt }, { cx - bw / 2, yt } },
        { dir = { 0, 1 }, gap = 6, keep = .5, col = P.trim(col) })
      P.text(tostring(r.label or ''), cx, b.y1 + 17, { size = 11, anchor = 'middle' })
      P.text(K.vfmt(v), cx, yt - 6, { size = 10.5, anchor = 'middle', col = P.LEAD })
    end
  end,
}

-- ---------------------------------------------------------------------------
M.lollipop = {
  label = '棒棒糖图',
  demo = {
    title = '一周卖掉的糖', note = '棍子多高就卖了多少。周六赢。',
    rows = { { label = '一', value = 18 }, { label = '二', value = 24 }, { label = '三', value = 21 },
             { label = '四', value = 30 }, { label = '五', value = 26 }, { label = '六', value = 44 },
             { label = '日', value = 28 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local b = K.boxPlot({ y0 = 70, y1 = 322 })
    local top = K.top(K.maxv(rs))
    K.ticksY(b, top, 4)
    local slot = (b.x1 - b.x0 - 10) / #rs
    for i, r in ipairs(rs) do
      local cx = b.x0 + slot * (i - .3)
      local v = K.vof(r)
      local yt = K.scale(v, 0, top, b.y1, b.y0)
      local col = r.col or K.col(i)
      P.line({ { cx, b.y1 }, { cx, yt + 7 } }, { w = 1.6, col = P.trim(col), amp = .3, over = 0 })
      P.dot(cx, yt + 6, 7.5, col, 1.3)
      P.text(tostring(r.label or ''), cx, b.y1 + 17, { size = 11, anchor = 'middle' })
      P.text(K.vfmt(v), cx + 11, yt + 9, { size = 10, col = P.LEAD })
    end
  end,
}

-- ---------------------------------------------------------------------------
M.waterfall = {
  label = '瀑布图',
  demo = {
    title = '雨水桶，一个星期', note = '从 200 升开始。每级是进来的或出去的水。',
    start = 200,
    rows = { { label = '一', value = 40 }, { label = '二', value = -25 }, { label = '三', value = 35 },
             { label = '四', value = -60 }, { label = '五', value = 15 }, { label = '六', value = -10 },
             { label = '日', value = 30 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local b = K.boxPlot({ y0 = 76, y1 = 316 })
    local start = spec.start or 0
    local cur, lo, hi = start, start, start
    local walk = {}
    for i, r in ipairs(rs) do
      local a, z = cur, cur + K.vof(r)
      walk[i] = { a = a, z = z }
      lo, hi = math.min(lo, a, z), math.max(hi, a, z)
      cur = z
    end
    local pad = (hi - lo) * .12 + 1
    lo, hi = math.max(0, lo - pad), hi + pad
    local n = #rs + 2
    local slot = (b.x1 - b.x0 - 6) / n
    local bw = math.min(slot * .62, 34)
    local st = K.step((hi - lo) / 4)
    local k0 = math.ceil(lo / st)
    for k = k0, k0 + 20 do
      local v = k * st
      if v > hi + 1e-9 then break end
      local y = K.scale(v, lo, hi, b.y1, b.y0)
      P.line({ { b.x0, y }, { b.x1, y } }, { w = .5, col = P.PAL.shade, amp = .3, over = 0, dash = '3 6' })
      P.text(K.vfmt(v), b.x0 - 8, y + 4, { size = 10, anchor = 'end', col = P.LEAD })
    end
    P.line({ { b.x0, b.y1 }, { b.x1 + 3, b.y1 } }, { w = 1.5, amp = .4 })
    P.line({ { b.x0, b.y0 - 2 }, { b.x0, b.y1 } }, { w = 1.5, amp = .4 })
    local function block(idx, a, z, col, label)
      local cx = b.x0 + slot * (idx - .5)
      local y0 = K.scale(a, lo, hi, b.y1, b.y0)
      local y1 = K.scale(z, lo, hi, b.y1, b.y0)
      L.vbar(cx - bw / 2, cx + bw / 2, y0, y1, col)
      P.text(tostring(label or ''), cx, b.y1 + 17, { size = 10, anchor = 'middle' })
      return cx
    end
    local sx = block(1, lo, start, P.PAL.sky, '起')
    P.line({ { sx + bw / 2, K.scale(start, lo, hi, b.y1, b.y0) }, { sx + bw / 2 + slot - bw, K.scale(start, lo, hi, b.y1, b.y0) } },
      { w = .9, col = P.LEAD, amp = .2, over = 0, dash = '3 3' })
    for i, w in ipairs(walk) do
      local col = K.vof(rs[i]) >= 0 and P.PAL.sage or P.PAL.pink
      local cx = block(i + 1, w.a, w.z, col, rs[i].label)
      if i < #walk then
        local yl = K.scale(w.z, lo, hi, b.y1, b.y0)
        P.line({ { cx + bw / 2, yl }, { cx + bw / 2 + slot - bw, yl } }, { w = .9, col = P.LEAD, amp = .2, over = 0, dash = '3 3' })
      end
    end
    local cx = block(#rs + 2, lo, cur, P.PAL.gold, '末')
    K.callout(cx, K.scale(cur, lo, hi, b.y1, b.y0), 470, 84, '剩 ' .. K.vfmt(cur) .. ' 升',
      '七天净变化 ' .. (cur - start >= 0 and '+' or '') .. K.vfmt(cur - start), 'end')
  end,
}

-- ---------------------------------------------------------------------------
M.gauge = {
  label = '表盘',
  demo = {
    title = '烤箱的旋钮', note = '拧到 180°。左边是慢火，右边是披萨。',
    value = 180, min = 0, max = 250, unit = '°',
    zones = { { to = .35, col = 'sky', label = '慢' }, { to = .72, col = 'sage', label = '烤' }, { to = 1, col = 'rose', label = '披萨' } },
  },
  draw = function(spec)
    local cx, cy, r = 256, 250, 130
    local v, lo, hi = spec.value or 0, spec.min or 0, spec.max or 100
    local zones = spec.zones or { { to = .5, col = 'sage' }, { to = 1, col = 'pink' } }
    local a0, a1 = pi + .34, 2 * pi - .34
    local prev = 0
    for _, z in ipairs(zones) do
      local t0, t1 = prev, z.to
      local outer = P.arcPts(cx, cy, r, a0 + (a1 - a0) * t0, a0 + (a1 - a0) * t1, 20)
      local inner = P.arcPts(cx, cy, r - 30, a0 + (a1 - a0) * t1, a0 + (a1 - a0) * t0, 20)
      local poly = {}
      for _, p in ipairs(outer) do poly[#poly + 1] = p end
      for _, p in ipairs(inner) do poly[#poly + 1] = p end
      P.shape(poly, P.PAL[z.col] or z.col, { w = 1.2 })
      if z.label then
        local am = a0 + (a1 - a0) * (t0 + t1) / 2
        P.text(z.label, cx + cos(am) * (r - 48), cy + sin(am) * (r - 48) + 4,
          { size = 10.5, anchor = 'middle', col = P.TONE })
      end
      prev = z.to
    end
    for i = 0, 10 do
      local t = i / 10
      local a = a0 + (a1 - a0) * t
      local big = i % 2 == 0
      local rr = r + (big and 14 or 9)
      P.line({ { cx + cos(a) * (r + 3), cy + sin(a) * (r + 3) }, { cx + cos(a) * rr, cy + sin(a) * rr } },
        { w = big and 1.3 or .9, amp = .25, over = 0 })
      if big then
        P.text(K.vfmt(lo + (hi - lo) * t), cx + cos(a) * (r + 25), cy + sin(a) * (r + 25) + 4,
          { size = 10, anchor = 'middle', col = P.LEAD })
      end
    end
    local t = (v - lo) / math.max(1e-9, hi - lo)
    local a = a0 + (a1 - a0) * t
    P.line({ { cx - cos(a) * 14, cy - sin(a) * 14 }, { cx + cos(a) * (r - 42), cy + sin(a) * (r - 42) } },
      { w = 2.2, col = P.RED, amp = .3, over = 0 })
    P.dot(cx, cy, 8, P.PAL.gold, 1.4)
    P.text(K.vfmt(v) .. (spec.unit or ''), cx, cy + 62, { size = 29, anchor = 'middle', col = P.INK })
    P.text('set to', cx, cy + 82, { size = 10.5, anchor = 'middle', col = P.LEAD })
  end,
}

-- ---------------------------------------------------------------------------
M.slope = {
  label = '斜率图',
  demo = {
    title = '四条雪道的积雪', note = '每条线从一月的雪深到三月的雪深。越陡化得越快。',
    left = '一月', right = '三月',
    rows = { { label = '北坡', a = 120, b = 40 }, { label = '南坡', a = 90, b = 12 },
             { label = '林中', a = 70, b = 58 }, { label = '冰川', a = 55, b = 50 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local xa, xb = 160, 360
    local top = K.top(math.max(K.maxv(rs, 'a'), K.maxv(rs, 'b')))
    local y0, y1 = 96, 300
    P.line({ { xa, y0 - 16 }, { xa, y1 + 16 } }, { w = .8, col = P.PAL.shade, amp = .3, over = 0, dash = '4 5' })
    P.line({ { xb, y0 - 16 }, { xb, y1 + 16 } }, { w = .8, col = P.PAL.shade, amp = .3, over = 0, dash = '4 5' })
    P.text(spec.left or 'A', xa, y0 - 26, { size = 11, anchor = 'middle', col = P.LEAD })
    P.text(spec.right or 'B', xb, y0 - 26, { size = 11, anchor = 'middle', col = P.LEAD })
    for i, r in ipairs(rs) do
      local col = r.col or K.col(i)
      local ya = K.scale(K.vof(r, 'a'), 0, top, y1, y0)
      local yb = K.scale(K.vof(r, 'b'), 0, top, y1, y0)
      P.line({ { xa, ya }, { xb, yb } }, { w = 2, col = col, amp = .4, over = 0 })
      P.dot(xa, ya, 4.5, col, 1.1)
      P.dot(xb, yb, 4.5, col, 1.1)
      P.text(tostring(r.label), xa - 12, ya + 4, { size = 11.5, anchor = 'end' })
      P.text(tostring(r.label), xb + 12, yb + 4, { size = 11.5 })
      P.text(K.vfmt(K.vof(r, 'b')), xb + 16 + P.textw(tostring(r.label), 11.5), yb + 4, { size = 9.5, col = P.LEAD })
    end
  end,
}

-- ---------------------------------------------------------------------------
M.spectrum = {
  label = '光谱条',
  demo = {
    title = '每种辣椒有多辣', note = '十分制，按口味排。条从柔和的紫到凶猛的赤红，每根辣椒挂在自己的分数上。',
    min = 0, max = 10, unit = ' 分',
    rows = { { label = '灯笼椒', value = 0 }, { label = '墨西哥', value = 2.5 }, { label = '哈瓦那', value = 7 },
             { label = '鸟眼', value = 8.2 }, { label = '卡罗莱纳', value = 10 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local x0, x1, y = 70, 450, 186
    local lo, hi = spec.min or 0, spec.max or 10
    local n = 46
    local from, to = '#8f7fb8', '#c2452f'
    for i = 0, n - 1 do
      local px0 = K.scale(lo + (hi - lo) * i / n, lo, hi, x0, x1)
      local px1 = K.scale(lo + (hi - lo) * (i + 1) / n, lo, hi, x0, x1) + .4
      P.flat({ { px0, y - 13 }, { px1, y - 13 }, { px1, y + 13 }, { px0, y + 13 } }, P.mix(from, to, i / n))
    end
    P.inkLoop({ { x0, y - 13 }, { x1, y - 13 }, { x1, y + 13 }, { x0, y + 13 } }, { w = 1.3, amp = .3, over = 0 })
    for i = 0, 10 do
      local px = K.scale(i, lo, hi, x0, x1)
      local len = (i % 5 == 0) and 24 or 19
      P.line({ { px, y + 14 }, { px, y + len } }, { w = 1, amp = .2, over = 0 })
      if i % 5 == 0 then P.text(K.int(i), px, y + 36, { size = 10, anchor = 'middle', col = P.LEAD }) end
    end
    for i, r in ipairs(rs) do
      local t = K.vof(r) / math.max(1e-9, hi - lo)
      local px = K.scale(K.vof(r), lo, hi, x0, x1)
      local yy = y + 58 + ((i - 1) % 3) * 32
      P.line({ { px, y + 14 }, { px, yy - 9 } }, { w = 1, col = P.LEAD, amp = .3, over = 0, dash = '2 3' })
      P.shape(P.blob(px, yy, 13, 6.5, .05, 5), P.mix(from, to, t), { w = 1.1 })
      local flip = (i % 2 == 0)
      local lb = tostring(r.label)
      local w = P.textw(lb, 11) + 4 + P.textw(K.vfmt(K.vof(r)) .. (spec.unit or ''), 9.5)
      if px - 18 - w < 8 then flip = true end
      if px + 18 + w > 472 then flip = false end
      P.text(lb, flip and (px + 18) or (px - 18), yy + 4, { size = 11, anchor = flip and 'start' or 'end' })
      P.text(K.vfmt(K.vof(r)) .. (spec.unit or ''),
        flip and (px + 22 + P.textw(lb, 11)) or (px - 22 - P.textw(lb, 11)),
        yy + 4, { size = 9.5, anchor = flip and 'start' or 'end', col = P.LEAD })
    end
  end,
}

-- ---------------------------------------------------------------------------
M.calendar = {
  label = '日历热力',
  demo = {
    title = '六月走的公里数', note = '格子越深走得越远。第二周下雨，之后又顺起来了。',
    month = '六月', first = 1, days = 30,
    values = { 4, 6, 2, 0, 0, 3, 5, 8, 2, 1, 0, 0, 7, 9, 5, 3, 2, 1, 0, 0, 6, 8, 11, 7, 4, 9, 12, 6, 3, 5 },
  },
  draw = function(spec)
    local vals = spec.values or {}
    local first = spec.first or 1
    local days = spec.days or #vals
    local top = 1
    for _, v in ipairs(vals) do top = math.max(top, v) end
    local gx, gy = 76, 92
    local cell, gap = 40, 4
    for i, d in ipairs({ '一', '二', '三', '四', '五', '六', '日' }) do
      P.text(d, gx + (i - 1) * (cell + gap) + cell / 2, gy - 12, { size = 10.5, anchor = 'middle', col = P.LEAD })
    end
    for i = 1, days do
      local idx = first + i - 2
      local col, row = idx % 7, floor(idx / 7)
      local x, y = gx + col * (cell + gap), gy + row * (cell + gap)
      local v = vals[i] or 0
      local t = v / top
      local sq = { { x, y }, { x + cell, y }, { x + cell, y + cell }, { x, y + cell } }
      P.fill(sq, P.mix('#f7f1e3', '#7f9f7a', t), { dx = .3, dy = .3, amp = .3 })
      P.inkLoop(sq, { w = .9, amp = .25, over = 0, col = P.TONE })
      P.text(K.int(i), x + 4, y + 13, { size = 9.5, col = t > .55 and '#f6f2e6' or P.TONE })
      if v > 0 then
        P.text(K.int(v), x + cell / 2, y + cell - 7, { size = 9.5, anchor = 'middle', col = t > .55 and '#f6f2e6' or P.TONE })
      end
    end
    local lx, ly = 76, 348
    P.text('少', lx, ly + 4, { size = 10, col = P.LEAD })
    for i = 0, 4 do
      local x = lx + 20 + i * 22
      local sq = { { x, ly - 7 }, { x + 16, ly - 7 }, { x + 16, ly + 9 }, { x, ly + 9 } }
      P.fill(sq, P.mix('#f7f1e3', '#7f9f7a', i / 4), { dx = .3, dy = .3, amp = .2 })
      P.rim(sq, .7, P.TONE, .8)
    end
    P.text('多', lx + 20 + 5 * 22 + 4, ly + 4, { size = 10, col = P.LEAD })
    P.text(spec.month or '', 76, 64, { size = 12, col = P.INK })
  end,
}

-- quad
M.quad = {
  label = '四象限',
  demo = {
    title = '在方院坐哪儿', note = '一条轴是日照小时 0–8，另一条是每小时路过的人 0–200。交叉点是 4 小时、100 人。',
    xLabel = '日照小时', yLabel = '路过的人', xMax = 8, yMax = 200,
    rows = { { label = '长椅', x = 6.5, y = 60 }, { label = '石阶', x = 5.2, y = 150 },
             { label = '树下', x = 2, y = 40 }, { label = '喷泉', x = 3, y = 130 },
             { label = '西廊', x = 7.2, y = 170 } },
  },
}

function M.quad.draw(spec)
  local rs = rows(spec)
  local b = { x0 = 66, y0 = 76, x1 = 448, y1 = 314 }
  local xm, ym = spec.xMax or 8, spec.yMax or 200
  local cx = K.scale(xm / 2, 0, xm, b.x0, b.x1)
  local cy = K.scale(ym / 2, 0, ym, b.y1, b.y0)
  P.line({ { b.x0, b.y1 }, { b.x1 + 3, b.y1 } }, { w = 1.5, amp = .4 })
  P.line({ { b.x0, b.y0 - 2 }, { b.x0, b.y1 } }, { w = 1.5, amp = .4 })
  P.line({ { cx, b.y0 }, { cx, b.y1 } }, { w = 1, col = P.LEAD, amp = .3, over = 0, dash = '5 4' })
  P.line({ { b.x0, cy }, { b.x1, cy } }, { w = 1, col = P.LEAD, amp = .3, over = 0, dash = '5 4' })
  for _, q in ipairs({ { '安静又阴', b.x0 + 8, b.y0 + 14, 'start' }, { '热闹有太阳', b.x1 - 6, b.y0 + 14, 'end' },
                       { '安静有太阳', b.x0 + 8, b.y1 - 10, 'start' }, { '热闹又阴', b.x1 - 6, b.y1 - 10, 'end' } }) do
    P.text(q[1], q[2], q[3], { size = 10, anchor = q[4], col = P.PAL.shade })
  end
  P.text(spec.xLabel or 'x', b.x1, b.y1 + 30, { size = 10.5, anchor = 'end', col = P.LEAD })
  P.text(spec.yLabel or 'y', b.x0 - 4, b.y0 - 12, { size = 10.5, col = P.LEAD })
  for i, r in ipairs(rs) do
    local x = K.scale(K.vof(r, 'x'), 0, xm, b.x0, b.x1)
    local y = K.scale(K.vof(r, 'y'), 0, ym, b.y1, b.y0)
    P.dot(x, y, 8, r.col or K.col(i), 1.2)
    local right = x < b.x1 - 74
    P.text(tostring(r.label), right and x + 13 or x - 13, y + 4, { size = 11, anchor = right and 'start' or 'end' })
  end
  K.mark(cx, cy, P.PAPER)
  P.text(K.vfmt(xm / 2), cx, b.y1 + 16, { size = 9.5, anchor = 'middle', col = P.LEAD })
  P.text(K.vfmt(ym / 2), b.x0 - 8, cy + 4, { size = 9.5, anchor = 'end', col = P.LEAD })
end

-- scatter / bubble / radar
M.scatter = {
  label = '散点图',
  demo = {
    title = '柜子里的每个杯子', note = '一个杯子一个点，按大小画。小的被拿得多，只有一个例外。',
    xLabel = '容量 ml', yLabel = '一周被拿几次',
    rows = { { label = '小盅', x = 60, y = 9 }, { label = '茶碗', x = 120, y = 7 }, { label = '大马克', x = 350, y = 3 },
             { label = '高杯', x = 300, y = 2 }, { label = '咖啡杯', x = 180, y = 6 }, { label = '海碗', x = 480, y = 1 },
             { label = '中杯', x = 240, y = 5.5 }, { label = '蛋杯', x = 40, y = 8 } },
  },
}

-- 散点/气泡共用平面
local function plane(spec)
  local b = K.box({ x0 = 68, y0 = 76, x1 = 450, y1 = 310 })
  local xm = spec.xMax or K.top(math.max(1, K.maxv(spec.rows, 'x')))
  local ym = spec.yMax or K.top(math.max(1, K.maxv(spec.rows, 'y')))
  L.axes(b, ym, { ticks = 4 })
  for i = 0, 4 do
    local v = xm * i / 4
    P.text(K.vfmt(v), K.scale(v, 0, xm, b.x0, b.x1), b.y1 + 16, { size = 10, anchor = 'middle', col = P.LEAD })
  end
  P.text(spec.xLabel or 'x', b.x1, b.y1 + 30, { size = 10.5, anchor = 'end', col = P.LEAD })
  P.text(spec.yLabel or 'y', b.x0 - 4, b.y0 - 12, { size = 10.5, col = P.LEAD })
  return b, xm, ym
end

function M.scatter.draw(spec)
  local b, xm, ym = plane(spec)
  for i, r in ipairs(rows(spec)) do
    local x = K.scale(K.vof(r, 'x'), 0, xm, b.x0, b.x1)
    local y = K.scale(K.vof(r, 'y'), 0, ym, b.y1, b.y0)
    local rad = r.r or 6.5
    P.dot(x, y, rad, r.col or K.col(i), 1.2)
    P.text(tostring(r.label), x + rad + 4, y + 4, { size = 10, col = P.TONE })
  end
end

M.bubble = {
  label = '气泡图',
  demo = {
    title = '最好的泡泡水', note = '越右越多泡泡水，越高撑得越久，泡越大就越多泡泡。',
    xLabel = '泡泡水 (ml)', yLabel = '撑住的秒数',
    rows = { { label = '糖水', x = 20, y = 8, r = 8 }, { label = '皂片', x = 45, y = 21, r = 14 },
             { label = '洗发液', x = 62, y = 14, r = 11 }, { label = '洗洁精', x = 78, y = 26, r = 16 },
             { label = '盐水', x = 30, y = 5, r = 6 } },
  },
}

function M.bubble.draw(spec)
  local b, xm, ym = plane(spec)
  for i, r in ipairs(rows(spec)) do
    local x = K.scale(K.vof(r, 'x'), 0, xm, b.x0, b.x1)
    local y = K.scale(K.vof(r, 'y'), 0, ym, b.y1, b.y0)
    local rad = r.r or 10
    local col = r.col or K.col(i)
    P.dot(x, y, rad, P.glow(col), 1.2)
    P.dot(x - rad * .3, y - rad * .35, rad * .22, '#ffffff', 0)
    P.text(tostring(r.label), x, y + rad + 12, { size = 10, anchor = 'middle', col = P.TONE })
  end
end

M.radar = {
  label = '雷达图',
  demo = {
    title = '两辆自行车比一比', note = '每条环是一分，共五分，中心是零。绿点是城市车，琥珀是赛车。',
    axes = { '轻', '耐', '快', '稳', '便宜' }, max = 5,
    rows = { { label = '城市车', values = { 3, 5, 2, 4, 5 }, col = 'sage' },
             { label = '赛车', values = { 5, 2, 5, 2, 2 }, col = 'gold' } },
  },
  draw = function(spec)
    local ax = spec.axes or {}
    local n = #ax
    local cx, cy, r = 258, 196, 116
    local top = spec.max or 5
    local function pt(i, v)
      local a = -pi / 2 + 2 * pi * (i - 1) / n
      local rr = r * v / top
      return cx + cos(a) * rr, cy + sin(a) * rr
    end
    for k = 1, top do
      local ring = {}
      for i = 1, n do
        local x, y = pt(i, k)
        ring[#ring + 1] = { x, y }
      end
      P.line(ring, { w = .6, col = P.PAL.shade, amp = .25, over = 0, dash = k == top and '' or '3 5' })
    end
    for i = 1, n do
      local x, y = pt(i, top)
      P.line({ { cx, cy }, { x, y } }, { w = .6, col = P.PAL.shade, amp = .2, over = 0 })
      local lx, ly = pt(i, top * 1.22)
      P.text(tostring(ax[i]), lx, ly + 4, { size = 11, anchor = 'middle', col = P.TONE })
    end
    for _, s in ipairs(rows(spec)) do
      local poly = {}
      for i = 1, n do
        local x, y = pt(i, (s.values or {})[i] or 0)
        poly[#poly + 1] = { x, y }
      end
      local col = P.PAL[s.col] or s.col or P.PAL.sage
      P.shape(poly, P.mix(col, '#fdf9f1', .45), { w = 1.4 })
      for _, p in ipairs(poly) do P.dot(p[1], p[2], 4, col, 1) end
    end
    local labs, cols = {}, {}
    for i, s in ipairs(rows(spec)) do
      labs[i], cols[i] = tostring(s.label), P.PAL[s.col] or s.col or K.col(i)
    end
    K.legend(labs, cols, 90, 360)
  end,
}

return M
