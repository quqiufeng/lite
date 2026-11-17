-- lua/gui/theme.lua —— 排版 + 色系单一真源（GUI/TUI 调色板 · CSS 卡片令牌）
--
-- 三层，别混：
--   色系  8 槽 paper/card/line/ink/text/muted/sel/shadow，搬自 reader 项目
--         ../reader/lua/ui/themes.lua（色值逐字相同）。light 主题就是 Kami 本身：
--         它的 paper/card/line/ink/text/muted/sel 与 helper/assets/kami.css 的
--         :root 令牌同值 —— 改一处必须同步另一处，M.css() 是它们的对账口。
--   强调  accent 是每套主题的**唯一**传统色强调（朱砂/竹青/赭石/藏青…），对应 Kami
--         的「单一强调色 ≤5% 面积」。卡片上不要再叠第二个强调色。
--   排版  M.TYPO 是 Kami 的字号阶与字体栈；M.css(name) 把色系 + 排版一起吐成
--         :root{...}，给 litehtml（trending/md2png/web2png）用。
--
-- 三个坑：
--   1. cairo "toy font API" 只按族名找字、无字形回退 → --serif/--mono 给多值栈，
--      缺字形画方框；CSS_FALLBACK 那类兜底只能写单族名。
--   2. palette() 返回 RGB 三元组（GUI 要),css() 返回 hex（CSS 要）—— 别互相塞。
--   3. accent ≠ ink：accent 做强调（用户行/标题/指标数字），ink 做正文墨色。
local M = {}

M.THEMES = {
  -- accent 注释里的色名是传统色；light 的 accent 就是 Kami brand（墨蓝）
  light = { paper = {245,244,237}, card = {250,249,245}, line = {228,223,211}, ink = {27,54,93},
            text = {43,42,38}, muted = {107,102,92}, sel = {241,239,230}, shadow = {236,232,222},
            stone = {154,148,138},                    -- kami --stone，唯一显式给定的一套
            accent = {27,54,93} },                    -- 墨蓝（Kami brand #1B365D）
  sepia = { paper = {245,236,217}, card = {250,244,230}, line = {216,203,174}, ink = {90,58,30},
            text = {60,50,35}, muted = {140,120,90}, sel = {240,231,211}, shadow = {230,218,193},
            accent = {156,83,51} },                   -- 赭石 #9C5333
  amber = { paper = {239,228,196}, card = {246,238,216}, line = {214,200,166}, ink = {122,82,45},
            text = {58,48,34}, muted = {140,122,92}, sel = {233,220,186}, shadow = {222,209,178},
            accent = {161,110,26} },                  -- 缃色·深 #A16E1A
  mist = { paper = {220,232,213}, card = {234,242,229}, line = {190,208,182}, ink = {47,93,58},
           text = {46,58,46}, muted = {104,122,102}, sel = {212,226,205}, shadow = {200,216,193},
           accent = {5,119,72} },                     -- 松花绿 #057748
  china = { paper = {226,240,203}, card = {243,248,232}, line = {196,214,166}, ink = {42,60,92},
            text = {29,27,28}, muted = {91,107,79}, sel = {231,240,214}, shadow = {185,203,160},
            accent = {22,133,169} },                  -- 石青 #1685A9
  moon = { paper = {242,246,247}, card = {251,253,253}, line = {216,226,230}, ink = {35,64,92},
           text = {36,49,59}, muted = {110,127,138}, sel = {232,240,243}, shadow = {220,230,234},
           accent = {46,78,126} },                    -- 藏青 #2E4E7E
  bamboo = { paper = {241,245,236}, card = {250,252,246}, line = {204,217,191}, ink = {47,93,58},
             text = {37,48,39}, muted = {110,128,104}, sel = {227,236,216}, shadow = {220,231,208},
             accent = {120,146,98} },                 -- 竹青 #789262
  lotus = { paper = {247,240,241}, card = {252,247,248}, line = {229,210,214}, ink = {110,59,78},
            text = {58,43,48}, muted = {138,111,120}, sel = {240,226,230}, shadow = {232,214,219},
            accent = {140,67,86} },                   -- 绛紫 #8C4356
  ochre = { paper = {246,239,230}, card = {251,246,238}, line = {226,208,184}, ink = {122,74,43},
            text = {59,46,36}, muted = {142,114,92}, sel = {239,227,210}, shadow = {230,213,194},
            accent = {156,83,51} },                   -- 赭石 #9C5333
  indigo = { paper = {238,242,246}, card = {248,250,252}, line = {203,214,224}, ink = {42,60,92},
             text = {31,42,54}, muted = {100,115,131}, sel = {224,232,240}, shadow = {214,224,232},
             accent = {46,78,126} },                  -- 藏青 #2E4E7E
  cinnabar = { paper = {248,241,238}, card = {253,248,246}, line = {232,210,202}, ink = {140,47,38},
               text = {58,42,38}, muted = {139,106,96}, sel = {241,224,219}, shadow = {234,216,210},
               accent = {195,39,43} },                -- 朱砂 #C3272B
  dark = { paper = {28,28,30}, card = {38,38,40}, line = {70,70,74}, ink = {160,190,230},
           text = {220,220,220}, muted = {150,150,150}, sel = {52,52,56}, shadow = {20,20,22},
           accent = {160,190,230} },                  -- 天青（暗底上唯一强调）
}

