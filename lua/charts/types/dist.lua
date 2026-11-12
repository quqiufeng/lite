-- lua/charts/types/dist.lua —— 「分布」这一族：
-- hexbin / candles / box / violin / ridge / bees / raincloud / volcano / manhattan / spaghetti / lasagna
local P = require('charts.pen')
local K = require('charts.kit')
local L = require('charts.types.lib')
local M = {}

local sin, cos, pi, sqrt, floor, abs, max, min = math.sin, math.cos, math.pi, math.sqrt, math.floor, math.abs, math.max, math.min
local function rows(spec) return spec.rows or {} end

M.hexbin = {
  label = '六边形分箱',
  demo = {
    title = '一帧蜂巢', note = '格子越深装的蜜越多。蜜都堆在上头，离育虫区远。',
    cols = 9, rowsN = 6,
    values = { 0,0,1,2,4,7,6,3,1, 0,1,2,5,9,12,8,4,2, 1,2,3,6,8,9,6,3,1,
               0,1,2,3,4,5,3,2,1, 0,0,1,1,2,2,1,1,0, 0,0,0,1,1,1,0,0,0 },
  },
  draw = function(spec)
    local cols, rowsN = spec.cols or 9, spec.rowsN or 6
    local vals = spec.values or {}
    local top = 1
    for _, v in ipairs(vals) do top = max(top, v) end
    -- 格子半径先按画布反推：宽 = (cols + .5) * √3 r，高 = (rowsN - 1) * 1.5r + 2r
    local bw, bh = 440, 250          -- 可用版面（x 40..480，y 76..326）
    local r = min(24, bw / ((cols + .5) * sqrt(3)), bh / ((rowsN - 1) * 1.5 + 2))
    local w = sqrt(3) * r
    local ox = 40 + (bw - (cols + .5) * w) / 2
    local oy = 76 + (bh - ((rowsN - 1) * 1.5 * r + 2 * r)) / 2 + r
    for j = 0, rowsN - 1 do
      for i = 0, cols - 1 do
        local cx = ox + i * w + (j % 2 == 1 and w / 2 or 0)
        local cy = oy + j * r * 1.5
        local v = vals[j * cols + i + 1] or 0
        local poly = P.ringAt(function(a, b) return { cx + a * r * .96, cy + b * r * .96 } end, 6)
        P.fill(poly, P.mix('#f7f1e3', '#c99a3f', v / top), { dx = .4, dy = .4, amp = .35 })
        P.inkLoop(poly, { w = 1, amp = .3, over = 0 })
      end
    end
  end,
}

