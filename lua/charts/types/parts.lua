-- lua/charts/types/parts.lua —— 「整体切成几块」这一族：
-- pie / doughnut / waffle / treemap / sunburst / stacked / rose / nested / pyramid
local P = require('charts.pen')
local K = require('charts.kit')
local M = {}

local function rows(spec) return spec.rows or {} end

-- 扇形：从圆心出发的两条边 + 一段弧，闭合
local function sector(cx, cy, r0, r1, a0, a1)
  local o = {}
  if r0 > 0 then
    for i = 0, 20 do
      local t = a0 + (a1 - a0) * i / 20
      o[#o + 1] = { cx + r0 * math.cos(t), cy + r0 * math.sin(t) }
    end
    for i = 20, 0, -1 do
      local t = a0 + (a1 - a0) * i / 20
      o[#o + 1] = { cx + r1 * math.cos(t), cy + r1 * math.sin(t) }
    end
  else
    o[1] = { cx, cy }
    for i = 0, 20 do
      local t = a0 + (a1 - a0) * i / 20
      o[#o + 1] = { cx + r1 * math.cos(t), cy + r1 * math.sin(t) }
    end
  end
  return o
end
M.sector = sector

local function pct(v, total)
  if total <= 0 then return '0%' end
  return string.format('%d%%', math.floor(v / total * 100 + .5))
end

local function pieLike(spec, r0)
  local rs = rows(spec)
  local total = K.sum(rs)
  local cx, cy = spec.cx or 232, spec.cy or 206
  local r1 = spec.r or 112
  local a = -math.pi / 2
  local best, bi = -1, 1
  for i, row in ipairs(rs) do
    if K.vof(row) > best then best, bi = K.vof(row), i end
  end
  for i, row in ipairs(rs) do
    local v = K.vof(row)
    local span = total > 0 and (v / total) * 2 * math.pi or 0
    local a0, a1 = a, a + span
    local mid = (a0 + a1) / 2
    local off = (i == bi) and 6 or 0
    local ox, oy = cx + math.cos(mid) * off, cy + math.sin(mid) * off
    local col = row.col or K.col(i)
    local s = sector(ox, oy, r0, r1, a0, a1)
    P.fill(s, col, { dx = .8, dy = .6, amp = .5 })
    P.inkLoop(s, { w = 1.5, amp = .4, over = 0 })
    if span > .34 then
      local rr = (r0 + r1) / 2
      P.text(pct(v, total), ox + math.cos(mid) * rr, oy + math.sin(mid) * rr + 4,
        { size = 13, anchor = 'middle', col = P.INK })
    end
    a = a1
  end
  return cx, cy, r1, total, bi
end

M.pie = {
  label = '饼图',
  demo = {
    title = '一整天是怎么花掉的', note = '扇形的角度就是小时数：数字是编的，只看形状。',
    rows = { { label = '睡', value = 8.5 }, { label = '吃', value = 2 }, { label = '路上', value = 1.5 },
             { label = '家事', value = 3 }, { label = '读书', value = 4 }, { label = '发呆', value = 5 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local cx, cy, r, total, bi = pieLike(spec, 0)
    local row, v = rs[bi], K.vof(rs[bi])
    -- 找到最大块的角平分线，标注就贴在那一块的外侧，不压在别的扇区上
    local a = -math.pi / 2
    for i = 1, #rs do
      local span = (K.vof(rs[i]) / total) * 2 * math.pi
      if i == bi then a = a + span / 2 break end
      a = a + span
    end
    local px, py = cx + math.cos(a) * (r + 4), cy + math.sin(a) * (r + 4)
    -- 标签放在饼右上方空白处，引线从角平分线外沿折回来
    local side = math.cos(a) >= 0
    K.callout(px, py, side and 500 or 40, 92, tostring(row.label),
      K.vfmt(v) .. ' h · ' .. pct(v, total), side and 'end' or 'start')
    local labs, cols = {}, {}
    for i, r2 in ipairs(rs) do labs[i], cols[i] = tostring(r2.label), r2.col or K.col(i) end
    K.legend(labs, cols, 60, 344)
  end,
}

-- ---------------------------------------------------------------------------
-- 甜甜圈：切块一族去掉圆心，中间放总数
-- ---------------------------------------------------------------------------
M.doughnut = {
  label = '甜甜圈图',
  demo = {
    title = '一盒里就这十二个', note = '中间那行数字才是结论：一共 12 个，一口没剩。',
    rows = { { label = '圆', value = 5 }, { label = '方', value = 3 }, { label = '长', value = 2 },
             { label = '碎', value = 1.5 }, { label = '边角', value = .5 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local total, r = K.sum(rs), spec.r or 110
    local cx, cy = spec.cx or 222, spec.cy or 208
    local inner = r * (spec.hole or .54)
    pieLike({ cx = cx, cy = cy, r = r, rows = rs, seed = spec.seed }, inner)
    -- 圆心：总数 + 一句解释，别留个大白洞
    P.text(K.vfmt(total), cx, cy + 4, { size = 26, anchor = 'middle', serif = true })
    P.text(spec.unit or '合计', cx, cy + 22, { size = 10.5, anchor = 'middle', col = P.LEAD })
    -- 右上角点出最大的一块，别挤在图里
    local bi, best = 1, -1
    for i, row in ipairs(rs) do if K.vof(row) > best then best, bi = K.vof(row), i end end
    local a = -math.pi / 2
    for i = 1, bi do
      local span = K.vof(rs[i]) / total * 2 * math.pi
      if i == bi then a = a + span / 2 break end
      a = a + span
    end
    local px, py = cx + math.cos(a) * (r + 2), cy + math.sin(a) * (r + 2)
    local side = math.cos(a) >= 0
    K.callout(px, py, side and 498 or 44, 92, tostring(rs[bi].label),
      K.vfmt(best) .. ' · ' .. pct(best, total), side and 'end' or 'start')
  end,
}

-- ---------------------------------------------------------------------------
-- 华夫图：100 格，一格一个百分点，能一眼数出来
-- ---------------------------------------------------------------------------
M.waffle = {
  label = '华夫图',
  demo = {
    title = '一百顿周日早饭', note = '一格一个百分点，数格子比读百分比快。',
    rows = { { label = '麦片', value = 38 }, { label = '吐司', value = 27 },
             { label = '蛋', value = 22 }, { label = '没吃', value = 13 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local total = K.sum(rs)
    local n, cell, gap = 10, 21, 2
    local x0, y0 = 84, 74
    local acc = 0
    local quotas = {}
    for i, row in ipairs(rs) do
      local q = math.floor(K.vof(row) / total * 100 + .5)
      quotas[i] = q
      acc = acc + q
    end
    -- 补齐/抹平舍入误差，保证恰好 100 格
    local k = 1
    while acc > 100 do
      while quotas[k] <= 1 do k = k % #quotas + 1 end
      quotas[k] = quotas[k] - 1; acc = acc - 1
    end
    while acc < 100 do quotas[k] = quotas[k] + 1; acc = acc + 1; k = k % #quotas + 1 end
    local idx = 0
    for i, row in ipairs(rs) do
      local col = row.col or K.col(i)
      for _ = 1, quotas[i] do
        local gx, gy = idx % n, math.floor(idx / n)
        local x, y = x0 + gx * (cell + gap), y0 + gy * (cell + gap)
        local p = { { x, y }, { x + cell, y }, { x + cell, y + cell }, { x, y + cell } }
        P.fill(p, col, { dx = .4, dy = .3, amp = .35 })
        P.inkLoop(p, { w = .9, amp = .25, over = 0 })
        idx = idx + 1
      end
    end
    local labs, cols = {}, {}
    for i, row in ipairs(rs) do
      labs[i] = tostring(row.label) .. ' ' .. quotas[i]
      cols[i] = row.col or K.col(i)
    end
    K.legend(labs, cols, 84, 342, { gap = 16 })
  end,
}

-- ---------------------------------------------------------------------------
-- 树图：面积就是数量，按长边交替切
-- ---------------------------------------------------------------------------
local function tsplit(items, x, y, w, h, out)
  if #items == 0 then return end
  if #items == 1 then
    out[#out + 1] = { x = x, y = y, w = w, h = h, it = items[1] }
    return
  end
  local total = 0
  for _, it in ipairs(items) do total = total + it.v end
  local acc, cut = 0, 1
  for i = 1, #items - 1 do
    acc = acc + items[i].v
    if acc >= total / 2 then cut = i break end
  end
  local a, b = {}, {}
  for i, it in ipairs(items) do
    if i <= cut then a[#a + 1] = it else b[#b + 1] = it end
  end
  local sa = 0
  for _, it in ipairs(a) do sa = sa + it.v end
  local frac = sa / total
  if w >= h then
    tsplit(a, x, y, w * frac, h, out)
    tsplit(b, x + w * frac, y, w * (1 - frac), h, out)
  else
    tsplit(a, x, y, w, h * frac, out)
    tsplit(b, x, y + h * frac, w, h * (1 - frac), out)
  end
end

M.treemap = {
  label = '树图',
  demo = {
    title = '一片果园的一百棵树', note = '每块面积就是棵数；小到放不下字的块并进「其他」。',
    rows = { { label = '苹果', value = 34 }, { label = '梨', value = 26 }, { label = '李', value = 18 },
             { label = '樱桃', value = 12 }, { label = '核桃', value = 6 }, { label = '其他', value = 4 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local total = K.sum(rs)
    local items = {}
    for i, row in ipairs(rs) do
      items[#items + 1] = { v = K.vof(row), label = tostring(row.label), col = row.col or K.col(i) }
    end
    table.sort(items, function(a, b) return a.v > b.v end)
    local out = {}
    tsplit(items, 46, 62, 428, 268, out)
    for _, q in ipairs(out) do
      local p = { { q.x, q.y }, { q.x + q.w, q.y }, { q.x + q.w, q.y + q.h }, { q.x, q.y + q.h } }
      P.fill(p, q.it.col, { dx = .6, dy = .5, amp = .4 })
      P.inkLoop(p, { w = 1.3, amp = .3, over = 0 })
      if q.w > 46 and q.h > 26 then
        P.text(q.it.label, q.x + 7, q.y + 17, { size = 12 })
        P.text(pct(q.it.v, total), q.x + 7, q.y + 32, { size = 11, col = P.TONE })
      end
    end
  end,
}

-- ---------------------------------------------------------------------------
-- 旭日图：内环是父级，外环是子级
-- ---------------------------------------------------------------------------
M.sunburst = {
  label = '旭日图',
  demo = {
    title = '花园里的一年', note = '内环四个季节，外环是每季的花；同一片颜色就是同一家。',
    groups = {
      { label = '春', value = 26, col = '#a0cab4', kids = { { '水仙', 12 }, { '郁金香', 8 }, { '风信子', 6 } } },
      { label = '夏', value = 34, col = '#e2b34d', kids = { { '玫瑰', 16 }, { '百合', 11 }, { '薰衣草', 7 } } },
      { label = '秋', value = 24, col = '#d6826d', kids = { { '菊', 14 }, { '大丽花', 10 } } },
      { label = '冬', value = 16, col = '#bcccdb', kids = { { '圣诞红', 9 }, { '腊梅', 7 } } },
    },
  },
  draw = function(spec)
    local gs = spec.groups or {}
    local total = 0
    for _, g in ipairs(gs) do total = total + g.value end
    local cx, cy = 250, 206
    local r0, r1, r2 = 44, 86, 128
    local a = -math.pi / 2
    for gi, g in ipairs(gs) do
      local span = g.value / total * 2 * math.pi
      local s = sector(cx, cy, r0, r1, a, a + span)
      P.fill(s, g.col or K.col(gi), { dx = .6, dy = .5, amp = .4 })
      P.inkLoop(s, { w = 1.2, amp = .25, over = 0 })
      local mid = a + span / 2
      if span > .5 then
        local tx, ty = cx + math.cos(mid) * (r0 + r1) / 2, cy + math.sin(mid) * (r0 + r1) / 2
        P.text(g.label, tx, ty + 4, { size = 11.5, anchor = 'middle' })
      end
      local aa = a
      local kt = 0
      for _, kid in ipairs(g.kids or {}) do kt = kt + kid[2] end
      for ki, kid in ipairs(g.kids or {}) do
        local ks = kid[2] / total * 2 * math.pi
        local c2 = P.lit(g.col or K.col(gi))
        c2 = P.mix(g.col or K.col(gi), '#ffffff', .18 + .12 * (ki % 3))
        local s2 = sector(cx, cy, r1 + 2, r2, aa, aa + ks)
        P.fill(s2, c2, { dx = .5, dy = .4, amp = .4 })
        P.inkLoop(s2, { w = 1, amp = .25, over = 0 })
        if ks > .28 then
          local m2 = aa + ks / 2
          local tx, ty = cx + math.cos(m2) * (r1 + r2) / 2, cy + math.sin(m2) * (r1 + r2) / 2
          P.text(kid[1], tx, ty + 4, { size = 10.5, anchor = 'middle', col = P.TONE })
        end
        aa = aa + ks
      end
      a = a + span
    end
  end,
}

-- ---------------------------------------------------------------------------
-- 堆叠柱：总量 + 每根柱子由什么组成
-- ---------------------------------------------------------------------------
M.stacked = {
  label = '堆叠柱',
  demo = {
    title = '一盒巧克力的一周', note = '柱高是总量，颜色是配方；周三那根最高，也最碎。',
    cols = { '牛奶', '黑巧', '坚果' },
    rows = { { label = '一', v = { 12, 8, 4 } }, { label = '二', v = { 15, 9, 5 } },
             { label = '三', v = { 21, 12, 7 } }, { label = '四', v = { 18, 11, 6 } },
             { label = '五', v = { 25, 14, 9 } }, { label = '六', v = { 22, 10, 8 } },
             { label = '日', v = { 9, 6, 3 } } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local keys = #(rs[1] and rs[1].v or {})
    local tops = {}
    for _, row in ipairs(rs) do
      local s = 0
      for k = 1, keys do s = s + (row.v[k] or 0) end
      tops[#tops + 1] = s
    end
    local mt = 1
    for _, v in ipairs(tops) do if v > mt then mt = v end end
    local top = K.top(mt)
    local b = K.box({ y0 = 60, y1 = 330 })
    local n = #rs
    local slot = (b.x1 - b.x0) / n
    for i, row in ipairs(rs) do
      local x0 = b.x0 + slot * (i - 1) + slot * .22
      local x1 = x0 + slot * .56
      local acc = 0
      for k = 1, keys do
        local v = row.v[k] or 0
        local yb = K.scale(acc + v, 0, top, b.y1, b.y0)
        local yt = K.scale(acc, 0, top, b.y1, b.y0)
        local col = K.col(k)
        P.fill({ { x0, yb }, { x1, yb }, { x1, yt }, { x0, yt } }, col, { dx = .4, dy = .3, amp = .3 })
        if k == keys then P.inkLoop({ { x0, yb }, { x1, yb }, { x1, yt }, { x0, yt } }, { w = 1.2, amp = .3, over = 0 }) end
        acc = acc + v
      end
      P.text(tostring(row.label), (x0 + x1) / 2, b.y1 + 17, { size = 11.5, anchor = 'middle' })
    end
    local labs = spec.cols or {}
    if #labs == 0 then for k = 1, keys do labs[k] = '第' .. k .. '种' end end
    local cols = {}
    for k = 1, keys do cols[k] = K.col(k) end
    -- 图例压到轴标下面一行（b.y1+17 是星期几，图例再高就撞上了）
    K.legend(labs, cols, 60, b.y1 + 42, { gap = 18 })
  end,
}

-- ---------------------------------------------------------------------------
-- 玫瑰图：等角度，半径按开方缩放（面积才和值成正比）
-- ---------------------------------------------------------------------------
M.rose = {
  label = '玫瑰图',
  demo = {
    title = '一年的雨', note = '每个花瓣一个月份；半径开方过，眼睛看到的面积才对得上毫米数。',
    rows = { { label = '1', value = 62 }, { label = '2', value = 48 }, { label = '3', value = 55 },
             { label = '4', value = 40 }, { label = '5', value = 68 }, { label = '6', value = 96 },
             { label = '7', value = 110 }, { label = '8', value = 88 }, { label = '9', value = 72 },
             { label = '10', value = 58 }, { label = '11', value = 44 }, { label = '12', value = 36 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local cx, cy = 250, 210
    local rmax = 128
    local mx = 0
    for _, row in ipairs(rs) do if K.vof(row) > mx then mx = K.vof(row) end end
    if mx <= 0 then mx = 1 end
    local n = #rs
    -- 参考圈：三档
    for _, f in ipairs({ .34, .67, 1 }) do
      P.line(P.oval(cx, cy, rmax * math.sqrt(f), rmax * math.sqrt(f), 40), { w = .6, col = P.PAL.shade, amp = .25, dash = '3 5' })
    end
    local step = 2 * math.pi / n
    for i, row in ipairs(rs) do
      local a0 = -math.pi / 2 + (i - 1) * step + .014
      local a1 = a0 + step - .028
      local rr = rmax * math.sqrt(math.max(0, K.vof(row)) / mx)
      local s = sector(cx, cy, 0, rr, a0, a1)
      local col = K.col((i - 1) % 8 + 1)
      P.fill(s, col, { dx = .5, dy = .4, amp = .45 })
      P.inkLoop(s, { w = 1.1, amp = .28, over = 0 })
      local m = (a0 + a1) / 2
      P.text(tostring(row.label), cx + math.cos(m) * (rmax + 13), cy + math.sin(m) * (rmax + 13) + 4,
        { size = 10.5, anchor = 'middle', col = P.LEAD })
    end
  end,
}

-- ---------------------------------------------------------------------------
-- 嵌套：一层套一层，每层写自己的名字和量
-- ---------------------------------------------------------------------------
M.nested = {
  label = '嵌套图',
  demo = {
    title = '娃娃里面还有娃娃', note = '从外到内是包含关系，不是并列；数字是这一层的值。',
    rows = { { label = '全部 100', value = 100 }, { label = '能用的 78', value = 78 },
             { label = '好用的 52', value = 52 }, { label = '爱用的 31', value = 31 },
             { label = '天天用 17', value = 17 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local total = #rs
    local base = total > 0 and K.vof(rs[1]) or 0
    local cx, cy = 176, 206
    local r0 = 122
    local rOf = function(i)
      if total <= 1 then return r0 end
      return r0 - (i - 1) * (r0 - 24) / (total - 1)
    end
    -- 相邻两环要一眼分得开：按这个顺序取色，别让 2 号和 5 号的蓝撞在一起
    local order = { 1, 4, 3, 6, 5, 2, 7, 8 }
    local cols = {}
    for i = 1, total do cols[i] = K.col(order[(i - 1) % #order + 1]) end
    -- 外环先画、内环后盖：一圈圈往里收，才是「包含」
    for i = 1, total do
      local p = P.oval(cx, cy, rOf(i), rOf(i) * .94, 44)
      P.fill(p, cols[i], { dx = .7, dy = .6, amp = .5 })
      P.inkLoop(p, { w = 1.35, amp = .35, over = 0 })
    end
    -- 环的说明挂在右边一列：外环在上、内环在下，顺序就是包含顺序
    local y = cy - (#rs - 1) * 15
    for i, row in ipairs(rs) do
      local col = cols[i] or K.col(i)
      local bx, by = 300, y + (i - 1) * 30
      P.fill({ { bx, by - 8 }, { bx + 9, by - 8 }, { bx + 9, by + 1 }, { bx, by + 1 } }, col,
        { dx = .2, dy = .2, amp = .2 })
      P.rim({ { bx, by - 8 }, { bx + 9, by - 8 }, { bx + 9, by + 1 }, { bx, by + 1 } }, .7, P.INK, .8)
      P.text(tostring(row.label), bx + 14, by, { size = 11.5, col = P.INK })
      P.text(pct(K.vof(row), base == 0 and 1 or base),
        bx + 14 + P.textw(tostring(row.label), 11.5) + 7, by, { size = 10.5, col = P.TONE })
    end
    if total > 0 then
      P.text(tostring(rs[1].label) .. ' = 100%', 300, cy - (#rs - 1) * 15 - 24,
        { size = 10, col = P.LEAD })
    end
  end,
}

-- ---------------------------------------------------------------------------
-- 金字塔：越往上越窄，层级就是括号里的那一段
-- ---------------------------------------------------------------------------
M.pyramid = {
  label = '金字塔',
  demo = {
    title = '一只猫要的是什么', note = '底层是活下去的东西，顶层是可有可无的；宽度按重要度画。',
    rows = { { label = '睡 16h', value = 5 }, { label = '吃', value = 4 }, { label = '舔毛', value = 3 },
             { label = '巡视', value = 2 }, { label = '逗你', value = 1 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local mx = K.maxv(rs)
    local n = #rs
    local cx, top, bot = 250, 66, 348
    local hw = 176
    local lh = (bot - top) / n
    -- 第一条数据在最底下（最宽），往上一层比一层窄
    local at = function(i) return rs[n - i + 1] end
    local wOf = function(i)
      local r = at(i)
      return r and hw * math.max(.30, K.vof(r) / mx) or nil
    end
    for i = 1, n do
      local row = at(i)
      -- w1 = 上缘宽 = 本层，最顶那层收成窄顶；w2 = 下缘宽 = 下一层的宽度
      local w1 = wOf(i)
      if i == 1 then w1 = math.max(12, w1 * .5) end
      local w2 = wOf(i + 1) or w1   -- 最底层没有下一层，直接直落
      local y0 = top + (i - 1) * lh
      local y1 = y0 + lh - 2
      local p = { { cx - w1, y0 }, { cx + w1, y0 }, { cx + w2, y1 }, { cx - w2, y1 } }
      local col = K.col(n - i + 1)
      P.fill(p, col, { dx = .6, dy = .4, amp = .4 })
      P.inkLoop(p, { w = 1.3, amp = .3, over = 0 })
      P.text(tostring(row.label), cx, (y0 + y1) / 2 + 4, { size = 12, anchor = 'middle' })
    end
  end,
}

return M