M.ORDER = { "light", "moon", "bamboo", "china", "sepia", "amber",
            "mist", "ochre", "lotus", "indigo", "cinnabar", "dark" }
M.NAMES = { light = "浅色", moon = "月白", bamboo = "竹青", china = "霜地", sepia = "护眼",
            amber = "羊皮纸", mist = "雾松绿", ochre = "赭石", lotus = "藕荷",
            indigo = "黛蓝", cinnabar = "朱砂", dark = "深色" }
-- GUI 起手色系（`t`/`T` 循环起点也是它）。TUI 不读这份调色板（用
-- lua/tui/screen.lua 的 ANSI SGR），所以改这里对 TUI 零影响。
-- LITE_THEME 可覆盖（见 lua/main.lua 的 --gui 分支）；未知名回落 M.DEFAULT。
M.DEFAULT = "moon"
-- Kami 本体的主题名：CSS 卡片（trending/md2png）默认用它，跟 kami.css 对得上
M.KAMI = "light"
-- 卡片（trending/md2png/web2png）没指定 theme 时用的色系：月白。
-- 与 M.KAMI 分开是因为 Kami 的 :root 必须和 kami.css 逐值对账（M.css("light")），
-- 那个基准不能动；默认观感另说。改默认只改这里。
M.CARD_DEFAULT = "moon"

-- 走 matplotlib 之外的图表数据系列：8 个传统色相，明度够拉开、都不刺眼。
-- 只在 charts 画多序列时轮转，别拿去改 8 槽（那是语义色，不是数据色）。
M.SERIES = {
  "#c3272b", -- 朱砂
  "#9c5333", -- 赭石
  "#c8962d", -- 缃色
  "#789262", -- 竹青
  "#1685a9", -- 石青
  "#2e4e7e", -- 藏青
  "#8c4356", -- 绛紫
  "#9a948a", -- 石（中性，兜重复项）
}

-- Kami 排版令牌（**基础字号**，未乘卡片放大量）。trending 的 ×1.2 在那边做，
-- 别在这里乘 —— 乘了就两头不一致。
M.TYPO = {
  h1 = 34, h2 = 20, h3 = 16, body = 16, lede = 17,
  metric = 26, small = 14, eyebrow = 12, footer = 12,
  lh_tight = 1.2, lh_head = 1.25, lh_body = 1.55,
  -- cairo 无字形回退，栈里必须自带兜底族
  serif = '"TsangerJinKai02","仓耳今楷02","Source Han Serif SC","Noto Serif CJK SC","Droid Sans Fallback",Georgia,serif',
  mono  = '"DejaVu Sans Mono","Maple Mono NF CN","JetBrains Mono","SF Mono",Consolas,monospace',
}

-- 亮/暗两套状态色（reader 没有，补在映射里；亮色走深色墨，暗色走浅色）
local LIGHT_STATUS = {
  ok = {45,110,75}, warn = {150,102,32}, err = {168,62,55},
  add = {226,240,224}, del = {245,224,222},
}
local DARK_STATUS = {
  ok = {126,200,140}, warn = {226,186,96}, err = {230,118,118},
  add = {46,82,58}, del = {86,46,50},
}

local function is_dark(t)
  local p = t.paper
  return (p[1] + p[2] + p[3]) < 240
end

-- 最弱文字色（元信息/页脚）。Kami 的 --stone 显式给定；其余主题按 muted→line
-- 的中点偏 muted 派生，别新增一套手调值：视觉上"比 muted 淡、不消失"就够。
local function stone_of(t)
  if t.stone then return t.stone end
  local m, l = t.muted, t.line
  local k = is_dark(t) and 0.30 or 0.42
  return {
    math.floor(m[1] + (l[1] - m[1]) * k + 0.5),
    math.floor(m[2] + (l[2] - m[2]) * k + 0.5),
    math.floor(m[3] + (l[3] - m[3]) * k + 0.5),
  }
end

-- {r,g,b} -> "#rrggbb"（CSS 用；GUI 要三元组，别拿这个回灌 palette）
function M.hex(c)
  if type(c) == "string" then return c end
  if type(c) ~= "table" then return "#000000" end
  return string.format("#%02x%02x%02x",
    math.floor(math.max(0, math.min(255, c[1] or 0))),
    math.floor(math.max(0, math.min(255, c[2] or 0))),
    math.floor(math.max(0, math.min(255, c[3] or 0))))
end

