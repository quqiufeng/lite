-- lua/gui/view.lua — SDL2 窗口 + 主题 + 行纹理缓存
-- 只做"画":排版(折行/列数)在此,内容由 transcript.lua 提供 span 列表。
-- 铁律:不用 PRESENTVSYNC(approval 等待会冻结),节奏靠 SDL_Delay。

local ffi = require("ffi")
local sdl = require("ffi.sdl2")
local ttf = require("ffi.sdl2_ttf")
local theme = require("gui.theme")

local WIN_EXTRA = 200  -- 默认窗口 = 桌面一半 + 200px(宽高各加)
local M = {}

-- 7 套语义调色板里的默认款(dark):高级感来自配色 + 行距,不是来自字符网格
M.palette = {
  bg      = {22, 24, 29},
  panel   = {30, 33, 40},
  line    = {48, 52, 62},
  text    = {214, 218, 226},
  muted   = {124, 132, 148},
  ink     = {150, 200, 235},   -- assistant 名/强调
  accent  = {222, 178, 108},   -- 用户 ❯ / 标题
  ok      = {126, 200, 140},
  warn    = {226, 186, 96},
  err     = {230, 118, 118},
  sel     = {58, 74, 104},
  add     = {46, 82, 58},      -- diff +
  del     = {86, 46, 50},      -- diff -
}

-- 语义样式 -> 调色板键 + 可选背景
M.styles = {
  text = {"text"},
  muted = {"muted"},
  ink = {"ink"},
  accent = {"accent"},
  ok = {"ok"},
  warn = {"warn"},
  err = {"err"},
  title = {"accent"},
  user = {"accent"},
  tool = {"ink"},
  add = {"ok", "add"},
  del = {"err", "del"},
  code = {"muted"},
  sel = {"text", "sel"},
}

