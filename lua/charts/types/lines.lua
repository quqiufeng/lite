-- lua/charts/types/lines.lua —— 「随时间走」这一族：line / steps / timeline / journey / gantt / swim
local P = require('charts.pen')
local K = require('charts.kit')
local L = require('charts.types.lib')
local M = {}

local sin, cos, pi, sqrt, floor, min, max = math.sin, math.cos, math.pi, math.sqrt, math.floor, math.min, math.max
local function rows(spec) return spec.rows or {} end

M.line = {
  label = '折线图',
  demo = {
    title = '一周的晒衣天气', note = '绳索在每根桩上的高度就是那天的日照小时，从左柱读。周四晒得最好。',
    rows = { { label = '一', value = 3 }, { label = '二', value = 5 }, { label = '三', value = 4 },
             { label = '四', value = 9 }, { label = '五', value = 6 }, { label = '六', value = 7 }, { label = '日', value = 4 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local b = K.boxPlot({ y0 = 76, y1 = 306 })
    local top = K.top(K.maxv(rs))
    K.ticksY(b, top, 4)
    local n = #rs
    local pts, bi = {}, 1
    for i, r in ipairs(rs) do
      pts[#pts + 1] = { K.scale(i, 1, max(n, 2), b.x0 + 18, b.x1 - 18), K.scale(K.vof(r), 0, top, b.y1, b.y0) }
      if K.vof(r) > K.vof(rs[bi]) then bi = i end
    end
    P.line(pts, { w = 2, col = P.PAL.rose, amp = .45, over = 0 })
    for i, p in ipairs(pts) do
      P.dot(p[1], p[2], 4.6, P.PAL.rose, 1.1)
      P.text(tostring(rs[i].label or ''), p[1], b.y1 + 17, { size = 10.5, anchor = 'middle' })
    end
    K.callout(pts[bi][1], pts[bi][2], 436, 90, K.vfmt(K.vof(rs[bi])) .. ' h', tostring(rs[bi].label) .. ' 最好', 'end')
  end,
}

M.steps = {
  label = '阶梯图',
  demo = {
    title = '爬到小屋', note = '每一级是一段爬升。每段长踏板是歇脚。',
    rows = { { label = '出发', value = 300 }, { label = '林线', value = 700 }, { label = '脊', value = 900 },
             { label = '岔口', value = 900 }, { label = '小屋', value = 1240 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local b = K.boxPlot({ y0 = 76, y1 = 306 })
    local top = K.top(K.maxv(rs))
    K.ticksY(b, top, 4)
    local n = #rs
    local pts = {}
    for i, r in ipairs(rs) do
      local x = K.scale(i, 1, max(n, 2), b.x0 + 12, b.x1 - 26)
      local y = K.scale(K.vof(r), 0, top, b.y1, b.y0)
      if i > 1 then pts[#pts + 1] = { x, pts[#pts][2] } end
      pts[#pts + 1] = { x, y }
      P.text(tostring(r.label or ''), x, b.y1 + 17, { size = 10, anchor = 'middle' })
    end
    P.line(pts, { w = 2, col = P.PAL.blue, amp = .4, over = 0 })
  end,
}

M.timeline = {
  label = '时间线',
  demo = {
    title = '一棵番茄苗', note = '从种子到三明治，六个月。横轴越靠右越晚。', unit = '月',
    rows = { { label = '播种', value = 0 }, { label = '出芽', value = 1 }, { label = '上架', value = 2.5 },
             { label = '开花', value = 3.5 }, { label = '转红', value = 5 }, { label = '三明治', value = 6 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local x0, x1, y = 64, 452, 200
    local top = K.top(K.maxv(rs))
    P.line({ { x0, y }, { x1, y } }, { w = 2, col = P.PAL.wood, amp = .4 })
    for i, r in ipairs(rs) do
      local x = K.scale(K.vof(r), 0, top, x0, x1)
      local up = (i % 2 == 1)
      local col = i == #rs and P.PAL.rose or P.PAL.sage
      P.dot(x, y, 6, col, 1.2)
      P.line({ { x, up and y - 8 or y + 8 }, { x, up and y - 46 or y + 46 } }, { w = 1, col = P.LEAD, amp = .25, over = 0 })
      P.text(tostring(r.label), x, up and y - 54 or y + 62, { size = 11, anchor = 'middle', col = P.INK })
      P.text(K.vfmt(K.vof(r)) .. (spec.unit or ''), x, up and y - 70 or y + 78,
        { size = 9.5, anchor = 'middle', col = P.LEAD })
    end
  end,
}

M.journey = {
  label = '用户旅程',
  demo = {
    title = '坐火车去海边', note = '这一天一步步是什么感觉。延误是低谷，靠窗的座把它救回来。', top = 5,
    rows = { { label = '买票', value = 4 }, { label = '进站', value = 3 }, { label = '延误', value = 1 },
             { label = '上车', value = 3 }, { label = '看海', value = 5 }, { label = '回家', value = 3 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local top = spec.top or 5
    local n = #rs
    local x0, x1, y0, y1 = 76, 448, 100, 286
    local pts = {}
    for i, r in ipairs(rs) do
      pts[#pts + 1] = { K.scale(i, 1, max(n, 2), x0, x1), K.scale(K.vof(r), 1, top, y1, y0) }
    end
    local poly = {}
    for _, p in ipairs(pts) do poly[#poly + 1] = p end
    poly[#poly + 1] = { pts[#pts][1], y1 + 8 }
    poly[#poly + 1] = { pts[1][1], y1 + 8 }
    P.fill(poly, P.mix(P.PAL.sky, '#fdf9f1', .45), { dx = .6, dy = .4, amp = .5 })
    P.line(pts, { w = 2, col = P.PAL.blue, amp = .4, over = 0 })
    for i, p in ipairs(pts) do
      P.dot(p[1], p[2], 5, P.PAL.sage, 1.1)
      P.text(tostring(rs[i].label), p[1], y1 + 26, { size = 10, anchor = 'middle' })
    end
    P.text('差', x0 - 12, y1, { size = 10, anchor = 'end', col = P.LEAD })
    P.text('好', x0 - 12, y0, { size = 10, anchor = 'end', col = P.LEAD })
  end,
}

M.gantt = {
  label = '甘特图',
  demo = {
    title = '把周日午饭端上桌', note = '所有事都在一点结束。从那儿往回倒推。',
    finish = '13:00', span = 180,
    rows = { { label = '烤鸡', from = 0, to = 150 }, { label = '土豆', from = 90, to = 150 },
             { label = '布丁', from = 30, to = 120 }, { label = '摆桌', from = 150, to = 180 } },
  },
  draw = function(spec)
    local rs = rows(spec)
    local x0, x1 = 116, 452
    local y0, ch = 96, 42
    local span = spec.span or 180
    for i, r in ipairs(rs) do
      local y = y0 + (i - 1) * ch
      P.text(tostring(r.label), x0 - 12, y + 18, { size = 11, anchor = 'end', col = P.TONE })
      local a = K.scale(spec['from'] and 0 or K.vof(r, 'from'), 0, span, x0, x1)
      local xa = K.scale(K.vof(r, 'from'), 0, span, x0, x1)
      local xb = K.scale(K.vof(r, 'to'), 0, span, x0, x1)
      L.hbar(xa, xb, y + 4, y + 32, K.col(i))
      if i < #rs then
        P.line({ { x0, y + ch - 4 }, { x1, y + ch - 4 } }, { w = .5, col = P.PAL.shade, amp = .3, over = 0, dash = '3 6' })
      end
    end
    -- 起点由 finish 往回推（finish 是最后一刻），刻度按分钟落位，别用 K.int 四舍五入
    -- 到整点，否则 10:30 会印成 11:00，半小时间距的轴上全是重号
    local fh, fm = tostring(spec.finish or '13:00'):match('^(%d+):(%d+)$')
    local base = (fh and (tonumber(fh) * 60 + tonumber(fm)) or 780) - span
    local function tlabel(t)
      local m = base + t
      return string.format('%d:%02d', math.floor(m / 60), m % 60)
    end
    local step = math.max(15, math.ceil(span / 6 / 15) * 15)
    for t = 0, span, step do
      local x = K.scale(t, 0, span, x0, x1)
      P.line({ { x, y0 - 12 }, { x, y0 + #rs * ch - 8 } }, { w = .6, col = P.PAL.shade, amp = .25, over = 0, dash = '3 5' })
      P.text(tlabel(t), x, y0 - 18, { size = 9.5, anchor = 'middle', col = P.LEAD })
    end
  end,
}

M.swim = {
  label = '泳道图',
  demo = {
    title = '两个人的早饭', note = '一台电器一条泳道。每块砖是 7:00 起的一分钟；红箭头是隔绳交接。',
    t0 = '7:00', span = 12,
    lanes = { { label = '水壶', from = 0, to = 4 }, { label = '烤面包机', from = 1, to = 6 }, { label = '灶', from = 3, to = 9 } },
    hops = { { { 0, 4 }, { 1, 1 } }, { { 1, 6 }, { 2, 3 } } },
  },
  draw = function(spec)
    local lanes = spec.lanes or {}
    local span = spec.span or 12
    local x0, x1 = 118, 452
    local y0, lh = 100, 62
    for i, l in ipairs(lanes) do
      local y = y0 + (i - 1) * lh
      P.text(tostring(l.label), x0 - 12, y + 26, { size = 11, anchor = 'end', col = P.TONE })
      P.line({ { x0, y + lh - 6 }, { x1, y + lh - 6 } }, { w = 1, col = P.PAL.shade, amp = .35, over = 0 })
      local xa = K.scale(K.vof(l, 'from'), 0, span, x0, x1)
      local xb = K.scale(K.vof(l, 'to'), 0, span, x0, x1)
      L.hbar(xa, xb, y + 8, y + 44, K.col(i))
      P.text(K.int(K.vof(l, 'from')) .. '–' .. K.int(K.vof(l, 'to')), (xa + xb) / 2, y + 32, { size = 10, anchor = 'middle' })
    end
    for t = 0, span, 2 do
      P.text(K.int(t + 7) .. ':00', K.scale(t, 0, span, x0, x1), y0 - 14, { size = 9.5, anchor = 'middle', col = P.LEAD })
    end
    for _, h in ipairs(spec.hops or {}) do
      local a = h[1]
      local b = h[2]
      local p = { K.scale(a[2], 0, span, x0, x1), y0 + a[1] * lh + 26 }
      local q = { K.scale(b[2], 0, span, x0, x1), y0 + b[1] * lh + 26 }
      L.arrow(p, q, { col = P.RED, w = 1.3, bend = 18, headSize = 5.5 })
    end
  end,
}

return M
