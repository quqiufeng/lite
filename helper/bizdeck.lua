-- helper/bizdeck.lua —— 商业汇报模板（16:9 幻灯片 PDF），Kami 排版骨架 + 商务密度
--
-- 用法：
--   bizdeck({})                                    自带 demo：年度经营回顾，9 页
--   bizdeck({out="/tmp/q4.pdf", spec={brand="ACME", slides={…}}})
--   bizdeck({spec_json='{"slides":[…]}'})           从 JSON 字符串喂 spec（脚本/集群用）
--   bizdeck({theme="cinnabar", size="4:3", keep_png=true})
--
-- spec 结构（唯一真相是本文件的 slides.<kind>()，字段名以那里为准）：
--   spec.brand / spec.confidential / spec.date        页脚
--   spec.slides[]  每项一个 kind：
--     cover    {kind, eyebrow, title, subtitle, presenter, org}
--     section  {kind, no, title, subtitle}                       章节分隔
--     agenda   {kind, title, items={"…"}}                        两栏编号
--     kpi      {kind, title, lead, kpis={{value,label,delta}}}    2–4 张指标卡
--     bullets  {kind, title, lead, items={ {t=…,d=…} 或 "纯文本" }}
--     compare  {kind, title, left={title,items}, right={title,items}}
--     timeline {kind, title, steps={{when,title,desc}}}
--     table    {kind, title, lead, head={…}, rows={{…}}, note}
--     chart    {kind, title, lead, chart={id,spec}, points={{t,d}}, caption, height, side}
--              chart 页的图由 charts 引擎（lua/charts）先出 PNG 再当 <img> 嵌进来：
--              chart.id 见 charts({action="list"})，chart.spec 与 charts 的 spec 同义
--              （只写要改的键）。points 非空 = 左图右要点；空 = 单图居中。
--              height 缺省按页高算（16:9 约 420px）。side="right" 把图挪到右边。
--              出图落在 PDF 同目录 <stem>-chart-NN.png（逐页预览同目录，可单独看）。
--     quote    {kind, text, source}
--     end      {kind, title, subtitle, contact}
--
-- 和 trending（GitHub 每日精选）的关系：骨架同一套 —— eyebrow 小标 + 细线 +
-- 编号列表 + mono 数字 + 大留白；换掉的只有三处：16:9 定高页（投影/PPT 放映）、
-- 正文 16→19px（会议室距离）、多页而非一张长图。色系仍走 lua/gui/theme.lua，
-- 版式一条轴、色系一条轴，互不影响（与 trending 相同：只换 :root）。
--
-- 坑（都踩过，改之前先读）：
--   1. litehtml 没有 flex/grid 可用，多栏一律用 <table>：KPI 卡、左右对比、
--      时间轴、页脚左右对齐全是表。
--   2. 定高页 .slide 必须给 height，但**溢出探针要出 height:auto 的那份**才能量出
--      真实内容高（固定高的探针量到的恒等于页高，见 helper/pdf.lua 坑 1）。
--   3. 中文没有 kinsoku：行头可能出现「，」。要点自己拆成 t= 标题 + d= 说明，
--      别指望长句自动断得好看。
--   4. 字号/间距随页宽等比缩放（k = w/1280），不然 4:3 和 A4 会挤成一团 ——
--      本文件 CSS 里的 `@N` 就是「在 1280 宽下 N px」，出页时统一乘 k。
--   5. 页脚用 position:absolute 贴底（.slide 是 position:relative）：放流里会随
--      内容长短跳动，投影时看得见。
--   6. body 默认 margin 要清零（litehtml 自带 8px），否则整页留白全错。
--   7. 色值只写 var(--token)，由 theme.lua 展开；本文件不出现 hex，加色先去
--      lua/gui/theme.lua:M.css 加令牌。

local M = { schema = {
  name = "bizdeck",
  description = "商业汇报模板：spec → 16:9 幻灯片 PDF（Kami 排版骨架；"
             .. "cover/section/agenda/kpi/bullets/compare/timeline/table/chart/quote/end；"
             .. "chart 页由 charts 引擎出图后嵌进页里）",
  parameters = { type = "object", properties = {
    spec      = { type = "object", description = "幻灯片内容（不给就出 demo）；字段见本文件头注释" },
    spec_json = { type = "string", description = "spec 的 JSON 字符串（与 spec 二选一）" },
    out       = { type = "string", description = "PDF 输出路径，默认 ~/deck.pdf；同名 -01.png… 逐页预览" },
    size      = { type = "string", description = "16:9(默认 1280x720) / 4:3 / a4l / a4，或 {w,h}" },
    theme     = { type = "string", description = "色系：moon(默认)/light/bamboo/china/indigo/cinnabar/dark" },
    keep_png  = { type = "boolean", description = "逐页留预览 PNG，默认 true" },
    scale     = { type = "number", description = "预览 PNG 的 device scale，默认 2" },
    check_overflow = { type = "boolean", description = "报溢出页（内容超出页高会被裁），默认 true" },
  } },
} }

local SIZES = {
  ["16:9"] = { 1280, 720 },
  ["4:3"]  = { 1024, 768 },
  ["a4l"]  = { 1123, 794 },
  ["a4"]   = { 794, 1123 },
}

