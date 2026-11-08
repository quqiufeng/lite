-- lua/gui/theme.lua — 与同级 reader(lua/ui/themes.lua)同一套配色
-- 原始 8 槽: paper/card/line/ink/text/muted/sel/shadow
-- 映射到 GUI 语义调色板: bg/panel/line/text/muted/ink/accent/sel + 状态色
local M = {}

M.THEMES = {
  light = { paper = {245,244,237}, card = {251,250,244}, line = {228,223,211}, ink = {27,54,93},
            text = {43,42,38}, muted = {107,102,92}, sel = {241,239,230}, shadow = {236,232,222} },
  sepia = { paper = {245,236,217}, card = {250,244,230}, line = {216,203,174}, ink = {90,58,30},
            text = {60,50,35}, muted = {140,120,90}, sel = {240,231,211}, shadow = {230,218,193} },
  amber = { paper = {239,228,196}, card = {246,238,216}, line = {214,200,166}, ink = {122,82,45},
            text = {58,48,34}, muted = {140,122,92}, sel = {233,220,186}, shadow = {222,209,178} },
  mist = { paper = {220,232,213}, card = {234,242,229}, line = {190,208,182}, ink = {47,93,58},
           text = {46,58,46}, muted = {104,122,102}, sel = {212,226,205}, shadow = {200,216,193} },
  china = { paper = {226,240,203}, card = {243,248,232}, line = {196,214,166}, ink = {42,60,92},
            text = {29,27,28}, muted = {91,107,79}, sel = {231,240,214}, shadow = {185,203,160} },
  moon = { paper = {242,246,247}, card = {251,253,253}, line = {216,226,230}, ink = {35,64,92},
           text = {36,49,59}, muted = {110,127,138}, sel = {232,240,243}, shadow = {220,230,234} },
  bamboo = { paper = {241,245,236}, card = {250,252,246}, line = {204,217,191}, ink = {47,93,58},
             text = {37,48,39}, muted = {110,128,104}, sel = {227,236,216}, shadow = {220,231,208} },
  lotus = { paper = {247,240,241}, card = {252,247,248}, line = {229,210,214}, ink = {110,59,78},
            text = {58,43,48}, muted = {138,111,120}, sel = {240,226,230}, shadow = {232,214,219} },
  ochre = { paper = {246,239,230}, card = {251,246,238}, line = {226,208,184}, ink = {122,74,43},
            text = {59,46,36}, muted = {142,114,92}, sel = {239,227,210}, shadow = {230,213,194} },
  indigo = { paper = {238,242,246}, card = {248,250,252}, line = {203,214,224}, ink = {42,60,92},
             text = {31,42,54}, muted = {100,115,131}, sel = {224,232,240}, shadow = {214,224,232} },
  cinnabar = { paper = {248,241,238}, card = {253,248,246}, line = {232,210,202}, ink = {140,47,38},
               text = {58,42,38}, muted = {139,106,96}, sel = {241,224,219}, shadow = {234,216,210} },
  dark = { paper = {28,28,30}, card = {38,38,40}, line = {70,70,74}, ink = {160,190,230},
           text = {220,220,220}, muted = {150,150,150}, sel = {52,52,56}, shadow = {20,20,22} },
}

M.ORDER = { "light", "moon", "bamboo", "china", "sepia", "amber",
            "mist", "ochre", "lotus", "indigo", "cinnabar", "dark" }
M.NAMES = { light = "浅色", moon = "月白", bamboo = "竹青", china = "霜地", sepia = "护眼",
            amber = "羊皮纸", mist = "雾松绿", ochre = "赭石", lotus = "藕荷",
            indigo = "黛蓝", cinnabar = "朱砂", dark = "深色" }
M.DEFAULT = "light"

-- 亮/暗两套状态色(reader 没有,补在映射里;亮色走深色墨,暗色走浅色)
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

-- name -> 调色板表,规范名;未知主题回落 light
function M.palette(name)
  local key = M.THEMES[name] and name or M.DEFAULT
  local t = M.THEMES[key]
  local st = is_dark(t) and DARK_STATUS or LIGHT_STATUS
  local pal = {
    bg = t.paper, panel = t.card, line = t.line, text = t.text, muted = t.muted,
    ink = t.ink, accent = t.ink, sel = t.sel, shadow = t.shadow,
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
