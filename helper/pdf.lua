-- helper/pdf.lua —— 两条出 PDF 的路，同一个入口（mode 选）：
--
--   ① mode="image"（默认）：分页 Markdown → 每页固定尺寸 PNG → 合成 PDF
--      pdf({path="deck.md", out="/tmp/deck.pdf"})                    16:9 幻灯片，`---` 分页
--      pdf({path="doc.md", size="a4"})                               A4 竖版文档（同样每页一张图）
--      pdf({pages={"# 封面", "# 第二页"}, out="/tmp/x.pdf", theme="cinnabar"})
--      → 位图版：**文字不可选中/不可搜索**，体积大；但分页/溢出/换行全在掌控内（见下）。
--
--   ② mode="html"：HTML/Markdown → cairo PDF surface，**矢量的**
--      pdf({path="doc.md", size="a4", mode="html"})                   分页 MD 直出 A4 矢量文档
--      pdf({path="deck.md", size="16:9", mode="html"})                定高幻灯片页（超出会报溢出）
--      pdf({path="doc.md", mode="html"})                              不给 size = 每页按内容定高
--      pdf({template="trending", out="/tmp/trending.pdf"})            GitHub 每日精选模板直出
--      pdf({template="trending", lang="lua", since="weekly", width=820})
--      pdf({html="/tmp/card.html", out="/tmp/card.pdf"})              trending 出来的同名 .html
--      pdf({mode="html", html="<html>…</html>"})                      裸 HTML 字符串
--      pdf({mode="html", pages={"<html>…</html>", "<html>…</html>"}}) 每页一段完整 HTML
--      → 文字**可选中/可搜索**、体积小。
--      **页高**：给了 path（分页 MD）就按 size 定整页高（A4 竖版/16:9 幻灯片，与图版同
--      几何）；template/html/pages（别人自带的 HTML 页面）h=0 = 按内容定高（长卡片出一整
--      页长纸）。要 MD 长文档自动流可分页就用 image 模式（见坑 6）。
--
-- 为什么图版仍然保留（不直接全用矢量）：
--   「分页」这件难事在图版里整个消失 —— 每页固定 w×h 渲一次，超出裁掉，不用把长文档
--   切 A4、不用处理「表格行被切一半」。矢量版省掉了这层缓冲：litehtml 不分页，你要固定
--   页高就得自己保证内容不溢出（默认会报溢出页，见坑 1）。所以：
--   **要能选中/搜索/打印清晰 → html 模式；要不操心分页、要 16:9 幻灯片 → image 模式。**
--   两种模式的页面几何一致（px × 0.75 = pt），同一份内容出来的页面大小完全相同。
--
-- 依赖（缺哪层报哪层）：
--   ① 布局+出图/出 PDF：build/liblite_html.so 的 lite_html_render（PNG）与
--      lite_html_render_pdf（cairo_pdf_surface，多页）；md2png 导出的
--      md_to_html/render_png/render_pdf/png_size（复用，不复制 md4c 回调）。
--   ② 图版的合成：系统 libcairo.so.2 的 PDF surface（cairo 自己就是 PDF 生成器，
--      不需要 libharu/poppler/ghostscript）。
--   ③ 字体/配色：helper/assets + lua/gui/theme.lua（颜色全走 var() 令牌，别写死 hex）。
--
-- 坑：
--   1. `.slide` 固定 height 时**溢出会被静默裁掉**，所以默认 check_overflow=true。
--      两种模式探针机制不一样：图版（和矢量的 MD 页）用 height:auto 渲一张探针图量真实
--      内容高；矢量 html 页面的 C 侧会回填 content_h，但「.slide 自己也定高」时它必然 ≥
--      页高（含 .pad 和 8px 根边距），拿它比页高**每页都误报** —— MD 页因此改走探针图。
--   2. cairo 的 transform 是**累积**的：每页必须 cairo_save/restore 包住 scale，
--      否则第 N 页的缩放会叠乘，越往后图越小（C 侧和图版合成侧都各自包了）。
--   3. 图版的图片按「填满页面」放（k = 页宽pt / 图宽px），所以页面尺寸必须与出图宽高比
--      严格一致；不一致会拉伸而不是留白 —— 改 size 就同时改渲染宽高。
--   4. litehtml 的 cairo toy font 只认单族名，字体栈只能写一个族；字号随页宽缩放，
--      统一从 w 推（见 BASE_K），别在 CSS 里写死 px。
--   5. html 模式的 HTML 必须**自带 <style>**（CSS 不跨页继承，也不做主题注入）：
--      template="trending" 和 trending 落盘的 .html 都满足；自己拼的裸 HTML 记得内联。
--   6. litehtml 不支持分页属性（page-break/break-inside）与 `@page`，所以矢量版也不做
--      自动分页 —— 要自动流的文档继续用 image 模式。


