-- lua/charts/spec.lua —— spec 的入口守卫：把「坏数据」变成「能出图 + 看得见的告警」
--
-- 为什么单列一层：卡片有 54 张，每张都自己 rows[i].value、算和、除总和。坏数据
-- （空 rows、全 0、负数、1e12、字符串、nan）以前是在某张卡的第 200 行炸，报错只剩
-- 「index nil」；而且同一个 bug 要在 54 个 draw 里各修一遍。
-- 这里统一做三件事，卡片只当「数据已经能用」：
--   1. 深拷贝后逐字段过一遍数值（nan/inf/字符串 → 0 或丢弃），调用方的表不动；
--   2. 行规整成 {label=string, value=number}（纯数字行也认），坏值计数；
--   3. 数据整体为空 → 打 _empty 标记（init 画「没有可用数据」占位卡，不再靠各卡自己防）。
-- 出了任何一条问题都在 note 里补一句人话，图上看得见 —— 静默兜底等于骗人。
local P = require('charts.pen')
local M = {}

-- 超过这个量级的一律当坏值：真数据不会这么写，几何上只会把坐标算爆
M.MAXABS = 1e15

-- 有限数值或 nil（nan/±inf/非数字/超限 → nil）
function M.num(v)
  v = tonumber(v)
  if not v or v ~= v then return nil end
  if v == math.huge or v == -math.huge then return nil end
  if v > M.MAXABS or v < -M.MAXABS then return nil end
  return v
end

-- 结构里的数值字段名（各卡约定俗成的那些）；不在这张表里的一律原样透传
local NUM = {
  value = true, from = true, to = true, size = true, weight = true,
  max = true, span = true, count = true, total = true, at = true,
}

-- 承载「图的数据」的键：全空就认为这张卡没数据可画
local DATA = {
  rows = true, values = true, flows = true, sinks = true, links = true,
  entities = true, tree = true, nodes = true, bars = true, series = true,
}

local function is_empty(v)
  if type(v) ~= 'table' then return true end
  return next(v) == nil
end

local function num_list(t, st)
  local o = {}
  for _, x in ipairs(t) do
    local n = M.num(x)
    if n == nil then st.bad = st.bad + 1 else o[#o + 1] = n end
  end
  -- 一串样本全坏：留一个 0，别让 downstream 除 dm=0 或取 [1]=nil
  if #o == 0 then o[1] = 0 end
  return o
end

-- 深拷贝 + 逐字段规整。depth 上限防止环形/超深结构把栈打穿
local norm
local function norm_rows(rows, depth, st)
  local o = {}
  for _, r in ipairs(rows) do
    local tr = type(r)
    if tr == 'number' then
      local n = M.num(r)
      if n == nil then st.bad = st.bad + 1; n = 0 end
      o[#o + 1] = { label = '', value = n }
    elseif tr == 'table' then
      o[#o + 1] = norm(r, depth, st)
    elseif tr == 'string' then
      -- kanban/鱼骨这类卡把 rows 当「一行一句话」用（不是数值行），原样留着
      o[#o + 1] = r
    else
      st.bad = st.bad + 1 -- nil/boolean/function：丢掉
    end
  end
  return o
end

norm = function(t, depth, st)
  if type(t) ~= 'table' or depth > 8 then return t end
  local o = {}
  for k, v in pairs(t) do
    if type(v) == 'table' then
      if k == 'rows' then
        o[k] = norm_rows(v, depth + 1, st)
      elseif k == 'values' or NUM[k] then
        o[k] = num_list(v, st)
      else
        o[k] = norm(v, depth + 1, st)
      end
    elseif NUM[k] and v ~= nil then
      -- 这张名单里的键在 54 张卡里都只当数字用（grep 过：没有当颜色/文本用的），
      -- 所以解析不出一律记坏值 + 归 0，不做"也许它是字符串"的猜测
      local n = M.num(v)
      if n == nil then st.bad = st.bad + 1; n = 0 end
      o[k] = n
    elseif (k == 'label' or k == 'name') and type(v) ~= 'string' and v ~= nil then
      o[k] = tostring(v)
    else
      o[k] = v
    end
  end
  return o
end

-- 入口：返回规整后的新 spec（不改入参），并在需要时补 note / 打 _empty
function M.guard(spec)
  local st = { bad = 0 }
  local s = norm(spec or {}, 0, st)

  -- 空数据判定：只在「这张卡确实有数据键」时才判（有些卡把数据写死在 draw 里）
  local seen, allEmpty = false, true
  for k in pairs(DATA) do
    if s[k] ~= nil then
      seen = true
      if not is_empty(s[k]) then allEmpty = false end
    end
  end
  if seen and allEmpty then s._empty = true end

  -- 空数据的话由占位图说（draw_empty 里已经写了一遍），别在注脚里再重复；
  -- 只有「部分值是坏的」才补一句，那是占位图表达不了的信息
  if not s._empty and st.bad > 0 then
    local msg = string.format('%d 个数值无法解析，按 0 记', st.bad)
    s.note = (type(s.note) == 'string' and s.note ~= '' and (s.note .. '　') or '') .. '（' .. msg .. '）'
  end
  return s
end

-- 「没有可用数据」占位：还是同一张纸、同一个画框，只是把话说清楚
function M.draw_empty()
  local b = { x0 = 46, y0 = 62, x1 = 474, y1 = 356 }
  P.rim({ { b.x0, b.y0 }, { b.x1, b.y0 }, { b.x1, b.y1 }, { b.x0, b.y1 } }, 1, P.PAL.shade, .85)
  P.text('没有可用的数据', (b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2, { size = 16, anchor = 'middle', col = P.LEAD })
  P.text('rows/values 为空，或所有值都解析不出数字', (b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2 + 24,
    { size = 11, anchor = 'middle', col = P.LEAD })
end

return M
