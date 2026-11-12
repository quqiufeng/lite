-- tools/render.lua —— 折叠栈渲染（火焰图 / 热力图 / 卡点排行），纯 LuaJIT，零 Python 依赖
--
-- 输入：lite trace_engine --json 的 top[]（oncpu/offcpu）或 folded[]（折叠栈），
--       字段 frame_dir 决定方向（root-first / leaf-first），unit 决定权重口径（样本 / ms）。
-- 输出：只出 SVG；要 PNG 由 engine.lua 在进程内用 cairo+librsvg（tools/svgpng.lua）转。
--
-- 用法（独立跑，调试用）：
--   luajit tools/render.lua flame in.json out.svg "标题"
--   luajit tools/render.lua heat  in.json out.svg "标题" [topN]
--   luajit tools/render.lua rank  in.json out.svg "标题" [topN] [self|incl|count]
-- 进程内（engine.lua）：dofile 后 M.render(kind, j, out, title, opts)
--
-- 这份是 tools/{flame,heat,rank}.py 的等价移植：归一规则、坐标算法、颜色、
-- 文案全部照抄，SVG 属性顺序与小数位也保持一致，便于逐字节对比回归。
-- 唯一不保证的是「同权重并列」的先后（Python 侧受 set 迭代顺序影响，本身不稳定）。

local M = {}

local floor, abs = math.floor, math.abs
local fmt = string.format
local concat = table.concat

-- ===========================================================================
-- 基础件：UTF-8 迭代、MD5、数字格式化、JSON 编码
-- ===========================================================================

-- UTF-8 解码迭代器：返回 (codepoint, 原字节串)
local function u8iter(s)
  local i, n = 1, #s
  return function()
    if i > n then return nil end
    local b = s:byte(i)
    local cp, len
    if b < 0x80 then cp, len = b, 1
    elseif b < 0xE0 then cp, len = b - 0xC0, 2
    elseif b < 0xF0 then cp, len = b - 0xE0, 3
    else cp, len = b - 0xF0, 4 end
    for k = 1, len - 1 do
      cp = cp * 64 + ((s:byte(i + k) or 0x80) - 0x80)
    end
    local chunk = s:sub(i, i + len - 1)
    i = i + len
    return cp, chunk
  end
end

-- MD5（纯 Lua，bit 库加速）：颜色哈希要和 Python hashlib.md5 逐字节一致，
-- 同一个函数名在两张图上必须是同一种色，所以不能换别的哈希糊弄。
local bitlib = require("bit")
local tobit, band, bor, bxor, bnot, rol =
  bitlib.tobit, bitlib.band, bitlib.bor, bitlib.bxor, bitlib.bnot, bitlib.rol

local MD5K, MD5S = {}, {}
do
  for i = 1, 64 do MD5K[i] = tobit(floor(abs(math.sin(i)) * 4294967296)) end
  local sh = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  }
  for i = 1, 64 do MD5S[i] = sh[i] end
end