-- name -> 调色板表（RGB 三元组）；未知主题回落 light
function M.palette(name)
  local key = M.THEMES[name] and name or M.DEFAULT
  local t = M.THEMES[key]
  local st = is_dark(t) and DARK_STATUS or LIGHT_STATUS
  local pal = {
    bg = t.paper, panel = t.card, line = t.line, text = t.text, muted = t.muted,
    ink = t.ink, accent = t.accent or t.ink, sel = t.sel, shadow = t.shadow,
    stone = stone_of(t),
    ok = st.ok, warn = st.warn, err = st.err, add = st.add, del = st.del,
  }
  -- 代码/工具区底色:纸色向墨色偏一点;深色主题得多偏些才看得出块
  local kk = is_dark(t) and 0.18 or 0.075
  pal.codebg = {
    t.paper[1] + (t.ink[1] - t.paper[1]) * kk,
    t.paper[2] + (t.ink[2] - t.paper[2]) * kk,
    t.paper[3] + (t.ink[3] - t.paper[3]) * kk,
  }
  return pal, key
end

-- 色系 + 排版一次吐成 CSS :root 块（litehtml 不解析 var，调用方还要 expand_vars）。
-- 变量名与 helper/assets/kami.css 对齐；额外给 --fs-* 字号阶，让卡片跟 Kami 同源。
function M.css(name)
  local pal, key = M.palette(name or M.KAMI)
  local t = M.THEMES[key]
  local T = M.TYPO
  return string.format([[:root{
  --parchment:%s; --ivory:%s; --brand:%s; --ink:%s;
  --muted:%s; --stone:%s; --hairline:%s; --tint:%s;
  --serif:%s;
  --mono:%s;
  --fs-h1:%dpx; --fs-h2:%dpx; --fs-h3:%dpx; --fs-body:%dpx;
  --fs-lede:%dpx; --fs-metric:%dpx; --fs-small:%dpx; --fs-eyebrow:%dpx;
  --lh-tight:%s; --lh-head:%s; --lh-body:%s;
}]],
    M.hex(t.paper), M.hex(t.card), M.hex(pal.accent), M.hex(t.text),
    M.hex(t.muted), M.hex(pal.stone), M.hex(t.line), M.hex(t.sel),
    T.serif, T.mono,
    T.h1, T.h2, T.h3, T.body, T.lede, T.metric, T.small, T.eyebrow,
    T.lh_tight, T.lh_head, T.lh_body)
end

-- 把 var(--x) 就地展开成字面值：litehtml 不认 CSS 变量，出图前必须调一次。
-- 只认第一个 :root 的定义块（多段 <style> 会各自声明，那是有意为之，别合并）。
-- 未定义的变量展开成 inherit 而不是留 var(...)：留 var 会让整条声明被 litehtml 丢掉。
function M.expand(css)
  local defs = {}
  local root = css:match(":root%s*{([^}]*)}")
  if root then
    for k, v in root:gmatch("%-%-([%w%-_]+)%s*:%s*([^;]+);") do
      defs[k] = v:gsub("^%s+", ""):gsub("%s+$", "")
    end
  end
  return (css:gsub("var%(%s*%-%-([%w%-_]+)%s*%)", function(k)
    return defs[k] or "inherit"
  end))
end

-- 换色系：把 css 里第一个 :root 整块换成该主题的令牌，排版规则一个字不动。
-- name 为空/未知 → 用 M.CARD_DEFAULT 换掉第一块 :root（卡片默认月白）；
-- 未知主题在 M.palette 里回落 light，不会报错。
-- 用法：M.expand(M.apply(css, args.theme))
function M.apply(css, name)
  name = (name ~= nil and name ~= "") and name or M.CARD_DEFAULT
  local block = M.css(name):match(":root%s*{(.-)}")
  if not block then return css end
  local out, n = css:gsub(":root%s*{.-}", ":root{" .. block .. "}", 1)
  if n == 0 then return css end
  return out
end

-- 出图装配：<主题 :root> + 你自己的排版规则 → 已展开 var 的一整段 CSS。
-- 排版规则里颜色一律写 var(--ivory/--ink/--hairline/--tint/--brand/--muted)，
-- 这样同一份规则配不同 theme 就换色而不换版式（md2png/web2png 走这条路）。
function M.page_css(body_css, name)
  return M.expand(M.css(name or M.CARD_DEFAULT) .. (body_css or ""))
end

-- 图表数据系列（hex 数组副本，防止 charts 侧原地改坏令牌）
-- 第一个色取 accent，默认跟卡片纸底同一色系（M.CARD_DEFAULT）；传 M.KAMI 可要 Kami 原色
function M.series(name)
  local _, key = M.palette(name or M.CARD_DEFAULT)
  local out = { M.hex(M.THEMES[key].accent) }
  for _, h in ipairs(M.SERIES) do
    if h ~= out[1] then out[#out + 1] = h end
  end
  return out
end

function M.index(name)
  for i, n in ipairs(M.ORDER) do if n == name then return i end end
  return 1
end

-- 循环切主题,delta 一般取 +1 / -1
function M.cycle(name, delta)
  local i = M.index(name) + (delta or 1) - 1
  i = (i % #M.ORDER) + 1
  return M.ORDER[i]
end

function M.label(name)
  return string.format("%s %s", M.NAMES[name] or name, name)
end

return M