local ffi = require("ffi")

-- ── 尺寸表：px 是渲染视口（出图），pt 是 PDF 页面（px × 0.75，96dpi → 72pt/inch）──
local SIZES = {
  ["16:9"]  = { 1280, 720 },
  ["4:3"]   = { 1024, 768 },
  ["a4"]    = { 794, 1123 },   -- 竖
  ["a4l"]   = { 1123, 794 },   -- 横
  ["letter"]= { 816, 1056 },
}

local BASE_K = 21 / 1280   -- 基准字号 / 页宽：21px @ 1280 宽，其余尺寸等比

-- ── 正文字体：仓耳今楷02 优先，缺失回落 Noto Sans CJK SC ────────────────────
-- 为什么换：Noto CJK 是 CID Type 0C（CFF charstring），仓耳是 TrueType(glyf) 子集，
-- 同样 8 页 A4 文档 PDF 从 134KB 降到 ~34KB（-75%），且已装在本机（family 名两个
-- 写法都能命中：'仓耳今楷02 W04' / 'TsangerJinKai02 W04'）。W04 比 W05 小 5KB。
-- 坑：cairo toy font 只按族名取字、无字形回退 —— 字体没装就会画方框，所以必须先
-- 用 fontconfig 探一次（FcFontList 对没装的族返回 nfont=0；FcFontMatch 不行，
-- 它总会返回"最接近"的那个，拿不到「有没有」这个事实）。
local BODY_FONT     = "仓耳今楷02 W04"
local BODY_FONT_ALT = "Noto Sans CJK SC"

local function font_installed(family)
  local ok, fc = pcall(function()
    local ffi = require("ffi")
    pcall(ffi.cdef, [[
      typedef struct _FcConfig FcConfig;
      typedef struct _FcPattern FcPattern;
      typedef struct _FcObjectSet FcObjectSet;
      typedef struct { int nfont; int sfont; void **fonts; } liteFcFontSet;
      typedef int FcBool;
      typedef unsigned char FcChar8;
      FcBool FcInit(void);
      FcPattern *FcNameParse(const FcChar8 *name);
      FcObjectSet *FcObjectSetCreate(void);
      FcBool FcObjectSetAdd(FcObjectSet *os, const char *object);
      liteFcFontSet *FcFontList(FcConfig *config, FcPattern *p, FcObjectSet *os);
    ]])
    return ffi.load("fontconfig")
  end)
  if not ok or not fc then return false end
  local ok2, found = pcall(function()
    fc.FcInit()
    local pat = fc.FcNameParse(family)
    local os  = fc.FcObjectSetCreate()
    fc.FcObjectSetAdd(os, "family")
    local set = fc.FcFontList(nil, pat, os)
    return set ~= nil and set.nfont > 0
  end)
  return ok2 and found or false
end

