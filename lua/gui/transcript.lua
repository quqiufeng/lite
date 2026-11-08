-- lua/gui/transcript.lua — 只读 transcript 窗口(P1)
-- 版式对齐同级 reader:每条消息一张卡片(填充 + 1px 线 + 左侧强调条),
-- 标题行 W05 粗体,正文 W04 按像素折行,滚动按像素而非行。
local M = {}
local ffi = require("ffi")

local function now_ms()
  return os.time() * 1000
end

local INNER = 18      -- 卡片内边距
local RAIL = 0        -- 左侧强调条
local GAP = 18        -- 卡片间距
local BODY_BOLD = false -- 正文走 Regular(与状态栏同字重),Bold 只是变粗不好看

local function text_of(content)
  if type(content) == "string" then return content end
  if type(content) ~= "table" then return "" end
  local buf = {}
  for _, p in ipairs(content) do
    if type(p) == "string" then
      buf[#buf + 1] = p
    elseif type(p) == "table" then
      if p.text then buf[#buf + 1] = p.text end
      if p.type == "tool_use" then
        buf[#buf + 1] = "[tool " .. tostring(p.name) .. "]"
      elseif p.type == "tool_result" then
        buf[#buf + 1] = "[result]"
      end
    end
  end
  return table.concat(buf, "\n")
end

-- 轻量 markdown 清洗:去掉 **粗体** 标记与行首 # 标题号(tool 输出不动)
local function md_clean(s)
  s = s:gsub("%*%*(.-)%*%*", "%1")
  s = s:gsub("(^|\n)#+%s*", "%1")
  s = s:gsub("(^|\n)%s*[-*]%s+", "%1· ")
  return s
end

-- messages -> blocks{who,style,text}
function M.blocks(messages)
  local out = {}
  for _, m in ipairs(messages or {}) do
    local role = m.role or "?"
    local text = text_of(m.content)
    if text ~= "" then
      local who, style = role, "text"
      if role == "user" then who, style = "▶ 你", "accent"
      elseif role == "assistant" then who, style = "◆ lite", "ink"
      elseif role == "tool" then who, style = "· tool", "tool"
      elseif role == "system" then who, style = "· system", "muted" end
      if role ~= "tool" then text = md_clean(text) end
      out[#out + 1] = { who = who, style = style, text = text, role = role }
    end
  end
  return out
end

-- 排版:blocks -> cards{x,y,w,h,style,who,lines},返回 cards, total_h
local function layout(v, blocks)
  local cards = {}
  local x = v.pad_x
  local cw = math.max(200, v.text_w)
  local body_x = x + INNER + RAIL + 4
  local body_w = math.max(80, cw - INNER * 2 - RAIL - 4)
  local y = 0
  for _, b in ipairs(blocks) do
    -- tool 输出是机器文本:走等宽体,对齐命令/日志才不乱
    local mono = b.role == "tool"
    local lines = v:wrap(b.text, body_w, BODY_BOLD, mono)
    local h = INNER + v.line_h + (#lines * v.line_h) + INNER - 6
    cards[#cards + 1] = {
      x = x, y = y, w = cw, h = h, style = b.style, who = b.who, mono = mono,
      lines = lines, body_x = body_x, body_w = body_w,
    }
    y = y + h + GAP
  end
  if #cards > 0 then y = y - GAP end
  return cards, y
end

function M.run(ctx, opts)
  opts = opts or {}
  local View = require("gui.view")
  local v, err = View.open({
    title = opts.title or "lite", w = opts.w, h = opts.h,
    theme = opts.theme, size = opts.size, line_factor = opts.line_factor,
  })
  if not v then return nil, err end

  local blocks = M.blocks(ctx.session.messages)
  local cards, total = layout(v, blocks)
  local scroll, quit, frame, deadline = 0, false, 0, nil
  local buf = ""                     -- 输入框内容
  local note = nil                   -- 输入框上方的临时提示(出错等)
  local input_h = v.line_h + 14      -- 输入框高度

  local function drop_char(s)        -- 退格:删掉最后一个 UTF-8 字符
    if s == "" then return s end
    local i = #s
    while i > 1 and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do i = i - 1 end
    return s:sub(1, i - 1)
  end

  -- 输入框之上是内容,之下是状态栏
  local function bar(h)              -- 状态栏基线距窗口底
    return math.floor(h) + 10
  end
  local function input_top()
    return v.h - bar(v.line_h) - 10 - input_h
  end
  local TOP = math.floor(v.pad_y / 2) + 12  -- 内容起始 y(无顶栏,留一点呼吸)
  local BOT = 0                      -- 每帧重算 = 输入框上方

  -- 发送:优先 opts.on_send;否则用 opts.agent 跑一轮(阻塞,回来再重排)
  local on_send = opts.on_send
  if not on_send and opts.agent then
    local agent = opts.agent
    on_send = function(text)
      local ok, res, err = pcall(agent.run, agent, text)
      if not ok then error(res, 0) end
      if res == nil and err then error(tostring(err), 0) end
      return res
    end
  end

  local inited = false
  local function clamp()
    local view_h = math.max(1, BOT - TOP)
    local max_scroll = math.max(0, total - view_h)
    if not inited then                 -- 首帧贴底:先看到最新消息
      inited, scroll = true, max_scroll
    end
    if scroll > max_scroll then scroll = max_scroll end
    if scroll < 0 then scroll = 0 end
    return view_h, max_scroll
  end

  while not quit do
    v:begin()
    BOT = input_top() - 10

    -- 无顶栏:标题/主题名都不画,内容直接顶到上沿
    local view_h, max_scroll = clamp()
    -- 内容视口裁剪:卡片滚出上下边界时不许压到顶栏/状态栏
    local sdl = require("ffi.sdl2")
    local clip = ffi.new("SDL_Rect", {
      x = 0, y = math.floor(TOP - 4),
      w = math.floor(v.w), h = math.max(0, math.floor(BOT - TOP + 4)),
    })
    sdl.set_clip_rect(v.ren, clip)
    -- 卡片:先底/边/强调条,再文字(避免边框压字)
    for _, c in ipairs(cards) do
      local y = TOP + c.y - scroll
      if y + c.h >= TOP - 4 and y <= BOT + 4 then
        v:frame(c.x, y, c.w, c.h, "panel")
        -- tool/代码卡片整卡铺底:标签行 + 正文同属一个代码块
        if c.mono then
          v:rect(c.x + 1, y + 1, c.w - 2, c.h - 1, "codebg")
        end
        v:text(c.who, c.body_x, y + INNER - 4, c.style, true)
        local by = y + INNER + v.line_h - 2
        for _, line in ipairs(c.lines) do
          v:text(line, c.body_x, by, "text", BODY_BOLD, c.mono)
          by = by + v.line_h
        end
      end
    end
    sdl.set_clip_rect(v.ren, nil)   -- 复位:状态栏/输入框不受裁剪

    -- 输入框:内容与状态栏之间的一条,Enter 发送
    local iy = input_top()
    local iw = math.floor(v.w - v.pad_x * 2)
    v:frame(v.pad_x, iy, iw, input_h, "panel", "line")
    local tx = v.pad_x + 16
    local ty = iy + (input_h - v.line_h) / 2
    if buf == "" then
      v:text("说点什么…  Enter 发送  Esc 退出", tx, ty, "muted")
    else
      local tw = v:text(buf, tx, ty, "text", false)
      if math.floor(now_ms() / 500) % 2 == 0 then        -- 光标闪烁
        v:rect(tx + tw + 2, ty + 5, 2, math.max(8, v.line_h - 12), "ink")
      end
    end
    if note then v:text(note, v.pad_x + 2, iy - v.line_h - 4, "muted") end

    -- 状态栏:细线 + 进度
    local by = v.h - bar(v.line_h)
    v:hrule(by - 8, "line")
    local pct = total <= view_h and 100 or math.floor((scroll / max_scroll) * 100)
    v:text(string.format("%d 条消息 · %d%%   Enter 发送  ↑↓/滚轮 滚动  t 换主题  Esc 退出", #cards, pct),
      v.pad_x, by, "muted")
    v:present()
    frame = frame + 1
    if opts.run_ms and not deadline then deadline = now_ms() + opts.run_ms end
    if deadline and now_ms() > deadline then quit = true end

    local ev = v:poll()
    if ev == "quit" then quit = true
    elseif ev == "resize" then
      cards, total = layout(v, blocks)
    elseif type(ev) == "table" then
      if ev.kind == "text" then                         -- IME 真字符直接进缓冲区
        local t = (ev.text or ""):gsub("[\r\n]", "")
        if t ~= "" then
          buf = buf .. t
          if #buf > 4000 then buf = buf:sub(1, 4000) end
        end
      elseif ev.kind == "wheel" then                    -- 鼠标滚轮翻历史
        local step = v.line_h * 3
        scroll = scroll - (ev.y or 0) * step            -- y>0 = 向上 = 看历史
      elseif ev.kind == "key" then
        local k = ev.key
        if k == 27 then quit = true                                    -- ESC
        elseif k == 13 or k == 1073741912 then                         -- Enter 发送
          local text = buf:gsub("^%s+", ""):gsub("%s+$", "")
          if text ~= "" then
            buf = ""
            if on_send then
              note = "… lite 正在处理"
              v:text(note, v.pad_x + 2, iy - v.line_h - 4, "muted")
              v:present()
              local ok, e = pcall(on_send, text)
              note = ok and nil or ("出错: " .. tostring(e))
              blocks = M.blocks(ctx.session.messages)
              cards, total = layout(v, blocks)
              inited = false                           -- 重新贴底看新消息
            end
          end
        elseif k == 8 then buf = drop_char(buf)                        -- Backspace
        elseif k == 1073741905 then scroll = scroll + v.line_h         -- down
        elseif k == 1073741906 then scroll = scroll - v.line_h         -- up
        elseif k == 1073741903 then scroll = scroll + view_h - v.line_h -- pgdn
        elseif k == 1073741904 then scroll = scroll - (view_h - v.line_h)
        elseif k == 1073741898 then scroll = 0                         -- home
        elseif k == 1073741901 then scroll = 1e9                       -- end
        elseif buf == "" and k == 116 then v:cycle_theme(1)             -- t
        elseif buf == "" and k == 84 then v:cycle_theme(-1)             -- T
        end
      end
    end
    v:delay(16)
  end

  v:close()
  return true
end

return M