-- ── 字体：cairo toy font 只按族名取字、无字形回退 → 装没装必须先探 ──────────
-- 与 helper/pdf.lua 同一招：FcFontList 返回 nfont=0 才算没装（FcFontMatch 永远有结果）。
local function font_installed(family)
  local ok, fc = pcall(function()
    local ffi = require("ffi")
    pcall(ffi.cdef, [[
      typedef struct _FcConfig FcConfig;
      typedef struct _FcPattern FcPattern;
      typedef struct _FcObjectSet FcObjectSet;
      typedef struct { int nfont; int sfont; void **fonts; } liteDeckFcFontSet;
      typedef int FcBool;
      typedef unsigned char FcChar8;
      FcBool FcInit(void);
      FcPattern *FcNameParse(const FcChar8 *name);
      FcObjectSet *FcObjectSetCreate(void);
      FcBool FcObjectSetAdd(FcObjectSet *os, const char *object);
      liteDeckFcFontSet *FcFontList(FcConfig *config, FcPattern *p, FcObjectSet *os);
    ]])
    return ffi.load("fontconfig")
  end)
  if not ok or not fc then return false end
  return (pcall(function()
    fc.FcInit()
    local pat = fc.FcNameParse(family)
    local os  = fc.FcObjectSetCreate()
    fc.FcObjectSetAdd(os, "family")
    local set = fc.FcFontList(nil, pat, os)
    return set ~= nil and set.nfont > 0
  end))
end

local font_cache
local function fonts()
  if font_cache then return font_cache end
  local body = os.getenv("LITE_DECK_FONT")
  if not body or body == "" then
    body = font_installed("Noto Sans CJK SC") and "Noto Sans CJK SC"
        or (font_installed("Droid Sans Fallback") and "Droid Sans Fallback" or "DejaVu Sans")
  end
  font_cache = {
    body  = body,
    mono  = font_installed("DejaVu Sans Mono") and "DejaVu Sans Mono" or body,
    serif = font_installed("Noto Serif CJK SC") and "Noto Serif CJK SC" or body,
  }
  return font_cache
end

