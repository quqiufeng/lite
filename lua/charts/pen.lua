-- lua/charts/pen.lua —— minicharts 的笔：纸、墨、wash、手绘抖动、引线注释
--
-- 纯 LuaJIT，零 JS 运行时、零 Chrome：所有图都拼成 SVG 字符串，PNG 交给
-- lua/trace/svgpng.lua（cairo+librsvg）。移植自 minicharts/assets/engine.js 的
-- 画法（wash 底 + 墨线描边 + 引线注释 + 便签），但按 lite 的习惯重排成模块：
--   M.reset() 清空画布 → 一堆 M.fill/M.line/M.text → M.svg() 出整张卡
-- 抖动（hand）默认 amp≈0.5：太小像 CAD，太大像涂鸦；种子固定所以可回归。
local M = {}

local floor, abs, max, min, sqrt = math.floor, math.abs, math.max, math.min, math.sqrt
local sin, cos, atan2, pi = math.sin, math.cos, math.atan2, math.pi
local fmt = string.format

-- 调色板：与 minicharts 同源（牛皮纸、鼠尾草、天蓝、玫瑰、金）
M.PAL = {
  cream = '#fdf9f1', tan = '#e3c999', wood = '#bd9963', pink = '#e2b7c2',
  rose = '#d6826d', sage = '#a0cab4', sky = '#bcccdb', blue = '#96adc7',
  gold = '#e2b34d', steel = '#c7cbcd', shade = '#e0ddd2', moss = '#b9d09f',
  soil = '#b89b70', water = '#a8c0d0', ink = '#2a2b2f',
}
M.INK, M.RED, M.LEAD = '#2a2b2f', '#b23a38', '#8a8174'
M.PAPER, M.TOOTH = '#fbf6ec', '#f4ecdd'
M.HAND = 'Chilanka, Noto Sans CJK SC, DejaVu Sans'
M.SERIF = 'Noto Serif CJK SC, DejaVu Serif'
M.TONE = '#676976'

-- 轮转色：wash 用浅色，画线用同色加深
M.SERIES = { '#a0cab4', '#bcccdb', '#e2b7c2', '#e2b34d', '#96adc7', '#d6826d', '#c7cbcd', '#bd9963' }

M.out = {}
M.rnd = nil
M.W, M.H = 520, 420

function M.n1(v)
  local s = fmt('%.1f', tonumber(v) or 0)
  if s == '-0.0' then s = '0.0' end
  return (s:gsub('%.0$', ''))
end

-- 固定种子（图里每一笔的抖动、每一处随机点缀都吃它，保证可回归）
-- 注意：LuaJIT 没有 Lua 5.3 的 `~`/`>>` 运算符，位运算一律走 bit 库
local bit = require('bit')
M.seed = nil
function M.seed(a)
  a = floor(a or 7)
  M.rnd = function()
    a = (a + 0x6D2B79F5) % 4294967296
    local t = a
    local r = bit.bxor(bit.rshift(t, 15), t)
    r = (r * (1 + t)) % 4294967296
    r = bit.bxor(r, bit.rshift(r, 7))
    r = (r * (61 + r)) % 4294967296
    r = bit.bxor(r, bit.rshift(r, 14))
    -- bxor 出来是带符号 32 位，不掩一下就有一半落在负数侧
    return (r % 4294967296) / 4294967296
  end
end

function M.reset(seed)
  M.out, M.shades = {}, {}
  M.seed(seed or 7)
  M.clipN, M.tagN = 0, 1
end