-- 字体只走系统:Noto Sans CJK SC。仓耳今楷在 22px 下细笔必然发虚(实心像素 16%),
-- 已弃用(assets/ 里的 37MB ttf 删除)。LITE_GUI_FONT 可覆盖。
local HOME = os.getenv("HOME") or ""
-- 每项 {路径, ttc 子字体序号};正文用 Noto Sans CJK SC(笔画实、字形稳),
-- ttc 里 SC 在 index 2(fc-match -f "%{file}:%{index}" "Noto Sans CJK SC")。
local FONT_CANDIDATES = {
  { "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", 2 },
  { "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc", 0 },
  { "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 0 },
}

local BOLD_CANDIDATES = {
  { "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc", 2 },
}

-- 等宽体(代码/tool 行):Maple Mono NF CN 带连字 + Nerd 图标,
-- 只缺全角 ／(U+FF0F),代码里罕见;LITE_GUI_FONT_MONO 可覆盖。
local MONO_CANDIDATES = {
  { HOME .. "/.local/share/fonts/MapleMono/MapleMono-NF-CN-Regular.ttf", 0 },
  { "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf", 0 },
  { "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 0 },
  { "/usr/share/fonts/truetype/hack/Hack-Regular.ttf", 0 },
}

-- 返回 path, index(index 缺省 0 = 单字体文件)
local function find_font(bold)
  local env = os.getenv(bold and "LITE_GUI_FONT_BOLD" or "LITE_GUI_FONT")
  if env and env ~= "" then
    local f = io.open(env, "rb")
    if f then f:close(); return env, 0 end
  end
  for _, c in ipairs(bold and BOLD_CANDIDATES or FONT_CANDIDATES) do
    local f = io.open(c[1], "rb")
    if f then f:close(); return c[1], c[2] or 0 end
  end
end

local function find_mono()
  local env = os.getenv("LITE_GUI_FONT_MONO")
  if env and env ~= "" then
    local f = io.open(env, "rb")
    if f then f:close(); return env, 0 end
  end
  for _, c in ipairs(MONO_CANDIDATES) do
    local f = io.open(c[1], "rb")
    if f then f:close(); return c[1], c[2] or 0 end
  end
end

-- wcwidth 近似:东亚宽字符/emoji 占 2 列
local function is_wide(cp)
  if cp < 0x20 then return false end
  if cp >= 0x1100 and cp <= 0x115F then return true end
  if cp >= 0x2E80 and cp <= 0xA4CF then return true end
  if cp >= 0xAC00 and cp <= 0xD7A3 then return true end
  if cp >= 0xF900 and cp <= 0xFAFF then return true end
  if cp >= 0xFE30 and cp <= 0xFE6F then return true end
  if cp >= 0xFF00 and cp <= 0xFF60 then return true end
  if cp >= 0xFFE0 and cp <= 0xFFE6 then return true end
  if cp >= 0x1F300 and cp <= 0x1FAFF then return true end
  return false
end
M.is_wide = is_wide

-- LuaJIT 没有 utf8 库,手工解 UTF-8:返回 cp,起始字节,字节数,下一位置
local function next_cp(s, i)
  local n = #s
  if i > n then return nil end
  local b = s:byte(i)
  local len, cp
  if b < 0x80 then len, cp = 1, b
  elseif b < 0xC0 then return b, i, 1, i + 1          -- 坏字节,当单字节吃
  elseif b < 0xE0 then len, cp = 2, b - 0xC0
  elseif b < 0xF0 then len, cp = 3, b - 0xE0
  else len, cp = 4, b - 0xF0 end
  if i + len - 1 > n then return b, i, 1, i + 1 end
  for k = 1, len - 1 do
    local c = s:byte(i + k)
    if c < 0x80 or c > 0xBF then return b, i, 1, i + 1 end
    cp = cp * 64 + (c - 0x80)
  end
  return cp, i, len, i + len
end
M.next_cp = next_cp

local function utf8_chars(s)
  local out, i = {}, 1
  while true do
    local cp, _, _, nxt = next_cp(s, i)
    if not cp then break end
    out[#out + 1] = cp
    i = nxt
  end
  return out
end
M.chars = utf8_chars

function M.display_width(s)
  local w, i = 0, 1
  while true do
    local cp, _, _, nxt = next_cp(s, i)
    if not cp then break end
    w = w + (is_wide(cp) and 2 or 1)
    i = nxt
  end
  return w
end

local View = {}
View.__index = View

function M.open(opts)
  opts = opts or {}
  if not sdl.init() then return nil, "SDL_Init failed" end
  sdl.set_hint("SDL_RENDER_SCALE_QUALITY", "1")   -- 线性缩放,避免整行纹理拉伸发虚
  if not ttf.init() then return nil, "TTF_Init failed" end

  local font_path, font_index = find_font()
  if opts.font then font_path, font_index = opts.font, opts.font_index or 0 end
  if not font_path then return nil, "no font found" end
  local size = opts.size or 22   -- reader 同款字号
  local font = ttf.open(font_path, size, font_index)
  if font == nil then return nil, "cannot open font: " .. font_path end
  -- 粗体字体:找不到就退回正文(颜色仍能区分 head)
  local bold_path, bold_index = find_font(true)
  if opts.font_bold then bold_path, bold_index = opts.font_bold, opts.font_bold_index or 0 end
  bold_path, bold_index = bold_path or font_path, bold_index or font_index
  local font_bold = ttf.open(bold_path, size, bold_index) or font
  -- 等宽体:找不到就退回正文(代码行只是字距不同,不至于崩)
  local mono_path, mono_index = find_mono()
  if opts.font_mono then mono_path, mono_index = opts.font_mono, opts.font_mono_index or 0 end
  -- 等宽体比正文小一号(0.86):代码信息密度高,同号会显臃肿
  local mono_size = opts.mono_size or math.max(10, math.floor(size * (opts.mono_scale or 0.72) + 0.5))
  local font_mono = mono_path and ttf.open(mono_path, mono_size, mono_index) or font
  -- Noto Sans 自带实心笔画,hinting 用默认(NORMAL)最干净;MONO 会横向挤粗
  ttf.hinting(font, opts.hinting or 0)
  ttf.hinting(font_bold, opts.hinting or 0)
  ttf.hinting(font_mono, opts.hinting or 0)

  -- 窗口默认占显示器一半再各加 WIN_EXTRA(居中由 SDL_WINDOWPOS_CENTERED 负责)
  local dw, dh = sdl.desktop_size()
  local w, h
  if dw and dh then w, h = math.floor(dw / 2) + WIN_EXTRA, math.floor(dh / 2) + WIN_EXTRA
  else w, h = 1200, 840 end
  w, h = opts.w or w, opts.h or h
  local win = sdl.create_window(opts.title or "lite", w, h)
  if win == nil then return nil, "SDL_CreateWindow failed" end
  local ren = sdl.create_renderer(win)   -- ACCELERATED,无 VSYNC
  if ren == nil then return nil, "SDL_CreateRenderer failed" end

  local v = setmetatable({
    win = win, ren = ren, font = font, font_bold = font_bold, font_mono = font_mono,
    font_path = font_path, bold_path = bold_path, mono_path = mono_path,
    font_size = size, mono_size = mono_size,
    w = w, h = h, palette = M.palette, styles = M.styles,
    cache = {}, ncache = 0, maxcache = 600,
    line_gap = opts.line_gap or 0,
    line_factor = opts.line_factor or 1.55,
    pad_x = opts.pad_x or 48, pad_y = opts.pad_y or 30,
    weight = opts.weight or 1.25,  -- alpha 增益:边缘提实过头会显粗,1=关
    drew = false,
  }, View)

  local cw, ch = ttf.size(font, "M")
  v.cell_w = opts.cell_w or cw
  v.line_h = opts.line_h or math.floor(size * v.line_factor + 0.5) + v.line_gap
  -- 折行按真实像素宽度,不用列数(全角 15px vs 半角 11px,列数会溢出)
  v.narrow_w = cw > 0 and cw or 10
  local ww = ttf.size(font, "中")
  v.wide_w = ww > 0 and ww or (v.narrow_w * 2)
  -- 粗体(W05)字宽更宽,折行按对应字重度取样,否则末字溢出卡片
  local cwb = ttf.size(font_bold, "M")
  v.narrow_wb = cwb > 0 and cwb or v.narrow_w
  local wwb = ttf.size(font_bold, "中")
  v.wide_wb = wwb > 0 and wwb or (v.narrow_wb * 2)
  v.text_h = ch
  -- 等宽体宽度:ASCII 全同宽,东亚宽字符另算
  local mw = ttf.size(font_mono, "M")
  v.narrow_wm = mw > 0 and mw or v.narrow_w
  local mww = ttf.size(font_mono, "中")
  v.wide_wm = mww > 0 and mww or (v.narrow_wm * 2)
  v:sync()
  v:apply_theme(opts.theme or theme.DEFAULT)
  if sdl.start_text_input then sdl.start_text_input() end  -- 开 IME:中文要真字符事件
  return v
end

function View:size()
  local ow, oh = sdl.get_renderer_output_size(self.ren)
  if ow and ow > 0 then self.w, self.h = ow, oh end
  return self.w, self.h
end

function View:sync()
  self:size()
  self.text_w = math.max(80, self.w - self.pad_x * 2)
  self.cols = math.max(20, math.floor(self.text_w / self.cell_w))
  self.rows = math.max(4, math.floor((self.h - self.pad_y * 2) / self.line_h))
  return self.cols, self.rows
end

function View:color(name)
  -- 调色板直出名(panel/line/bg/shadow)优先:它们不是语义样式,别回退成正文色
  if self.palette[name] and not self.styles[name] then return self.palette[name] end
  local st = self.styles[name] or self.styles.text
  return self.palette[st[1]] or self.palette.text, st[2] and self.palette[st[2]]
end

-- 行纹理缓存:整行一次 render_texture,绝不逐字画点
function View:tex(text, style, bold, mono)
  local key = (style or "text") .. (bold and "\2b" or "\2n")
    .. (mono and "\2m" or "\2p") .. "\1" .. text
  local e = self.cache[key]
  if e then return e.tex, e.w, e.h end
  local fg = self:color(style)
  local font = mono and self.font_mono or ((bold and self.font_bold) or self.font)
  local tex = ttf.render_texture(self.ren, font, text, fg[1], fg[2], fg[3], 255, self.weight)
  if tex == nil then return nil end
  local tw, th = 0, 0
  -- 纹理宽高:用 TTF_SizeUTF8 反查即可(与纹理一致),省 SDL_QueryTexture
  tw, th = ttf.size(font, text)
  if self.ncache >= self.maxcache then
    for k in pairs(self.cache) do self.cache[k] = nil end
    self.ncache = 0
  end
  self.cache[key] = {tex = tex, w = tw, h = th}
  self.ncache = self.ncache + 1
  return tex, tw, th
end

-- 折行:按真实像素宽度切(maxw 默认整个内容区宽度)
function View:wrap(text, maxw, bold, mono)
  maxw = maxw or self.text_w or (self.w - self.pad_x * 2)
  local nw = mono and self.narrow_wm or (bold and self.narrow_wb or self.narrow_w)
  local ww = mono and self.wide_wm or (bold and self.wide_wb or self.wide_w)
  local out = {}
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    if #raw == 0 then
      out[#out + 1] = ""
    else
      local curw, start, i = 0, 1, 1
      while true do
        local cp, pos, _, nxt = next_cp(raw, i)
        if not cp then break end
        local cw = is_wide(cp) and ww or nw
        if curw + cw > maxw and pos > start then
          out[#out + 1] = raw:sub(start, pos - 1)
          start, curw = pos, 0
        end
        curw = curw + cw
        i = nxt
      end
      if start <= #raw then out[#out + 1] = raw:sub(start) end
    end
  end
  return out
end

function View:begin()
  local bg = self.palette.bg
  sdl.set_draw_color(self.ren, bg[1], bg[2], bg[3], 255)
  sdl.render_clear(self.ren)
  self.drew = false
end

local rect = ffi.new("SDL_Rect")
function View:rect(x, y, w, h, name)
  local c = self:color(name)
  sdl.set_draw_color(self.ren, c[1], c[2], c[3], 255)
  rect.x, rect.y, rect.w, rect.h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
  sdl.render_fill_rect(self.ren, rect)
end

-- 画一行(不折行);返回实际宽度
function View:text(s, x, y, style, bold, mono)
  if s == nil or s == "" then return 0 end
  local font = mono and self.font_mono or ((bold and self.font_bold) or self.font)
  -- 等宽体小一号:压在行高中间,不然贴行顶显飘
  if mono and self.mono_size and self.mono_size < self.font_size then
    y = y + math.floor((self.font_size - self.mono_size) * 0.55)
  end
  local bgname = select(2, self:color(style))
  if bgname then
    local tw, th = ttf.size(font, s)
    self:rect(x - 2, y - 1, tw + 4, th + 2, bgname or style)
  end
  local tex, tw = self:tex(s, style, bold, mono)
  if tex == nil then return 0 end
  local _, th = ttf.size(font, s)
  local r = ffi.new("SDL_Rect")
  r.x = math.floor(x)
  r.y = math.floor(y + (self.line_h - th) / 2)
  r.w, r.h = tw, th
  sdl.render_copy(self.ren, tex, nil, r)
  self.drew = true
  return tw
end

-- 单行像素宽(输入框光标定位用)
function View:width(s, bold, mono)
  local font = mono and self.font_mono or ((bold and self.font_bold) or self.font)
  return ttf.size(font, s or "") or 0
end

-- 卡片:填充 + 1px 描边,可选左侧 3px 强调条
local frect = ffi.new("SDL_Rect")
function View:frame(x, y, w, h, fill, stroke, rail)
  x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
  if fill then
    -- 卡片投影:reader 的纸页层次感,2px 偏移一层淡影
    local sc = self.palette.shadow
    if sc then
      sdl.set_draw_color(self.ren, sc[1], sc[2], sc[3], 255)
      frect.x, frect.y, frect.w, frect.h = x + 2, y + 3, w, h
      sdl.render_fill_rect(self.ren, frect)
    end
    local c = self:color(fill)
    sdl.set_draw_color(self.ren, c[1], c[2], c[3], 255)
    frect.x, frect.y, frect.w, frect.h = x, y, w, h
    sdl.render_fill_rect(self.ren, frect)
  end
  if stroke then
    local c = self:color(stroke)
    sdl.set_draw_color(self.ren, c[1], c[2], c[3], 255)
    frect.x, frect.y, frect.w, frect.h = x, y, w, h
    sdl.render_draw_rect(self.ren, frect)
  end
  if rail then
    local c = self:color(rail)
    sdl.set_draw_color(self.ren, c[1], c[2], c[3], 255)
    frect.x, frect.y, frect.w, frect.h = x, y + 1, 3, h - 1
    sdl.render_fill_rect(self.ren, frect)
  end
end

-- 水平细线
function View:hrule(y, name)
  local c = self:color(name or "line")
  sdl.set_draw_color(self.ren, c[1], c[2], c[3], 255)
  frect.x, frect.y, frect.w, frect.h = 0, math.floor(y), self.w, 1
  sdl.render_fill_rect(self.ren, frect)
end

function View:apply_theme(name)
  local pal, key = theme.palette(name)
  if not pal then return end
  self.palette, self.theme = pal, key
  for k, e in pairs(self.cache) do
    if e.tex then sdl.destroy_texture(e.tex) end
    self.cache[k] = nil
  end
  self.ncache = 0
  return key
end

function View:cycle_theme(delta)
  return self:apply_theme(theme.cycle(self.theme, delta))
end

-- 截图(验收/自测用):当前帧写入 png
function View:capture(path)
  self:size()
  return sdl.capture(self.ren, self.w, self.h, path)
end

function View:present()
  sdl.render_present(self.ren)
end

function View:delay(ms)
  sdl.delay(ms)
end

-- 事件泵;返回 "quit" / "resize" / "text"/"key" 事件表 / nil
local last_w, last_h = 0, 0
function View:poll()
  local ev = ffi.new("SDL_Event[1]")
  while sdl.poll_event(ev) ~= 0 do
    local t = ev[0].type
    if t == 0x100 then
      return "quit"
    elseif t == 0x200 then
      local nw, nh = self:sync()
      if nw ~= last_w or nh ~= last_h then
        last_w, last_h = nw, nh
        return "resize"
      end
    elseif t == 0x300 then          -- SDL_KEYDOWN
      local k = ev[0].key
      return { kind = "key", key = k.sym, mod = k.mod, repeat_n = k["repeat"] }
    elseif t == 0x303 then          -- SDL_TEXTINPUT(IME 真字符)
      return { kind = "text", text = ffi.string(ev[0].text.text) }
    elseif t == 0x403 then          -- SDL_MOUSEWHEEL:y>0 向上(历史)
      return { kind = "wheel", x = ev[0].wheel.x, y = ev[0].wheel.y }
    elseif t == 0x401 then          -- 老式 X11 滚轮 = 按钮 4/5
      local b = ev[0].button.button
      if b == 4 then return { kind = "wheel", x = 0, y = 1 } end
      if b == 5 then return { kind = "wheel", x = 0, y = -1 } end
    end
  end
end

function View:close()
  for _, e in pairs(self.cache) do
    if e.tex then sdl.destroy_texture(e.tex) end
  end
  self.cache = {}
  if self.ren then sdl.destroy_renderer(self.ren) end
  if self.win then sdl.destroy_window(self.win) end
  if self.font then ttf.close(self.font) end
  if self.font_bold and self.font_bold ~= self.font then ttf.close(self.font_bold) end
  if self.font_mono and self.font_mono ~= self.font and self.font_mono ~= self.font_bold then
    ttf.close(self.font_mono)
  end
  ttf.quit(); sdl.quit()
end

M.View = View
return M