local function md5hex(msg)
  local bitlen = #msg * 8
  local tail = #msg % 64
  local pad = (tail < 56) and (56 - tail) or (120 - tail)
  msg = msg .. "\128" .. string.rep("\0", pad - 1)
  -- 长度按小端 64 位追加
  local lo = bitlen % 4294967296
  local hi = floor(bitlen / 4294967296)
  local lb = {}
  for i = 0, 7 do
    local v = (i < 4) and lo or hi
    lb[#lb + 1] = string.char(floor(v / 2 ^ (8 * (i % 4))) % 256)
  end
  msg = msg .. concat(lb)

  local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
  local X = {}
  for off = 1, #msg, 64 do
    for i = 1, 16 do
      local j = off + (i - 1) * 4
      local b1, b2, b3, b4 = msg:byte(j, j + 3)
      X[i] = tobit(b1 + b2 * 256 + b3 * 65536 + b4 * 16777216)
    end
    local A, B, C, D = a0, b0, c0, d0
    for i = 1, 64 do
      local F, g
      if i <= 16 then
        F = bor(band(B, C), band(bnot(B), D)); g = i
      elseif i <= 32 then
        F = bor(band(D, B), band(bnot(D), C)); g = (5 * (i - 1) + 1) % 16 + 1
      elseif i <= 48 then
        F = bxor(B, bxor(C, D)); g = (3 * (i - 1) + 5) % 16 + 1
      else
        F = bxor(C, bor(B, bnot(D))); g = (7 * (i - 1)) % 16 + 1
      end
      F = tobit(F + A + MD5K[i] + X[g])
      A, B, C, D = D, tobit(B + rol(F, MD5S[i])), B, C
    end
    a0 = tobit(a0 + A); b0 = tobit(b0 + B); c0 = tobit(c0 + C); d0 = tobit(d0 + D)
  end
  local function le32(v)
    local t = {}
    for i = 0, 3 do
      t[#t + 1] = fmt("%02x", floor(v / 2 ^ (8 * i)) % 256)
    end
    return concat(t)
  end
  return le32(a0) .. le32(b0) .. le32(c0) .. le32(d0)
end

-- Python round()：四舍六入五取偶。权重都非负，负数分支不管
local function pyround(v)
  local f = floor(v)
  local d = v - f
  if d > 0.5 then return f + 1 end
  if d < 0.5 then return f end
  return (f % 2 == 0) and f or f + 1
end

-- math.log1p：LuaJIT 没有，小 x 用级数保精度（色阶靠它归一，别直接 log(1+x)）
local function log1p(x)
  if abs(x) < 1e-4 then
    return x * (1 - x * (0.5 - x * (1 / 3 - x * 0.25)))
  end
  return math.log(1 + x)
end

-- JSON 数字：整数不带小数点（对齐 Python json.dumps 的 int）
local function jnum(v)
  if v == floor(v) and abs(v) < 1e15 then return fmt("%d", v) end
  return fmt("%.14g", v)
end

local JESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
               ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function jstr(s)
  return '"' .. s:gsub('[%z\1-\31"\\]', function(c)
    return JESC[c] or fmt("\\u%04x", c:byte())
  end) .. '"'
end

local function esc(s)  -- 文本节点转义（不含引号）
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  return (s:gsub(">", "&gt;"))
end

local function xesc(s) -- 属性/文本全转义
  return (esc(s):gsub('"', "&quot;"))
end

-- ===========================================================================
-- 归一化：折叠帧、清裸地址、建树
--   三张图共用这一套，函数名/权重必须完全一致，否则同一份数据三张图对不上。
-- ===========================================================================

local MAXD = tonumber(os.getenv("MAXD") or "") or 32

-- 折叠连续重复帧：内核 unwind 在不可靠的栈帧上会扫出几十层同一地址，
-- 真实递归不会连续出现同一个返回地址上百次。保留一帧即可。
local function collapse(frames)
  local out = {}
  local prev
  for i = 1, #frames do
    local f = frames[i]
    if i > 1 and f == prev then
      -- 折叠
    else
      out[#out + 1] = f
      prev = f
    end
  end
  return out
end

-- 从 "func+0x1a]"/"0x7f..." 里取偏移；取不到返回 nil
local function off_of(f)
  local h = f:match("%+0x(%x+)%]?$") or f:match("^0x(%x+)$")
  return h and tonumber(h, 16) or nil
end

local BAD_OFF = 2 ^ 40   -- 用户态地址不可能到这个量级

-- 裸用户态地址归并成占位帧（ASLR 下几乎每条都不同，展开会炸成上万节点）；
-- 符号化出错产生的超大偏移才丢弃；超深部分合并成一个节点。
-- 返回 (frames, 丢帧数, 截断层数, 归并的裸地址帧数)
local function scrub(frames)
  local kept, dropped, unsym = {}, 0, 0
  for i = 1, #frames do
    local f = frames[i]
    local o = off_of(f)
    local bare = f:match("^0x%x+$") ~= nil
    if o and o >= BAD_OFF then
      if bare then
        kept[#kept + 1] = "[user-addr]"   -- 纯 ASCII：mono 字体没有 CJK 字形
        unsym = unsym + 1
      else
        dropped = dropped + 1
      end
    else
      kept[#kept + 1] = f
    end
  end
  local tail = 0
  if #kept > MAXD then
    tail = #kept - MAXD
    local cut = {}
    for i = 1, MAXD do cut[i] = kept[i] end
    cut[MAXD + 1] = fmt("[…%d 层过深栈已合并]", tail)
    kept = cut
  end
  return kept, dropped, tail, unsym
end

-- 归一一份 JSON：返回 (stat, folded)。folded 是数组 { {frames=…, w=…}, … }，
-- 顺序 = 首次出现顺序（Python dict 语义），并列排序时靠它定先后。
local function load(j)
  local stat = { collapsed = 0, dropped = 0, trunc = 0, unsym = 0 }
  local rows = j.top or j.folded or {}
  local leaf_first = (j.frame_dir or "leaf-first") == "leaf-first"
  local unit_ms = j.unit == "ms"
  local folded, order = {}, {}

  for r = 1, #rows do
    local e = rows[r]
    local stack = e.stack or ""
    local frames = {}
    for piece in (stack .. ";"):gmatch("([^;]*);") do
      if piece ~= "" then frames[#frames + 1] = piece end
    end
    if leaf_first then            -- 叶子在前 -> 反转，根在底部
      local rv = {}
      for i = #frames, 1, -1 do rv[#rv + 1] = frames[i] end
      frames = rv
    end
    -- oncpu/folded 权重是样本数(count)；offcpu 权重是阻塞时长(total_ms)。
    -- offcpu 条目同样带 count（=配对数），只能靠 unit 区分。
    local w
    if unit_ms then w = e.total_ms or 0 else w = e.count or 0 end

    local n0 = #frames
    frames = collapse(frames)
    if #frames < n0 then stat.collapsed = stat.collapsed + 1 end
    local dropped, trunc, unsym
    frames, dropped, trunc, unsym = scrub(frames)
    frames = collapse(frames)     -- 归并裸地址后可能相邻，再折一次
    stat.dropped = stat.dropped + dropped * w
    stat.unsym = stat.unsym + unsym * w
    if trunc > 0 then stat.trunc = stat.trunc + 1 end

    local key = concat(frames, "\0")
    local idx = folded[key]
    if idx then
      order[idx].w = order[idx].w + w
    else
      local rec = { frames = frames, w = w }
      folded[key] = #order + 1
      order[#order + 1] = rec
    end
  end
  return stat, order, unit_ms
end

-- 把 folded 数组搭成调用树：children 保插入顺序，count 累加
local function build(folded)
  local root = { name = "all", count = 0, children = {}, cmap = {} }
  for _, rec in ipairs(folded) do
    local n = root
    root.count = root.count + rec.w
    for _, f in ipairs(rec.frames) do
      local idx = n.cmap[f]
      local c
      if idx then
        c = n.children[idx]
      else
        c = { name = f, count = 0, children = {}, cmap = {} }
        n.children[#n.children + 1] = c
        n.cmap[f] = #n.children
      end
      c.count = c.count + rec.w
      n = c
    end
  end
  return root
end

local function is_user(name)
  return (name:find(".", 1, true) and name:sub(1, 1) ~= "[") or name:sub(1, 2) == "0x"
end

-- 颜色：md5 前 32 位定色相，用户态=冷色，内核=暖色。同一函数名跨图同色
local COLcache = {}
local function color(name, user)
  local key = (user and "u" or "k") .. name
  local c = COLcache[key]
  if c then return c end
  local h = tonumber(md5hex(name):sub(1, 8), 16)
  if user then
    c = fmt("#%02x%02x%02x",
            30 + h % 40, 120 + floor(h / 2 ^ 8) % 60, 170 + floor(h / 2 ^ 16) % 60)
  else
    c = fmt("#%02x%02x%02x",
            230 + floor(h / 2 ^ 4) % 25, 150 + floor(h / 2 ^ 12) % 60, 60 + floor(h / 2 ^ 20) % 50)
  end
  COLcache[key] = c
  return c
end

-- 预序展开，顺带算好 x（子节点按权重降序，与 PNG 侧 layout 一致）
local function flatten(root)
  local nodes = {}
  local function rec(n, name, parent, depth, x0)
    local i = #nodes
    local u = (name ~= "") and is_user(name) or false
    nodes[i + 1] = { n = name, c = n.count, p = parent, d = depth, x = x0,
                     u = u, col = color(name ~= "" and name or "all", u) }
    local kids = {}
    for k, c in ipairs(n.children) do kids[k] = { c = c, i = k } end
    table.sort(kids, function(a, b)
      if a.c.count ~= b.c.count then return a.c.count > b.c.count end
      return a.i < b.i
    end)
    local cx = x0
    for _, kv in ipairs(kids) do
      rec(kv.c, kv.c.name, i, depth + 1, cx)
      cx = cx + kv.c.count
    end
    return i
  end
  rec(root, "all", -1, 0, 0)
  return nodes
end

-- 数值文案（热力图 / 排行共用）
local function fmt_w(v, unit_ms)
  if unit_ms then
    if v < 10 then return fmt("%.1f", v) .. "ms" end
    -- 上到秒级就换算，1090930ms 这种数字没人读得动
    if v >= 10000 then return fmt("%.1f", v / 1000.0) .. "s" end
    return fmt("%d", pyround(v)) .. "ms"
  end
  return fmt("%d", pyround(v))
end

-- unit_ms=true 时数字是毫秒，缩写要同时把单位标对（73k 让读者以为是次数，其实是 73s）
local function shortv(v, unit_ms)
  if unit_ms then
    if v >= 1e4 then return fmt("%.0f", v / 1e3) .. "s" end
    if v >= 1e3 then return fmt("%.1f", v / 1e3) .. "s" end
    return fmt("%.0f", v) .. "ms"
  end
  if v >= 1e6 then return fmt("%.1f", v / 1e6) .. "m" end
  if v >= 1e4 then return fmt("%.0f", v / 1e3) .. "k" end
  if v >= 1e3 then return fmt("%.1f", v / 1e3) .. "k" end
  return fmt("%.0f", v)
end

-- 按像素宽度截断（ASCII 约 0.6em/字，CJK 1.0em）；超宽补一个 …
local function clip(name, px, font_px)
  local w, out = 0, {}
  for cp, ch in u8iter(name) do
    local cw = font_px * ((cp > 0x2E80) and 1.0 or 0.6)
    if w + cw > px then
      out[#out + 1] = "…"
      return concat(out)
    end
    w = w + cw
    out[#out + 1] = ch
  end
  return concat(out)
end

-- 排行版裁字：ASCII 约 0.55em，CJK 1em；没超宽就原样返回
local function fit(t, px, fs)
  local w, out = 0, {}
  for cp, ch in u8iter(t) do
    local cw = (cp > 0x2E80) and fs or fs * 0.55
    if w + cw > px then return concat(out) .. "…" end
    w = w + cw
    out[#out + 1] = ch
  end
  return t
end

-- ===========================================================================
-- 火焰图（可交互 SVG：悬停看占比、点框放大、点空白回退）
--   静态 rect 也照写一份，丢了 JS 的查看器（rsvg / Inkscape）仍有图看。
-- ===========================================================================
local SW, SROW, SHEAD, SFOOT, SM = 1400, 17, 96, 44, 12

local FLAME_JS = [==[

var N=__DATA__,W=__W__,H=__H__,HEAD=__HEAD__,ROW=__ROW__,FOOT=__FOOT__,M=__M__,WU=__WU__,DIV=__DIV__,DG=__DG__;
function fmt(v){v=v/DIV;var s=v.toFixed(DG);if(DG>0){s=s.replace(/\.0+$/,'')}return s}
var NS='http://www.w3.org/2000/svg',kids=[],root=0;
for(var i=0;i<N.length;i++)kids.push([]);
for(var i=1;i<N.length;i++)kids[N[i][2]].push(i);
for(var i=0;i<kids.length;i++)kids[i].sort(function(a,b){return N[b][1]-N[a][1]});
var dyn=document.getElementById('dyn'),stat=document.getElementById('stat');
var TOTAL=N[0][1];
function pct(v){return (v*100/TOTAL).toFixed(2)+'%'}
function render(){
  while(dyn.firstChild)dyn.removeChild(dyn.firstChild);
  var st0=document.getElementById('static');
  if(st0&&st0.parentNode)st0.parentNode.removeChild(st0);
  var k=(W-2*M)/N[root][1],stack=[[root,0,0]];
  while(stack.length){
    var it=stack.pop(),i=it[0],x=it[1],d=it[2],w=N[i][1]*k,y=H-FOOT-(d+1)*ROW;
    if(w>=0.7){
      var r=document.createElementNS(NS,'rect');
      r.setAttribute('x',(M+x*k).toFixed(2));
      r.setAttribute('y',y);
      r.setAttribute('width',Math.max(w-0.6,0.4).toFixed(2));
      r.setAttribute('height',ROW-1);
      r.setAttribute('fill',N[i][4]);
      r.setAttribute('class','f');
      r.setAttribute('data-i',i);
      var ti=document.createElementNS(NS,'title');
      ti.textContent=N[i][0]+'  '+fmt(N[i][1])+WU+'  '+pct(N[i][1]);
      r.appendChild(ti);
      dyn.appendChild(r);
      if(w>26){
        var ch=Math.max(1,Math.floor((w-6)/6.3)),nm=N[i][0];
        var t=document.createElementNS(NS,'text');
        t.setAttribute('x',(M+x*k+3).toFixed(2));
        t.setAttribute('y',y+12);
        t.textContent=nm.length>ch?nm.slice(0,ch-1)+'\u2026':nm;
        dyn.appendChild(t);
      }
    }
    var kk=kids[i],pos=[],cx=x;
    for(var j=0;j<kk.length;j++){pos.push([kk[j],cx]);cx+=N[kk[j]][1];}
    for(var j=pos.length-1;j>=0;j--)stack.push([pos[j][0],pos[j][1],d+1]);
  }
  document.getElementById('zoom').textContent=
    (root?N[root][0]:'全部')+' · '+fmt(N[root][1])+WU+' · '+pct(N[root][1]);
}
dyn.addEventListener('mousemove',function(e){
  var i=e.target.getAttribute&&e.target.getAttribute('data-i');
  if(i===null||i===undefined){return}
  i=+i;
  stat.textContent=N[i][0]+'   '+fmt(N[i][1])+WU+'   '+pct(N[i][1])+
    (root?'   （占当前根 '+(N[i][1]*100/N[root][1]).toFixed(1)+'%）':'');
});
dyn.addEventListener('click',function(e){
  var i=e.target.getAttribute&&e.target.getAttribute('data-i');
  if(i===null||i===undefined)return;
  i=+i;
  if(i===root)root=0; else root=i;
  render();
});
document.getElementById('bg').addEventListener('click',function(){root=0;render();});
render();
]==]

local FSTYLE = [[<style>
rect.f{stroke:#fff;stroke-width:.5;cursor:pointer}
rect.f:hover{stroke:#111;stroke-width:1.2}
text{font-size:11px;fill:#1a1a1a;pointer-events:none}
.t{fill:#141414;font-size:19px}
.s{font-size:12.5px;fill:#5a5a5a}
.h{font-size:12.5px;fill:#0b62c4}
#stat{font-size:12.5px;fill:#b03030}
</style>
]]

-- j: engine 的 result 表；返回 (total, framedepth, path)
local function draw_flame(j, out_svg, title)
  local stat, folded, unit_ms = load(j)
  local root = build(folded)
  local nodes = flatten(root)

  local depth = 0
  for i = 1, #nodes do if nodes[i].d > depth then depth = nodes[i].d end end
  depth = depth + 1
  local H = SHEAD + depth * SROW + SFOOT
  local total = root.count
  local scale = (SW - 2 * SM) / (total ~= 0 and total or 1)
  local bottom = H - SFOOT

  local div, dg, divs
  if unit_ms and total > 100000 then div, dg, divs = 1000.0, 1, "1000.0"
  else div, dg, divs = 1, 0, "1" end

  local nfunc = (#nodes > 1) and (#nodes - 1) or 0
  local sub
  if unit_ms then
    -- div=1000 时数字已经是秒，标签必须跟着变（之前硬写 ms，141s 显示成 "141.5ms"）
    local shown = (div > 1) and fmt("%.1fs", total / div) or fmt("%.1fms", total)
    sub = fmt("阻塞 %s · 栈种类 %d · 最深 %d 层 · 权重=阻塞时长",
              shown, nfunc, depth)
  else
    local fr = j.freq
    sub = fmt("样本 %d · 栈种类 %d · 最深 %d 层 · %s",
              total, nfunc, depth, fr and (fmt("%d", fr) .. "Hz") or "-")
  end
  local bits = {}
  if (stat.collapsed or 0) > 0 then bits[#bits + 1] = fmt("%d 条栈的连续重复帧已折叠", stat.collapsed) end
  if (stat.dropped or 0) > 0 then bits[#bits + 1] = fmt("丢弃非法偏移 %d 个样本", floor(stat.dropped)) end
  if (stat.unsym or 0) > 0 then bits[#bits + 1] = fmt("%d 个裸地址已归并", floor(stat.unsym)) end
  if (stat.trunc or 0) > 0 then bits[#bits + 1] = fmt("%d 条过深栈截断至 %d 层", stat.trunc, MAXD) end
  if #bits > 0 then sub = sub .. " · " .. concat(bits, "，") end
  if j.sym then sub = sub .. fmt(" · 用户态已符号化(%d 帧命中)", j.sym_hits or 0) end

  local o = {}
  local function add(s) o[#o + 1] = s end
  add(fmt('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
          .. 'viewBox="0 0 %d %d" font-family="DejaVu Sans Mono, Menlo, monospace">',
          SW, H, SW, H))
  add(FSTYLE)
  add(fmt('<rect id="bg" x="0" y="0" width="%d" height="%d" fill="#fafaf8"/>', SW, H))
  add(fmt('<text class="t" x="%d" y="30">%s</text>', SM, xesc(title)))
  add(fmt('<text class="s" x="%d" y="56">%s</text>', SM, xesc(sub)))
  add(fmt('<text id="stat" x="%d" y="78">悬停看占比 · 点框缩放 · 点空白退回</text>', SM))
  add(fmt('<text class="h" id="zoom" x="%d" y="78" text-anchor="end">全部</text>', SW - SM))
  add('<g id="static">')
  for i = 2, #nodes do
    local n = nodes[i]
    local w = n.c * scale
    if w >= 0.7 then
      local x = SM + n.x * scale
      local y = bottom - (n.d + 1) * SROW + 1
      add(fmt('<rect class="f" x="%.2f" y="%d" width="%.2f" height="%d" fill="%s">'
              .. '<title>%s  %.0f%s  %.2f%%</title></rect>',
              x, y, (w - 0.6 > 0.4) and (w - 0.6) or 0.4, SROW - 1, n.col,
              xesc(n.n), n.c / div, (div > 1) and "s" or "", n.c * 100.0 / (total ~= 0 and total or 1)))
      if w > 26 then
        local ch = floor((w - 6) / 6.3)
        if ch < 1 then ch = 1 end
        local label = n.n
        if #label > ch then label = label:sub(1, ch - 1) .. "…" end
        add(fmt('<text x="%.2f" y="%d">%s</text>', x + 3, y + 12, xesc(label)))
      end
    end
  end
  add("</g>")
  add('<g id="dyn"></g>')
  add(fmt('<text class="s" x="%d" y="%d">lite trace_engine · 共 %d 个框 · 内核=暖色 / 用户态=冷色</text>',
          SM, H - 14, nfunc))

  -- JS 数据：[[name,count,parent,depth,color], …]
  local data = {}
  for i = 1, #nodes do
    local n = nodes[i]
    data[i] = "[" .. jstr(n.n) .. "," .. jnum(n.c) .. "," .. jnum(n.p) .. ","
              .. jnum(n.d) .. "," .. jstr(n.col) .. "]"
  end
  local wu = jstr(unit_ms and ((div > 1) and " s" or " ms") or " 样本")
  local reps = {
    __DATA__ = "[" .. concat(data, ",") .. "]",
    __W__ = fmt("%d", SW), __H__ = fmt("%d", H),
    __HEAD__ = fmt("%d", SHEAD), __ROW__ = fmt("%d", SROW),
    __FOOT__ = fmt("%d", SFOOT), __M__ = fmt("%d", SM),
    __WU__ = wu, __DIV__ = divs, __DG__ = fmt("%d", dg),
  }
  local js = FLAME_JS:gsub("__%u+__", function(k) return reps[k] or k end)
  add("<script><![CDATA[" .. js .. "]]></script>")
  add("</svg>")

  local f = assert(io.open(out_svg, "wb"))
  f:write(concat(o, "\n"))
  f:close()
  return total, nfunc, depth
end

-- ===========================================================================
-- 权重聚合：self / incl / edges 三张表（热力图与排行共用）
--   与 proto/render-py 里的 py 版同一套归一（折叠帧 + 清裸地址），结果必须能对上。
-- ===========================================================================
local function agg(folded, unit_ms)
  local self_w, incl_w, edges = {}, {}, {}
  local sord, iord, seq = {}, {}, 0        -- 首次插入序 = Python dict 序（并列时的先后）
  for i = 1, #folded do
    local frames, w = folded[i].frames, folded[i].w
    if #frames > 0 then
      local leaf = frames[#frames]
      self_w[leaf] = (self_w[leaf] or 0) + w
      if not sord[leaf] then seq = seq + 1; sord[leaf] = seq end
      local seenf = {}
      for k = 1, #frames do
        local f = frames[k]
        if not seenf[f] then
          seenf[f] = true
          incl_w[f] = (incl_w[f] or 0) + w
          if not iord[f] then seq = seq + 1; iord[f] = seq end
        end
      end
      local seen = {}                       -- 同一栈里的递归对只算一次，避免自乘
      for k = 1, #frames - 1 do
        local key = frames[k] .. "\0" .. frames[k + 1]
        if not seen[key] then
          seen[key] = true
          edges[key] = (edges[key] or 0) + w
        end
      end
    end
  end
  return unit_ms, self_w, incl_w, edges, sord, iord
end

local function ekey(a, b) return a .. "\0" .. b end

-- 按权重降序；并列时按名字定序（Python 侧受 dict 迭代顺序影响，本身不稳定）
local function rank_of(w, ord)
  local r = {}
  for f, v in pairs(w) do r[#r + 1] = { f, v } end
  table.sort(r, function(a, b)
    if a[2] ~= b[2] then return a[2] > b[2] end
    local oa = (ord and ord[a[1]]) or 0
    local ob = (ord and ord[b[1]]) or 0
    if oa ~= ob then return oa < ob end
    return a[1] < b[1]
  end)
  return r
end

-- ===========================================================================
-- 热力图：行=调用者，列=被调用者，格色=该调用边的权重（log 色阶）
-- ===========================================================================
local HCELL, HRANKW, HNAMEW, HPAD, HHEAD, HTOPEDGE = 26, 400, 300, 14, 96, 8

local HSTOPS = { { 251, 250, 246 }, { 254, 224, 144 }, { 253, 174, 97 },
                 { 244, 109, 67 }, { 178, 24, 43 } }

-- t in [0,1] -> OrRd 顺序色
local function hcolor(t)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local x = t * (#HSTOPS - 1)
  local i = floor(x)
  if i > #HSTOPS - 2 then i = #HSTOPS - 2 end
  local f = x - i
  local a, b = HSTOPS[i + 1], HSTOPS[i + 2]
  return fmt("#%02x%02x%02x", floor(a[1] + (b[1] - a[1]) * f),
             floor(a[2] + (b[2] - a[2]) * f), floor(a[3] + (b[3] - a[3]) * f))
end

local function heat_geom(rank, edges, topn)
  local funcs = {}
  for i = 1, math.min(topn, #rank) do funcs[i] = rank[i][1] end
  local N = #funcs
  local mx = 0
  for i = 1, N do
    for j = 1, N do
      local v = edges[ekey(funcs[i], funcs[j])]
      if v and v > mx then mx = v end
    end
  end
  if mx <= 0 then mx = 1 end
  local MW = N * HCELL
  local W = HPAD + HRANKW + 26 + HNAMEW + MW + 60
  local H = HHEAD + 40 + MW + 26 + 15 * HTOPEDGE + 40
  return funcs, N, mx, MW, W, H
end

-- 返回 (tot, N, mx)：给上层打日志用
local function draw_heat(j, out_svg, title, topn)
  local _, folded, unit_ms = load(j)
  local _, self_w, incl_w, edges, _, iord = agg(folded, unit_ms)
  local rank = rank_of(incl_w, iord)
  if #rank == 0 then return nil, "没有栈数据" end
  topn = topn or 24
  local funcs, N, mx, MW, W, H = heat_geom(rank, edges, topn)
  local idx = {}
  for i = 1, N do idx[funcs[i]] = true end
  -- 分母必须是「采样点/阻塞总权重」，不能是 incl_w 求和：包含权重沿调用链层层累加，
  -- 求和会把 141.5s 放大成 1090930ms（八倍），所有百分比跟着失真
  local tot = 0
  for i = 1, #folded do tot = tot + folded[i].w end
  if tot == 0 then
    for _, v in pairs(incl_w) do tot = tot + v end
  end
  if tot == 0 then tot = 1 end

  local o = {}
  local function add(s) o[#o + 1] = s end
  add('<?xml version="1.0" encoding="UTF-8"?>')
  add(fmt('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
          .. 'font-family="Noto Sans CJK SC, DejaVu Sans Mono, monospace">', W, H, W, H))
  add('<style>rect.c:hover{stroke:#111;stroke-width:1.6}'
      .. 'text{dominant-baseline:middle}</style>')
  add(fmt('<rect width="%d" height="%d" fill="#fff"/>', W, H))
  add(fmt('<text x="%d" y="26" font-size="20" fill="#1a1a1a">%s</text>', HPAD, esc(title)))
  add(fmt('<text x="%d" y="52" font-size="12.5" fill="#5a5a5a">%s</text>', HPAD,
          esc("行 = 调用者，列 = 被调用者，格色 = 该调用边占总权重的比例（log 色阶） · "
              .. fmt("%d 个函数 · 总权重 ", N) .. fmt_w(tot, unit_ms))))

  -- ---- 左：热门函数（浅色=包含权重，深色=自身） ----
  local y = HHEAD + 6
  add(fmt('<text x="%d" y="%d" font-size="13" fill="#333">热门函数（按包含权重排名，深色为自身）</text>',
          HPAD, y - 12))
  local bw = HRANKW - 175          -- 留出右侧「自身/包含」数字列，别压到矩阵标题
  local topi = rank[1][2]
  if topi <= 0 then topi = 1 end
  for i = 1, N do
    local f = funcs[i]
    local yy = y + (i - 1) * (HCELL - 4)
    local sw, iw = self_w[f] or 0, incl_w[f] or 0
    local ww = math.max(1.0, bw * iw / topi)
    add(fmt('<rect x="%d" y="%.1f" width="%.1f" height="%d" rx="2" fill="#dfe6ee"/>',
            HPAD + 130, yy, ww, HCELL - 7))
    if sw > 0 then
      add(fmt('<rect x="%d" y="%.1f" width="%.1f" height="%d" rx="2" fill="#3f7cb5"/>',
              HPAD + 130, yy, math.max(1.0, bw * sw / topi), HCELL - 7))
    end
    add(fmt('<text x="%d" y="%.1f" font-size="11" fill="#2a2a2a" text-anchor="end">%s</text>',
            HPAD + 124, yy + (HCELL - 7) / 2.0, esc(clip(f, 122, 11))))
    add(fmt('<text x="%.1f" y="%.1f" font-size="10" fill="#666">%s / %s</text>',
            HPAD + 136 + ww, yy + (HCELL - 7) / 2.0, shortv(sw, unit_ms), shortv(iw, unit_ms)))
  end

  -- ---- 右：调用边矩阵 ----
  local x0 = HPAD + HRANKW + 26 + HNAMEW
  local y0 = HHEAD + 40
  add(fmt('<text x="%d" y="%d" font-size="13" fill="#333">调用边热力矩阵</text>', x0 - HNAMEW, y0 - 18))
  for jx = 1, N do                   -- 列标签旋转
    local f = funcs[jx]
    local cx = x0 + (jx - 1) * HCELL + HCELL / 2.0 + 2
    add(fmt('<text x="%.1f" y="%d" font-size="10.5" fill="#333" transform="rotate(-62 %.1f %d)" '
            .. 'text-anchor="start">%s</text>', cx, y0 - 6, cx, y0 - 6, esc(clip(f, 112, 10.5))))
  end
  for iy = 1, N do                   -- 行标签
    local f = funcs[iy]
    add(fmt('<text x="%d" y="%.1f" font-size="10.5" fill="#2a2a2a" text-anchor="end">%s</text>',
            x0 - 6, y0 + (iy - 1) * HCELL + HCELL / 2.0, esc(clip(f, HNAMEW - 10, 10.5))))
  end
  local lm = log1p(mx)
  for iy = 1, N do
    local a = funcs[iy]
    for jx = 1, N do
      local b = funcs[jx]
      local v = edges[ekey(a, b)] or 0
      local diag = (a == b)
      local fill
      if v <= 0 then
        fill = diag and "#eef1f4" or "#f7f8fa"
      else
        fill = hcolor(log1p(v) / lm)
      end
      add(fmt('<rect class="c" data-r="%d" data-c="%d" x="%d" y="%d" width="%d" height="%d" '
              .. 'fill="%s" stroke="#fff" stroke-width="0.8"><title>%s → %s&#10;%s · 占全部 %.2f%%</title></rect>',
              jx - 1, iy - 1, x0 + (jx - 1) * HCELL, y0 + (iy - 1) * HCELL, HCELL - 1, HCELL - 1, fill,
              esc(a), esc(b), fmt_w(v, unit_ms), 100.0 * v / tot))
      if v > 0 and log1p(v) / lm > 0.62 then
        add(fmt('<text x="%.1f" y="%.1f" font-size="8.5" fill="#fff" text-anchor="middle" '
                .. 'pointer-events="none">%s</text>',
                x0 + (jx - 1) * HCELL + HCELL / 2.0, y0 + (iy - 1) * HCELL + HCELL / 2.0,
                shortv(v, unit_ms)))
      end
    end
  end
  local side = MW - (N - 1)
  add(fmt('<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="#c8ced8"/>',
          x0, y0, side, side))

  -- ---- 最热调用边 ----
  local ly = y0 + MW + 34
  add(fmt('<text x="%d" y="%d" font-size="13" fill="#333">最热调用边</text>', HPAD, ly - 12))
  local hot = {}
  for k, v in pairs(edges) do
    local a, b = k:match("^(.-)%z(.*)$")
    if a and idx[a] and idx[b] then hot[#hot + 1] = { a, b, v } end
  end
  table.sort(hot, function(x, y2)
    if x[3] ~= y2[3] then return x[3] > y2[3] end
    if x[1] ~= y2[1] then return x[1] < y2[1] end
    return x[2] < y2[2]
  end)
  for i = 1, math.min(HTOPEDGE, #hot) do
    local a, b, v = hot[i][1], hot[i][2], hot[i][3]
    local yy = ly + (i - 1) * 15
    add(fmt('<rect x="%d" y="%d" width="6" height="10" rx="1" fill="%s"/>',
            HPAD, yy - 5, hcolor(log1p(v) / lm)))
    add(fmt('<text x="%d" y="%d" font-size="11" fill="#333">%s  →  %s</text>',
            HPAD + 12, yy, esc(clip(a, 150, 11)), esc(clip(b, 150, 11))))
    add(fmt('<text x="%d" y="%d" font-size="10.5" fill="#666">%s · %.2f%%</text>',
            HPAD + 340, yy, fmt_w(v, unit_ms), 100.0 * v / tot))
  end

  -- ---- 图例 ----
  local gx, gy, gw = W - 300, H - 46, 200
  for k = 0, 99 do
    add(fmt('<rect x="%.1f" y="%d" width="%.1f" height="12" fill="%s"/>',
            gx + gw * k / 100.0, gy, gw / 100.0 + 0.4, hcolor(k / 99.0)))
  end
  add(fmt('<text x="%d" y="%d" font-size="10" fill="#666">低</text>', gx, gy + 26))
  add(fmt('<text x="%d" y="%d" font-size="10" fill="#666" text-anchor="end">高 %s</text>',
          gx + gw, gy + 26, fmt_w(mx, unit_ms)))
  add(fmt('<text x="%d" y="%d" font-size="11" fill="#888">trace_engine · 色阶按 log(1+w) 归一</text>',
          HPAD, H - 22))

  -- 悬停：同行同列高亮，其余压暗
  add('<script><![CDATA['
      .. 'var cs=[].slice.call(document.querySelectorAll("rect.c"));'
      .. 'document.addEventListener("mouseover",function(e){var t=e.target;'
      .. 'if(!t.getAttribute)return;var r=t.getAttribute("data-r");'
      .. 'if(r===null||r===undefined)return;var c=t.getAttribute("data-c");'
      .. 'cs.forEach(function(x){x.setAttribute("opacity",'
      .. '(x.getAttribute("data-r")===r||x.getAttribute("data-c")===c)?"1":"0.25")})});'
      .. 'document.addEventListener("mouseout",function(){'
      .. 'cs.forEach(function(x){x.setAttribute("opacity","1")})});'
      .. ']]></script>')
  add('</svg>')

  local fh = assert(io.open(out_svg, "wb"))
  fh:write(concat(o, "\n"))
  fh:close()
  return tot, N, mx
end

-- ===========================================================================
-- 卡点排行：按自身/包含/命中排序，顶部一句话说清卡在哪
-- ===========================================================================
local RPAD, RROW, RTOPH, RNAMEW, RBARW, RW = 16, 27, 168, 250, 300, 940
local X_TAG, X_NAME = RPAD + 30, RPAD + 100
local X_BAR = X_NAME + RNAMEW
local X_SELF = X_BAR + RBARW + 46
local X_INCL = X_BAR + RBARW + 104
local X_HIT  = X_BAR + RBARW + 158
local X_CUM  = X_BAR + RBARW + 212

-- ms 值超过 1s 就换秒，否则「4430ms」会把命中列挤爆
local function rnum(v, unit_ms)
  if unit_ms and v >= 1000 then return fmt("%.1fs", v / 1000.0) end
  return fmt_w(v, unit_ms)
end

-- 每个函数出现在多少种不同调用栈里
local function stacks_of(folded)
  local c = {}
  for i = 1, #folded do
    local frames, seen = folded[i].frames, {}
    for k = 1, #frames do
      local f = frames[k]
      if not seen[f] then
        seen[f] = true
        c[f] = (c[f] or 0) + 1
      end
    end
  end
  return c
end

-- 已采总量 vs 列出的折叠栈总量：--limit 会截断，结论必须说清覆盖多少
local function coverage(j, tot)
  local got
  if j.unit == "ms" then
    -- ms 模式下 j.blocked 是「阻塞事件个数」，和 tot（毫秒）混算会得出 3357% 这种鬼话；
    -- 真分母是全部阻塞时长 = 事件数 × 平均时长（overall 来自完整事件集，不受 --limit 影响）
    local o = j.overall
    if o and o.count and o.avg_us then got = o.count * o.avg_us / 1000.0 end
  else
    got = j.events
  end
  got = got or tot
  if got == 0 then got = nil end
  if got and tot > got then got = tot end
  return got or tot, (got and got ~= 0) and (100.0 * tot / got) or 100.0
end

-- 最重的那条栈 = 权重真正堆住的完整路径
local function trail(folded)
  if #folded == 0 then return {}, 0 end
  local best = folded[1]
  for i = 2, #folded do
    if folded[i].w > best.w then best = folded[i] end
  end
  return best.frames, best.w
end

local function rverdict(j, unit_ms, self_w, incl_w, tot, folded, sord, iord)
  local top_self, vself = "-", 1
  local rs, ri = rank_of(self_w, sord), rank_of(incl_w, iord)
  if #rs > 0 then top_self, vself = rs[1][1], rs[1][2] end
  local top_incl, vincl = "-", 1
  if #ri > 0 then top_incl, vincl = ri[1][1], ri[1][2] end
  local got, cov = coverage(j, tot)
  local u = unit_ms and "" or " 样本"
  local head = fmt("最热卡点 %s：自身 %s%s，占已列栈 %.1f%%",
                   fit(top_self, 330, 13.5), rnum(vself, unit_ms), u, 100.0 * vself / tot)
  if top_incl ~= top_self and (vincl - (self_w[top_incl] or 0)) > 0.12 * tot then
    if vincl > 0.85 * tot and (self_w[top_incl] or 0) < 0.10 * tot then
      head = head .. fmt("；%s 吃掉 %.0f%% 的包含权重但自身极少——它是全栈共同入口，不是热点",
                         fit(top_incl, 190, 13.5), 100.0 * vincl / tot)
    else
      head = head .. fmt("；%s 含下游 %s，重心在它下面",
                         fit(top_incl, 210, 13.5), rnum(vincl, unit_ms))
    end
  end
  local path, pw = trail(folded)
  return head, 100.0 * vself / tot, path, pw, top_self, got, cov
end

local function tag_of(f, self_w, incl_w)
  local s, i = self_w[f] or 0, incl_w[f] or 0
  if i == 0 then i = 1 end
  local r = s / i
  if r >= 0.5 then return "自热", "#b2182b" end
  if r <= 0.02 then return "纯转发", "#969696" end
  return "混合", "#3f7cb5"
end

local function rows_of(self_w, incl_w, stk, sortkey, topn, sord, iord)
  local out = {}
  if sortkey == "count" then
    local pool = {}
    for f in pairs(stk) do pool[#pool + 1] = f end
    table.sort(pool, function(a, b)
      local sa, sb = self_w[a] or 0, self_w[b] or 0
      if sa ~= sb then return sa > sb end
      if stk[a] ~= stk[b] then return stk[a] > stk[b] end
      return a < b
    end)
    for _, f in ipairs(pool) do
      if (self_w[f] or 0) > 0 then out[#out + 1] = f end
    end
    if #out < topn then
      local rest = rank_of(self_w, sord)
      local has = {}
      for _, f in ipairs(out) do has[f] = true end
      for _, r in ipairs(rest) do
        if not has[r[1]] then out[#out + 1] = r[1] end
      end
    end
    local cut = {}
    for i = 1, math.min(topn, #out) do cut[i] = out[i] end
    return cut
  end
  local keys = (sortkey == "incl") and rank_of(incl_w, iord) or rank_of(self_w, sord)
  for i = 1, math.min(topn, #keys) do out[i] = keys[i][1] end
  return out
end

-- 底部要留够：每条红色提示一行 15px + 页脚一行 16px + 边距，
-- 否则两条提示会压到页脚上（之前只按一行提示算，2 条时重叠）
local function rgeom(n, nnotes)
  if n < 1 then n = 1 end
  if nnotes < 1 then nnotes = 1 end
  return RTOPH + 26 + n * RROW + 34 + nnotes * 15
end

local SORTNAME = { self = "自身权重", incl = "含下游", count = "命中次数" }

local function rsubtitle(sortkey, n, tot, unit_ms)
  return fmt("排序 = %s · %d 个函数 · 已列权重 %s · 深色条=自身，浅色条=含下游",
             SORTNAME[sortkey] or SORTNAME.self, n, rnum(tot, unit_ms))
end

-- 底部提示：数据被截断 / 大量未符号化，这两个不说清结论就是错的
local function rnotes(j, folded, cov, got, unit_ms)
  local out = {}
  if cov < 99.5 then
    out[#out + 1] = fmt("top[] 只收 %s / 共 %s（--limit 截断，覆盖 %.0f%%），调大 --limit 再排更准",
                        rnum(got * cov / 100.0, unit_ms), rnum(got, unit_ms), cov)
  end
  local n, raw = 0, 0
  for i = 1, #folded do
    local frames = folded[i].frames
    n = n + #frames
    for k = 1, #frames do
      local x = frames[k]
      if x:find("+0x", 1, true) or x:sub(1, 2) == "0x" then raw = raw + 1 end
    end
  end
  if n == 0 then n = 1 end
  if raw * 2 > n then
    out[#out + 1] = "超半数帧是裸偏移（无符号），加 --sym 或给 pid 对应 ELF 才能看出函数名"
  end
  return out
end

local function draw_rank(j, out_svg, title, topn, sortkey)
  local _, folded, unit_ms = load(j)
  if #folded == 0 then return nil, "没有栈数据" end
  topn = topn or 18
  if sortkey ~= "self" and sortkey ~= "incl" and sortkey ~= "count" then sortkey = "self" end
  local _, self_w, incl_w, _, sord, iord = agg(folded, unit_ms)
  local tot = 0
  for _, v in pairs(self_w) do tot = tot + v end
  if tot == 0 then tot = 1 end
  local stk = stacks_of(folded)
  local rows = rows_of(self_w, incl_w, stk, sortkey, topn, sord, iord)
  local head, _, path, _, _, got, cov = rverdict(j, unit_ms, self_w, incl_w, tot, folded, sord, iord)
  local nts = rnotes(j, folded, cov, got, unit_ms)
  local H = rgeom(#rows, #nts)
  local mx = 0
  for _, r in ipairs(rows) do
    local v = incl_w[r] or 0
    if v > mx then mx = v end
  end
  if mx <= 0 then mx = 1 end

  local o = {}
  local function add(s) o[#o + 1] = s end
  add('<?xml version="1.0" encoding="UTF-8"?>')
  add(fmt('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
          .. 'font-family="Noto Sans CJK SC, DejaVu Sans Mono, monospace">', RW, H, RW, H))
  add('<style>text{dominant-baseline:middle}.row:hover{opacity:.82}</style>')
  add(fmt('<rect width="%d" height="%d" fill="#fff"/>', RW, H))
  add(fmt('<text x="%d" y="30" font-size="21" fill="#161616">%s</text>', RPAD, esc(title)))
  add(fmt('<text x="%d" y="58" font-size="12.5" fill="#5c5c5c">%s</text>', RPAD,
          esc(rsubtitle(sortkey, #rank_of(incl_w, iord), tot, unit_ms))))
  add(fmt('<rect x="%d" y="76" width="%d" height="62" rx="4" fill="#f4f7fb" stroke="#dbe4ee"/>',
          RPAD, RW - 2 * RPAD))
  add(fmt('<rect x="%d" y="76" width="5" height="62" fill="#b2182b"/>', RPAD))
  add(fmt('<text x="%d" y="99" font-size="13.5" fill="#1f3d5c">%s</text>', RPAD + 16, esc(head)))
  local chain = "-"
  if #path > 0 then
    local from = #path - 5
    if from < 1 then from = 1 end
    local seg = {}
    for i = from, #path do seg[#seg + 1] = path[i] end
    chain = concat(seg, "  ->  ")
  end
  add(fmt('<text x="%d" y="121" font-size="12" fill="#4a4a4a">卡点链：%s</text>',
          RPAD + 16, esc(fit(chain, RW - 2 * RPAD - 90, 12))))

  local hy = RTOPH + 14
  local heads = { { X_TAG, "结论", "start" }, { X_NAME, "函数", "start" },
                  { X_BAR, "相对权重", "start" }, { X_SELF, "自身%", "end" },
                  { X_INCL, "包含%", "end" }, { X_HIT, "命中", "end" }, { X_CUM, "累计%", "end" } }
  for i = 1, #heads do
    add(fmt('<text x="%d" y="%d" font-size="11.5" fill="#6b7280" text-anchor="%s">%s</text>',
            heads[i][1], hy, heads[i][3], heads[i][2]))
  end
  add(fmt('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#e2e6ec"/>',
          RPAD, hy + 10, RW - RPAD, hy + 10))

  local y0, cum = RTOPH + 26, 0.0
  for i = 1, #rows do
    local f = rows[i]
    local yy = y0 + (i - 1) * RROW
    local sw, iw = self_w[f] or 0, incl_w[f] or 0
    local pct_s, pct_i = 100.0 * sw / tot, 100.0 * iw / tot
    cum = cum + pct_s
    local tw, swd = math.max(2.0, RBARW * iw / mx), math.max(2.0, RBARW * sw / mx)
    local tg, tc = tag_of(f, self_w, incl_w)
    add(fmt('<g class="row"><title>%s&#10;自身 %s（%.1f%%）  包含 %s（%.1f%%）'
            .. '&#10;累计 %.1f%%  出现在 %d 种栈里</title>',
            esc(f), rnum(sw, unit_ms), pct_s, rnum(iw, unit_ms), pct_i,
            cum, stk[f] or 0))
    add(fmt('<rect x="%d" y="%.1f" width="%d" height="%d" fill="transparent"/>',
            RPAD, yy - 4, RW - 2 * RPAD, RROW - 4))
    add(fmt('<text x="%d" y="%.1f" font-size="11" fill="#9aa3ae">%d</text>', RPAD, yy + 8, i))
    add(fmt('<text x="%d" y="%.1f" font-size="10.5" fill="%s">%s</text>',
            X_TAG, yy + 8, tc, tg))
    add(fmt('<text x="%d" y="%.1f" font-size="11.5" fill="#22262b">%s</text>',
            X_NAME, yy + 8, esc(fit(f, RNAMEW - 10, 11.5))))
    add(fmt('<rect x="%d" y="%.1f" width="%.1f" height="13" rx="2" fill="rgb(219,228,238)"/>',
            X_BAR, yy + 1, tw))
    add(fmt('<rect x="%d" y="%.1f" width="%.1f" height="13" rx="2" fill="rgb(47,111,178)"/>',
            X_BAR, yy + 1, swd))
    add(fmt('<text x="%d" y="%.1f" font-size="11.5" fill="#1f2937" text-anchor="end" '
            .. 'font-weight="600">%.1f%%</text>', X_SELF, yy + 8, pct_s))
    local it = "·"
    if abs(pct_i - pct_s) >= 0.05 then it = fmt("%.1f%%", pct_i) end
    add(fmt('<text x="%d" y="%.1f" font-size="11" fill="%s" text-anchor="end">%s</text>',
            X_INCL, yy + 8, (it == "·") and "#c8ced6" or "#6b7280", it))
    add(fmt('<text x="%d" y="%.1f" font-size="11" fill="#4b5563" text-anchor="end">%s</text>',
            X_HIT, yy + 8, rnum(sw, unit_ms)))
    add(fmt('<text x="%d" y="%.1f" font-size="11" fill="#9aa3ae" text-anchor="end">%.1f%%</text>',
            X_CUM, yy + 8, cum))
    add('</g>')
  end

  for k = 1, #nts do
    add(fmt('<text x="%d" y="%d" font-size="10.5" fill="#b2182b">%s</text>',
            RPAD, H - 28 - (#nts - k) * 15, esc(fit(nts[k], RW - 2 * RPAD, 10.5))))
  end
  add(fmt('<text x="%d" y="%d" font-size="11" fill="#8a8f98">trace_engine · 自身=采样点落在此函数，'
          .. '包含=含下游 · 采样模式命中=样本数或毫秒，folded 模式=真实调用次数</text>', RPAD, H - 16))
  add('</svg>')

  local fh = assert(io.open(out_svg, "wb"))
  fh:write(concat(o, "\n"))
  fh:close()
  return #rows, #nts, cov
end

-- ===========================================================================
-- 对外入口：M.render(kind, j, out_svg, title, opts)
--   kind = "flame" | "heat" | "rank"
--   opts = { heat_top = N, rank_top = N, rank_by = "self|incl|count" }
-- 返回 (ok, detail)：ok=nil 时 detail 是错误文案
-- ===========================================================================
function M.render(kind, j, out_svg, title, opts)
  opts = opts or {}
  title = title or "trace"
  if kind == "flame" then
    local total, nfunc, depth = draw_flame(j, out_svg, title)
    if not total then return nil, nfunc or "渲染失败" end
    return true, { total = total, nfunc = nfunc, depth = depth }
  elseif kind == "heat" then
    local tot, n, mx = draw_heat(j, out_svg, title, opts.heat_top)
    if not tot then return nil, n end
    return true, { total = tot, nfunc = n, max = mx }
  elseif kind == "rank" then
    local n, nnotes, cov = draw_rank(j, out_svg, title, opts.rank_top, opts.rank_by)
    if not n then return nil, nnotes end
    return true, { rows = n, notes = nnotes, coverage = cov }
  end
  return nil, "未知图类型: " .. tostring(kind)
end

M.kinds = { flame = true, heat = true, rank = true }

-- 独立跑（调试用）：luajit tools/render.lua <kind> in.json out.svg "标题" [topN] [sortkey]
--   require 它（或 dofile 后取 M）时不会走这里
if arg and arg[1] and M.kinds[arg[1]] and arg[2] and arg[3] then
  local kind, src, out = arg[1], arg[2], arg[3]
  local title = arg[4] or "trace"
  local fh = assert(io.open(src, "rb"))
  local body = fh:read("*a")
  fh:close()
  local j = require("cjson").decode(body)
  local topn = tonumber(arg[5])
  local opts = { heat_top = topn, rank_top = topn, rank_by = arg[6] }
  local ok, detail = M.render(kind, j, out, title, opts)
  if not ok then
    io.stderr:write("[render] " .. tostring(detail) .. "\n")
    os.exit(1)
  end
  if kind == "heat" then
    io.stderr:write(fmt("[render] %s · %d 个函数 · 总权重 %s\n", out, detail.nfunc,
                        fmt_w(detail.total, j.unit == "ms")))
  elseif kind == "rank" then
    io.stderr:write(fmt("[render] %s · %d 行 · 覆盖 %.0f%%\n", out, detail.rows, detail.coverage))
  else
    io.stderr:write(fmt("[render] %s · %d 个框 · 深度 %d\n", out, detail.nfunc, detail.depth))
  end
  return M
end

return M