local function emit(s) M.out[#M.out + 1] = s end
M.emit = emit

function M.mix(a, b, t)
  if type(a) ~= 'string' or #a ~= 7 then return a end
  local function p(c, i) return tonumber(c:sub(i + 1, i + 2), 16) end
  local o = { '#' }
  for _, i in ipairs({ 1, 3, 5 }) do
    o[#o + 1] = fmt('%02x', floor(p(a, i) * (1 - t) + p(b, i) * t + .5))
  end
  return table.concat(o)
end
function M.dim(c) return M.mix(c, '#535978', .24) end
function M.glow(c) return M.mix(c, '#fbfbfb', .22) end
function M.lit(c) return M.mix(c, '#fdf9f1', .22) end
function M.shadeOf(c) return M.mix(c, M.TONE, .17) end
function M.trim(c) return M.mix(c, M.TONE, .34) end
function M.lerp(a, b, t) return a + (b - a) * t end

-- ---------------------------------------------------------------------------
-- 手绘：折线 → 等距重采样 → 沿法线缓慢漂移（低频正弦，不跳）
-- ---------------------------------------------------------------------------
function M.resample(pts, step)
  step = step or 8
  local o = {}
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    local d = sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
    local n = max(1, floor(d / step + .5))
    for k = 0, n - 1 do o[#o + 1] = { a[1] + (b[1] - a[1]) * k / n, a[2] + (b[2] - a[2]) * k / n } end
  end
  o[#o + 1] = { pts[#pts][1], pts[#pts][2] }
  return o
end

function M.wob()
  local a, b, c = M.rnd() * 9, M.rnd() * 9, M.rnd() * 9
  local f = .012 + M.rnd() * .01
  return function(t) return .55 * sin(t * f + a) + .3 * sin(t * f * 2.3 + b) + .15 * sin(t * f * 5.1 + c) end
end

function M.hand(pts, amp, over)
  amp = amp or .5
  if #pts < 2 then return pts end
  if over and over > 0 then
    local a, b, y, z = pts[1], pts[2], pts[#pts], pts[#pts - 1]
    local la = sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)
    if la < 1e-6 then la = 1 end
    local lz = sqrt((y[1] - z[1]) ^ 2 + (y[2] - z[2]) ^ 2)
    if lz < 1e-6 then lz = 1 end
    local oa, oz = over * M.rnd(), over * M.rnd()
    local n = {}
    n[1] = { a[1] + (a[1] - b[1]) / la * oa, a[2] + (a[2] - b[2]) / la * oa }
    for i = 2, #pts - 1 do n[#n + 1] = pts[i] end
    n[#n + 1] = { y[1] + (y[1] - z[1]) / lz * oz, y[2] + (y[2] - z[2]) / lz * oz }
    pts = n
  end
  if amp == 0 then return pts end
  local r, f, d = M.resample(pts), M.wob(), 0
  local o = {}
  for i, p in ipairs(r) do
    local q, e = r[min(i + 1, #r)], r[max(i - 1, 1)]
    local dx, dy = q[1] - e[1], q[2] - e[2]
    local l = sqrt(dx * dx + dy * dy)
    if l < 1e-6 then l = 1 end
    d = d + 8
    local m = f(d) * amp
    o[i] = { p[1] - dy / l * m, p[2] + dx / l * m }
  end
  return o
end

function M.pathOf(pts, closed)
  local t = { 'M', M.n1(pts[1][1]), ' ', M.n1(pts[1][2]) }
  for i = 2, #pts do t[#t + 1] = 'L' .. M.n1(pts[i][1]) .. ' ' .. M.n1(pts[i][2]) end
  if closed then t[#t + 1] = 'Z' end
  return table.concat(t)
end

-- Catmull-Rom 采样：平滑曲线（云、饼边、山脊）
function M.spline(c, closed, step)
  step = step or 1.4
  local n = #c
  local function at(i)
    if closed then return c[(i - 1) % n + 1] end
    return c[max(1, min(n, i))]
  end
  local o = {}
  local lim = closed and n or n - 1
  for i = 1, lim do
    local p0, p1 = at(i), at(i + 1)
    local m0 = { (p1[1] - at(i - 1)[1]) / 2, (p1[2] - at(i - 1)[2]) / 2 }
    local m1 = { (at(i + 2)[1] - p0[1]) / 2, (at(i + 2)[2] - p0[2]) / 2 }
    local d = sqrt((p1[1] - p0[1]) ^ 2 + (p1[2] - p0[2]) ^ 2)
    local k = max(1, floor(d / step + .999))
    for j = 0, k - 1 do
      local t = j / k
      local t2, t3 = t * t, t * t * t
      local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
      o[#o + 1] = {
        h00 * p0[1] + h10 * m0[1] + h01 * p1[1] + h11 * m1[1],
        h00 * p0[2] + h10 * m0[2] + h01 * p1[2] + h11 * m1[2],
      }
    end
  end
  if not closed then o[#o + 1] = { c[n][1], c[n][2] } end
  return o
end

function M.ringAt(fn, n)
  n = n or 30
  local o = {}
  for i = 0, n - 1 do
    local t = i / n * 2 * pi
    o[#o + 1] = fn(cos(t), sin(t))
  end
  return o
end

function M.oval(cx, cy, rx, ry, n)
  ry = ry or rx
  return M.ringAt(function(a, b) return { cx + a * rx, cy + b * ry } end, n or 16)
end

function M.blob(cx, cy, rx, ry, bump, k)
  bump, k = bump or 0, k or 7
  return M.ringAt(function(a, b)
    local t = atan2(b, a)
    local r = 1 + bump * sin(t * k)
    return { cx + rx * a * r, cy + ry * b * r }
  end, 34)
end

function M.arcPts(cx, cy, r, a0, a1, n)
  n = n or 24
  local o = {}
  for i = 0, n do
    local t = a0 + (a1 - a0) * i / n
    o[#o + 1] = { cx + r * cos(t), cy + r * sin(t) }
  end
  return o
end

-- ---------------------------------------------------------------------------
-- 落笔：fill（wash + 略偏移的色块）、line（墨线）、rim、hatch
-- ---------------------------------------------------------------------------
function M.fill(pts, col, o)
  o = o or {}
  local dx, dy, amp = o.dx or 1.1, o.dy or .8, o.amp or .5
  local j = M.hand(pts, amp)
  local a = {}
  for i, p in ipairs(j) do a[i] = { p[1] + dx, p[2] + dy } end
  emit(fmt('<path fill="%s" d="%s"/>', col or M.PAL.cream, M.pathOf(a, true)))
end

function M.flat(pts, col) M.fill(pts, col, { dx = 0, dy = 0, amp = 0 }) end

function M.line(pts, o)
  o = o or {}
  if #pts < 2 then return end
  local w, col, amp = o.w or 1.4, o.col or M.INK, o.amp
  if amp == nil then amp = .55 end
  local j = M.hand(pts, amp, o.over or 1.6)
  emit(fmt('<path d="%s" fill="none" stroke="%s" stroke-width="%s" stroke-linecap="round" stroke-linejoin="round" opacity="%s"%s/>',
    M.pathOf(j), col, M.n1(w), M.n1(o.op or 1),
    o.dash and (' stroke-dasharray="' .. o.dash .. '"') or ''))
end

function M.rim(pts, w, col, op)
  emit(fmt('<path d="%s" fill="none" stroke="%s" stroke-width="%s" opacity="%s"/>', M.pathOf(pts, true), col or M.INK, M.n1(w or 1), M.n1(op or 1)))
end

function M.inkLoop(pts, o)
  o = o or {}
  local c = {}
  for i, p in ipairs(pts) do c[i] = p end
  c[#c + 1] = pts[1]
  c[#c + 1] = pts[2] or pts[1]
  local oo = {}
  for k, v in pairs(o) do oo[k] = v end
  if oo.over == nil then oo.over = 0 end
  M.line(c, oo)
end

function M.shape(pts, col, o)
  o = o or {}
  M.fill(pts, col, { dx = .4, dy = .3, amp = .45 })
  M.inkLoop(pts, { w = o.w or 1.5, col = o.col or M.INK, amp = .35, over = 0 })
end

-- 排线阴影（雕版风格）：短平行线，随机断、随机留边
function M.hatch(poly, o)
  o = o or {}
  local dir, gap, w = o.dir or { 0, 1 }, o.gap or 5.5, o.w or .6
  local col, keep = o.col or M.INK, o.keep or .86
  local from, to = o.from or 0, o.to or 1
  local d = sqrt(dir[1] ^ 2 + dir[2] ^ 2)
  if d < 1e-6 then return end
  local u, v = { dir[1] / d, dir[2] / d }, { -dir[2] / d, dir[1] / d }
  local lo, hi = math.huge, -math.huge
  for _, p in ipairs(poly) do
    local pr = p[1] * v[1] + p[2] * v[2]
    if pr < lo then lo = pr end
    if pr > hi then hi = pr end
  end
  local s = lo + (hi - lo) * from + gap * .5
  local guard = 0
  while s < lo + (hi - lo) * to and guard < 400 do
    guard = guard + 1
    s = s + gap * (.82 + .36 * M.rnd())
    if M.rnd() <= keep then
      local hits = {}
      for i, a in ipairs(poly) do
        local b = poly[i % #poly + 1]
        local sa = a[1] * v[1] + a[2] * v[2] - s
        local sb = b[1] * v[1] + b[2] * v[2] - s
        if sa * sb < 0 then
          local t = sa / (sa - sb)
          hits[#hits + 1] = { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t }
        end
      end
      if #hits >= 2 then
        local p, q = hits[1], hits[2]
        local m, e = .06 + .2 * M.rnd(), .1 + .16 * M.rnd()
        M.line({ { M.lerp(p[1], q[1], m), M.lerp(p[2], q[2], m) },
                 { M.lerp(p[1], q[1], 1 - e), M.lerp(p[2], q[2], 1 - e) } }, { w = w, col = col, amp = .25, over = 0 })
      end
    end
  end
end

function M.dot(x, y, r, col, ink)
  local c = M.ringAt(function(a, b) return { x + r * a, y + r * b } end, 22)
  M.fill(c, col, { dx = .5, dy = .4, amp = .3 })
  M.inkLoop(c, { w = ink or 1.1, amp = .35, over = 0 })
end

-- 投影：卡片上唯一允许的"蓝灰影子"，压在物件下面
function M.cast(x, y, w, h, skew)
  skew = skew or { -.2, .35 }
  local o = { { x, y }, { x + w, y }, { x + w + skew[1], y + h + skew[2] }, { x + skew[1], y + h + skew[2] } }
  M.hullPush = M.hullPush or {}
  M.hullPush[#M.hullPush + 1] = o
end

function M.layCast()
  local list = M.hullPush or {}
  for _, p in ipairs(list) do
    M.fill(p, M.PENCIL_SHADOW or '#dfe3ea', { dx = 0, dy = 0, amp = .3 })
    M.rim(p, .8, '#c9cfdb', .9)
  end
  M.hullPush = {}
end

-- ---------------------------------------------------------------------------
-- 字：屏幕上写字（不跟 3D 平面走），CJK 与拉丁都走同一套
-- ---------------------------------------------------------------------------
local function esc(s)
  s = tostring(s == nil and '' or s)
  s = s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')
  return s
end
M.esc = esc

function M.text(str, x, y, o)
  o = o or {}
  local size = o.size or 13
  local fam = o.serif and M.SERIF or M.HAND
  local t = {
    fmt('<text x="%s" y="%s"', M.n1(x), M.n1(y)),
    fmt(' font-family="%s" font-size="%s"', fam, M.n1(size)),
    fmt(' fill="%s" text-anchor="%s"', o.col or M.INK, o.anchor or 'start'),
  }
  if o.track then t[#t + 1] = fmt(' letter-spacing="%s"', M.n1(o.track)) end
  if o.weight then t[#t + 1] = fmt(' font-weight="%s"', o.weight) end
  if o.op then t[#t + 1] = fmt(' opacity="%s"', M.n1(o.op)) end
  if o.rot then t[#t + 1] = fmt(' transform="rotate(%s %s %s)"', M.n1(o.rot), M.n1(x), M.n1(y)) end
  t[#t + 1] = '>' .. esc(str) .. '</text>'
  emit(table.concat(t))
end

-- UTF-8 逐字走一遍（LuaJIT 没有 utf8 库，自己解码）
-- fn(ch, nbyte) 每个字符调一次；返回累计值（由 fn 自己累）
local function each_char(s, fn)
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = 1
    if b >= 240 then len = 4 elseif b >= 224 then len = 3 elseif b >= 192 then len = 2 end
    if i + len - 1 > n then len = 1 end
    fn(s:sub(i, i + len - 1), len, b)
    i = i + len
  end
end
M.each_char = each_char

-- 粗估字宽（CJK 1em，拉丁 0.52em），折行用
function M.textw(s, size)
  local w = 0
  each_char(s, function(_, len, b)
    if len == 1 then
      w = w + (b == 32 and .28 or .52)
    else
      w = w + 1
    end
  end)
  return w * size
end

function M.wrap(s, maxw, size)
  local lines, cur = {}, ''
  for _, word in ipairs(M.split(s)) do
    local t = (cur == '' ) and word or (cur .. ' ' .. word)
    if M.textw(t, size) > maxw and cur ~= '' then
      lines[#lines + 1] = cur
      cur = word
    else
      cur = t
    end
  end
  if cur ~= '' then lines[#lines + 1] = cur end
  return lines
end

-- 折行：CJK 按字切，拉丁按词切（两者混排时都能用）
function M.split(s)
  local o, cur = {}, ''
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = 1
    if b >= 240 then len = 4 elseif b >= 224 then len = 3 elseif b >= 192 then len = 2 end
    local ch = s:sub(i, i + len - 1)
    if len == 1 then
      if ch == ' ' then
        if cur ~= '' then o[#o + 1] = cur; cur = '' end
      else
        cur = cur .. ch
      end
    else
      if cur ~= '' then o[#o + 1] = cur; cur = '' end
      o[#o + 1] = ch
    end
    i = i + len
  end
  if cur ~= '' then o[#o + 1] = cur end
  return o
end

-- ---------------------------------------------------------------------------
-- 引线注释：一条细灰引线 + 端点小圈 + 大写标题 + 斜体说明（minicharts 的 marker 语汇）
-- ---------------------------------------------------------------------------
function M.leader(a, b, sx)
  local dy = b[2] - a[2]
  local run = abs(dy) * .58
  local ex = b[1] - sx * run
  local e = (sx * (ex - a[1]) > 0) and { ex, a[2] } or a
  if e == a then
    M.line({ a, b }, { w = 1.05, col = M.LEAD, over = 0, amp = .4 })
  else
    M.line({ a, e, b }, { w = 1.05, col = M.LEAD, over = 0, amp = .4 })
  end
  M.dot(a[1], a[2], 3.8, M.PAPER, .9)
  M.dot(b[1], b[2], 3.8, M.PAPER, .9)
  emit(fmt('<circle cx="%s" cy="%s" r="1.2" fill="%s"/>', M.n1(b[1]), M.n1(b[2]), M.LEAD))
end

-- 标题 + 说明：tx,ty 是文字那端的基准点，to 是被指的点
-- 引线走正交肘：从字块离目标最近的那个顶角出发，先横着离开，再竖着绕到目标高度，
-- 最后插到点上——纵段永远在字块上方，不会从字身上穿过去。
function M.label(tx, ty, title, note, to, o)
  o = o or {}
  local side = o.side or 'start'
  local size = o.size or 20
  local w = max(M.textw(title, size), note and M.textw(note, size * .86) or 0)
  local base = ty + 20
  local xa = (side == 'start') and tx or (tx - w)
  local xb = xa + w
  local top = base - size * .92
  M.text(title, tx, base, { size = size, anchor = side, col = o.col or M.INK, track = .3 })
  if note then
    M.text(note, tx, base + size * 1.16, { size = size * .86, anchor = side, col = M.LEAD })
  end
  if not to then return end
  local d = (to[1] < (xa + xb) / 2) and -1 or 1
  local sx = (d < 0) and (xa - 1) or (xb + 1)
  local ex = sx + d * 13
  local pts = { { sx, top }, { ex, top } }
  if abs(to[2] - top) > 3 then pts[#pts + 1] = { ex, to[2] } end
  pts[#pts + 1] = to
  M.line(pts, { w = 1.05, col = M.LEAD, over = 0, amp = .35 })
  M.dot(sx, top, 2.4, M.LEAD, .6)
  M.dot(to[1], to[2], 3.6, M.PAPER, .9)
  emit(fmt('<circle cx="%s" cy="%s" r="1.2" fill="%s"/>', M.n1(to[1]), M.n1(to[2]), M.LEAD))
end

-- 便签：一张贴在图上的小纸片（wash 底 + 墨边 + 别针）
function M.tag(x, y, w, txt, o)
  o = o or {}
  local h = o.h or 34
  local n = max(6, floor(w / 5))
  local near = {}
  for i = 0, n do
    near[#near + 1] = { x + w * i / n, y + h + 1.6 * sin(i * 1.25) + M.rnd() * .6 }
  end
  local p = { { x, y }, { x + w, y } }
  for i = #near, 1, -1 do p[#p + 1] = near[i] end
  M.fill(p, o.fill or '#f8f3e9', { dx = .3, dy = .3, amp = .25 })
  M.line({ { x, y + h }, { x, y }, { x + w, y }, { x + w, y + h } }, { w = 1.2, amp = .3, over = 1.1 })
  M.line(near, { w = 1.05, amp = .15, over = 0 })
  M.text(txt, x + w / 2, y + h * .66, { anchor = 'middle', size = o.size or 13, col = o.col or M.INK, track = .4 })
  local pin = o.pin or M.PAL.gold
  M.dot(x + w / 2, y - 1, 4, pin, .9)
  if o.note then M.text(o.note, x + w / 2, y + h + 16, { anchor = 'middle', size = 10.5, col = M.LEAD }) end
end

-- ---------------------------------------------------------------------------
-- 卡片：520×420 一张纸，标题在上、红笔注脚在下
-- ---------------------------------------------------------------------------
-- 动效层（spec.anim 开关）：按落笔顺序给每个元素编号 --i，用 CSS keyframes
-- 让墨线"描出来"、色块"淡进来"。纯 CSS，零 JS；librsvg 出 PNG 时忽略 keyframes
-- 只取属性值，所以同一份字符串既能当静态图也能在浏览器里动。
M.ANIM_CSS = table.concat({
  '<style>',
  '@keyframes ink{from{stroke-dashoffset:2600}to{stroke-dashoffset:0}}',
  '@keyframes fade{from{opacity:0}to{opacity:1}}',
  '.a [stroke]:not([stroke="none"]):not([stroke-dasharray]){stroke-dasharray:2600;',
  '  animation:ink .95s cubic-bezier(.33,0,.2,1) both;animation-delay:calc(var(--i,0)*16ms)}',
  '.a path:not([stroke]),.a polygon:not([stroke]),.a ellipse:not([stroke]),.a circle:not([stroke]){',
  '  animation:fade .7s ease-out both;animation-delay:calc(var(--i,0)*16ms + 140ms)}',
  '.a text{animation:fade .6s ease-out both;animation-delay:calc(var(--i,0)*16ms + 260ms)}',
  '.a .grain{animation:fade .8s ease-out both}',
  '.a>:first-child{animation:none}',
  '@media (prefers-reduced-motion:reduce){.a *{animation:none!important}}',
  '</style>',
}, '\n')

-- 给一段 SVG 里的每个开标签塞一个 --i 序号（= 绘制先后）。
-- 闭合标签 '</path>' 的 '/' 不被 %a 匹配，天然跳过；自闭合 '/>' 要插在斜杠前。
function M.stagger(body)
  local i = 0
  return (body:gsub('<(%a+)([^>]*)>', function(tag, attrs)
    if tag == 'svg' then return '<' .. tag .. attrs .. '>' end
    i = i + 1
    -- 自闭合元素的 attrs 以 '/' 收尾（'>' 已被 [^>]* 吃掉），先把斜杠摘出来
    local tail = ''
    if attrs:sub(-1) == '/' then tail, attrs = '/', attrs:sub(1, -2) end
    if attrs:find(' style="', 1, true) then
      attrs = attrs:gsub(' style="', ' style="--i:' .. i .. ';', 1)
    else
      attrs = attrs .. ' style="--i:' .. i .. '"'
    end
    return '<' .. tag .. attrs .. tail .. '>'
  end))
end

function M.card(spec, draw)
  M.reset(spec.seed or 7)
  local W, H = M.W, M.H
  local anim = spec.anim and true or false
  local head, grain, ink = {}, {}, {}
  head[#head + 1] = fmt('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d"%s>',
    W, H, W, H, anim and ' class="a"' or '')
  head[#head + 1] = fmt('<rect width="%d" height="%d" fill="%s"/>', W, H, M.PAPER)
  -- 纸面颗粒：几撮极淡的斑点，让平涂不至于太"数字"
  for i = 1, 90 do
    local x, y = M.rnd() * W, M.rnd() * H
    local r = .4 + M.rnd() * .7
    grain[#grain + 1] = fmt('<circle cx="%s" cy="%s" r="%s" fill="#e6dcc9" opacity="%s"/>', M.n1(x), M.n1(y), M.n1(r * 2), M.n1(.25 + M.rnd() * .3))
  end
  -- 标题
  if spec.title and spec.title ~= '' then
    ink[#ink + 1] = fmt('<text x="24" y="34" font-family="%s" font-size="17" fill="%s" letter-spacing=".4">%s</text>',
      M.SERIF, M.INK, esc(spec.title))
    ink[#ink + 1] = fmt('<path d="M24 43 L%s 43" stroke="%s" stroke-width="1" opacity=".45"/>', M.n1(24 + M.textw(spec.title, 17) + 12), M.PAL.shade)
  end
  draw(spec)
  -- 落笔先出（M.out），红笔注脚永远压在最上层
  ink[#ink + 1] = table.concat(M.out, '\n')
  if spec.note and spec.note ~= '' then
    local lines = M.wrap(spec.note, W - 60, 11)
    local ruleY = H - 26 - (#lines - 1) * 13
    local y = H - 12 - (#lines - 1) * 13
    ink[#ink + 1] = fmt('<path d="M24 %s L%d %s" stroke="%s" stroke-width="1" stroke-dasharray="4 4" opacity=".6"/>',
      M.n1(ruleY), W - 24, M.n1(ruleY), M.PAL.shade)
    for i, ln in ipairs(lines) do
      ink[#ink + 1] = fmt('<text x="24" y="%s" font-family="%s" font-size="11.5" fill="%s">%s</text>',
        M.n1(y + (i - 1) * 13), M.HAND, M.RED, esc(ln))
    end
  end
  -- 开动效时：颗粒包成一组整体淡入，墨线按落笔顺序编号（静态渲染器只看到属性值）
  local body = table.concat(ink, '\n')
  if anim then
    body = M.stagger(body)
    head[#head + 1] = '<g class="grain">' .. table.concat(grain, '\n') .. '</g>'
    head[#head + 1] = M.ANIM_CSS
  else
    head[#head + 1] = table.concat(grain, '\n')
  end
  head[#head + 1] = body
  head[#head + 1] = '</svg>'
  return table.concat(head, '\n') .. '\n'
end

return M