local function esc(s)
  return (tostring(s == nil and "" or s):gsub("[&<>]", function(c)
    return ({ ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" })[c]
  end))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 版式（一条轴只放版式：字号/间距/线；颜色全走 var(--token)）
-- `@N` = 1280 宽下的 N px，出页按 k=w/1280 缩放（坑 4）。
-- fixed=true 出定高页（正式），false 出 height:auto（溢出探针，坑 2）。
-- ═══════════════════════════════════════════════════════════════════════════
local CSS = [[
html,body{margin:0;padding:0;background:var(--parchment)}
body{font-family:{{body}};color:var(--ink);font-size:@16;line-height:1.5}
.slide{position:relative;width:{{w}}px;{{slide_h}}padding:@56 @80 @40 @80;background:var(--parchment)}
.eyebrow{font-family:{{mono}};font-size:@12.5;letter-spacing:@2.6;color:var(--stone)}
.title{font-size:@37;line-height:1.22;color:var(--brand);margin-top:@12;font-weight:600}
.rule{width:@64;height:2px;background:var(--brand);margin-top:@20}
.lead{font-size:@18;color:var(--muted);line-height:1.5;margin-top:@16}
.body{margin-top:@28}
/* litehtml 不认 position:absolute+bottom，只能给 top（值由 slide_css 按页高算，坑 5） */
.foot{position:absolute;left:@80;top:{{foot_top}}px;width:{{foot_w}}px}
.foot table{width:100%;border-collapse:collapse}
.foot td{font-family:{{mono}};font-size:@11.5;color:var(--stone);padding:0}
.foot td.r{text-align:right}

/* 编号要点：trending 的 ol.tr 换成幻灯片密度 */
ol.pts{list-style:none;padding:0;margin:0}
ol.pts li{position:relative;padding:@17 0 @17 @62;border-bottom:1px solid var(--hairline)}
ol.pts li:last-child{border-bottom:0 none}
/* 编号写死在 span 里：litehtml 的 content:counter() 会跳号（1,2,4） */
ol.pts li .pn{position:absolute;left:0;top:@16;font-family:{{mono}};font-size:@14;color:var(--stone)}
.pt{display:block;font-size:@22;font-weight:600;color:var(--ink);line-height:1.35}
.pd{display:block;font-size:@16;color:var(--muted);line-height:1.5;margin-top:@6}

/* KPI 卡：table-layout:fixed + .kc 显式 px 宽（含 padding 由 .build 算好传进来）
   litehtml 下 table 的 border-spacing / td 的 padding / border 都会把 100% 撑破右边界，
   块级 auto 宽 + padding 也会（无 box-sizing），只有写死 px 宽才稳。 */
table.kpis{width:100%;border-collapse:collapse;table-layout:fixed}
table.kpis td{vertical-align:top;padding:0}
table.kpis td .kc{background:var(--tint);border-top:2px solid var(--brand);padding:@20}
.kv{font-family:{{serif}};font-size:@44;color:var(--brand);line-height:1.15}
.kl{font-size:@15;color:var(--muted);margin-top:@10;line-height:1.4}
.kd{font-family:{{mono}};font-size:@12.5;color:var(--stone);margin-top:@6}

/* 左右对比 */
table.cmp{border-collapse:collapse;table-layout:fixed}
table.cmp td{width:50%;vertical-align:top;padding:0 @28 0 0}
table.cmp td.alt{padding:0 0 0 @28}
.ch{font-size:@19;font-weight:600;color:var(--brand);padding-bottom:@10;border-bottom:1px solid var(--hairline)}
.ch.alt{color:var(--muted)}
ul.cl{list-style:none;padding:0;margin:@14 0 0}
ul.cl li{font-size:@16;line-height:1.55;color:var(--ink);padding-left:@20;position:relative;margin-bottom:@10}
ul.cl li::before{content:"·";position:absolute;left:0;color:var(--brand);font-weight:600}

/* 时间轴 */
table.tl{border-collapse:collapse;table-layout:fixed}
table.tl td{padding:@15 0;vertical-align:top;border-bottom:1px solid var(--hairline)}
table.tl tr:last-child td{border-bottom:0 none}
td.ph{width:@104;font-family:{{mono}};font-size:@15;color:var(--brand);padding-right:@24}
.tt{font-size:@19;font-weight:600;line-height:1.35}
.td{font-size:@16;color:var(--muted);line-height:1.5;margin-top:@5}

/* 数据表：列宽由 colgroup 写死 px（auto 布局下末列会被撑出右边界） */
table.dt{border-collapse:collapse;table-layout:fixed}
table.dt th{font-family:{{mono}};font-size:@12.5;color:var(--stone);text-align:left;
  font-weight:400;letter-spacing:@0.6;padding:0 0 @11;border-bottom:1px solid var(--brand)}
table.dt td{font-size:@17;padding:@13 0;border-bottom:1px solid var(--hairline);color:var(--ink)}
table.dt td.n{font-family:{{mono}};text-align:right;padding-left:@18}
table.dt th.n{text-align:right;padding-left:@18}
.note{font-size:@13;color:var(--stone);margin-top:@16}

/* 图表页：左图右要点。litehtml 没有 flex，还是 table；图宽高由 charts 出图的
   PNG 长宽比算出后写死 px（img 只给 width 在 litehtml 下不会等比缩放）。 */
table.chart{border-collapse:collapse;table-layout:fixed;width:100%}
table.chart td{vertical-align:top;padding:0}
table.chart td.ci{padding-right:@32}
table.chart td.pd2{padding-left:@32}
.chartimg{display:block}
.cap{font-family:{{mono}};font-size:@12;color:var(--stone);margin-top:@12;line-height:1.45}
.pts2{list-style:none;padding:0;margin:0}
.pts2 li{padding:@12 0;border-bottom:1px solid var(--hairline)}
.pts2 li:last-child{border-bottom:0 none}
.pt2{display:block;font-size:@18;font-weight:600;color:var(--ink);line-height:1.35}
.pd3{display:block;font-size:@15;color:var(--muted);line-height:1.5;margin-top:@5}

/* 议程两栏 */
table.agenda{width:100%;border-collapse:collapse}
table.agenda td.ag{width:50%;vertical-align:top;padding:@16 @32 @16 0;border-bottom:1px solid var(--hairline)}
.agn{font-family:{{mono}};font-size:@13;color:var(--stone);margin-right:@16}
.agt{font-size:@19;color:var(--ink)}

/* 章节页 / 引语 / 封面 / 结束页 */
.sec-no{font-family:{{mono}};font-size:@96;color:var(--hairline);line-height:1;margin-top:@24}
.sec-title{font-size:@44;color:var(--brand);font-weight:600;line-height:1.2}
.sec-sub{font-size:@20;color:var(--muted);margin-top:@14}
.quote{font-family:{{serif}};font-size:@30;color:var(--ink);line-height:1.55;margin-top:@96}
.qs{font-family:{{mono}};font-size:@13.5;color:var(--stone);margin-top:@24}
.cv-bar{position:absolute;left:0;top:0;width:@10;height:100%;background:var(--brand)}
.cv-eyebrow{font-family:{{mono}};font-size:@13;letter-spacing:@3.4;color:var(--brand);margin-top:@72}
.cv-title{font-size:@54;line-height:1.15;color:var(--ink);font-weight:600;margin-top:@22}
.cv-sub{font-size:@22;color:var(--muted);margin-top:@18;line-height:1.5}
.cv-meta{font-family:{{mono}};font-size:@13;color:var(--stone);margin-top:@26}
]]

local function slide_css(w, h, fixed)
  local f = fonts()
  local k = w / 1280
  local out = CSS:gsub("@([%d%.]+)", function(v)
    return string.format("%.1fpx", tonumber(v) * k)
  end)
  out = out:gsub("{{([%w_]+)}}", {   -- 注意 %w 不含下划线（slide_h）
    body = f.body, mono = f.mono, serif = f.serif,
    w = string.format("%d", w),
    slide_h = fixed and string.format("height:%dpx;", h) or "",
    -- 页脚：底距 32 + 单行高 ~17，顶上定位（litehtml 无 bottom）
    foot_top = string.format("%.0f", h - 49 * k),
    foot_w = string.format("%.0f", w - 160 * k),
  })
  return out
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 页渲染：每 kind 一个函数，只吐 .slide 内部结构（页脚统一由 foot() 贴底）
-- ═══════════════════════════════════════════════════════════════════════════
local function foot(meta, no, total)
  local left = esc(meta.brand or "")
  if meta.confidential then left = left .. "  ·  CONFIDENTIAL" end
  if meta.date then left = left .. "  ·  " .. esc(meta.date) end
  return ('<div class="foot"><table><tr><td>%s</td><td class="r">%02d / %02d</td></tr></table></div>')
    :format(left, no, total)
end

local function head(s, meta)
  local out = { '<div class="eyebrow">' .. esc(s.eyebrow or meta.brand or "") .. '</div>' }
  if s.title then out[#out + 1] = '<div class="title">' .. esc(s.title) .. '</div>' end
  out[#out + 1] = '<div class="rule"></div>'
  if s.lead then out[#out + 1] = '<div class="lead">' .. esc(s.lead) .. '</div>' end
  return table.concat(out)
end

local slides = {}

-- 封面
function slides.cover(s, meta, no, total)
  return table.concat({
    '<div class="cv-bar"></div>',
    '<div class="cv-eyebrow">' .. esc(s.eyebrow or (meta.brand or "")) .. '</div>',
    '<div class="cv-title">' .. esc(s.title or "") .. '</div>',
    '<div class="cv-sub">' .. esc(s.subtitle or "") .. '</div>',
    s.presenter and ('<div class="cv-meta">' .. esc(s.presenter)
      .. (s.org and ("  ·  " .. esc(s.org)) or "") .. '</div>') or "",
    foot(meta, no, total),
  })
end

-- 章节分隔
function slides.section(s, meta, no, total)
  return table.concat({
    '<div class="eyebrow">' .. esc(s.eyebrow or "SECTION") .. '</div>',
    '<div class="sec-no">' .. esc(s.no or "") .. '</div>',
    '<div class="sec-title">' .. esc(s.title or "") .. '</div>',
    s.subtitle and ('<div class="sec-sub">' .. esc(s.subtitle) .. '</div>') or "",
    foot(meta, no, total),
  })
end

-- 议程：两栏编号，左栏 ceil(n/2) 条
function slides.agenda(s, meta, no, total)
  local items = s.items or {}
  local half = math.ceil(#items / 2)
  local rows = {}
  for i = 1, half do
    local function cell(idx)
      local v = items[idx]
      if not v then return '<td class="ag"></td>' end
      return ('<td class="ag"><span class="agn">%02d</span><span class="agt">%s</span></td>')
        :format(idx, esc(v))
    end
    rows[#rows + 1] = "<tr>" .. cell(i) .. cell(i + half) .. "</tr>"
  end
  return table.concat({
    head(s, meta),
    '<div class="body"><table class="agenda">' .. table.concat(rows) .. '</table></div>',
    foot(meta, no, total),
  })
end

-- KPI：2–4 张指标卡
-- 宽度写死 px：litehtml 无 box-sizing，百分比宽 + padding 会撑破右边界（见 slide_css 注释）
function slides.kpi(s, meta, no, total)
  local ks = s.kpis or {}
  local n = math.max(#ks, 1)
  local W = meta.w or 1280
  local gap, pad = 14, 20
  local content = W - 160                      -- .slide 左右 padding 80
  local pitch = math.floor(content / n + 0.5)    -- 表宽写死后 td 是等分的，给宽也只按等分
  local kcw = pitch - gap - 2 * pad             -- .kc 内容宽（padding 另算，无 box-sizing）
  local cells = {}
  for i, v in ipairs(ks) do
    cells[#cells + 1] = ('<td style="width:%dpx"><div class="kc" style="width:%dpx;margin-right:%dpx">'
      .. '<div class="kv">%s</div><div class="kl">%s</div>%s</div></td>')
      :format(pitch, kcw, i == n and 0 or gap, esc(v.value), esc(v.label),
              v.delta and ('<div class="kd">' .. esc(v.delta) .. '</div>') or "")
  end
  return table.concat({
    head(s, meta),
    ('<div class="body"><table class="kpis" style="width:%dpx"><tr>%s</tr></table></div>')
      :format(content, table.concat(cells)),
    foot(meta, no, total),
  })
end

-- 要点：编号 + 标题/说明
function slides.bullets(s, meta, no, total)
  local li = {}
  for i, v in ipairs(s.items or {}) do
    if type(v) == "table" then
      li[#li + 1] = ('<li><span class="pn">%02d</span><span class="pt">%s</span>%s</li>')
        :format(i, esc(v.t), v.d and ('<span class="pd">' .. esc(v.d) .. '</span>') or "")
    else
      li[#li + 1] = ('<li><span class="pn">%02d</span><span class="pt">%s</span></li>'):format(i, esc(v))
    end
  end
  return table.concat({
    head(s, meta),
    '<div class="body"><ol class="pts">' .. table.concat(li) .. '</ol></div>',
    foot(meta, no, total),
  })
end

-- 左右对比
function slides.compare(s, meta, no, total)
  local function col(c, alt)
    local items = {}
    for _, v in ipairs((c and c.items) or {}) do
      items[#items + 1] = "<li>" .. esc(v) .. "</li>"
    end
    return ('<td class="%s"><div class="ch%s">%s</div><ul class="cl">%s</ul></td>')
      :format(alt and "alt" or "", alt and " alt" or "", esc((c and c.title) or ""),
              table.concat(items))
  end
  local content = (meta.w or 1280) - 160
  local half = math.floor(content / 2 + 0.5)
  return table.concat({
    head(s, meta),
    ('<div class="body"><table class="cmp" style="width:%dpx"><colgroup><col style="width:%dpx">'
      .. '<col style="width:%dpx"></colgroup><tr>'):format(content, half, content - half)
      .. col(s.left, false) .. col(s.right, true) .. '</tr></table></div>',
    foot(meta, no, total),
  })
end

-- 时间轴
function slides.timeline(s, meta, no, total)
  local rows = {}
  for _, v in ipairs(s.steps or {}) do
    rows[#rows + 1] = ('<tr><td class="ph">%s</td><td><div class="tt">%s</div>%s</td></tr>')
      :format(esc(v.when), esc(v.title),
              v.desc and ('<div class="td">' .. esc(v.desc) .. '</div>') or "")
  end
  return table.concat({
    head(s, meta),
    ('<div class="body"><table class="tl" style="width:%dpx">%s</table></div>')
      :format((meta.w or 1280) - 160, table.concat(rows)),
    foot(meta, no, total),
  })
end

-- 数据表：首列文本左对齐，其余按数字右对齐（mono）
function slides.table(s, meta, no, total)
  local head_ = s.head or {}
  local n = math.max(#head_, 1)
  local W = meta.w or 1280
  local content = W - 160                        -- .slide 左右 padding 80
  -- 首列 40%，其余等分（写死 px，auto 布局会把末列撑出右边界）
  local c0 = math.floor(content * 0.4 + 0.5)
  local rest = math.floor((content - c0) / math.max(n - 1, 1) + 0.5)
  local cols = { ('<col style="width:%dpx">'):format(c0) }
  for i = 2, n do
    cols[i] = ('<col style="width:%dpx">'):format(i == n and (content - c0 - rest * (n - 2)) or rest)
  end
  -- 只有「像数字」的格才右对齐（td.n 是等宽右对齐）：首列永远是标签，其余看内容。
  local function isnum(v)
    if type(v) == "number" then return true end
    return tostring(v):match("^%-?%d[%d,%.]*%%?$") ~= nil
  end
  local th, trs = {}, {}
  for i, v in ipairs(head_) do
    th[#th + 1] = (i > 1 and isnum(v)) and ('<th class="n">' .. esc(v) .. "</th>")
                                         or ("<th>" .. esc(v) .. "</th>")
  end
  for _, r in ipairs(s.rows or {}) do
    local tds = {}
    for i, v in ipairs(r) do
      tds[#tds + 1] = (i > 1 and isnum(v)) and ('<td class="n">' .. esc(v) .. "</td>")
                                           or ("<td>" .. esc(v) .. "</td>")
    end
    trs[#trs + 1] = "<tr>" .. table.concat(tds) .. "</tr>"
  end
  return table.concat({
    head(s, meta),
    ('<div class="body"><table class="dt" style="width:%dpx"><colgroup>%s</colgroup><tr>%s</tr>%s</table>')
      :format(content, table.concat(cols), table.concat(th), table.concat(trs))
      .. (s.note and ('<div class="note">' .. esc(s.note) .. '</div>') or "") .. '</div>',
    foot(meta, no, total),
  })
end

-- 图表页：图由 charts 引擎预渲染成 PNG（见 M.run 的第 0 步），这里只摆位。
-- 为什么不在 build 里出图：build 是纯排版（探针还要再调一次），出图有副作用 + 慢。
-- src 只放**文件名**：litehtml 把相对 src 拼在 base_dir 后面（imgcache.cpp:resolve），
-- 而 M.run 已 set_base_dir(PDF 目录)，写成 "assets/x.png" 会被拼成 "assets/assets/x.png"
-- → 静默画成虚线占位框（页面上看着像「图还没画」，其实是路径错）。
local function img_tag(path, w, h, cap)
  return ('<img class="chartimg" src="%s" style="width:%dpx;height:%dpx">')
      :format(esc(path:match("([^/]+)$") or path), w, h)
      .. (cap and ('<div class="cap">' .. esc(cap) .. '</div>') or "")
end

function slides.chart(s, meta, no, total)
  local im = s._img
  if not im then
    error(("bizdeck: 第 %d 页 chart 没有预渲染图（chart 页由 M.run 出图，别直调 M.build）")
      :format(no), 0)
  end
  local content = meta.w - 160
  local k = meta.w / 1280
  -- 可用高度：页高 − 上 56 − 下 40 − 标题区（title+rule+lead ≈ 200k），留点余量
  local ch = tonumber(s.height) or math.floor(meta.h - 300 * k)
  local cw = math.floor(ch * im.w / im.h + 0.5)
  local pts = s.points
  local html = { head(s, meta) }
  if type(pts) == "table" and #pts > 0 then
    local chart_first = s.side ~= "right"
    local maxcw = math.floor(content * 0.58)      -- 留一半给文字
    if cw > maxcw then
      cw = maxcw
      ch = math.floor(cw * im.h / im.w + 0.5)
    end
    local lis = {}
    for _, v in ipairs(pts) do
      if type(v) == "table" then
        lis[#lis + 1] = ('<li><span class="pt2">%s</span>%s</li>')
          :format(esc(v.t or v[1] or ""),
                  v.d and ('<span class="pd3">' .. esc(v.d) .. '</span>') or "")
      else
        lis[#lis + 1] = ('<li><span class="pt2">%s</span></li>'):format(esc(v))
      end
    end
    local cell_img = ('<td class="ci" style="width:%dpx">%s</td>'):format(cw,
      img_tag(im.path, cw, ch, s.caption))
    local cell_txt = ('<td>%s</td>'):format('<ul class="pts2">' .. table.concat(lis) .. '</ul>')
    local c1 = chart_first and cw or (content - cw)
    html[#html + 1] = ('<div class="body"><table class="chart" style="width:%dpx">'
      .. '<colgroup><col style="width:%dpx"><col style="width:%dpx"></colgroup><tr>%s</tr>'
      .. '</table></div>'):format(content, c1, content - c1,
        chart_first and (cell_img .. cell_txt) or (cell_txt .. cell_img))
  else
    -- 单图：居中，宽度受内容宽约束
    if cw > content then
      cw = content
      ch = math.floor(cw * im.h / im.w + 0.5)
    end
    html[#html + 1] = ('<div class="body"><table class="chart" style="width:%dpx"><tr>'
      .. '<td style="text-align:center">%s</td></tr></table></div>')
      :format(content, img_tag(im.path, cw, ch, s.caption))
  end
  html[#html + 1] = foot(meta, no, total)
  return table.concat(html)
end

-- 引语
function slides.quote(s, meta, no, total)
  return table.concat({
    '<div class="body"><div class="quote">“' .. esc(s.text or "") .. '”</div>'
      .. (s.source and ('<div class="qs">— ' .. esc(s.source) .. '</div>') or "") .. '</div>',
    foot(meta, no, total),
  })
end

-- 结束页
slides["end"] = function(s, meta, no, total)
  return table.concat({
    '<div class="cv-bar"></div>',
    '<div class="cv-eyebrow">' .. esc(s.eyebrow or (meta.brand or "")) .. '</div>',
    '<div class="cv-title">' .. esc(s.title or "谢谢") .. '</div>',
    '<div class="cv-sub">' .. esc(s.subtitle or "") .. '</div>',
    s.contact and ('<div class="cv-meta">' .. esc(s.contact) .. '</div>') or "",
    foot(meta, no, total),
  })
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 组装：spec → 每页完整 HTML（自带 <style>，pdf 工具与 html= 通道都吃这个）
-- ═══════════════════════════════════════════════════════════════════════════
-- 同目录插件按需加载（与 helper/pdf.lua 同一份实现：只读盘 loadfile，不 require）
local function load_sibling(name, env)
  local dirs = { (env and env.helper_dir) or "helper", "helper",
                 ((env and env.cwd) or ".") .. "/helper" }
  for _, d in ipairs(dirs) do
    local p = d .. "/" .. name .. ".lua"
    local f = io.open(p, "rb")
    if f then
      f:close()
      local chunk, err = loadfile(p)
      if not chunk then error("加载 " .. p .. " 失败: " .. tostring(err)) end
      return chunk()
    end
  end
  error("找不到同目录插件 helper/" .. name .. ".lua（cwd=" .. ((env and env.cwd) or "?") .. "）")
end

local function page_html(body, css)
  return '<!DOCTYPE html><html><head><meta charset="utf-8"><style>' .. css
    .. '</style></head><body><div class="slide">' .. body .. '</div></body></html>'
end

-- 返回 htmls[], spec 里的页数
function M.build(spec, opt, env)
  local md2png = load_sibling("md2png", env)
  local w, h = opt.w, opt.h
  local src = spec.slides
  if type(src) ~= "table" or #src == 0 then
    error("bizdeck: spec.slides 是空的；required: slides (array)")
  end
  local meta = {
    brand = spec.brand or "ACME",
    confidential = spec.confidential,
    date = spec.date or os.date("%Y-%m-%d"),
    w = w,          -- 版式里要算 px 宽（KPI 卡）用
    h = h,          -- 图表页算可用高度用
  }
  local total = #src
  local css_fixed = md2png.theme_css(slide_css(w, h, true), opt.theme)
  local htmls = {}
  for i, s in ipairs(src) do
    local kind = s.kind or "bullets"
    local fn = slides[kind]
    if not fn then
      local names = {}
      for k in pairs(slides) do names[#names + 1] = k end
      table.sort(names)
      error(("bizdeck: 第 %d 页未知 kind '%s'；可用：%s")
        :format(i, tostring(kind), table.concat(names, " / ")))
    end
    htmls[i] = page_html(fn(s, meta, i, total), css_fixed)
  end
  return htmls, total
end

M.page_html = page_html
M.slide_css = slide_css

-- ═══════════════════════════════════════════════════════════════════════════
-- demo：一份能直接改的年度经营回顾（每个 kind 各来一页，当样板读）
-- ═══════════════════════════════════════════════════════════════════════════
function M.demo()
  return {
    brand = "NORTHWIND · 企业服务事业部",
    confidential = true,
    slides = {
      { kind = "cover", eyebrow = "ANNUAL BUSINESS REVIEW",
        title = "2026 年度经营回顾",
        subtitle = "从规模扩张转向单位经济模型健康：ARR 增长 32%，NBR 118%，毛利率提升 6.4pt",
        presenter = "汇报人 张明", org = "经营分析部 · 2026 年 11 月" },
      { kind = "agenda", title = "汇报结构", eyebrow = "AGENDA",
        lead = "四个问题：挣了多少、靠什么挣、卡在哪里、下一步押什么。",
        items = { "经营概览：三项核心指标", "增长驱动：新增与扩张拆解",
                  "问题诊断：交付与续约缺口", "区域结构与人效对比",
                  "2027 战略节奏与资源投入", "关键风险与应对" } },
      { kind = "section", no = "01", title = "经营概览", subtitle = "收入、毛利、留存三条线" },
      { kind = "kpi", title = "三项核心指标均超预算", eyebrow = "01 / 经营概览",
        lead = "全年 ARR 2.84 亿元，达成年度预算的 108%；毛利结构改善主要来自交付标准化。",
        kpis = {
          { value = "2.84亿", label = "年度 ARR", delta = "+32.1% YoY · 预算 108%" },
          { value = "71.4%", label = "综合毛利率", delta = "+6.4pt YoY" },
          { value = "118%", label = "净收入留存 NBR", delta = "+9pt YoY" },
          { value = "1.32", label = "获客成本回收周期（年）", delta = "−0.4 年 YoY" },
        } },
      { kind = "bullets", title = "增长来自两头：新增客户与存量扩张", eyebrow = "02 / 增长驱动",
        lead = "新增贡献 61%，存量扩张 39%；续约率是唯一拖后腿的指标。",
        items = {
          { t = "中大型客户新增 186 家，客单价提升 24%", d = "聚焦制造与零售两条行业线，销售周期从 96 天压缩到 71 天。" },
          { t = "存量客户交叉销售贡献 1.11 亿元", d = "数据分析模块渗透率从 31% 提升至 54%，是扩张的主要来源。" },
          { t = "渠道收入占比 22%，同比翻倍", d = "但渠道交付质量不稳定，占全年客诉的 41%。" },
        } },
      { kind = "compare", title = "问题集中在交付与续约", eyebrow = "03 / 问题诊断",
        lead = "",
        left = { title = "现状（2026 实际）", items = {
          "续约率 82%，低于行业 88% 的中位数",
          "标准交付周期 34 天，超期项目占 29%",
          "渠道客诉占比 41%，集中在实施环节",
          "人效 68 万/人，同比持平" } },
        right = { title = "目标（2027 计划）", items = {
          "续约率提升至 89%，靠客户成功前置",
          "交付周期压缩到 24 天，模板化 70%",
          "渠道认证与交付托管，客诉降到 15%",
          "人效提升到 85 万/人" } } },
      { kind = "table", title = "区域结构：华东贡献过半，华南效率最高",
        eyebrow = "04 / 区域对比",
        head = { "区域", "收入（万元）", "同比", "人均产出（万元）" },
        rows = {
          { "华东", "14,820", "+36%", "79" },
          { "华南", "6,340",  "+41%", "92" },
          { "华北", "4,910",  "+18%", "61" },
          { "西部", "2,330",  "+27%", "54" },
        },
        note = "注：人均产出 = 区域收入 / 区域全口径人数（含交付），数据截至 2026-11-30。" },
      { kind = "timeline", title = "2027 战略节奏：先修内功，再放规模", eyebrow = "05 / 战略节奏",
        steps = {
          { when = "Q1", title = "客户成功体系落地", desc = "续约健康分上线，Top 200 客户全量覆盖，续约前置 90 天。" },
          { when = "Q2", title = "交付模板化与渠道认证", desc = "标准实施包覆盖 70% 场景，渠道认证 40 家。" },
          { when = "Q3", title = "行业解决方案复制", desc = "制造线标杆客户打透，复制到零售与物流。" },
          { when = "Q4", title = "规模放量", desc = "在续约率 89%、交付 24 天的前提下，销售编制增加 35%。" },
        } },
      { kind = "quote", text = "增长不是问题，可复制的增长才是问题。",
        source = "2026 年度经营复盘会 · 共识结论" },
      { kind = "end", title = "谢谢", subtitle = "详细数据与分区域明细见附录，欢迎质询。",
        contact = "经营分析部  ·  zhangming@northwind.example  ·  分机 8021" },
    },
  }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 出 PDF（矢量，文字可选中）+ 逐页预览 PNG
-- ═══════════════════════════════════════════════════════════════════════════
local function spec_of(args)
  local spec = args.spec
  if type(spec) == "string" then spec = nil; args.spec_json = args.spec end
  if not spec and args.spec_json and args.spec_json ~= "" then
    local cjson = require("cjson")
    local ok, v = pcall(cjson.decode, args.spec_json)
    if not ok then error("bizdeck: spec_json 不是合法 JSON：" .. tostring(v)) end
    spec = v
  end
  if type(spec) ~= "table" or next(spec) == nil then return M.demo() end
  return spec
end

local function geometry(args)
  local s = args.size
  local w, h
  if type(s) == "table" then
    w, h = tonumber(s.w), tonumber(s.h)
    if not (w and h) then error("bizdeck: size 给对象时必须 {w=…, h=…}（px）") end
  else
    local sz = SIZES[s or "16:9"]
    if not sz then
      error("bizdeck: 未知 size '" .. tostring(s) .. "'，可用：" .. "16:9 / 4:3 / a4l / a4 / {w,h}")
    end
    w, h = sz[1], sz[2]
  end
  if w < 640 then error("bizdeck: size 太小（" .. w .. "px），required: w >= 640") end
  return w, h
end

function M.run(args, env)
  args = args or {}
  local md2png = load_sibling("md2png", env)
  local spec = spec_of(args)
  local w, h = geometry(args)
  local theme = args.theme

  local home = os.getenv("HOME") or "/tmp"
  local out = args.out or (home .. "/deck.pdf")
  if not out:match("%.pdf$") then out = out .. ".pdf" end
  local dir  = out:match("^(.*)/[^/]*$") or "."
  local stem = out:match("([^/]+)%.pdf$") or "deck"

  -- 0 图表页先出 PNG（charts 引擎 → PNG，再当 <img> 嵌进页里；build 只摆位）
  md2png.set_base_dir(dir)          -- 相对/绝对 <img src> 都按 PDF 所在目录兜底
  for i, s in ipairs(spec.slides or {}) do
    if type(s) == "table" and s.kind == "chart" then
      local c = s.chart
      if type(c) == "string" then c = { id = c }; s.chart = c end
      c = c or {}
      local id = c.id or s.chart_id
      if not id then
        error(("bizdeck: 第 %d 页 chart 缺 chart.id（如 pie/bar/waterfall/wordcloud），"
          .. "required: chart.id (string)"):format(i), 0)
      end
      local ok, C = pcall(require, "charts")
      if not ok or type(C) ~= "table" then
        error("bizdeck: chart 页要 lua/charts 引擎，require('charts') 失败：" .. tostring(C), 0)
      end
      local png = ("%s/%s-chart-%02d.png"):format(dir, stem, i)
      local cspec = {}
      for kk, vv in pairs(c.spec or {}) do cspec[kk] = vv end
      cspec.scale = cspec.scale or 2
      -- 卡自带 demo 的标题/注脚/单位**和轴标签**不能漏进正文（用户给了就用用户的）：
      -- charts 是「spec 覆盖 demo」，demo 里的「七天」「升」「起/末」会原样继承下来。
      if cspec.title == nil then cspec.title = "" end
      if cspec.note == nil then cspec.note = "" end
      if cspec.unit == nil then cspec.unit = "" end
      -- 「起/末」是通用轴标签，保留卡默认；「七天/升」这类演示口径才清空
      if cspec.spanLabel == nil then cspec.spanLabel = "" end
      -- 数据必须自己给：charts 缺 rows 会静默沿用 demo 的示例数据（图对不上正文）
      local has_data = false
      for _, kk in ipairs({ "rows", "values", "flows", "links", "tree", "nodes", "series", "bars", "entities" }) do
        if cspec[kk] then has_data = true break end
      end
      if not has_data then
        error(("bizdeck: 第 %d 页图表 '%s' 缺数据，required: chart.spec.rows（不给会静默用卡片 demo 数据）")
          :format(i, id), 0)
      end
      local ok2, err = pcall(C.render, id, cspec, png)
      if not ok2 then
        error(("bizdeck: 第 %d 页图表 '%s' 出图失败：%s"):format(i, id, tostring(err)), 0)
      end
      local pw, ph = md2png.png_size(png)
      if not (pw and ph) then
        error(("bizdeck: 第 %d 页图表 PNG 读不出尺寸：%s"):format(i, png), 0)
      end
      s._img = { path = png, w = pw, h = ph }
    end
  end

  local htmls, npages = M.build(spec, { w = w, h = h, theme = theme }, env)

  -- 1 矢量 PDF：C 侧逐页 save/restore，定高页每页都是 w×h
  md2png.render_pdf(htmls, out, w, h, 0.75, env)

  -- 2 逐页预览 PNG（投影验收 / 截图 diff 都靠它）
  local pngs, overflows = {}, {}
  local scale = tonumber(args.scale) or 2
  for i, html in ipairs(htmls) do
    if args.keep_png ~= false then
      local png = string.format("%s/%s-%02d.png", dir, stem, i)
      md2png.render_png(html, png, w, h, scale, env)
      pngs[i] = png
    end
    -- 3 溢出探针：**height:auto** 那份才量得出真实内容高（坑 2）
    if args.check_overflow ~= false then
      local css_auto = md2png.theme_css(slide_css(w, h, false), theme)
      local probe = string.format("%s/.bizdeck-probe-%02d.png", os.getenv("TMPDIR") or "/tmp", i)
      local body = html:match('<div class="slide">(.*)</div></body></html>$')
      md2png.render_png(page_html(body, css_auto), probe, w, 0, 1, env)
      local _, ph = md2png.png_size(probe)
      os.remove(probe)
      if ph and ph > h then
        overflows[#overflows + 1] = ("第 %d 页超出 %dpx（内容 %d / 页高 %d）"):format(i, ph - h, ph, h)
      end
    end
  end

  -- 4 报告
  local sz = io.open(out, "rb")
  local bytes = 0
  if sz then bytes = sz:seek("end") or 0; sz:close() end
  local lines = {
    ("PDF %d 页 · %dx%d px（%.0fx%.0f pt）· %s"):format(
      npages, w, h, w * 0.75, h * 0.75, theme or "moon"),
    ("→ %s (%d KB)"):format(out, math.floor(bytes / 1024)),
  }
  if #pngs > 0 then
    lines[#lines + 1] = ("预览 PNG: %s-01.png … （共 %d 张，@%dx）"):format(stem, #pngs, scale)
  end
  if #overflows > 0 then
    lines[#lines + 1] = "⚠ 溢出被裁（缩字数 / 拆页）: " .. table.concat(overflows, "; ")
  end
  return table.concat(lines, "\n")
end

return M