M.candles = {
  label = 'K 线',
  demo = {
    title = '温室的一个星期', note = '每根蜡烛是早上到傍晚：红蜡变暖，蓝蜡变冷。烛台到火苗是一整天的高低。',
    rows = { { label = '一', o = 12, c = 17, lo = 9, hi = 19 }, { label = '二', o = 17, c = 14, lo = 12, hi = 18 },
             { label = '三', o = 14, c = 21, lo = 13, hi = 23 }, { label = '四', o = 21, c = 19, lo = 17, hi = 24 },
             { label = '五', o = 19, c = 24, lo = 18, hi = 26 }, { label = '六', o = 24, c = 22, lo = 20, hi = 27 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local b = K.boxPlot({ y0 = 72, y1 = 312 })
    local top = K.top(K.maxv(rs, 'hi'))
    local lo = min(0, K.minv(rs, 'lo'))
    for i = 0, 4 do
      local v = lo + (top - lo) * i / 4
      local y = K.scale(v, lo, top, b.y1, b.y0)
      P.line({ { b.x0, y }, { b.x1, y } }, { w = .5, col = P.PAL.shade, amp = .3, over = 0, dash = '3 6' })
      P.text(K.vfmt(v), b.x0 - 8, y + 4, { size = 10, anchor = 'end', col = P.LEAD })
    end
    local slot = (b.x1 - b.x0 - 8) / #rs
    for i, r in ipairs(rs) do
      local cx = b.x0 + slot * (i - .5)
      local bw = min(slot * .5, 26)
      local up = K.vof(r, 'c') >= K.vof(r, 'o')
      local col = up and P.PAL.pink or P.PAL.sky
      local yh = K.scale(K.vof(r, 'hi'), lo, top, b.y1, b.y0)
      local yl = K.scale(K.vof(r, 'lo'), lo, top, b.y1, b.y0)
      local yo = K.scale(K.vof(r, 'o'), lo, top, b.y1, b.y0)
      local yc = K.scale(K.vof(r, 'c'), lo, top, b.y1, b.y0)
      P.line({ { cx, yl }, { cx, yh } }, { w = 1.2, col = P.TONE, amp = .25, over = 0 })
      L.vbar(cx - bw / 2, cx + bw / 2, yo, yc, col)
      P.text(tostring(r.label), cx, b.y1 + 17, { size = 10.5, anchor = 'middle' })
    end
  end,
}

M.box = {
  label = '箱线图',
  demo = {
    title = '邮包走了多久', note = '箱子装的是中间一半的件。红绳那根是平常的一天。',
    rows = { { label = '本镇', values = { 1, 1, 2, 2, 2, 3, 3, 4 } }, { label = '邻县', values = { 2, 3, 3, 4, 4, 5, 6, 8 } },
             { label = '外省', values = { 3, 5, 6, 7, 8, 9, 10, 14 } }, { label = '海外', values = { 6, 9, 11, 12, 13, 16, 19, 26 } } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local b = K.boxPlot({ y0 = 72, y1 = 312 })
    local top = 1
    for _, r in ipairs(rs) do for _, v in ipairs(r.values or {}) do top = max(top, v) end end
    top = K.top(top)
    K.ticksY(b, top, 4)
    local slot = (b.x1 - b.x0 - 10) / #rs
    local function y(v) return K.scale(v, 0, top, b.y1, b.y0) end
    for i, r in ipairs(rs) do
      local cx = b.x0 + slot * (i - .5)
      local lo, q1, q2, q3, hi = L.quartiles(r.values or {})
      local bw = min(slot * .42, 40)
      P.line({ { cx, y(lo) }, { cx, y(hi) } }, { w = 1.2, col = P.TONE, amp = .25, over = 0 })
      P.line({ { cx - 10, y(lo) }, { cx + 10, y(lo) } }, { w = 1.2, amp = .25, over = 0 })
      P.line({ { cx - 10, y(hi) }, { cx + 10, y(hi) } }, { w = 1.2, amp = .25, over = 0 })
      L.vbar(cx - bw / 2, cx + bw / 2, y(q1), y(q3), P.PAL.sky)
      P.line({ { cx - bw / 2, y(q2) }, { cx + bw / 2, y(q2) } }, { w = 2, col = P.RED, amp = .3, over = 0 })
      P.text(tostring(r.label), cx, b.y1 + 17, { size = 10.5, anchor = 'middle' })
    end
  end,
}

-- 核密度身形（violin / ridge 共用）
local function shape(cx, hw, vals, top, b)
  local d = L.density(vals, 0, top, 26)
  local dm = 0
  for _, p in ipairs(d) do dm = max(dm, p.d) end
  local left, right = {}, {}
  for _, p in ipairs(d) do
    local y = K.scale(p.v, 0, top, b.y1, b.y0)
    local w = hw * p.d / max(dm, 1e-9)
    left[#left + 1] = { cx - w, y }
    right[#right + 1] = { cx + w, y }
  end
  local poly = {}
  for _, p in ipairs(left) do poly[#poly + 1] = p end
  for k = #right, 1, -1 do poly[#poly + 1] = right[k] end
  return poly, d, dm
end

M.violin = {
  label = '小提琴图',
  demo = {
    title = '每周练习，按人分', note = '每个身形是小时数的分布。多数人坐在哪儿，那儿就宽；红条是中位数。',
    rows = { { label = '甲', values = { 2, 3, 3, 4, 4, 4, 5 } }, { label = '乙', values = { 1, 2, 4, 6, 7, 8, 10 } },
             { label = '丙', values = { 3, 3, 4, 4, 4, 5, 5 } }, { label = '丁', values = { 0, 1, 1, 2, 3, 5, 9 } } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local b = K.boxPlot({ y0 = 72, y1 = 312 })
    local top = K.top(K.maxv(rs, 'values') > 0 and K.maxv(rs, 'values') or 10)
    K.ticksY(b, top, 4)
    local slot = (b.x1 - b.x0) / #rs
    for i, r in ipairs(rs) do
      local cx = b.x0 + slot * (i - .5)
      local poly = shape(cx, min(slot * .36, 38), r.values or { 0 }, top, b)
      P.shape(poly, P.mix(K.col(i), '#fdf9f1', .35), { w = 1.2 })
      local _, _, q2 = L.quartiles(r.values or {})
      local y = K.scale(q2, 0, top, b.y1, b.y0)
      P.line({ { cx - 9, y }, { cx + 9, y } }, { w = 2, col = P.RED, amp = .25, over = 0 })
      P.text(tostring(r.label), cx, b.y1 + 17, { size = 10.5, anchor = 'middle' })
    end
  end,
}

M.ridge = {
  label = '山脊图',
  demo = {
    title = '山上的人，按小时', note = '每条山脊是一个月，高低是那个钟点路上有多挤。',
    labels = { '一', '二', '三', '四', '五' }, top = 12,
    rows = { { values = { 0, 1, 3, 6, 9, 11, 8, 4, 1 } }, { values = { 0, 0, 2, 5, 8, 10, 6, 3, 1 } },
             { values = { 1, 2, 4, 7, 10, 12, 9, 5, 2 } }, { values = { 0, 2, 5, 9, 11, 7, 3, 1, 0 } },
             { values = { 0, 1, 2, 4, 6, 8, 5, 2, 1 } } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local labs = spec.labels or {}
    local top = spec.top or 12
    local x0, x1 = 74, 460
    local step, base = 46, 96
    for i, r in ipairs(rs) do
      local y0 = base + (i - 1) * step
      local vals = r.values or {}
      local m = 0
      for _, v in ipairs(vals) do m = max(m, v) end
      local up, dn = {}, {}
      for k, v in ipairs(vals) do
        local x = K.scale(k, 1, #vals, x0, x1)
        local h = 34 * v / max(m, 1e-9)
        up[#up + 1] = { x, y0 - h }
        dn[#dn + 1] = { x, y0 }
      end
      local poly = {}
      for _, p in ipairs(up) do poly[#poly + 1] = p end
      for k = #dn, 1, -1 do poly[#poly + 1] = dn[k] end
      P.shape(poly, P.mix(K.col(i), '#fdf9f1', .25), { w = 1.1 })
      P.text(tostring(labs[i] or i), x0 - 12, y0 + 4, { size = 10.5, anchor = 'end', col = P.TONE })
    end
    -- 横轴是「第几列」，不是 top 的等分：列数自己算，标签按列落位
    -- （原来所有标签都用 K.scale(1,1,9,...) 一个死 x，全叠在同一处）
    local n = #((rs[1] or {}).values or {})
    if n >= 2 then
      local step = math.max(1, math.floor((n - 1) / 3))
      for k = 1, n, step do
        local hour = top * (k - 1) / (n - 1)
        local hh, mm = math.floor(hour), math.floor((hour % 1) * 60 + .5)
        P.text(string.format('%d:%02d', hh, mm), K.scale(k, 1, n, x0, x1), 330,
          { size = 9, col = P.LEAD, anchor = 'middle' })
      end
    end
  end,
}

M.bees = {
  label = '蜂群图',
  demo = {
    title = '薰衣草上的蜜蜂', note = '一只蜂一次来访。中午刚过，蜂团最挤。',
    rows = { { label = '八点', values = { 1, 2, 2, 3 } }, { label = '十点', values = { 3, 4, 4, 5, 6 } },
             { label = '十二点', values = { 5, 6, 7, 7, 8, 9, 9, 10, 11 } },
             { label = '两点', values = { 4, 5, 6, 6, 7 } }, { label = '四点', values = { 2, 3, 3, 4 } } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local b = K.boxPlot({ y0 = 72, y1 = 312 })
    local top = K.top(K.maxv(rs, 'values'))
    K.ticksY(b, top, 4)
    local slot = (b.x1 - b.x0) / #rs
    for i, r in ipairs(rs) do
      local cx = b.x0 + slot * (i - .5)
      local seen = {}
      for _, v in ipairs(r.values or {}) do
        local y = K.scale(v, 0, top, b.y1, b.y0)
        local n = seen[K.int(v)] or 0
        seen[K.int(v)] = n + 1
        local x = cx + ((n % 2 == 0) and 1 or -1) * (7 + 7 * floor(n / 2))
        P.dot(x, y, 4.6, K.col(i), 1)
      end
      P.text(tostring(r.label), cx, b.y1 + 17, { size = 10.5, anchor = 'middle' })
    end
  end,
}

M.raincloud = {
  label = '雨云图',
  demo = {
    title = '三种上班方式', note = '每一滴是一趟。云是它们的形状，下面横条是中间一半。',
    rows = { { label = '走路', values = { 22, 24, 25, 26, 26, 28, 30 } }, { label = '骑车', values = { 12, 14, 15, 15, 16, 18, 21 } },
             { label = '公交', values = { 28, 31, 33, 34, 36, 39, 44 } } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local top = K.top(K.maxv(rs, 'values'))
    local slot = (470 - 90) / #rs
    local bb = { y0 = 78, y1 = 226 }
    for i, r in ipairs(rs) do
      local cx = 90 + slot * (i - .5)
      local vals = r.values or {}
      local poly = shape(cx, min(slot * .34, 34), vals, top, bb)
      P.shape(poly, P.mix(K.col(i), '#fdf9f1', .3), { w = 1.2 })
      for k, v in ipairs(vals) do
        P.dot(cx - 16 + (k % 5) * 7, 248 + (k % 2) * 9, 3.6, K.col(i), .9)
      end
      local _, q1, q2, q3 = L.quartiles(vals)
      -- 下面的横条＝横向箱线：须是 min..max，粗条是中间一半
      -- 用本组自己的 min..max 做比例尺（套 0..top 的话四分位差只有几像素，缩成一个点）
      local half = min(slot * .34, 34)
      local lo, hi = vals[1], vals[1]
      for _, v in ipairs(vals) do
        if v < lo then lo = v end
        if v > hi then hi = v end
      end
      if hi == lo then hi = lo + 1 end
      local sx = function(v) return K.scale(v, lo, hi, cx - half, cx + half) end
      P.line({ { sx(lo), 288 }, { sx(hi), 288 } }, { w = 1.1, col = P.LEAD, amp = .3, over = 0 })
      P.line({ { sx(lo), 284 }, { sx(lo), 292 } }, { w = 1.1, col = P.LEAD, amp = .25, over = 0 })
      P.line({ { sx(hi), 284 }, { sx(hi), 292 } }, { w = 1.1, col = P.LEAD, amp = .25, over = 0 })
      P.line({ { sx(q1), 288 }, { sx(q3), 288 } }, { w = 5, amp = .45, over = 0 })
      P.dot(sx(q2), 288, 3.2, P.RED, 1)
      P.text(tostring(r.label), cx, 312, { size = 10.5, anchor = 'middle' })
    end
  end,
}

M.volcano = {
  label = '火山图',
  demo = {
    title = '四十处改动，一个蛋糕', note = '左变更糟，右变更好，越高越确定。只有越过虚线的才算数。',
    rows = { { label = '糖', x = -2.6, y = 4.1 }, { label = '黄油', x = -1.8, y = 2.2 }, { label = '盐', x = .4, y = 1.1 },
             { label = '香草', x = 2.2, y = 3.4 }, { label = '泡打', x = 3.1, y = 5.2 }, { label = '牛奶', x = 1.2, y = 1.6 },
             { label = '柠檬', x = -3.4, y = 5.6 }, { label = '可可', x = 2.9, y = .9 } },
      line = 2, xMax = 4, yMax = 6,
  },
  draw = function(spec)
    local rs = rows(spec)
    local b = K.box({ x0 = 70, y0 = 76, x1 = 452, y1 = 306 })
    local xm, ym = spec.xMax or 4, spec.yMax or 6
    local cut = spec.line or 2
    P.line({ { b.x0, b.y1 }, { b.x1 + 3, b.y1 } }, { w = 1.5, amp = .4 })
    P.line({ { b.x0, b.y0 - 2 }, { b.x0, b.y1 } }, { w = 1.5, amp = .4 })
    local cx = K.scale(0, -xm, xm, b.x0, b.x1)
    P.line({ { cx, b.y0 }, { cx, b.y1 } }, { w = 1, col = P.LEAD, amp = .25, over = 0, dash = '4 4' })
    local yc = K.scale(cut, 0, ym, b.y1, b.y0)
    P.line({ { b.x0, yc }, { b.x1, yc } }, { w = 1, col = P.RED, amp = .25, over = 0, dash = '6 5' })
    P.text('P = ' .. K.vfmt(cut), b.x1, yc - 6, { size = 9.5, anchor = 'end', col = P.RED })
    for i, r in ipairs(rs) do
      local x = K.scale(K.vof(r, 'x'), -xm, xm, b.x0, b.x1)
      local y = K.scale(K.vof(r, 'y'), 0, ym, b.y1, b.y0)
      local up = K.vof(r, 'y') >= cut
      P.dot(x, y, up and 6 or 4.4, up and (K.vof(r, 'x') > 0 and P.PAL.sage or P.PAL.pink) or P.PAL.steel, 1.1)
      if K.vof(r, 'y') >= cut then
        local right = K.vof(r, 'x') > 0
        P.text(tostring(r.label), right and x + 9 or x - 9, y + 4, { size = 10, anchor = right and 'start' or 'end' })
      end
    end
  end,
}

M.manhattan = {
  label = '曼哈顿图',
  demo = {
    title = '十四条大街上的行人', note = '每条大街一座塔，多挤就多高。有两座越过了线。',
    line = 25,
    rows = { { label = '一', value = 8 }, { label = '二', value = 14 }, { label = '三', value = 11 }, { label = '四', value = 22 },
             { label = '五', value = 19 }, { label = '六', value = 31 }, { label = '七', value = 12 }, { label = '八', value = 9 },
             { label = '九', value = 26 }, { label = '十', value = 17 }, { label = '十一', value = 13 }, { label = '十二', value = 7 },
             { label = '十三', value = 24 }, { label = '十四', value = 10 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local b = K.box({ x0 = 62, y0 = 80, x1 = 452, y1 = 300 })
    local top = K.top(K.maxv(rs))
    local cut = spec.line or top * .8
    P.line({ { b.x0, b.y1 }, { b.x1 + 3, b.y1 } }, { w = 1.5, amp = .4 })
    P.line({ { b.x0, b.y0 - 2 }, { b.x0, b.y1 } }, { w = 1.5, amp = .4 })
    local yc = K.scale(cut, 0, top, b.y1, b.y0)
    P.line({ { b.x0, yc }, { b.x1, yc } }, { w = 1, col = P.RED, amp = .3, over = 0, dash = '6 5' })
    local slot = (b.x1 - b.x0) / #rs
    for i, r in ipairs(rs) do
      local cx = b.x0 + slot * (i - .5)
      local v = K.vof(r)
      local yt = K.scale(v, 0, top, b.y1, b.y0)
      local over = v >= cut
      L.vbar(cx - slot * .3, cx + slot * .3, b.y1, yt, over and P.PAL.rose or (i % 2 == 0 and P.PAL.sky or P.PAL.steel))
      P.text(tostring(r.label), cx, b.y1 + 16, { size = 9.5, anchor = 'middle', col = P.LEAD })
      if over then P.text(K.vfmt(v), cx, yt - 8, { size = 10, anchor = 'middle', col = P.RED }) end
    end
  end,
}

local function lines(spec, o)
  o = o or {}
  local rs = rows(spec)
  local b = K.box({ x0 = 66, y0 = o.y0 or 80, x1 = 452, y1 = o.y1 or 300 })
  local top = spec.top or K.top(K.maxv(rs, 'values'))
  local n = 0
  for _, r in ipairs(rs) do n = max(n, #(r.values or {})) end
  P.line({ { b.x0, b.y1 }, { b.x1 + 3, b.y1 } }, { w = 1.5, amp = .4 })
  P.line({ { b.x0, b.y0 - 2 }, { b.x0, b.y1 } }, { w = 1.5, amp = .4 })
  for i = 0, 4 do
    local v = top * i / 4
    local y = K.scale(v, 0, top, b.y1, b.y0)
    P.text(K.vfmt(v), b.x0 - 8, y + 4, { size = 10, anchor = 'end', col = P.LEAD })
    if i > 0 then P.line({ { b.x0, y }, { b.x1, y } }, { w = .5, col = P.PAL.shade, amp = .3, over = 0, dash = '3 6' }) end
  end
  for i, r in ipairs(rs) do
    local pts = {}
    for k, v in ipairs(r.values or {}) do
      pts[#pts + 1] = { K.scale(k, 1, max(n, 2), b.x0, b.x1), K.scale(v, 0, top, b.y1, b.y0) }
    end
    P.line(pts, { w = o.w or 1.7, col = r.col or K.col(i), amp = .4, over = 0, op = o.op or 1 })
    if o.dots then for _, p in ipairs(pts) do P.dot(p[1], p[2], 3, r.col or K.col(i), .9) end end
  end
  return b, top, n
end

M.spaghetti = {
  label = '意大利面图',
  demo = {
    title = '七个孩子，一起长大', note = '一根面是一个孩子，从两岁量到十二岁。', top = 160,
    rows = { { label = '阿', values = { 90, 100, 108, 116, 124, 130, 140, 148, 152, 158, 160 } },
             { label = '波', values = { 84, 92, 100, 104, 112, 118, 124, 128, 134, 138, 142 } },
             { label = '西', values = { 88, 96, 104, 110, 118, 126, 132, 140, 146, 150, 156 } },
             { label = '伊', values = { 82, 88, 94, 100, 108, 114, 120, 126, 130, 136, 140 } } },
  },
  draw = function(spec)
    local b, top, n = lines(spec)
    local ends = {}
    for i, r in ipairs(rows(spec)) do
      local last = (r.values or {})[n]
      if last then
        ends[#ends + 1] = { y = K.scale(last, 0, top, b.y1, b.y0), label = tostring(r.label), col = K.col(i) }
      end
    end
    -- 末值挨得近时标签会叠字：按 y 排好再逐个下推，保证最小行距，整体再夹回画布
    local gap = 11
    table.sort(ends, function(a, c) return a.y < c.y end)
    for i = 2, #ends do
      if ends[i].y - ends[i - 1].y < gap then ends[i].y = ends[i - 1].y + gap end
    end
    local lastE = ends[#ends]
    local spill = lastE and (lastE.y - b.y1)
    if spill and spill > 0 then
      local first = ends[1].y - spill
      if first < b.y0 - 6 then spill = spill - (b.y0 - 6 - first) end
      for _, e in ipairs(ends) do e.y = e.y - spill end
    end
    for _, e in ipairs(ends) do
      -- 右边放得下就挂轴外，放不下就贴着右端反挂（不越画布）
      local anchor = (b.x1 + 8 + P.textw(e.label, 10) > 496) and 'end' or 'start'
      P.text(e.label, anchor == 'end' and (b.x1 + 6) or (b.x1 + 8), e.y + 3.4,
        { size = 10, col = e.col, anchor = anchor })
    end
    P.text('两岁', b.x0, b.y1 + 16, { size = 9.5, anchor = 'middle', col = P.LEAD })
    P.text('十二岁', b.x1, b.y1 + 16, { size = 9.5, anchor = 'middle', col = P.LEAD })
  end,
}

M.lasagna = {
  label = '千层面图',
  demo = {
    title = '一家人，一周的睡眠', note = '每一层是一个人，每一格是一夜。番茄色是短夜，奶白是长夜。',
    rows = { { label = '爸', values = { 6, 7, 5, 8, 7, 9, 8 } }, { label = '妈', values = { 5, 6, 7, 6, 8, 8, 7 } },
             { label = '哥', values = { 8, 9, 7, 6, 7, 10, 9 } }, { label = '妹', values = { 7, 8, 8, 9, 6, 7, 8 } } },
    days = { '一', '二', '三', '四', '五', '六', '日' },
  },
  draw = function(spec)
    local rs = rows(spec)
    local days = spec.days or {}
    local x0, y0, cw, ch = 88, 100, 48, 36
    local lo, hi = 4, 11
    for k, d in ipairs(days) do
      P.text(tostring(d), x0 + (k - .5) * cw, y0 - 12, { size = 10, anchor = 'middle', col = P.LEAD })
    end
    for i, r in ipairs(rs) do
      P.text(tostring(r.label), x0 - 12, y0 + (i - .5) * ch + 4, { size = 10.5, anchor = 'end', col = P.TONE })
      for k, v in ipairs(r.values or {}) do
        local t = (v - lo) / (hi - lo)
        local x, y = x0 + (k - 1) * cw, y0 + (i - 1) * ch
        local sq = { { x, y }, { x + cw - 3, y }, { x + cw - 3, y + ch - 3 }, { x, y + ch - 3 } }
        P.fill(sq, P.mix('#dfae95', '#f4eddc', t), { dx = .4, dy = .3, amp = .3 })
        P.inkLoop(sq, { w = .8, amp = .2, over = 0, col = P.TONE })
        P.text(K.int(v), x + (cw - 3) / 2, y + (ch - 3) / 2 + 4, { size = 10, anchor = 'middle', col = t > .5 and P.INK or '#8a6a56' })
      end
    end
    P.text('小时', x0 - 12, y0 + #rs * ch + 18, { size = 9.5, anchor = 'end', col = P.LEAD })
  end,
}

return M