-- 探一次就够（进程内不变）；LITE_PDF_FONT 可强指任意族名，绕过探测
local body_font_cache
local function body_font()
  if body_font_cache then return body_font_cache end
  local env = os.getenv("LITE_PDF_FONT")
  if env and env ~= "" then body_font_cache = env
  elseif font_installed(BODY_FONT) then body_font_cache = BODY_FONT
  else body_font_cache = BODY_FONT_ALT end
  return body_font_cache
end

-- ── 版式（色值一律 var(--token)，由 theme.lua 展开）────────────────────────────
local function slide_css(w, h, fixed)
  local b   = math.max(11, math.floor(w * BASE_K + 0.5))
  local padx= math.floor(w * 0.056 + 0.5)   -- 72 @1280
  local pady= math.floor(h * 0.089 + 0.5)   -- 64 @720
  local inner = w - padx * 2
  local height = fixed and (h .. "px") or "auto"
  return string.format([[
body{margin:0;background:var(--parchment);color:var(--ink);font-family:%q;font-size:%dpx;line-height:%s}
.pad{height:%dpx}
.slide{width:%dpx;height:%s;margin:0 %dpx}
h1,h2,h3,h4{color:var(--brand);line-height:%s;margin:.7em 0 .45em}
h1{font-size:%dpx;margin-top:0;border-bottom:1px solid var(--hairline);padding-bottom:.22em}
h2{font-size:%dpx}h3{font-size:%dpx}h4{font-size:%dpx}
p{margin:.55em 0}strong{color:var(--brand)}
a{color:var(--brand);text-decoration:none}
code{font-family:%q;font-size:%dpx;background:var(--tint);padding:1px 5px;border-radius:3px}
pre{background:var(--tint);border:1px solid var(--hairline);border-radius:5px;padding:12px 14px}
pre code{background:none;padding:0;font-size:%dpx;line-height:%s}
blockquote{margin:.7em 0;padding:.15em .9em;border-left:3px solid var(--brand);color:var(--muted);background:var(--tint)}
ul,ol{margin:.5em 0;padding-left:1.5em}li{margin:.22em 0}
hr{border:0;border-top:1px solid var(--hairline);margin:1em 0}
table{border-collapse:collapse;margin:.7em 0;width:100%%}
th,td{border:1px solid var(--hairline);padding:6px 10px;text-align:left;font-size:%dpx}
th{background:var(--tint);color:var(--brand)}
img{max-width:100%%}
]],
    body_font(), b, "var(--lh-body)",
    pady, inner, height, padx,
    "var(--lh-head)",
    math.floor(b * 2.1 + 0.5), math.floor(b * 1.52 + 0.5),
    math.floor(b * 1.2 + 0.5),  math.floor(b * 1.05 + 0.5),
    "DejaVu Sans Mono", math.floor(b * 0.86 + 0.5),
    math.floor(b * 0.8 + 0.5), "var(--lh-body)",
    math.floor(b * 0.88 + 0.5))
end

-- ── 复用 md2png 的 md4c/dlopen/png_size（按名加载，别 require 依赖 package.path）──
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
  error("找不到 helper/" .. name .. ".lua（pdf 复用它出图）")
end

