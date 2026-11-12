-- lua/charts/types/hier.lua —— 「层级」这一族：
-- tree / org / plan / mind / venn / kanban / fishbone / wordcloud / exploded
local P = require('charts.pen')
local K = require('charts.kit')
local L = require('charts.types.lib')
local M = {}

local sin, cos, pi, min, max = math.sin, math.cos, math.pi, math.min, math.max

local function rows(spec) return spec.rows or {} end

-- ---------------------------------------------------------------------------
-- 通用：把 {label, kids={...}} 摆成一张从上往下的树
-- 每个节点占的横向宽度 = 它的叶子数，父节点居中压在孩子上方
-- ---------------------------------------------------------------------------
local function layout(root, o)
  o = o or {}
  local x0, x1 = o.x0 or 30, o.x1 or 490
  local top, rowh = o.top or 68, o.rowh or 76
  local nh = o.nh or 30
  local nodes, edges = {}, {}
  local function leaves(n)
    if not n.kids or #n.kids == 0 then return 1 end
    local s = 0
    for _, k in ipairs(n.kids) do s = s + leaves(k) end
    return s
  end
  local total = leaves(root)
  local slot = (x1 - x0) / max(total, 1)
  local function place(n, depth, i0, parent)
    local span = leaves(n)
    local cx = x0 + slot * (i0 + span / 2)
    local w = min(o.nw or 92, max(46, slot * span - 8))
    local nd = { n = n, cx = cx, cy = top + depth * rowh + nh / 2, w = w, h = nh, depth = depth }
    nodes[#nodes + 1] = nd
    if parent then edges[#edges + 1] = { a = parent, b = nd } end
    if n.kids and #n.kids > 0 then
      local c = i0
      for _, k in ipairs(n.kids) do
        place(k, depth + 1, c, nd)
        c = c + leaves(k)
      end
    end
    return nd
  end
  place(root, 0, 0, nil)
  -- 垂直居中：层深决定内容高度，把整棵树摆在标题与注脚之间，别在下方留一片空地
  local dmax = 0
  for _, nd in ipairs(nodes) do dmax = max(dmax, nd.depth) end
  local ch = dmax * rowh + nh
  local avail = (o.bottom or 366) - top
  local shift = max(0, (avail - ch) / 2)
  for _, nd in ipairs(nodes) do nd.cy = nd.cy + shift end
  return nodes, edges
end

-- 直角折线：父下沿 → 中间高度 → 孩子上沿（组织图的味道，不用直线斜插）
local function elbow(a, b, mid)
  return { { a.cx, a.cy + a.h / 2 }, { a.cx, mid }, { b.cx, mid }, { b.cx, b.cy - b.h / 2 } }
end

local function drawTree(spec, o)
  o = o or {}
  local nodes, edges = layout(spec.tree or { label = '?' }, o)
  local ink = P.mix(P.PAL.wood, P.INK, .3)
  for _, e in ipairs(edges) do
    local mid = (e.a.cy + e.a.h / 2 + e.b.cy - e.b.h / 2) / 2
    P.line(elbow(e.a, e.b, mid), { w = 1.2, col = ink, amp = .25 })
  end
  for i, nd in ipairs(nodes) do
    local col = nd.depth == 0 and P.PAL.gold or K.col(nd.depth + 2)
    if o.band then
      -- 每层一条极淡的横带，把"同一层"这件事画出来
      if nd.depth > 0 and nodes[i - 1] and nodes[i - 1].depth ~= nd.depth then
        local y = nd.cy - nd.h / 2 - 5
        P.line({ { 26, y }, { 494, y } }, { w = .8, col = P.PAL.shade, amp = .2, dash = '3 5', op = .7 })
      end
    end
    local bx, by = nd.cx - nd.w / 2, nd.cy - nd.h / 2
    local p = L.roundRect(bx, by, nd.w, nd.h, 8)
    P.fill(p, col, { dx = .6, dy = .5, amp = .3 })
    P.inkLoop(p, { w = 1.2, amp = .3, over = 0 })
    local label = tostring(nd.n.label)
    -- 单行优先：先按框宽缩字号（下限 8.5），实在放不下才折行
    local size = o.size or 10.5
    local avail = nd.w - 10
    local tw = P.textw(label, size)
    if tw > avail then size = max(8.5, size * avail / tw) end
    P.text(label, nd.cx, nd.cy + size * .36, { size = size, anchor = 'middle', col = P.INK })
  end
  return nodes
end

-- ---------------------------------------------------------------------------
-- tree：一张普通的树状图
-- ---------------------------------------------------------------------------
M.tree = {
  label = '树图',
  demo = {
    title = '一篇文章是怎么长出来的',
    note = '越往下越具体：上层是判断，下层才落成句子。',
    tree = { label = '选题', kids = {
      { label = '读者', kids = { { label = '谁在问' }, { label = '他急什么' } } },
      { label = '材料', kids = { { label = '访谈' }, { label = '数据' }, { label = '反例' } } },
      { label = '结构', kids = { { label = '开头' }, { label = '中段' }, { label = '收尾' } } },
    } },
  },
  draw = function(spec) drawTree(spec, { rowh = 76, nw = 84, nh = 34, size = 10.5 }) end,
}

-- ---------------------------------------------------------------------------
-- org：组织架构——同上布局，但每格多一行副标题，层与层之间留出引线
-- ---------------------------------------------------------------------------
M.org = {
  label = '组织架构',
  demo = {
    title = '谁向谁汇报',
    note = '框里是岗位，框下小字是它的活。',
    tree = { label = '总编', kids = {
      { label = '采访组', kids = { { label = '记者' }, { label = '摄影' } } },
      { label = '编辑组', kids = { { label = '文字' }, { label = '校对' } } },
      { label = '运营组', kids = { { label = '发布' }, { label = '社群' } } },
    } },
    posts = { '定稿', '跑现场', '出图', '改稿', '抓错字', '排期', '回留言' },
  },
  draw = function(spec)
    local nodes = drawTree(spec, { rowh = 88, nw = 92, nh = 36, size = 11 })
    local posts = spec.posts or {}
    for i, nd in ipairs(nodes) do
      if i > 1 and posts[i - 1] then
        -- 小字压在折线的竖段上，先铺一层纸色把线断开，否则字和线糊成一团
        local txt = tostring(posts[i - 1])
        local tw = P.textw(txt, 9.5)
        P.flat(L.roundRect(nd.cx - tw / 2 - 3, nd.cy + 13, tw + 6, 13, 4), P.PAPER)
        P.text(txt, nd.cx, nd.cy + 23, { size = 9.5, anchor = 'middle', col = P.LEAD })
      end
    end
  end,
}

-- ---------------------------------------------------------------------------
-- plan：工作分解（WBS）——缩进清单 + 编号 + 进度条
-- ---------------------------------------------------------------------------
M.plan = {
  label = '分解图',
  demo = {
    title = '这件事拆成几步',
    note = '每行末尾的细条是这一步的进度。',
    rows = {
      { label = '写一本书', value = 100, depth = 0 },
      { label = '选题与提纲', value = 100, depth = 1 },
      { label = '访谈十五个人', value = 100, depth = 2 },
      { label = '写完初稿', value = 45, depth = 1 },
      { label = '前六章', value = 80, depth = 2 },
      { label = '后四章', value = 10, depth = 2 },
      { label = '改到能看', value = 0, depth = 1 },
    },
  },
  draw = function(spec)
    local rs = rows(spec)
    local x, y = 40, 76
    local rh = min(40, 250 / max(#rs, 1))
    local barx, barw = 328, 148
    for i, r in ipairs(rs) do
      local d = r.depth or 0
      local yy = y + (i - 1) * rh
      if d > 0 then
        -- 缩进竖线：从上一层引下来，一根就够
        P.line({ { x + (d - 1) * 16 + 6, yy - rh + 8 }, { x + (d - 1) * 16 + 6, yy + 4 } },
          { w = 1, col = P.PAL.shade, amp = .2 })
        P.line({ { x + (d - 1) * 16 + 6, yy + 4 }, { x + d * 16 - 4, yy + 4 } },
          { w = 1, col = P.PAL.shade, amp = .2 })
      end
      local col = d == 0 and P.INK or P.TONE
      P.text(tostring(r.label), x + d * 16 + (d > 0 and 10 or 0), yy + 8,
        { size = d == 0 and 12.5 or 11, col = col })
      -- 进度：细条 + 百分比
      local v = K.vof(r)
      local bw = barw - d * 12
      local bx = barx + d * 12
      P.line({ { bx, yy + 4 }, { bx + bw, yy + 4 } }, { w = 6, col = P.PAL.shade, amp = .2, op = .8 })
      if v > 0 then
        P.line({ { bx, yy + 4 }, { bx + bw * min(v, 100) / 100, yy + 4 } },
          { w = 6, col = d == 0 and P.PAL.wood or K.col(d + 1), amp = .2 })
      end
      P.text(K.int(v) .. '%', bx + bw + 8, yy + 8, { size = 10, col = P.LEAD })
    end
  end,
}

-- ---------------------------------------------------------------------------
-- mind：思维导图——中心一团，分支左右甩出去，藤蔓式的弯线
-- ---------------------------------------------------------------------------
M.mind = {
  label = '思维导图',
  demo = {
    title = '一个念头能扯出多少枝',
    note = '中心写结论，四周写支撑它的话。',
    center = '把文章写短',
    rows = {
      { label = '删形容词' }, { label = '一段只讲一件事' }, { label = '先写长再砍' },
      { label = '留一个反例' }, { label = '标题别许诺' }, { label = '结尾不总结' },
    },
  },
  draw = function(spec)
    local rs = rows(spec)
    local cx, cy = 260, 208
    local half = math.ceil(#rs / 2)
    local rcol = P.PAL.wood
    -- 中心
    local cw, ch = 116, 46
    L.node(cx - cw / 2, cy - ch / 2, cw, ch, tostring(spec.center or '中心'),
      { col = P.PAL.gold, r = 20, size = 12.5 })
    local function branch(i)
      local right = i <= half
      local k = right and i or (#rs - i + 1)
      local n = right and half or (#rs - half)
      local t = n > 1 and (k - 1) / (n - 1) or .5
      local y = 96 + t * 224
      local x = right and 392 or 128
      return x, y
    end
    for i, r in ipairs(rs) do
      local right = i <= half
      local bx, by = branch(i)
      local a = { cx + (right and cw / 2 - 6 or -cw / 2 + 6), cy + (by - cy) * .18 }
      local b = { bx + (right and -46 or 46), by }
      P.line(L.curve(a, b, (right and 1 or -1) * 26), { w = 1.5, col = rcol, amp = .35 })
      P.dot(b[1], b[2], 2.4, rcol, true)
      P.text(tostring(r.label), bx, by + 4,
        { size = 11, anchor = right and 'start' or 'end', col = P.INK })
    end
  end,
}

-- ---------------------------------------------------------------------------
-- venn：韦恩图——两三个交叠的圆，重叠处写共同点
-- ---------------------------------------------------------------------------
M.venn = {
  label = '韦恩图',
  demo = {
    title = '两件事重到哪一步',
    note = '重叠那一块，才是两边都认的部分。',
    rows = { { label = '我懂的' }, { label = '他关心的' } },
    overlap = '能一起聊的',
  },
  draw = function(spec)
    local rs = rows(spec)
    local n = min(#rs, 3)
    local r = n >= 3 and 86 or 96
    local cxs, cy = {}, 200
    if n == 3 then
      cxs = { 214, 306, 260 }
      cy = 176
    elseif n == 2 then
      cxs = { 196, 324 }
    else
      cxs = { 260 }
    end
    local cys = n == 3 and { 168, 168, 246 } or { cy, cy, cy }
    local cols = { P.PAL.sage, P.PAL.sky, P.PAL.pink }
    -- 先都填淡色，再叠一次半透明（pen 没有 alpha，就用更浅的混色压出交集）
    for i = 1, n do
      local p = P.oval(cxs[i], cys[i], r, r, 64)
      P.fill(p, P.lit(cols[i]), { dx = .8, dy = .6, amp = .35 })
    end
    for i = 1, n do
      local p = P.oval(cxs[i], cys[i], r, r, 64)
      P.inkLoop(p, { w = 1.4, col = P.mix(cols[i], P.INK, .35), amp = .3, over = 0 })
    end
    local anchors = n == 3
      and { { 168, 118 }, { 352, 118 }, { 260, 300 } }
      or { { 150, 128 }, { 370, 128 } }
    for i = 1, n do
      local a = anchors[i]
      P.text(tostring(rs[i].label), a[1], a[2], { size = 11.5, anchor = 'middle', col = P.INK })
    end
    if spec.overlap then
      local ox, oy = n == 3 and 260 or 260, n == 3 and 224 or 208
      P.text(tostring(spec.overlap), ox, oy, { size = 11, anchor = 'middle', col = P.RED })
    end
    local labs, cols2 = {}, {}
    for i = 1, n do labs[i], cols2[i] = tostring(rs[i].label), cols[i] end
    K.legend(labs, cols2, 60, 348)
  end,
}

-- ---------------------------------------------------------------------------
-- kanban：看板——三列便签，列头写状态和条数
-- ---------------------------------------------------------------------------
M.kanban = {
  label = '看板',
  demo = {
    title = '三列就知道卡在哪',
    note = '一张便签只装一件事，谁在动就挪一格。',
    cols = {
      { label = '待做', rows = { '写提纲', '约访谈', '找图' } },
      { label = '在做', rows = { '改第四章' } },
      { label = '做完', rows = { '定标题', '校一遍' } },
    },
  },
  draw = function(spec)
    local cols = spec.cols or {}
    local n = max(#cols, 1)
    local gap = 12
    local cw = (464 - gap * (n - 1)) / n
    local top = 74
    -- 先算每列高度（便签高度跟着字走），列底板取最高那列，别一律拖到页底
    local plan, maxh = {}, 0
    for i, c in ipairs(cols) do
      local items, h = {}, 0
      for _, t in ipairs(c.rows or {}) do
        local lines = P.wrap(tostring(t), cw - 26, 10.5)
        local th = max(32, 18 + min(#lines, 4) * 13)
        items[#items + 1] = { lines = lines, th = th }
        h = h + th + 9
      end
      h = (h > 0) and (h - 9) or 0
      plan[i] = items
      maxh = max(maxh, h)
    end
    maxh = max(maxh, 176)   -- 泳道最矮也留一段空白，别缩成一条裤腰带
    for i, c in ipairs(cols) do
      local x = 28 + (i - 1) * (cw + gap)
      local bh = min(maxh + 24, 292)
      -- 列底板：一条虚线框，比实线更"可以随便改"
      P.line({ { x, top }, { x, top + bh } }, { w = 1, col = P.PAL.shade, amp = .25, dash = '4 6', op = .9 })
      P.line({ { x + cw, top }, { x + cw, top + bh } }, { w = 1, col = P.PAL.shade, amp = .25, dash = '4 6', op = .9 })
      P.line({ { x, top + bh }, { x + cw, top + bh } }, { w = 1, col = P.PAL.shade, amp = .25, dash = '4 6', op = .9 })
      -- 列头
      local hd = c.label .. ' · ' .. #(c.rows or {})
      P.text(hd, x + 4, top - 8, { size = 11, col = P.INK })
      P.line({ { x + 2, top - 3 }, { x + 2 + P.textw(hd, 11), top - 3 } },
        { w = 2, col = K.col(i), amp = .3 })
      -- 便签
      local y = top + 12
      for j, it in ipairs(plan[i]) do
        local th = it.th
        local p = L.roundRect(x + 6 + (j % 2) * 1.5, y, cw - 12, th, 4)
        P.fill(p, P.PAL.cream, { dx = .7, dy = .7, amp = .5 })
        P.inkLoop(p, { w = 1, col = P.mix(K.col(i), P.INK, .45), amp = .3, over = 0 })
        -- 便签左上角一小块颜色，像压了个标签
        P.line({ { x + 10, y + 5 }, { x + 28, y + 5 } }, { w = 3, col = K.col(i), amp = .2 })
        for k = 1, min(#it.lines, 4) do
          P.text(it.lines[k], x + 12, y + 20 + (k - 1) * 13, { size = 10.5, col = P.TONE })
        end
        y = y + th + 9
      end
    end
  end,
}

-- ---------------------------------------------------------------------------
-- fishbone：鱼骨图——一条脊线，斜刺上挂着原因
-- ---------------------------------------------------------------------------
M.fishbone = {
  label = '鱼骨图',
  demo = {
    title = '为什么又拖到最后一晚',
    note = '骨头是类别，刺上是一句句具体的话。',
    effect = '交稿晚',
    rows = {
      { label = '人', rows = { '资料没到齐', '没人拍板' } },
      { label = '法', rows = { '提纲改了四版', '没有截稿点' } },
      { label = '料', rows = { '访谈只做了两次', '数据过期' } },
    },
  },
  draw = function(spec)
    local rs = rows(spec)
    -- 鱼头先占位：脊到 392 收，结论框摆右边，别顶出纸外
    local sx0, sx1, sy = 40, 392, 232
    P.line({ { sx0, sy }, { sx1, sy } }, { w = 2, col = P.INK, amp = .5 })
    L.arrow({ sx1 - 6, sy }, { sx1 + 20, sy }, { w = 2, col = P.INK })
    local head = tostring(spec.effect or '?')
    local hw = max(64, P.textw(head, 11.5) + 18)
    local p = L.roundRect(sx1 + 20, sy - 21, hw, 42, 12)
    P.fill(p, P.PAL.rose, { dx = .8, dy = .6, amp = .4 })
    P.inkLoop(p, { w = 1.3, amp = .3, over = 0 })
    P.text(head, sx1 + 20 + hw / 2, sy + 4, { size = 11.5, anchor = 'middle', col = P.INK })
    local n = max(#rs, 1)
    local step = (sx1 - sx0) / n
    for i, r in ipairs(rs) do
      local bx = sx0 + step * (i - .5)
      local bone = K.col(i)
      local ax, ay = bx - 34, sy + 70      -- 下半截骨根
      local tx, ty = bx + 32, sy + 8       -- 骨尖贴着脊
      P.line({ { bx - 34, sy - 70 }, { bx + 32, sy - 8 } }, { w = 1.8, col = bone, amp = .4 })
      P.line({ { ax, ay }, { tx, ty } }, { w = 1.8, col = bone, amp = .4 })
      P.text(tostring(r.label), bx - 36, sy - 74, { size = 11, anchor = 'end', col = P.INK })
      local items, k = r.rows or {}, #(r.rows or {})
      local up_cnt = math.floor((k + 1) / 2)
      local maxw = step - 14
      local function fit(s)
        s = tostring(s)
        if P.textw(s, 9.5) <= maxw then return s end
        local n = #s
        while n > 1 and P.textw(s:sub(1, n) .. '…', 9.5) > maxw do n = n - 1 end
        return s:sub(1, n) .. '…'
      end
      for j, t in ipairs(items) do
        local up = j <= up_cnt
        local idx = up and j or (j - up_cnt)
        local cnt = up and up_cnt or (k - up_cnt)
        local u = idx / (cnt + 1)
        local x0, y0, x1, y1 = bx - 34, sy - 70, bx + 32, sy - 8
        if not up then x0, y0, x1, y1 = ax, ay, tx, ty end
        local py = y0 + (y1 - y0) * u
        -- 标签一律左对齐在本骨列内，短了不散、长了截断，绝不越过下一根骨
        P.text(fit(t), bx - 32, py + 3, { size = 9.5, col = P.TONE })
      end
    end
  end,
}

-- ---------------------------------------------------------------------------
-- wordcloud：词云——字号 = 权重，按列错落排，避免互相压住
-- ---------------------------------------------------------------------------
M.wordcloud = {
  label = '词云',
  demo = {
    title = '他说得最多的那几个词',
    note = '字号是次数，位置没含义。',
    rows = {
      { label = '时间', value = 32 }, { label = '结构', value = 28 }, { label = '读者', value = 24 },
      { label = '删', value = 22 }, { label = '例子', value = 20 }, { label = '节奏', value = 17 },
      { label = '标题', value = 15 }, { label = '反例', value = 13 }, { label = '开头', value = 12 },
      { label = '短句', value = 11 }, { label = '留白', value = 9 }, { label = '校对', value = 8 },
      { label = '访谈', value = 7 }, { label = '数据', value = 6 }, { label = '收尾', value = 5 },
    },
  },
  draw = function(spec)
    local rs = rows(spec)
    local hi = K.maxv(rs)
    local cx, cy = 260, 206
    -- 由大到小，用黄金角螺旋找位置；和已放好的框做一次粗略相交检查
    local placed = {}
    local function hits(x, y, w, h)
      for _, b in ipairs(placed) do
        if x < b.x + b.w + 4 and x + w + 4 > b.x and y < b.y + b.h + 2 and y + h + 2 > b.y then
          return true
        end
      end
      return false
    end
    local items = {}
    -- 一个词先按理论字号找位置；没空位就缩一号再螺旋找，直到小幅缩到能塞进去。
    -- 之前只试一次、失败就 continue，词会静默消失（15 条只画出 9 条）。
    for _, r in ipairs(rs) do
      local v = K.vof(r)
      local want = 10 + 26 * (hi > 0 and v / hi or 0)
      local placedok
      for _, f in ipairs({ 1, .88, .76, .64, .52 }) do
        local size = want * f
        local w, h = P.textw(tostring(r.label), size), size * 1.1
        for k = 0, 900 do
          local a = k * 2.3999
          -- 螺旋半径随字号放大：大词自己撑开一圈，小词才不会被挤到纸边
          local rad = (1.9 + size * .16) * math.sqrt(k)
          local x = cx + cos(a) * rad * 1.45 - w / 2
          local y = cy + sin(a) * rad * .9 - h / 2
          if not hits(x, y, w, h) and x > 22 and x + w < 498 and y > 58 and y + h < 352 then
            placed[#placed + 1] = { x = x, y = y, w = w, h = h }
            local col = v / hi > .6 and P.INK or (v / hi > .3 and P.TONE or P.LEAD)
            if v / hi < .18 then col = P.PAL.wood end
            items[#items + 1] = { t = tostring(r.label), x = x, y = y, w = w, h = h, size = size, col = col }
            placedok = true
            break
          end
        end
        if placedok then break end
      end
    end
    -- 螺旋是「从中心往外」的贪心，只按理论字号占位，摆出来的云往往只占纸面中间一小块
    -- （外接框 340x200，版面 476x294，四周全空）。所以摆完做一次归一化：
    -- 取实际外接框，等比放大到内容框的 92%，再整体挪回中心。
    -- 字号与坐标同乘一个系数即可——textw 对标量近似线性，缩放后不会互相压住。
    if #items > 0 then
      local bx0, by0, bx1, by1 = 1e9, 1e9, -1e9, -1e9
      for _, b in ipairs(items) do
        bx0, by0 = min(bx0, b.x), min(by0, b.y)
        bx1, by1 = max(bx1, b.x + b.w), max(by1, b.y + b.h)
      end
      local bw, bh = max(bx1 - bx0, 1), max(by1 - by0, 1)
      local s = min(476 * .92 / bw, 294 * .92 / bh)
      -- 只放大不缩小到失真：超过 1.9 倍字会糊出纸面感，缩到 .8 以下就说明塞不下
      s = min(max(s, .8), 1.9)
      local cxr, cyr = (bx0 + bx1) / 2, (by0 + by1) / 2
      for _, b in ipairs(items) do
        local nx = 260 + (b.x + b.w / 2 - cxr) * s
        local ny = 205 + (b.y + b.h / 2 - cyr) * s
        P.text(b.t, nx, ny, { size = b.size * s, anchor = 'middle', col = b.col })
      end
    end
  end,
}

-- ---------------------------------------------------------------------------
-- exploded：爆炸图——零件沿一条斜轴拆开，引线标名字
-- ---------------------------------------------------------------------------
M.exploded = {
  label = '爆炸图',
  demo = {
    title = '一支笔拆开是这些东西',
    note = '沿一条轴分开，按装回去的顺序从上往下排。',
    rows = {
      { label = '笔帽', value = 12 }, { label = '笔夹', value = 8 }, { label = '笔身', value = 34 },
      { label = '墨囊', value = 20 }, { label = '笔尖', value = 9 },
    },
  },
  draw = function(spec)
    local rs = rows(spec)
    local n = max(#rs, 1)
    local maxv = K.maxv(rs)
    -- 斜轴：从左下到右上，零件沿轴等比铺开
    local ax0, ay0, ax1, ay1 = 150, 336, 340, 84
    P.line({ { ax0 - 8, ay0 + 28 }, { ax1 + 18, ay1 - 18 } },
      { w = 1, col = P.PAL.shade, amp = .4, dash = '5 5' })
    for i, r in ipairs(rs) do
      local t = n > 1 and (i - 1) / (n - 1) or .5
      local x = ax0 + (ax1 - ax0) * t
      local y = ay0 + (ay1 - ay0) * t
      local v = K.vof(r)
      local hw = 26 + 34 * (maxv > 0 and v / maxv or 0)
      -- 零件：一个扁圆角块（俯视剖面），越靠上越窄，像笔的锥度
      local hgt = 12
      local p = L.roundRect(x - hw / 2, y - hgt / 2, hw, hgt, 6)
      P.fill(p, K.col(i), { dx = .8, dy = .5, amp = .4 })
      P.inkLoop(p, { w = 1.2, col = P.mix(K.col(i), P.INK, .4), amp = .3, over = 0 })
      -- 引线拐到左边，名字写在左栏
      local lx = 118
      P.line({ { x - hw / 2 - 2, y }, { lx + 4, y } },
        { w = .9, col = P.LEAD, amp = .25, dash = '2 4' })
      -- 数值跟在名字左边（同一条横引线上），别压在斜轴上
      local vt = K.vfmt(v)
      local vw = P.textw(vt, 9.5) + 8
      P.text(tostring(r.label), lx - vw, y + 4, { size = 11, anchor = 'end', col = P.INK })
      P.text(vt, lx, y + 4, { size = 9.5, anchor = 'end', col = P.LEAD })
    end
  end,
}

return M
