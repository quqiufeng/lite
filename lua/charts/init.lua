-- lua/charts/init.lua —— 图表卡的注册表与出口
--
-- 用法：
--   local C = require('charts')
--   C.list()                          -- 所有卡 id
--   C.svg('pie', spec)                -- 出 SVG 字符串
--   C.render('pie', spec, '/tmp/a.png')  -- 出 PNG（cairo+librsvg）
--   C.render('pie')                   -- 不给 spec 就用卡自带的 demo
local P = require('charts.pen')

local M = { PEN = P }

M.families = { parts = '整体切成几块', bars = '长短比较', lines = '随时间走',
               dist = '分布', flow = '流向与关系', hier = '层级' }

M.order = {}
M.cards = {}

-- 加载某一族；文件缺了不炸，只跳过（方便边写边跑）
function M.load(fam)
  local ok, mod = pcall(require, 'charts.types.' .. fam)
  if not ok or type(mod) ~= 'table' then return end
  for id, def in pairs(mod) do
    if type(def) == 'table' and def.draw then
      def.id, def.family = id, fam
      def.label = def.label or id
      if not M.cards[id] then M.order[#M.order + 1] = id end
      M.cards[id] = def
    end
  end
end

function M.scan()
  for _, fam in ipairs({ 'parts', 'bars', 'lines', 'dist', 'flow', 'hier' }) do M.load(fam) end
  return M
end

function M.list(fam)
  M.scan()
  local o = {}
  for _, id in ipairs(M.order) do
    local d = M.cards[id]
    if not fam or d.family == fam then
      o[#o + 1] = { id = id, label = d.label, family = d.family }
    end
  end
  return o
end

function M.get(id)
  M.scan()
  return M.cards[id]
end

-- 把 spec 补成一张完整的卡（缺 title 用卡自己的 label，缺数据用 demo）
function M.spec(id, spec)
  local d = M.get(id)
  if not d then error('no such chart: ' .. tostring(id)) end
  local s = {}
  for k, v in pairs(d.demo or {}) do s[k] = v end
  for k, v in pairs(spec or {}) do s[k] = v end
  if s.title == nil then s.title = d.label end
  return s, d
end

function M.svg(id, spec)
  local s, d = M.spec(id, spec)
  return P.card(s, function(sp) d.draw(sp) end)
end

-- 上层目录不存在时 cairo 只会报 "error while writing to output stream"，看不出是缺目录
local function ensure_dir(path)
  local dir = path:match('^(.*)/[^/]*$')
  if not dir or dir == '' then return end
  local probe = io.open(dir .. '/.', 'r')
  if probe then probe:close(); return end
  os.execute('mkdir -p "' .. dir .. '"')
end

function M.render(id, spec, out)
  local s = M.svg(id, spec)
  if not out then return s end
  ensure_dir(out)
  local png = require('trace.svgpng')
  local ok, info = png.render(s, out, (spec and spec.scale) or 2)
  if not ok then error('render failed: ' .. tostring(info)) end
  return out, s
end

return M
