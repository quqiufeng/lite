-- lua/charts/types/lib.lua —— 各族共用的画法：坐标轴、柱、折线、节点框、箭头、连线
-- 只放「换一张图也要用的」几何，配色与数值格式仍在 kit.lua。
local P = require('charts.pen')
local K = require('charts.kit')
local M = {}

local sin, cos, pi, sqrt, floor = math.sin, math.cos, math.pi, math.sqrt, math.floor

function M.rows(spec) return spec.rows or {} end
function M.count(spec) return #(spec.rows or {}) end

-- 值域：0 起算（bar/line 的常规），带负值时上下都留
function M.range(rows, key)
  local lo, hi = 0, K.top(K.maxv(rows, key))
  local mn = K.minv(rows, key)
  if mn < 0 then lo = -K.top(-mn) end
  return lo, hi
end

-- 一块绘图区 + 左轴 + 底轴 + 淡网格；返回 box
function M.axes(b, top, o)
  o = o or {}
  local lo = o.lo or 0
  local n = o.ticks or 4
  for i = 0, n do
    local v = lo + (top - lo) * i / n
    local y = K.scale(v, lo, top, b.y1, b.y0)
    if i > 0 then
      P.line({ { b.x0, y }, { b.x1, y } }, { w = .5, col = P.PAL.shade, amp = .3, over = 0, dash = '3 6' })
    end
    P.text(o.fmt and o.fmt(v) or K.vfmt(v), b.x0 - 8, y + 4, { size = 10.5, anchor = 'end', col = P.LEAD })
  end
  -- 轴线：手画的两笔，比网格重
  P.line({ { b.x0, b.y1 }, { b.x1 + 3, b.y1 } }, { w = 1.5, amp = .4 })
  P.line({ { b.x0, b.y0 - 2 }, { b.x0, b.y1 } }, { w = 1.5, amp = .4 })
  if lo < 0 then
    local z = K.scale(0, lo, top, b.y1, b.y0)
    P.line({ { b.x0, z }, { b.x1, z } }, { w = 1, amp = .3, dash = '0.5 0' })
  end
  return b
end

-- 柱：x0..x1 一段，从基准 yb 长到 yt，wash 填充 + 墨线描边
function M.vbar(x0, x1, yb, yt, col, o)
  o = o or {}
  local p = { { x0, yb }, { x1, yb }, { x1, yt }, { x0, yt } }
  P.fill(p, col, { dx = .5, dy = .2, amp = .35 })
  -- 顶面稍亮一条，让平涂有厚度
  if o.lid ~= false then
    P.line({ { x0 + 1, yt }, { x1 - 1, yt } }, { w = 1, col = P.lit(col), amp = .2, over = 0 })
  end
  P.inkLoop(p, { w = o.w or 1.2, amp = .3, over = 0 })
end

function M.hbar(x0, x1, y0, y1, col, o)
  o = o or {}
  local p = { { x0, y0 }, { x1, y0 }, { x1, y1 }, { x0, y1 } }
  P.fill(p, col, { dx = .5, dy = .2, amp = .35 })
  P.inkLoop(p, { w = o.w or 1.1, amp = .3, over = 0 })
end

