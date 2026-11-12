-- lua/charts/types/flow.lua —— 「流向与关系」这一族：sankey / funnel / flow / loop / state / seq / er / arch
local P = require('charts.pen')
local K = require('charts.kit')
local L = require('charts.types.lib')
local M = {}

local sin, cos, pi, sqrt, floor, min, max = math.sin, math.cos, math.pi, math.sqrt, math.floor, math.min, math.max
local function rows(spec) return spec.rows or {} end

M.sankey = {
  label = '桑基图',
  demo = {
    title = '一家农场的牛奶去哪儿了', note = '左边罐里出去 100 升。带子的宽窄全程都是升数。', stage = '罐 100 升',
    rows = { { label = '喝鲜奶', value = 40 }, { label = '做奶酪', value = 32 }, { label = '做黄油', value = 18 },
             { label = '倒掉', value = 10 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local total = K.sum(rs)
    local x0, x1 = 108, 320
    local y0, y1 = 84, 306
    local cy = (y0 + y1) / 2
    local src = { { x0 - 14, y0 }, { x0, y0 }, { x0, y1 }, { x0 - 14, y1 } }
    P.fill(src, P.PAL.steel, { dx = .5, dy = .3, amp = .3 })
    P.rim(src, 1.1, P.INK, .9)
    P.text(spec.stage or '全部', x0 - 20, cy + 4, { size = 10.5, anchor = 'end', col = P.TONE })
    local n = #rs
    local gap = 12
    local room = (y1 - y0) - gap * (n - 1)
    -- 左右两列都按升数等高，带子才不撒谎
    -- 左边贴着罐子堆满（不留缝），右边一排留缝，带子因此自然收窄/挪位
    local la, ra, al, ar = {}, {}, 0, 0
    for i, r in ipairs(rs) do
      local hl = (y1 - y0) * K.vof(r) / max(total, 1e-9)
      local hr = room * K.vof(r) / max(total, 1e-9)
      la[i] = { y0 + al, y0 + al + hl }
      ra[i] = { y0 + ar, y0 + ar + hr }
      al = al + hl
      ar = ar + hr + gap
    end
    for i = 1, n do
      local v = K.vof(rs[i])
      local band = {}
      for k = 0, 14 do
        local t = k / 14
        local e = t * t * (3 - 2 * t)
        band[#band + 1] = { x0 + (x1 - x0) * t, la[i][1] + (ra[i][1] - la[i][1]) * e }
      end
      for k = 14, 0, -1 do
        local t = k / 14
        local e = t * t * (3 - 2 * t)
        band[#band + 1] = { x0 + (x1 - x0) * t, la[i][2] + (ra[i][2] - la[i][2]) * e }
      end
      P.fill(band, P.mix(K.col(i), '#fdf9f1', .3), { dx = .4, dy = .3, amp = .5 })
      local nd = { { x1, ra[i][1] }, { x1 + 13, ra[i][1] }, { x1 + 13, ra[i][2] }, { x1, ra[i][2] } }
      P.fill(nd, K.col(i), { dx = .4, dy = .3, amp = .3 })
      P.rim(nd, 1, P.INK, .85)
      local my = (ra[i][1] + ra[i][2]) / 2
      P.text(tostring(rs[i].label), x1 + 21, my - 1, { size = 11 })
      P.text(K.vfmt(v) .. (spec.unit or ''), x1 + 21, my + 13, { size = 9.5, col = P.LEAD })
    end
  end,
}

-- ---------------------------------------------------------------------------
M.funnel = {
  label = '漏斗图',
  demo = {
    title = '一件下单到收货', note = '横条越来越短，右边写着还剩多少人。',
    rows = { { label = '打开页面', value = 1000 }, { label = '加入购物车', value = 420 },
             { label = '填地址', value = 260 }, { label = '付款', value = 180 }, { label = '收货', value = 172 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local b = K.box({ y0 = 70, y1 = 330, x0 = 40, x1 = 360 })
    local top = K.maxv(rs)
    local n = #rs
    local ch = (b.y1 - b.y0) / n
    local h = ch * .74
    for i, r in ipairs(rs) do
      local y = b.y0 + (i - .5) * ch
      local v = K.vof(r)
      local w = (b.x1 - b.x0) * v / top
      local col = K.col(i)
      L.roundRect(b.x0, y - h / 2, w, h, 4)
      P.fill(L.roundRect(b.x0, y - h / 2, w, h, 4), col, { dx = .5, dy = .4, amp = .35 })
      P.inkLoop(L.roundRect(b.x0, y - h / 2, w, h, 4), { w = 1.1, amp = .3, over = 0 })
      P.text(tostring(r.label), b.x0 + 10, y + 4, { size = 11, col = i > 2 and P.INK or '#3a3b40' })
      local px = b.x0 + w + 10
      P.text(K.vfmt(v), px, y + 4, { size = 10.5, col = P.LEAD })
      if i > 1 then
        local drop = K.vof(rs[i - 1]) - v
        P.text('-' .. K.vfmt(drop), b.x1 + 12, y + 4, { size = 9.5, col = P.RED })
      end
    end
  end,
}

-- ---------------------------------------------------------------------------
M.flow = {
  label = '流程图',
  demo = {
    title = '一封信从写来到寄出', note = '方块是做的事，菱形是判断，圆角是两头。',
    rows = { { label = '写信', kind = 'start' }, { label = '装信封', kind = 'step' },
             { label = '贴够邮票？', kind = 'check' }, { label = '投进邮筒', kind = 'step' },
             { label = '到了', kind = 'end' } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local n = #rs
    local cx = 260
    local y0, ch = 76, 58
    local w, h = 152, 34
    for i, r in ipairs(rs) do
      local y = y0 + (i - 1) * ch
      local kind = r.kind or 'step'
      local col = kind == 'check' and P.PAL.gold or kind == 'step' and P.PAL.cream or P.PAL.sage
      if kind == 'check' then
        local d = 62
        P.shape({ { cx - d, y }, { cx, y - 22 }, { cx + d, y }, { cx, y + 22 } }, col, { w = 1.2 })
        P.text(tostring(r.label), cx, y + 4, { size = 10.5, anchor = 'middle' })
      else
        local rr = (kind == 'start' or kind == 'end') and 18 or 7
        L.node(cx - w / 2, y - h / 2, w, h, r.label, { col = col, r = rr })
      end
      if i < n then
        L.arrow({ cx, y + (kind == 'check' and 22 or h / 2) }, { cx, y + ch - (h / 2) + 1 }, { w = 1.2 })
      end
    end
    P.text('不够 → 补邮票再投', cx + 78, y0 + 2 * ch + 4, { size = 9.5, col = P.LEAD })
  end,
}


-- ---------------------------------------------------------------------------
M.loop = {
  label = '循环图',
  demo = {
    title = '一周里的作业时间', note = '箭头首尾相接，一圈就是一轮。',
    rows = { { label = '听课' }, { label = '读材料' }, { label = '写草稿' }, { label = '找同学看' }, { label = '改一遍' } },
    center = '每圈约 6 小时',
  },
  draw = function(spec)
    local rs = rows(spec)
    local n = #rs
    if n < 3 then return end
    local cx, cy, R = 260, 206, 120
    local a0 = -pi / 2
    local pts = {}
    for i = 1, n do
      local a = a0 + (i - 1) * 2 * pi / n
      pts[i] = { cx + R * cos(a), cy + R * sin(a), a }
    end
    local bw, bh = 88, 32
    -- 先把连线画在下面：沿圆周从上一块外沿走到下一块外沿
    local aline = P.mix(P.PAL.wood, P.INK, .25)
    local function edge(pt, ang)
      -- 从节点中心往 ang 方向射出，落在方框边上的点
      local dx, dy = cos(ang), sin(ang)
      local tx = dx ~= 0 and (bw / 2) / math.abs(dx) or 1e3
      local ty = dy ~= 0 and (bh / 2) / math.abs(dy) or 1e3
      local t = math.min(tx, ty) + 3
      return { pt[1] + dx * t, pt[2] + dy * t }
    end
    for i = 1, n do
      local a, b = pts[i], pts[i % n + 1]
      local a1, a2 = a[3] + .34, b[3] - .34
      if a2 <= a1 then a2 = a2 + 2 * pi end
      local Ra = R + 10
      local arc = { edge(a, a1 + .10) }
      for k = 0, 16 do
        local t = a1 + (a2 - a1) * k / 16
        arc[#arc + 1] = { cx + Ra * cos(t), cy + Ra * sin(t) }
      end
      arc[#arc + 1] = edge(b, a2 - .10)
      P.line(arc, { w = 1.3, col = aline, amp = .3 })
      L.arrow(arc[#arc - 1], arc[#arc], { w = 1.3, col = aline, headSize = 7 })
    end
    for i = 1, n do
      local x, y = pts[i][1], pts[i][2]
      L.node(x - bw / 2, y - bh / 2, bw, bh, rs[i].label, { col = K.col(i), r = 15, size = 11 })
    end
    if spec.center then
      P.text(spec.center, cx, cy - 2, { size = 12, anchor = 'middle', col = P.TONE })
      P.text('一圈', cx, cy + 16, { size = 9.5, anchor = 'middle', col = P.LEAD })
    end
  end,
}

-- ---------------------------------------------------------------------------
M.state = {
  label = '状态图',
  demo = {
    title = '一个包裹的几种状态', note = '圆是状态，箭头上的字是让它变过去的那件事。',
    rows = { { label = '待付款', note = '刚下单' }, { label = '已付款', note = '付完钱' },
             { label = '在途', note = '发货' }, { label = '已签收', note = '快递到了' } },
    side = { label = '取消', to = 3 },
  },
  draw = function(spec)
    local rs = rows(spec)
    local n = #rs
    if n < 2 then return end
    -- 蛇形排：一行走完拐到下一行再往回走，箭头不交叉
    local cols = (n > 3) and 2 or n
    local pos = {}
    for i = 1, n do
      local r = math.floor((i - 1) / cols)
      local c = (i - 1) % cols
      if r % 2 == 1 then c = cols - 1 - c end
      pos[i] = { 110 + c * 230, 112 + r * 96 }
    end
    for i = 1, n - 1 do
      local a, b = pos[i], pos[i + 1]
      local sameRow = math.abs(a[2] - b[2]) < 1
      local p1, p2
      if sameRow then
        local s = (b[1] > a[1]) and 1 or -1
        p1 = { a[1] + 46 * s, a[2] }
        p2 = { b[1] - 46 * s, b[2] }
      else
        p1 = { a[1], a[2] + 26 }
        p2 = { b[1], b[2] - 26 }
      end
      L.arrow(p1, p2, { w = 1.2, headSize = 6 })
      local mx, my = (p1[1] + p2[1]) / 2, (p1[2] + p2[2]) / 2
      local txt = rs[i + 1].note or ''
      if txt ~= '' then
        P.text(txt, mx + (sameRow and 0 or 34), my + (sameRow and -7 or 4),
          { size = 9.5, anchor = sameRow and 'middle' or 'start', col = P.RED })
      end
    end
    for i = 1, n do
      local x, y = pos[i][1], pos[i][2]
      local endNode = (i == 1 or i == n)
      P.fill(P.oval(x, y, 44, 26, 30), K.col(i), { dx = .5, dy = .4, amp = .3 })
      P.inkLoop(P.oval(x, y, 44, 26, 30), { w = 1.2, amp = .3, over = 0 })
      if endNode then P.inkLoop(P.oval(x, y, 36, 19, 26), { w = .8, amp = .2, over = 0 }) end
      P.text(tostring(rs[i].label), x, y + 4, { size = 11, anchor = 'middle' })
    end
    if spec.side then
      local s = spec.side
      local a = pos[1]
      local b = pos[math.min(#pos, s.to or #pos)]
      local p1 = { a[1] - 30, a[2] + 22 }
      local p2 = { b[1] - 30, b[2] - 22 }
      L.arrow(p1, p2, { w = 1.1, bend = 40, headSize = 6, dash = '3 3' })
      P.text(tostring(s.label), math.min(p1[1], p2[1]) - 52, (a[2] + b[2]) / 2 + 2,
        { size = 9.5, col = P.RED })
    end
  end,
}

-- ── 时序图 ────────────────────────────────────────────────────────
M.seq = {
  label = '时序图',
  demo = {
    title = '点一杯拿铁的顺序', note = '从上往下读：谁跟谁说话，竖条是它正忙的那一段。',
    lanes = { '你', '咖啡师', '咖啡机' },
    msgs = {
      { a = 1, b = 2, label = '一杯拿铁，谢谢' },
      { a = 2, b = 3, label = '磨豆，萃一份' },
      { a = 3, b = 2, label = '30 秒后' },
      { a = 2, b = 2, label = '打奶泡' },
      { a = 2, b = 1, label = '您的拿铁' },
    },
  },
  draw = function(spec)
    local lanes = spec.lanes or {}
    local msgs = spec.msgs or {}
    local n, m = #lanes, #msgs
    if n < 2 or m == 0 then return end
    local x0, x1 = 92, 428
    local xs = {}
    for i = 1, n do xs[i] = x0 + (x1 - x0) * (i - 1) / (n - 1) end
    local top, bot = 118, 350
    -- 顶部一条木色台面，名字刻在上面；下面三条虚线垂到底
    local band = { { 24, top - 32 }, { 496, top - 32 }, { 496, top - 8 }, { 24, top - 8 } }
    P.fill(band, P.PAL.wood, { dx = .6, dy = .4, amp = .35 })
    P.inkLoop(band, { w = 1.1, amp = .3, over = 0 })
    P.line({ { 28, top - 29 }, { 492, top - 29 } }, { w = .8, col = P.lit(P.PAL.wood), amp = .2, over = 0 })
    for i = 1, n do
      P.text(tostring(lanes[i]), xs[i], top - 15, { size = 11.5, anchor = 'middle', col = P.PAL.cream })
      P.line({ { xs[i], top }, { xs[i], bot } }, { w = 1, col = P.LEAD, amp = .3, dash = '4 6' })
    end
    local y0 = top + 30
    local step = m > 1 and (bot - 18 - y0) / (m - 1) or 0
    -- 忙的那一段：某条泳道第一次被找、最后一次出声之间的范围
    local act = {}
    for i = 1, n do act[i] = {} end
    for k, g in ipairs(msgs) do
      local y = y0 + step * (k - 1)
      local a, b = g.a or 1, g.b or 1
      for _, i in ipairs({ a, b }) do
        act[i].lo = math.min(act[i].lo or y, y)
        act[i].hi = math.max(act[i].hi or y, y)
      end
    end
    local function busy(i, y)
      local t = act[i]
      return t.lo and y >= t.lo and y <= t.hi
    end
    for i = 1, n do
      local t = act[i]
      if t.lo and t.hi > t.lo then
        local bar = { { xs[i] - 5, t.lo - 11 }, { xs[i] + 5, t.lo - 11 },
                      { xs[i] + 5, t.hi + 11 }, { xs[i] - 5, t.hi + 11 } }
        P.fill(bar, P.PAL.cream, { dx = .4, dy = .3, amp = .25 })
        P.inkLoop(bar, { w = .9, amp = .25, over = 0 })
      end
    end
    for k, g in ipairs(msgs) do
      local y = y0 + step * (k - 1)
      local a, b = g.a or 1, g.b or 1
      local txt = tostring(g.label or '')
      if a == b then
        -- 自己跟自己：右边绕一个小圈，箭头拐回来
        local xa = xs[a]
        P.line({ { xa + 5, y - 7 }, { xa + 40, y - 7 }, { xa + 40, y + 8 } }, { w = 1.1, amp = .3 })
        L.arrow({ xa + 40, y + 8 }, { xa + 5, y + 8 }, { w = 1.1, headSize = 5.5 })
        if txt ~= '' then P.text(txt, xa + 48, y + 4, { size = 10.5, col = P.INK }) end
      else
        local s = xs[b] > xs[a] and 1 or -1
        local xa = xs[a] + (busy(a, y) and 5 * s or 0)
        local xb = xs[b] - (busy(b, y) and 5 * s or 0)
        L.arrow({ xa, y }, { xb, y }, { w = 1.2, headSize = 6 })
        if txt ~= '' then
          P.text(txt, (xs[a] + xs[b]) / 2, y - 7, { size = 10.5, anchor = 'middle', col = P.INK })
        end
      end
    end
  end,
}

-- ── 实体关系图 ────────────────────────────────────────────────────
M.er = {
  label = '实体关系图',
  demo = {
    title = '村图书馆的三张表', note = '一个读者借很多次，一本书也被借很多次——借阅这张表把两边连起来。',
    entities = {
      { name = '读者', fields = { '卡号', '姓名', '地址' }, key = 1, col = P.PAL.tan },
      { name = '图书', fields = { '索书号', '书名', '作者', '册数' }, key = 1, col = P.PAL.sky },
      { name = '借阅', fields = { '卡号', '索书号', '借出日', '应还日' }, col = P.PAL.pink },
    },
    links = { { a = 1, b = 3, label = '借出' }, { a = 2, b = 3, label = '被借' } },
  },
  draw = function(spec)
    local es = spec.entities or {}
    local n = #es
    if n == 0 then return end
    local cols = (n <= 2) and n or min(n, 3)
    local rown = math.ceil(n / cols)
    local gapX, HD, FH = 40, 28, 20
    local bw = (440 - gapX * (cols - 1)) / cols
    local function bh(e) return HD + #(e.fields or {}) * FH + 12 end
    -- 先只算每行的最大高度，行距按剩下的空间分配（卡片多了自己挤，不越界）
    local rowH = {}
    for r = 1, rown do
      local mh = 0
      for c = 1, min(cols, n - (r - 1) * cols) do
        mh = max(mh, bh(es[(r - 1) * cols + c]))
      end
      rowH[r] = mh
    end
    local avail = 372 - 76
    local sumH = 0
    for r = 1, rown do sumH = sumH + rowH[r] end
    local gapY = rown > 1 and min(76, max(16, (avail - sumH) / (rown - 1))) or 0
    -- 排版：每行居中；整块再垂直居中（往上偏一点，标题底下更松快）
    local box = {}
    local span = sumH + gapY * (rown - 1)
    local y = 76 + (avail - span) * .42
    for r = 1, rown do
      local cnt = min(cols, n - (r - 1) * cols)
      local tw = cnt * bw + (cnt - 1) * gapX
      local x = (520 - tw) / 2
      for c = 1, cnt do
        local i = (r - 1) * cols + c
        box[i] = { x = x, y = y, w = bw, h = bh(es[i]) }
        x = x + bw + gapX
      end
      y = y + rowH[r] + gapY
    end
    for i = 1, n do
      local e, b = es[i], box[i]
      local p = { { b.x, b.y }, { b.x + b.w, b.y }, { b.x + b.w, b.y + b.h }, { b.x, b.y + b.h } }
      P.fill(p, P.PAL.cream, { dx = .6, dy = .5, amp = .3 })
      P.fill({ { b.x, b.y }, { b.x + b.w, b.y }, { b.x + b.w, b.y + HD }, { b.x, b.y + HD } },
        e.col or P.PAL.tan, { dx = .5, dy = .4, amp = .3 })
      P.inkLoop(p, { w = 1.1, amp = .3, over = 0 })
      P.line({ { b.x, b.y + HD }, { b.x + b.w, b.y + HD } }, { w = .9, amp = .2 })
      P.text(tostring(e.name), b.x + b.w / 2, b.y + 19, { size = 12, anchor = 'middle' })
      for fi, f in ipairs(e.fields or {}) do
        local fy = b.y + HD + 4 + (fi - 1) * FH
        P.text(tostring(f), b.x + 10, fy + 11, { size = 10.5 })
        -- 字段后面一条淡的填写线，像真的著录卡
        P.line({ { b.x + 10, fy + 15 }, { b.x + b.w - 10, fy + 15 } },
          { w = .5, col = P.mix(P.PAL.sky, P.INK, .3), amp = .25, dash = '3 5' })
        if e.key == fi then
          -- 主键：一个钥匙圈
          local kx, ky = b.x + b.w - 14, fy + 6
          P.inkLoop(P.oval(kx, ky, 2.6, 2.6, 10), { w = .9, amp = .2, over = 0 })
          P.line({ { kx + 2.4, ky }, { kx + 8, ky }, { kx + 8, ky + 3 } }, { w = .9, amp = .2 })
        end
      end
      -- 卡片底下打的孔
      P.inkLoop(P.oval(b.x + b.w / 2, b.y + b.h - 6, 3.4, 3.4, 12), { w = .8, amp = .2, over = 0 })
    end
    -- 一头一条横杠（一），一头三根叉（多）
    local function crow(p, dx, dy)
      for _, s in ipairs({ -7, 0, 7 }) do
        P.line({ { p[1] - dx * 12, p[2] - dy * 12 },
                 { p[1] + (dy ~= 0 and s or 0), p[2] + (dx ~= 0 and s or 0) } },
          { w = 1.1, col = P.RED, amp = .25 })
      end
    end
    local function one(p, dx, dy)
      local a = { p[1] + (dy ~= 0 and -7 or 0), p[2] + (dx ~= 0 and -7 or 0) }
      local b = { p[1] + (dy ~= 0 and 7 or 0), p[2] + (dx ~= 0 and 7 or 0) }
      P.line({ a, b }, { w = 1.1, col = P.RED, amp = .25 })
    end
    for _, lk in ipairs(spec.links or {}) do
      local ta, tb = box[lk.a], box[lk.b]
      if ta and tb then
        local txt = tostring(lk.label or '')
        if math.abs(ta.y - tb.y) < .5 then
          local s = tb.x > ta.x and 1 or -1
          local lo, hi = math.min(ta.x, tb.x), math.max(ta.x + ta.w, tb.x + tb.w)
          -- 中间还隔着别的卡？那就从底下的通道绕过去，别把卡片穿个洞
          local blocked = nil
          for i = 1, n do
            local o = box[i]
            if o ~= ta and o ~= tb and math.abs(o.y - ta.y) < .5
               and o.x + o.w > lo and o.x < hi then blocked = o break end
          end
          if blocked then
            local ry = math.max(ta.y + ta.h, tb.y + tb.h) + 26
            local pa = { ta.x + ta.w * .35, ta.y + ta.h }
            local pb = { tb.x + tb.w * .35, tb.y + tb.h }
            P.line({ pa, { pa[1], ry }, { pb[1], ry }, pb }, { w = 1.1, col = P.INK, amp = .3 })
            one(pa, 0, 1)
            crow(pb, 0, -1)
            if txt ~= '' then
              P.text(txt, (pa[1] + pb[1]) / 2, ry + 13, { size = 10, anchor = 'middle', col = P.RED })
            end
          else
            -- 同一行的邻居：从两张卡的腰上连一条横线
            local ry = ta.y + HD / 2
            local pa = { s > 0 and ta.x + ta.w or ta.x, ry }
            local pb = { s > 0 and tb.x or tb.x + tb.w, ry }
            P.line({ pa, pb }, { w = 1.1, col = P.INK, amp = .3 })
            one(pa, -s, 0)
            crow(pb, s, 0)
            if txt ~= '' then
              P.text(txt, (pa[1] + pb[1]) / 2, ry - 7, { size = 10, anchor = 'middle', col = P.RED })
            end
          end
        else
          -- 跨行：下到底边拐个弯再进目标顶边
          local down = tb.y > ta.y
          local pa = { ta.x + ta.w / 2, down and ta.y + ta.h or ta.y }
          local pb = { tb.x + tb.w / 2, down and tb.y or tb.y + tb.h }
          local my = (pa[2] + pb[2]) / 2
          local dx = (pb[1] > pa[1]) and 1 or -1
          local pts = { pa, { pa[1], my }, { pb[1], my }, pb }
          if math.abs(pb[1] - pa[1]) < .5 then pts = { pa, pb } end
          P.line(pts, { w = 1.1, col = P.INK, amp = .3 })
          one(pa, 0, down and -1 or 1)
          crow(pb, 0, down and 1 or -1)
          if txt ~= '' then
            P.text(txt, pts[2][1] + (math.abs(pb[1] - pa[1]) < .5 and 10 or 6), my - 5,
              { size = 10, col = P.RED, anchor = 'start' })
          end
        end
      end
    end
  end,
}

-- ── 分层架构 ──────────────────────────────────────────────────────
M.arch = {
  label = '分层架构',
  demo = {
    title = '一家面包店的四层', note = '一层一件事。右边那三条是层与层之间真正在跑的东西。',
    layers = {
      { label = '存料层', note = '面粉、黄油、冷水' },
      { label = '制作层', note = '和面机、醒发架' },
      { label = '烤卖层', note = '烤炉、货架、柜台' },
      { label = '供给层', note = '地窖：水箱、冷库' },
    },
    links = { { from = 1, to = 2, label = '溜槽' }, { from = 4, to = 3, label = '货梯' },
              { from = 4, to = 2, label = '水管' } },
  },
  draw = function(spec)
    local ls = spec.layers or {}
    local n = #ls
    if n == 0 then return end
    local cx, hw, d, t, gap = 288, 148, 42, 15, 68
    local yTop = {}
    for i = 1, n do yTop[i] = 104 + (i - 1) * gap end
    -- 从下往上画，上面的板压住下面的
    for i = n, 1, -1 do
      local y = yTop[i]
      local c = K.col(i)
      local A, B, C, D = { cx - hw, y }, { cx, y - d }, { cx + hw, y }, { cx, y + d }
      local A2, D2, C2 = { A[1], A[2] + t }, { D[1], D[2] + t }, { C[1], C[2] + t }
      -- 两块侧面先铺（暗一点），顶面最后压上
      local lf = { A, D, D2, A2 }
      P.fill(lf, P.shadeOf(c), { dx = .4, dy = .3, amp = .3 })
      P.inkLoop(lf, { w = 1, amp = .25, over = 0 })
      local rf = { D, C, C2, D2 }
      P.fill(rf, P.trim(c), { dx = .4, dy = .3, amp = .3 })
      P.inkLoop(rf, { w = 1, amp = .25, over = 0 })
      local topf = { A, B, C, D }
      P.fill(topf, c, { dx = .5, dy = .4, amp = .3 })
      P.inkLoop(topf, { w = 1.2, amp = .3, over = 0 })
      -- 顶面上淡淡的砖缝，给平涂一点质地
      for k = 1, 3 do
        local u = k / 4
        P.line({ { P.lerp(A[1], B[1], u), P.lerp(A[2], B[2], u) },
                 { P.lerp(D[1], C[1], u), P.lerp(D[2], C[2], u) } },
          { w = .5, col = P.mix(c, P.INK, .2), amp = .2, dash = '3 6', over = 0 })
      end
      -- 名字和这一层有什么，写在左边
      local lx = 118
      P.text(tostring(ls[i].label or ''), lx, y + 4, { size = 12, anchor = 'end' })
      if ls[i].note then
        P.text(tostring(ls[i].note), lx, y + 19, { size = 9.5, anchor = 'end', col = P.LEAD })
      end
      P.line({ { lx + 6, y }, { A[1] - 8, y } }, { w = .9, col = P.LEAD, amp = .25, dash = '2 4' })
    end
    -- 层间在跑的东西：右侧一列竖向箭头，各自错开一条
    local links = spec.links or {}
    for k, lk in ipairs(links) do
      local a, b = yTop[lk.from], yTop[lk.to]
      if a and b and lk.from ~= lk.to then
        local x = 452 + ((k - 1) % 3) * 15
        local up = a > b
        local pa = { x, a + (up and -4 or 4) }
        local pb = { x, b + (up and 4 or -4) }
        L.arrow(pa, pb, { w = 1.1, headSize = 5.5, col = P.INK })
        if lk.label then
          P.text(tostring(lk.label), x + 6, (pa[2] + pb[2]) / 2 + 3, { size = 9.5, col = P.RED })
        end
      end
    end
  end,
}

return M