-- ── 分页：默认只认独占一行的 `---`（marp/slidev 习惯）；也可 <!-- page --> ──────
local function split_pages(src, pat)
  local pages, cur = {}, {}
  local marker = pat or "^%s*%-%-%-%s*$"
  local htmlmark = "^%s*<!%-%-%s*page%s*%-%->%s*$"
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    if line:match(marker) or line:match(htmlmark) then
      pages[#pages + 1] = table.concat(cur, "\n")
      cur = {}
    else
      cur[#cur + 1] = line
    end
  end
  pages[#pages + 1] = table.concat(cur, "\n")
  return pages
end

-- ── cairo PDF surface 绑定（进程内可能已被别的插件 cdef 过，先探再用）────────────
local function cdef()
  local ok = pcall(ffi.typeof, "cairo_t")
  if ok then return end
  ffi.cdef[[
    typedef struct _cairo_surface cairo_surface_t;
    typedef struct _cairo cairo_t;
    cairo_surface_t* cairo_pdf_surface_create(const char* filename, double w, double h);
    void cairo_pdf_surface_set_size(cairo_surface_t* s, double w, double h);
    cairo_surface_t* cairo_image_surface_create_from_png(const char* filename);
    int  cairo_surface_status(cairo_surface_t* s);
    void cairo_surface_finish(cairo_surface_t* s);
    void cairo_surface_destroy(cairo_surface_t* s);
    cairo_t* cairo_create(cairo_surface_t* s);
    void cairo_destroy(cairo_t* cr);
    void cairo_save(cairo_t* cr);
    void cairo_restore(cairo_t* cr);
    void cairo_scale(cairo_t* cr, double sx, double sy);
    void cairo_set_source_surface(cairo_t* cr, cairo_surface_t* s, double x, double y);
    void cairo_paint(cairo_t* cr);
    void cairo_show_page(cairo_t* cr);
    const char* cairo_status_to_string(int st);
  ]]
end

local function load_cairo()
  cdef()
  for _, so in ipairs({ "libcairo.so.2", "libcairo.so", "cairo" }) do
    local ok, l = pcall(ffi.load, so)
    if ok then return l end
  end
  error("缺 libcairo（apt/dnf 装 libcairo2；PDF surface 是 cairo 自带的，不需要 libharu）")
end

local function file_size(p)
  local f = io.open(p, "rb")
  if not f then return 0 end
  local n = f:seek("end") f:close() return n or 0
end

local function human(n)
  if n < 1024 then return n .. "B" end
  if n < 1024 * 1024 then return string.format("%.0fKB", n / 1024) end
  return string.format("%.1fMB", n / 1048576)
end

-- ── 合成：一页一张图，按页宽铺满（宽高比已由 size 保证一致）──────────────────
local function compose(pdf_path, pages, pw_pt, ph_pt)
  local cairo = load_cairo()
  local surf = cairo.cairo_pdf_surface_create(pdf_path, pw_pt, ph_pt)
  local st = cairo.cairo_surface_status(surf)
  if st ~= 0 then
    error("cairo_pdf_surface_create 失败: " .. ffi.string(cairo.cairo_status_to_string(st)))
  end
  local cr = cairo.cairo_create(surf)
  for i, pg in ipairs(pages) do
    local p = pg.path or pg
    local img = cairo.cairo_image_surface_create_from_png(p)
    local ist = cairo.cairo_surface_status(img)
    if ist ~= 0 then
      cairo.cairo_surface_destroy(img)
      cairo.cairo_destroy(cr)
      cairo.cairo_surface_destroy(surf)
      error(("第 %d 页读图失败（%s）: %s")
        :format(i, p, ffi.string(cairo.cairo_status_to_string(ist))))
    end
    local iw = pg._w or pw_pt
    local k = pw_pt / iw                       -- 图宽px → 页宽pt，整页铺满
    cairo.cairo_save(cr)
    cairo.cairo_scale(cr, k, k)
    cairo.cairo_set_source_surface(cr, img, 0, 0)
    cairo.cairo_paint(cr)
    cairo.cairo_restore(cr)                    -- 坑 2：transform 会累积
    cairo.cairo_surface_destroy(img)
    cairo.cairo_show_page(cr)
  end
  cairo.cairo_destroy(cr)
  cairo.cairo_surface_finish(surf)
  cairo.cairo_surface_destroy(surf)
end

local M = { schema = {
  name = "pdf",
  description = "出 PDF 两条路：mode=image（分页 Markdown → 每页 PNG → 合成，图版）/ "
             .. "mode=html（HTML/Markdown 直出矢量 PDF，文字可选中；template=trending 复用每日精选模板）",
  parameters = { type = "object", properties = {
    mode     = { type = "string",  description = "image(默认，图版) / html(矢量，需 path|html|template|pages)；"
                  .. "别名 raster→image、vector→html" },
    path     = { type = "string",  description = "Markdown 文件路径（与 pages 二选一）；两种模式都认，page 由 `---`/`break_on` 切" },
    pages    = { type = "array",   description = "image 模式：每页 Markdown 或整段 HTML；"
                  .. "html 模式：每页一段**完整** HTML（自带 <style>）",
                  items = { type = "string" } },
    html     = { type = "string",  description = "html 模式：.html 文件路径，或以 < 开头的裸 HTML 字符串" },
    template = { type = "string",  description = "html 模式：复用模板，目前支持 trending（GitHub 每日精选，"
                  .. "出图前那份 HTML）" },
    lang     = { type = "string",  description = "template=trending：语言过滤，如 lua/go/rust" },
    since    = { type = "string",  description = "template=trending：daily(默认)/weekly/monthly" },
    limit    = { type = "number",  description = "template=trending：取前 N 条，默认 9" },
    out      = { type = "string",  description = "PDF 输出路径，默认 ~/<name>.pdf；image 模式同名 PNG 逐页落盘" },
    size     = { type = "string",  description = "16:9(默认)/4:3/a4/a4l/letter，或给 {w,h} 像素对象" },
    width    = { type = "number",  description = "页面视口宽（px），默认 1280（给 path 时按 size 推）；trending 建议 820（≥780）" },
    height   = { type = "number",  description = "页高（px）。给 path 时按 size 定整页高（不给 size=0 按内容定高）；其余默认 0" },
    scale    = { type = "number",  description = "image 模式出图 device scale，默认 2（×2 更清晰、PDF 更大）" },
    theme    = { type = "string",  description = "色系：moon(默认)/light/bamboo/china/indigo/cinnabar/dark" },
    keep_png = { type = "boolean", description = "image 模式默认 true（逐页留 PNG）；html 模式默认 false，"
                  .. "置 true 额外出首页预览 PNG" },
    check_overflow = { type = "boolean", description = "报溢出页，默认 true（定高页多渲一张探针图量真实内容高）" },
  } },
} }

local function run_image(args, env)
  local md2png = load_sibling("md2png", env)

  -- 1 取页
  local raw
  if args.pages then
    raw = {}
    for i, p in ipairs(args.pages) do raw[i] = tostring(p) end
    if #raw == 0 then error("pdf: pages 是空数组") end
  elseif args.path then
    local f = assert(io.open(args.path, "rb"), "读不到 " .. tostring(args.path))
    local src = f:read("*a") f:close()
    raw = split_pages(src, args.break_on)
  else
    error("pdf: required 其一 —— path (string) 或 pages (array)")
  end

  -- 2 尺寸
  local w, h
  if type(args.size) == "table" then
    w, h = tonumber(args.size.w), tonumber(args.size.h)
    if not (w and h) then error("pdf: size 给对象时必须 {w=…, h=…}（像素）") end
  else
    local s = SIZES[args.size or "16:9"]
    if not s then
      error("pdf: 未知 size '" .. tostring(args.size) .. "'，可用：16:9 / 4:3 / a4 / a4l / letter / {w,h}")
    end
    w, h = s[1], s[2]
  end
  local scale = tonumber(args.scale) or 2

  -- 3 输出路径
  local home = os.getenv("HOME") or "/tmp"
  local base = args.out
  if not base then
    local name = (args.path and args.path:match("([^/]+)%.md$")) or "deck"
    base = home .. "/" .. name .. ".pdf"
  end
  local dir = base:match("^(.*)/[^/]*$") or "."
  local stem = base:match("([^/]+)%.pdf$") or "deck"
  local do_png  = (args.keep_png ~= false)
  local do_chk  = (args.check_overflow ~= false)

  -- 4 逐页出图（探针 + 正式）
  local out_pngs, overflows = {}, {}
  for i, src in ipairs(raw) do
    local body, rc
    if src:match("^%s*<") then body, rc = src, 0        -- 整段 HTML 直接当页内容
    else body, rc = md2png.md_to_html(src) end
    if rc < 0 then error(("第 %d 页 md_parse 失败 rc=%d"):format(i, rc)) end

    local function html_for(fixed)
      local css = md2png.theme_css(slide_css(w, h, fixed), args.theme)
      return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>" .. css ..
             "</style></head><body><div class=\"pad\"></div>" ..
             "<div class=\"slide\">" .. body .. "</div></body></html>"
    end

    if do_chk then
      -- 探针：height:auto 量真实内容高度。固定 height 的探针量不出溢出（会被容器盖住）
      local probe = string.format("%s/.pdf-probe-%02d.png", dir, i)
      md2png.render_png(html_for(false), probe, w, 0, scale, env)
      local _, ph_px = md2png.png_size(probe)
      os.remove(probe)
      -- 坑 5：png_size 给的是**设备像素**（@2x 时 ×2），必须除以 scale 才是 CSS px。
      -- 直接和 h 比会一律误报（720 CSS px 的页，@2x 光页高就是 1440 像素）。
      local ph = math.floor(ph_px / scale + 0.5)
      if ph > h then
        overflows[#overflows + 1] = string.format("第 %d 页超出 %dpx（内容 %dpx / 页高 %dpx）",
          i, ph - h, ph, h)
      end
    end

    local png = do_png and string.format("%s/%s-%02d.png", dir, stem, i)
                     or string.format("%s/.pdf-page-%02d.png", dir, i)
    md2png.render_png(html_for(true), png, w, h, scale, env)
    local pw = md2png.png_size(png)
    out_pngs[i] = { path = png, _w = pw, keep = do_png }
  end

  -- 5 合成 PDF
  local pw_pt, ph_pt = w * 0.75, h * 0.75
  compose(base, out_pngs, pw_pt, ph_pt)

  -- 6 收拾临时图（keep_png=false 时）
  if not do_png then
    for _, p in ipairs(out_pngs) do os.remove(p.path) end
  end

  -- 7 报告
  local lines = {
    string.format("PDF %d 页 · 页面 %dx%dpt（%dx%d px @%gx）· %s → %s",
      #out_pngs, math.floor(pw_pt + 0.5), math.floor(ph_pt + 0.5), w, h, scale,
      human(file_size(base)), base),
  }
  if do_png then
    lines[#lines + 1] = string.format("逐页 PNG %d 张 → %s/%s-%02d.png … %s-%02d.png",
      #out_pngs, dir, stem, 1, stem, #out_pngs)
  end
  if #overflows > 0 then
    lines[#lines + 1] = "⚠ 溢出被裁（拆页或加大 size）: " .. table.concat(overflows, "; ")
  end
  return table.concat(lines, "\n")
end

-- ── ② 矢量：HTML → cairo_pdf_surface（文字可选中/可搜索）─────────────────────
-- 不做分页（litehtml 不认 page-break），h 默认 0 让每页按内容定高。
local function run_html(args, env)
  local md2png = load_sibling("md2png", env)

  -- 0 页面几何先定（md 分支要用它算 CSS；px，C 侧 ×0.75 转 pt）
  local sz = SIZES[args.size or ""] or {}
  local w = tonumber(args.width) or sz[1] or (args.template and 820) or 1280
  -- path(md) 给了 size 就按整页定高（A4 文档 / 16:9 幻灯片），否则 0=按内容定高；
  -- mode=html 的 HTML 页面维持 h=0 的旧行为（模板自己带页高）
  local h = tonumber(args.height) or (args.path and sz[2]) or 0
  if w < 200 then error("pdf: width 太小（" .. w .. "），required: width >= 200") end

  -- 1 取 HTML（pages / html / path(md) / template）
  local htmls, name, md_content = {}, nil, nil
  if args.pages then
    for i, p in ipairs(args.pages) do htmls[i] = tostring(p) end
    if #htmls == 0 then error("pdf: mode=html 时 pages 是空数组") end
  elseif args.html then
    local s = tostring(args.html)
    if s:match("^%s*<") then htmls[1] = s                       -- 裸 HTML 字符串
    else
      local f, err = io.open(s, "rb")
      if not f then error("pdf: html 读不到 " .. s .. "（" .. tostring(err) .. "）") end
      htmls[1] = f:read("*a") f:close()
      name = s:match("([^/]+)%.html?$")
    end
  elseif args.path then
    -- Markdown 直出矢量：与 image 模式同一份 slide_css / md4c，只是出口换成
    -- cairo_pdf_surface —— 文字可选中；字体走仓耳今楷（TrueType 子集），8 页 A4
    -- 从 Noto CJK 的 137KB 降到 36KB（见 body_font 注释）。
    local f = assert(io.open(tostring(args.path), "rb"),
      "pdf: path 读不到 " .. tostring(args.path))
    local src = f:read("*a") f:close()
    local raw = split_pages(src, args.break_on)
    local function page_html(css, body)
      return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>" .. css ..
             "</style></head><body><div class=\"pad\"></div>" ..
             "<div class=\"slide\">" .. body .. "</div></body></html>"
    end
    local css_fixed = md2png.theme_css(slide_css(w, h, h > 0), args.theme)
    local bodies = {}
    for i, src_page in ipairs(raw) do
      local body, rc
      if src_page:match("^%s*<") then body, rc = src_page, 0
      else body, rc = md2png.md_to_html(src_page) end
      if rc < 0 then error(("第 %d 页 md_parse 失败 rc=%d"):format(i, rc)) end
      bodies[i] = body
      htmls[i]  = page_html(css_fixed, body)
    end
    -- 定高页的溢出检测：C 侧 content_h 在「.slide 自己也定了高」时必然 ≥ 页高
    -- （含 .pad 与 8px 根边距），拿它比页高**每页都会误报**。改用 image 模式同一招：
    -- 渲一张 height:auto 的探针图量真实内容高。
    if h > 0 and args.check_overflow ~= false then
      local css_auto = md2png.theme_css(slide_css(w, h, false), args.theme)
      local tmpd = os.getenv("TMPDIR") or "/tmp"
      md_content = {}
      for i, body in ipairs(bodies) do
        local probe = string.format("%s/.pdf-vprobe-%02d.png", tmpd, i)
        md2png.render_png(page_html(css_auto, body), probe, w, 0, 1, env)
        local _, ph_px = md2png.png_size(probe)
        os.remove(probe)
        if ph_px and ph_px > h then md_content[i] = ph_px end
      end
    end
    name = tostring(args.path):match("([^/]+)%.md$")
  elseif args.template then
    local tpl = tostring(args.template)
    if tpl ~= "trending" then
      error("pdf: 未知 template '" .. tpl .. "'（目前只有 trending）；"
        .. "要别的模板就用 html= 给文件，或 pages= 给页数组")
    end
    local trending = load_sibling("trending", env)
    htmls[1] = trending.build(args, env)      -- 与 trending 工具同一份模板
    name = "trending"
  else
    error("pdf: mode=html 需要四者之一 —— path (Markdown 文件) / html (路径或裸 HTML) / template (string) / pages (array)")
  end
  for i, h in ipairs(htmls) do
    if not h:match("<style") then
      error(("pdf: 第 %d 页 HTML 没有内联 <style> —— CSS 不跨页继承也不做主题注入，"
        .. "否则会出一张没样式的白纸（required: 每页完整 HTML）"):format(i))
    end
  end

  -- 2 页面几何（已在步骤 0 定好；这里只补 pt 换算）
  local pt_per_px = 0.75

  -- 3 输出路径
  local base = args.out
  if not base then
    base = (os.getenv("HOME") or "/tmp") .. "/" .. (name or "doc") .. ".pdf"
  end
  if not base:match("%.pdf$") then base = base .. ".pdf" end
  local dir  = base:match("^(.*)/[^/]*$") or "."
  local stem = base:match("([^/]+)%.pdf$") or "doc"

  -- 4 矢量出 PDF（一次调用，C 侧逐页 save/restore 换 surface 尺寸）
  local page_hs, content_hs = md2png.render_pdf(htmls, base, w, h, pt_per_px, env)

  -- 5 预览 PNG（可选）：拿首页真实页高出图，与 PDF 首页像素级一致
  local preview
  if args.keep_png then
    preview = string.format("%s/%s-01.png", dir, stem)
    local scale = tonumber(args.scale) or 2
    md2png.render_png(htmls[1], preview, w, page_hs[1] > 0 and page_hs[1] or 800, scale, env)
  end

  -- 6 报告（md 页面用探针量出的真实内容高；HTML 页面用 C 回填的 content_h）
  local overflows = {}
  if h > 0 and args.check_overflow ~= false then
    if md_content then
      for i = 1, #page_hs do
        local ch = md_content[i]
        if ch and ch > page_hs[i] then
          overflows[#overflows + 1] = string.format("第 %d 页超出 %dpx（内容 %dpx / 页高 %dpx）",
            i, ch - page_hs[i], ch, page_hs[i])
        end
      end
    else
      for i, ch in ipairs(content_hs) do
        if ch > page_hs[i] then
          overflows[#overflows + 1] = string.format("第 %d 页超出 %dpx（内容 %dpx / 页高 %dpx）",
            i, ch - page_hs[i], ch, page_hs[i])
        end
      end
    end
  end
  local ph_min, ph_max = page_hs[1] or 0, page_hs[1] or 0
  for _, v in ipairs(page_hs) do
    if v < ph_min then ph_min = v end
    if v > ph_max then ph_max = v end
  end
  local geo
  if ph_min == ph_max then
    geo = string.format("%dx%dpt（%dx%d px）", math.floor(w * pt_per_px + 0.5),
      math.floor(ph_max * pt_per_px + 0.5), w, ph_max)
  else
    geo = string.format("%dx%d…%dpt（%d px 宽，页高 %d…%d px 按内容）",
      math.floor(w * pt_per_px + 0.5), math.floor(ph_min * pt_per_px + 0.5),
      math.floor(ph_max * pt_per_px + 0.5), w, ph_min, ph_max)
  end
  local lines = {
    string.format("PDF(矢量) %d 页 · 页面 %s · %s → %s",
      #htmls, geo, human(file_size(base)), base),
    "文字可选中/可搜索；litehtml 不分页，要多页请给 pages 数组",
  }
  if preview then lines[#lines + 1] = "预览 PNG: " .. preview end
  if #overflows > 0 then
    lines[#lines + 1] = "⚠ 溢出被裁（拆页 / 加大 height / 去掉 height）: "
      .. table.concat(overflows, "; ")
  end
  return table.concat(lines, "\n")
end

local MODES = { image = "image", raster = "image", png = "image",
                html = "html", vector = "html", pdf = "html" }

function M.run(args, env)
  local mode = MODES[tostring(args.mode or "image"):lower()]
  if not mode then
    error("pdf: 未知 mode '" .. tostring(args.mode) .. "'，可用 image(默认) / html")
  end
  -- mode 不给就按参数推断：给了 template/html 且没给 path 明显想走矢量
  if not args.mode and not args.path and not args.pages and (args.html or args.template) then
    mode = "html"
  end
  if mode == "html" then return run_html(args, env) end
  return run_image(args, env)
end

return M