-- 圆角矩形（节点框、便签）
function M.roundRect(x, y, w, h, r)
  r = math.min(r or 6, w / 2, h / 2)
  local o = {}
  -- 四个圆心都得往内缩一个 r，否则每个角都往框外多长出一个 r
  local corners = { { x + r, y + r, 180 }, { x + w - r, y + r, 270 },
                    { x + w - r, y + h - r, 0 }, { x + r, y + h - r, 90 } }
  for ci, c in ipairs(corners) do
    for i = 0, 4 do
      local t = (c[3] + 90 * i / 4) * pi / 180
      o[#o + 1] = { c[1] + r * cos(t), c[2] + r * sin(t) }
    end
  end
  return o
end

-- 节点：圆角框 + 居中文字；返回中心点
function M.node(x, y, w, h, label, o)
  o = o or {}
  local p = M.roundRect(x, y, w, h, o.r or 7)
  P.fill(p, o.col or P.PAL.cream, { dx = .6, dy = .5, amp = .3 })
  P.inkLoop(p, { w = o.w or 1.2, amp = .3, over = 0 })
  local size = o.size or 11.5
  local lines = {}
  if P.textw(tostring(label), size) > w - 10 then lines = P.wrap(tostring(label), w - 10, size) else lines = { tostring(label) } end
  local cy = y + h / 2 - (#lines - 1) * size * .58 + size * .36
  for i, ln in ipairs(lines) do
    P.text(ln, x + w / 2, cy + (i - 1) * size * 1.16, { size = size, anchor = 'middle', col = o.ink or P.INK })
  end
  if o.note then
    P.text(o.note, x + w / 2, y + h + 13, { size = 10, anchor = 'middle', col = P.LEAD })
  end
  return x + w / 2, y + h / 2
end

-- 折线：从 a 到 b，可给弯度（0=直线，正=向一侧鼓）
function M.curve(a, b, bend, n)
  n = n or 16
  local mx, my = (a[1] + b[1]) / 2, (a[2] + b[2]) / 2
  local dx, dy = b[1] - a[1], b[2] - a[2]
  local len = sqrt(dx * dx + dy * dy)
  if len == 0 then return { a, b } end
  local nx, ny = -dy / len, dx / len
  local cx, cy = mx + nx * (bend or 0), my + ny * (bend or 0)
  local o = {}
  for i = 0, n do
    local t = i / n
    local u = 1 - t
    o[#o + 1] = { u * u * a[1] + 2 * u * t * cx + t * t * b[1],
                  u * u * a[2] + 2 * u * t * cy + t * t * b[2] }
  end
  return o
end

-- 连线 + 箭头（流程/状态图）
function M.arrow(a, b, o)
  o = o or {}
  local pts = o.bend and M.curve(a, b, o.bend) or { a, b }
  if o.dash then
    P.line(pts, { w = o.w or 1.2, col = o.col or P.INK, amp = .3, dash = o.dash })
  else
    P.line(pts, { w = o.w or 1.2, col = o.col or P.INK, amp = .3 })
  end
  if o.head ~= false then
    local p2, p1 = pts[#pts], pts[#pts - 1]
    local ang = math.atan2(p2[2] - p1[2], p2[1] - p1[1])
    local s = o.headSize or 6.5
    local t1 = { p2[1] - s * cos(ang - .42), p2[2] - s * sin(ang - .42) }
    local t2 = { p2[1] - s * cos(ang + .42), p2[2] - s * sin(ang + .42) }
    P.line({ t1, p2, t2 }, { w = o.w or 1.2, col = o.col or P.INK, amp = .2 })
  end
  return pts
end

-- 极坐标
function M.polar(cx, cy, r, a) return cx + r * cos(a), cy + r * sin(a) end

-- 高斯核密度（violin / ridge 用）
function M.density(vals, lo, hi, n)
  n = n or 40
  local mean, sd = 0, 0
  for _, v in ipairs(vals) do mean = mean + v end
  mean = mean / math.max(1, #vals)
  for _, v in ipairs(vals) do sd = sd + (v - mean) ^ 2 end
  sd = sqrt(sd / math.max(1, #vals))
  if sd <= 0 then sd = (hi - lo) / 6 > 0 and (hi - lo) / 6 or 1 end
  local bw = sd * 1.06 * math.max(1, #vals) ^ (-0.2)
  local o = {}
  for i = 0, n do
    local v = lo + (hi - lo) * i / n
    local d = 0
    for _, x in ipairs(vals) do d = d + math.exp(-0.5 * ((v - x) / bw) ^ 2) end
    o[#o + 1] = { v = v, d = d / (#vals * bw * 2.5066) }
  end
  return o
end

-- 一组数值的分位数
function M.quartiles(vals)
  local t = {}
  for i, v in ipairs(vals) do t[i] = v end
  table.sort(t)
  local function q(p)
    if #t == 0 then return 0 end
    local pos = (p / 100) * (#t - 1) + 1
    local i = floor(pos)
    local f = pos - i
    local a = t[i] or t[#t]
    local b = t[i + 1] or a
    return a + (b - a) * f
  end
  return q(0), q(25), q(50), q(75), q(100), t
end

-- 抖动散点：同一 x 上多个值按序号错开
function M.jitter(i, n, w)
  if n <= 1 then return 0 end
  return ((i - 1) / (n - 1) - .5) * w
end

-- 便签：小纸片 + 折角，流程图注释与 kanban 用
function M.slip(x, y, w, h, col)
  local p = { { x, y }, { x + w, y }, { x + w, y + h }, { x, y + h } }
  P.fill(p, col or P.PAL.gold, { dx = .8, dy = .8, amp = .5 })
  P.inkLoop(p, { w = 1.1, amp = .35, over = 0 })
end

return M
