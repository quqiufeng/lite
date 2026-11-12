-- lua/charts/kit.lua —— 画卡用的小工具：绘图框、坐标轴、比例尺、图例、数值格式
-- 只放「每张卡都会用」的东西；每种图自己的笔法在 lua/charts/types/。
local P = require('charts.pen')
local M = {}

-- 取一行的数值：给了 key 就用 key，否则 value（也兼容纯数字行）
local function vof(r, key)
  if type(r) == 'number' then return r end
  if type(r) ~= 'table' then return 0 end
  local v = key and (r[key] or r.value) or r.value
  -- 一行可能是一串样本（蜂群/雨云/山脊的 values = {...}）：取其中最大那个，
  -- 否则 maxv 拿到 0，纵轴缩成 0..1，所有点挤在轴外看不见
  if type(v) == 'table' then
    local mx = -math.huge
    for _, x in ipairs(v) do
      x = tonumber(x)
      if x and x > mx then mx = x end
    end
    return mx == -math.huge and 0 or mx
  end
  if type(v) ~= 'number' then v = tonumber(v) or 0 end
  return v
end
M.vof = vof

function M.box(o)
  o = o or {}
  return { x0 = o.x0 or 46, y0 = o.y0 or 62, x1 = o.x1 or 474, y1 = o.y1 or 356 }
end

function M.scale(v, a, b, c, d)
  if b == a then b = a + 1e-9 end
  return c + (d - c) * (v - a) / (b - a)
end

function M.maxv(rows, key)
  local m = -math.huge
  for _, r in ipairs(rows) do
    local v = vof(r, key)
    if v > m then m = v end
  end
  if m == -math.huge then m = 0 end
  return m
end

function M.minv(rows, key)
  local m = math.huge
  for _, r in ipairs(rows) do
    local v = vof(r, key)
    if v < m then m = v end
  end
  if m == math.huge then m = 0 end
  return m
end

function M.sum(rows, key)
  local s = 0
  for _, r in ipairs(rows) do s = s + vof(r, key) end
  return s
end

-- 数值：1200 → 1.2k；3.25 → 3.25；5 → 5（不留小数点后的零）
-- 不给 0 写成 0.00：轴原点、时间线起点全用它，尾巴上的零只是噪声。
local function trim0(s)
  if s:find('%.') then s = s:gsub('0+$', ''):gsub('%.$', '') end
  return s
end

function M.vfmt(v)
  v = tonumber(v) or 0
  local a = math.abs(v)
  if a >= 1e6 then return trim0(string.format('%.1f', v / 1e6)) .. 'M' end
  if a >= 1000 then return trim0(string.format('%.1f', v / 1000)) .. 'k' end
  if a >= 10 then return string.format('%d', math.floor(v + .5)) end
  return trim0(string.format('%.2f', v))
end

function M.int(v) return string.format('%d', math.floor((tonumber(v) or 0) + .5)) end

-- 一律按 0 起算的比例尺上界（bar/line 通用），留 8% 余量
function M.top(v)
  if v <= 0 then return 1 end
  local mag = 10 ^ math.floor(math.log(v, 10))
  local n = v / mag
  -- 尾档必须封到 10：n 落在 (8,10) 时若给 8，上界就小于最大值，点/柱会溢出画框
  local step = n <= 1.2 and 1.2 or n <= 2 and 2 or n <= 2.5 and 2.5 or n <= 4 and 4
    or n <= 5 and 5 or n <= 6 and 6 or n <= 8 and 8 or 10
  return step * mag
end

function M.col(i)
  local s = P.SERIES
  return s[(i - 1) % #s + 1]
end

function M.row(r)
  if type(r) == 'number' then return { label = '', value = r } end
  return r
end

function M.boxPlot(o)
  local b = M.box(o)
  -- 底轴：一条墨线 + 刻度；网格用极淡的虚线
  P.line({ { b.x0, b.y1 }, { b.x1 + 4, b.y1 } }, { w = 1.5, amp = .45 })
  P.line({ { b.x0, b.y0 - 2 }, { b.x0, b.y1 } }, { w = 1.5, amp = .45 })
  return b
end

-- 轴上的刻度数字与淡网格
-- 好读的刻度步长：1 / 2 / 2.5 / 5 / 10 × 10^k
function M.step(v)
  if v <= 0 then return 1 end
  local mag = 10 ^ math.floor(math.log(v, 10))
  local n = v / mag
  local s = n <= 1 and 1 or n <= 2 and 2 or n <= 2.5 and 2.5 or n <= 5 and 5 or 10
  return s * mag
end

function M.ticksY(b, top, n)
  n = n or 4
  local st = M.step(top / n)
  if st * math.floor(top / st + 1e-9) < top * .55 then st = st / 2 end
  local k = 0
  while true do
    local v = k * st
    if v > top * 1.0001 then break end
    local y = M.scale(v, 0, top, b.y1, b.y0)
    if k > 0 then P.line({ { b.x0, y }, { b.x1, y } }, { w = .5, col = P.PAL.shade, amp = .3, over = 0, dash = '3 5' }) end
    P.text(M.vfmt(v), b.x0 - 8, y + 4, { size = 10.5, anchor = 'end', col = P.LEAD })
    k = k + 1
  end
end

function M.ticksX(b, rows, n)
  n = n or #rows
  local step = math.ceil(#rows / n)
  for i = 1, #rows, step do
    local x = M.scale(i - .5, 0, #rows, b.x0, b.x1)
    P.text(tostring(rows[i].label or ''), x, b.y1 + 16, { size = 11, anchor = 'middle', col = P.INK })
  end
end

-- 图例：小方块 + 名字，横排，超过宽度自动换行
function M.legend(labels, cols, x, y, o)
  o = o or {}
  local size, gap = 11, o.gap or 14
  local cx, cy = x, y
  for i, lb in ipairs(labels) do
    local w = P.textw(lb, size)
    if cx + w + 18 > (o.right or 476) and cx > x then cx, cy = x, cy + 15 end
    P.fill({ { cx, cy - 7 }, { cx + 8, cy - 7 }, { cx + 8, cy + 1 }, { cx, cy + 1 } }, cols[i] or M.col(i), { dx = .2, dy = .2, amp = .2 })
    P.rim({ { cx, cy - 7 }, { cx + 8, cy - 7 }, { cx + 8, cy + 1 }, { cx, cy + 1 } }, .7, P.INK, .8)
    P.text(lb, cx + 12, cy, { size = size, col = P.INK })
    cx = cx + w + 12 + gap
  end
  return cy
end

-- 引线注释：给某个点挂一句话（minicharts 的注释语汇）
function M.callout(px, py, tx, ty, title, note, side)
  P.label(tx, ty, title, note, { px, py }, { side = side or 'start', size = 17 })
end

-- 一个被指向的小圈（和 callout 配对）
function M.mark(x, y, col)
  P.dot(x, y, 4.2, col or P.PAPER, 1.1)
end

return M
