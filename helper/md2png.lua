-- helper/md2png.lua —— Markdown 文件 → HTML → 长图 PNG（零子进程、零 Chrome）
--
-- 用法：
--   md2png({path="README.md"})                          默认出 ~/<name>.png，宽 820，scale 2
--   md2png({path="a.md", out="/tmp/a.png", width=820, scale=2, gfm=true})
--   md2png({path="a.md", theme="cinnabar"})             换色系（light/moon/bamboo/china/dark…）
--
-- 依赖（四层，缺哪层报哪层）：
--   ① 解析：libmd4c.so.0（系统已装 /lib/x86_64-linux-gnu/libmd4c.so.0，MIT，GFM 全支持）
--      本机**没有 md4c.h**，cdef 按 `nm -D --defined-only` 的导出符号手写：只有 md_parse。
--      md_parse 是回调式 API（MD_PARSER 五个函数指针），本文件在 LuaJIT FFI 回调里直接拼 HTML。
--   ② 出图：build/liblite_html.so（litehtml + cairo），./tools/build.sh 产出。缺则报错。
--   ③ 字体：src/html/render.cpp 注册 helper/assets 两个 ttf；无字体则中文/★ 变方框（不报错）。
--   ④ 样式：本文件内联 MD_CSS（cairo toy font 只认单族名，禁写字体栈）。
--
-- 原理：read file → md_parse 边解析边吐 HTML 片段 → 包一层 <style> → FFI 调
--       lite_html_render(html, out, w, h, scale) → cairo 出 PNG。同名 .html 一起落盘便于调试。
-- 坑：md4c 的 abi_version 必须 = 0（cdef 里写死），结构体字段顺序不能错，否则崩在回调里。

local ffi = require("ffi")
local M = { schema = {
  name = "md2png",
  description = "Markdown → HTML → 长图 PNG（md4c + litehtml，零 Chrome）",
  parameters = { type = "object", properties = {
    path  = { type = "string",  description = "Markdown 文件路径（必填）" },
    out   = { type = "string",  description = "PNG 输出路径，默认 ~/<name>.png（同名 .html 一起写）" },
    width = { type = "number",  description = "视口宽度，默认 820" },
    height= { type = "number",  description = "图像高度，默认 0 = 自动测高（按内容撑满）；给正数则固定高度、超出裁掉" },
    scale = { type = "number",  description = "device scale factor，默认 2" },
    gfm   = { type = "boolean", description = "GitHub 方言（表格/任务列表/删除线），默认 true" },
    theme = { type = "string",  description = "色系：moon(默认)/light/bamboo/china/indigo/cinnabar/dark；版式不变" },
    base_dir = { type = "string", description = "相对图片路径基准目录，默认 md 所在目录（md 里 ![](sub/a.png) 就按它解析）；"
                  .. "给了 md 就不必给" },
  }, required = { "path" } },
} }

-- 颜色一律走 var(--token)，由 lua/gui/theme.lua 提供 :root 并展开（litehtml 不认 CSS 变量）。
-- 版式（字号/行高/字距/内边距）留在这里，色系（--parchment/--ink/--brand…）由 args.theme 决定，
-- 两条轴分开：换色不动版式，改版式不动色。新增颜色别写死 hex，先在 theme.lua 的 M.css 里加令牌。
local MD_CSS = [[
body{margin:0;background:var(--parchment);color:var(--ink);font-family:"Noto Sans CJK SC";font-size:16px;line-height:1.65}
.page{width:auto;padding:44px 52px}
h1,h2,h3,h4{font-family:"Noto Sans CJK SC";color:var(--brand);line-height:1.3;margin:1.4em 0 .6em}
h1{font-size:33px;border-bottom:1px solid var(--hairline);padding-bottom:.3em;margin-top:0}
h2{font-size:25px}h3{font-size:20px}h4{font-size:17px}
p{margin:.75em 0}strong{color:var(--brand)}
a{color:var(--brand);text-decoration:none}
code{font-family:"DejaVu Sans Mono";font-size:14px;background:var(--tint);padding:1px 5px;border-radius:3px}
pre{background:var(--tint);border:1px solid var(--hairline);border-radius:5px;padding:14px 16px;overflow:hidden}
pre code{background:none;padding:0;font-size:13.5px;line-height:1.5}
blockquote{margin:.9em 0;padding:.2em 1em;border-left:3px solid var(--brand);color:var(--muted);background:var(--tint)}
ul,ol{margin:.7em 0;padding-left:1.6em}li{margin:.28em 0}
hr{border:0;border-top:1px solid var(--hairline);margin:1.5em 0}
table{border-collapse:collapse;margin:1em 0;width:100%}
th,td{border:1px solid var(--hairline);padding:7px 11px;text-align:left;font-size:14.5px}
th{background:var(--tint);color:var(--brand)}
img{max-width:100%}
]]

local function esc(s)
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
  return s
end

-- 色系唯一真源在 lua/gui/theme.lua：M.page_css 吐 <主题 :root> + 上面 MD_CSS 并把 var() 展开。
-- 拿不到主题模块就直接报错 —— MD_CSS 里的颜色全是 var()，静默降级会出白底白字。
local function theme_css(body_css, name)
  local ok, th = pcall(require, "gui.theme")
  if not ok then
    error("md2png: 读不到 lua/gui/theme.lua（色系真源），确认 package.path 含仓库 lua/")
  end
  return th.page_css(body_css, name)
end

-- md4c 常量（md4c.h）
local BLOCK = { DOC=0, QUOTE=1, UL=2, OL=3, LI=4, HR=5, H=6, CODE=7, HTML=8, P=9,
                TABLE=10, THEAD=11, TBODY=12, TR=13, TH=14, TD=15 }
local SPAN = { EM=0, STRONG=1, A=2, IMG=3, CODE=4, DEL=5, LATEXMATH=6, LATEXMATH_DISPLAY=7,
               WIKILINK=8, U=9 }

-- 坑：MD_PARSER 是**共享**声明（helper/lib/md4c.lua 也 cdef 它），所以别拿
-- 「MD_PARSER 已存在」当「本文件都声明过了」—— 先加载 md4c 时本文件的 lite_html_*
-- 就会被跳过，调用时才炸 missing declaration。两个 cdef 各自用私有 marker 判定。
local function cdef()
  if not pcall(ffi.typeof, "MD_PARSER") then
    ffi.cdef[[
      typedef struct MD_PARSER {
        unsigned abi_version; int flags;
        int (*enter_block)(int, void*, void*);
        int (*leave_block)(int, void*, void*);
        int (*enter_span)(int, void*, void*);
        int (*leave_span)(int, void*, void*);
        int (*text)(int, const char*, unsigned, void*);
        void (*debug_log)(const char*, void*);
        void (*syntax)(void*);
      } MD_PARSER;
      int md_parse(const char*, unsigned, const MD_PARSER*, void*);
    ]]
  end
  if pcall(ffi.typeof, "lite_html_render_declared_t") then return end
  ffi.cdef[[
    int lite_html_render(const char*, const char*, int, int, double);
    int lite_html_render_pdf(const char* const*, int, const char*, int, int, double,
                             int*, int*);
    const char* lite_html_error(void);
    void lite_html_set_base_dir(const char*);
    typedef int lite_html_render_declared_t;
  ]]
end

-- md4c 的 MD_ATTRIBUTE：`![](src "title")` 的 src 只藏在这里，指针**只在 enter_span
-- 回调期间有效**，必须当场读出来。布局（md4c.h）：text,size,substr_count,substr_types,
-- substr_offsets —— substr_count=0 表示整串就是值；>0 时要按 substr 段拼（段类型里可能是
-- ENTITY/NULLCHAR，属性值才不是字面量）。
local function cdef_attr()
  if pcall(ffi.typeof, "MD_ATTR_PIECES") then return end
  ffi.cdef[[
    /* 字段名可以随便写（FFI 按声明顺序算偏移），叫 end 会撞 Lua 关键字 */
    typedef struct MD_OFFSET_PIECE { unsigned first; unsigned last; } MD_OFFSET_PIECE;
    typedef struct MD_ATTR_PIECES {
      const char* text;
      unsigned size;
      unsigned substr_count;
      const int* substr_types;
      const MD_OFFSET_PIECE* substr_offsets;
    } MD_ATTR_PIECES;
  ]]
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

local function decode_entity(piece)
  local body = piece:match("^&(.-);$") or piece:match("^&?(.-);?$") or piece
  local named = ENTITIES[body]
  if named then return named end
  local dec = body:match("^#(%d+)$")
  if dec then return utf8.char(tonumber(dec)) end
  local hex = body:match("^#[xX](%x+)$")
  if hex then return utf8.char(tonumber(hex, 16)) end
  return body
end

-- MD_ATTRIBUTE*（detail 的首字段）→ Lua 字符串；非法/空返回 ""
local function attr_string(p)
  if p == nil then return "" end
  local a = ffi.cast("MD_ATTR_PIECES*", p)
  if a.text == nil or a.size == 0 then return "" end
  if a.substr_count == 0 or a.substr_types == nil or a.substr_offsets == nil then
    return ffi.string(a.text, a.size)
  end
  local acc = {}
  for i = 0, a.substr_count - 1 do
    local t = a.substr_types[i]
    local beg, fin = a.substr_offsets[i].first, a.substr_offsets[i].last
    if fin > beg then
      local s = ffi.string(a.text + beg, fin - beg)
      if t == 1 then                        -- MD_TEXT_NULLCHAR（U+0000）：丢掉
        s = nil
      elseif t == 5 then acc[#acc + 1] = decode_entity(s)   -- MD_TEXT_ENTITY
      else acc[#acc + 1] = s end
    end
  end
  return table.concat(acc)
end

local function md_to_html(src)
  cdef()
  cdef_attr()
  local md
  for _, so in ipairs({ "libmd4c.so.0", "libmd4c.so", "md4c" }) do
    local ok, l = pcall(ffi.load, so)
    if ok then md = l break end
  end
  if not md then error("缺 libmd4c（apt/dnf 装 md4c 或 libmd4c0）") end
  local out = {}
  local function emit(s) out[#out+1] = s end
  local raw = ffi.new("char[?]", #src + 1, src)

  local hlevels = {}
  local cb_enter_block = ffi.cast("int (*)(int,void*,void*)", function(t, d)
    if t == BLOCK.H then
      local lvl = 1
      if d ~= nil then lvl = ffi.cast("unsigned*", d)[0] end -- MD_BLOCK_H_DETAIL.level 是首字段
      if lvl < 1 or lvl > 6 then lvl = 1 end
      hlevels[#hlevels + 1] = lvl
      emit("<h" .. lvl .. ">")
    elseif t == BLOCK.P then emit("<p>")
    elseif t == BLOCK.LI then emit("<li>")
    elseif t == BLOCK.UL then emit("<ul>")
    elseif t == BLOCK.OL then emit("<ol>")
    elseif t == BLOCK.QUOTE then emit("<blockquote>")
    elseif t == BLOCK.HR then emit("<hr>")
    elseif t == BLOCK.CODE then emit("<pre><code>")
    elseif t == BLOCK.TABLE then emit("<table>")
    elseif t == BLOCK.THEAD then emit("<thead>")
    elseif t == BLOCK.TBODY then emit("<tbody>")
    elseif t == BLOCK.TR then emit("<tr>")
    elseif t == BLOCK.TH then emit("<th>")
    elseif t == BLOCK.TD then emit("<td>") end
    return 0
  end)

  local cb_leave_block = ffi.cast("int (*)(int,void*,void*)", function(t)
    if t == BLOCK.H then
      local lvl = table.remove(hlevels) or 1
      emit("</h" .. lvl .. ">")
    elseif t == BLOCK.P then emit("</p>")
    elseif t == BLOCK.LI then emit("</li>")
    elseif t == BLOCK.UL then emit("</ul>")
    elseif t == BLOCK.OL then emit("</ol>")
    elseif t == BLOCK.QUOTE then emit("</blockquote>")
    elseif t == BLOCK.CODE then emit("</code></pre>")
    elseif t == BLOCK.TABLE then emit("</table>")
    elseif t == BLOCK.THEAD then emit("</thead>")
    elseif t == BLOCK.TBODY then emit("</tbody>")
    elseif t == BLOCK.TR then emit("</tr>")
    elseif t == BLOCK.TH then emit("</th>")
    elseif t == BLOCK.TD then emit("</td>") end
    return 0
  end)

  -- 图片：md4c 把 src 放进 enter_span 的 detail（只在回调期间有效），alt 是随后的
  -- text 回调 → 先攒着，leave_span 时一次性吐 <img>。不认 {{width=…}} 这类扩展。
  local img_depth, img_src, img_alt = 0, "", nil
  local cb_enter_span = ffi.cast("int (*)(int,void*,void*)", function(t, d)
    if t == SPAN.EM then emit("<em>") elseif t == SPAN.STRONG then emit("<strong>")
    elseif t == SPAN.DEL then emit("<del>") elseif t == SPAN.CODE then emit("<code>")
    elseif t == SPAN.IMG then
      img_depth = img_depth + 1
      img_src = attr_string(d)          -- detail 首字段就是 MD_ATTRIBUTE src
      img_alt = {}
    end
    return 0
  end)
  local cb_leave_span = ffi.cast("int (*)(int,void*,void*)", function(t)
    if t == SPAN.EM then emit("</em>") elseif t == SPAN.STRONG then emit("</strong>")
    elseif t == SPAN.DEL then emit("</del>") elseif t == SPAN.CODE then emit("</code>")
    elseif t == SPAN.IMG then
      img_depth = img_depth - 1
      local alt = img_alt and table.concat(img_alt) or ""
      if img_src ~= "" then
        emit('<img src="' .. esc(img_src):gsub('"', "&quot;") .. '" alt="' .. esc(alt) .. '">')
      elseif alt ~= "" then emit(esc(alt)) end   -- 空 src 时至少留下替代文字
      img_src, img_alt = "", nil
    end
    return 0
  end)
  -- MD_TEXTTYPE: 0=NORMAL 1=NULLCHAR 2=BR 3=SOFTBR 4=HTML 5=ENTITY 6=CODE
  local cb_text = ffi.cast("int (*)(int,const char*,unsigned,void*)", function(tt, p, n)
    local s = ffi.string(p, n)
    if img_depth > 0 and img_alt then img_alt[#img_alt + 1] = s return 0 end
    if tt == 4 or tt == 6 then emit(s) elseif tt == 2 then emit("<br>")
    elseif tt == 3 then emit(" ") else emit(esc(s)) end
    return 0
  end)

  local parser = ffi.new("MD_PARSER")
  parser.abi_version = 0
  parser.flags = 0x0100 + 0x0200 + 0x0800 -- TABLES | STRIKETHROUGH | TASKLISTS
  parser.enter_block = cb_enter_block
  parser.leave_block = cb_leave_block
  parser.enter_span = cb_enter_span
  parser.leave_span = cb_leave_span
  parser.text = cb_text
  local rc = md.md_parse(raw, #src, parser, nil)
  return table.concat(out), rc
end

-- dlopen liblite_html（图版和 PDF 版共用同一个 .so，加载失败信息也只写一份）
local function load_html_lib(env)
  cdef()   -- 只走 PDF 分支时 md_to_html 不会被调用，这里补一次（cdef 自己幂等）
  local cands = { "build/liblite_html.so",
                  ((env and env.helper_dir) or "helper") .. "/../build/liblite_html.so" }
  for _, p in ipairs(cands) do
    local ok, l = pcall(ffi.load, p)
    if ok then return l end
  end
  -- 安装版：$LITE_ROOT/build/ 里除了 liblite_html.so 还必须躺着它的私有依赖
  -- liblitehtml.so.0 + libgumbo.so.0（同一目录 $ORIGIN 自解析，由 tools/package.sh 带入）。
  -- 只缺后两者时 dlopen 报的是 "libgumbo.so.0: cannot open shared object"，别误判成没编译。
  error("缺 " .. cands[1] .. " / " .. cands[2] .. "\n"
    .. "  源码树：./tools/build.sh\n"
    .. "  安装版：./tools/release.sh（打包会带上 liblitehtml.so.0 + libgumbo.so.0）\n"
    .. "  自检：./tools/check_deps.sh | grep lite_html")
end

local base_dir = ""  -- 相对图片路径基准；空 = 进程 cwd。必须声明在 render_png 之前：
-- 声明在后面的话函数里读到的是同名**全局** nil，set_base_dir 白设（踩过）。
local function render_png(html, out, w, h, scale, env)
  local lib = load_html_lib(env)
  -- 相对 <img src>/url() 的基准目录（md 所在目录）。不设就落到进程 cwd，
  -- 于是 helper/md2png.lua 里写 ![](img/a.png) 的文档会因为 agent 的 cwd 不同而丢图。
  lib.lite_html_set_base_dir(base_dir)
  if lib.lite_html_render(html, out, w, h, scale) ~= 0 then
    error("lite_html_render 失败（检查 PNG 路径可写、字体目录 helper/assets 存在）: "
      .. tostring(ffi.string(lib.lite_html_error())))
  end
end

-- 矢量 PDF：同一套布局/绘制，surface 换成 cairo_pdf_surface（文字可选中/可搜索）。
-- htmls 是页数组，每页一段**完整** HTML（自带 <style>，CSS 不跨页继承）。
-- h = 0 → 每页按内容高度定页（长卡片出一整页长纸）；h > 0 → 固定页高，超出裁掉。
-- pt_per_px 默认 0.75（96dpi 屏 px → 72pt/inch，与图版 PDF 几何一致）。
-- 返回 page_hs（每页最终页高，CSS px）、content_hs（每页内容高度，CSS px；>page_h 即溢出）。
local function render_pdf(htmls, out_pdf, w, h, pt_per_px, env)
  if type(htmls) == "string" then htmls = { htmls } end
  if type(htmls) ~= "table" or #htmls == 0 then error("render_pdf: htmls 需要非空数组") end
  local lib = load_html_lib(env)
  lib.lite_html_set_base_dir(base_dir)
  local n = #htmls
  local arr = ffi.new("const char*[?]", n)
  local keep = {}                       -- 防止 GC 提前回收页面字符串
  for i = 1, n do
    local s = tostring(htmls[i])
    keep[i] = ffi.new("char[?]", #s + 1, s)
    arr[i - 1] = keep[i]
  end
  local ph = ffi.new("int[?]", n)
  local ch = ffi.new("int[?]", n)
  local rc = lib.lite_html_render_pdf(arr, n, out_pdf, w, h, tonumber(pt_per_px) or 0.75, ph, ch)
  if rc ~= 0 then
    error(("lite_html_render_pdf 失败 rc=%d（检查 PDF 路径可写、字体目录 helper/assets 存在）: %s")
      :format(rc, tostring(ffi.string(lib.lite_html_error()))))
  end
  local page_hs, content_hs = {}, {}
  for i = 1, n do page_hs[i] = ph[i - 1]; content_hs[i] = ch[i - 1] end
  return page_hs, content_hs
end

-- 读 PNG IHDR 拿真实像素尺寸（h=0 自动测高时才知道最终高度）
local function png_size(path)
  local f = io.open(path, "rb")
  if not f then return 0, 0 end
  local d = f:read(24) f:close()
  if not d or #d < 24 then return 0, 0 end
  local b = { d:byte(17, 24) }
  local function be(i) return ((b[i] * 256 + b[i+1]) * 256 + b[i+2]) * 256 + b[i+3] end
  return be(1), be(5)
end

function M.run(args, env)
  if not args.path then error("md2png: required: path (string)") end
  local f = assert(io.open(args.path, "rb"), "读不到 " .. args.path)
  local src = f:read("*a") f:close()
  base_dir = args.base_dir or args.path:match("^(.*)/") or ""   -- md 里 ![](sub/a.png) 以 md 目录为准
  local width  = tonumber(args.width)  or 820
  local height = tonumber(args.height) or 0 -- 0 = 自动测高
  local scale  = tonumber(args.scale)  or 2
  local body, rc = md_to_html(src)
  if rc < 0 then error("md_parse 失败 rc=" .. rc) end

  local home = os.getenv("HOME") or "/tmp"
  local name = args.path:match("([^/]+)%.md$") or "md"
  local out = args.out or (home .. "/" .. name .. ".png")
  local css = theme_css(MD_CSS, args.theme)
  local html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>" .. css ..
               "</style></head><body><div class=\"page\">" .. body .. "</div></body></html>"
  local hp = out:gsub("%.png$", "") .. ".html"
  local hf = io.open(hp, "wb") if hf then hf:write(html) hf:close() end
  render_png(html, out, width, height, scale, env)
  -- 工具返回值必须是字符串（返回 table 会被 tostring 成 "table: 0x..."）
  local size = (function() local s = io.open(out, "rb") if not s then return 0 end
    local n = s:seek("end") s:close() return n end)()
  local pw, ph = png_size(out)
  return string.format("PNG %dx%d (%d 字节) → %s\nHTML → %s",
    pw, ph, size, out, hp)
end

-- 供其它插件复用（helper/pdf.lua 按页出图就是这么用的）：
-- 这三件事各自都不小（md4c 回调拼 HTML / dlopen liblite_html / 读 PNG IHDR），
-- 复制一份就是两份漂移源。**改这里就是改所有调用方**。
M.md_to_html = md_to_html      -- (src) -> html_body, rc
M.render_png = render_png      -- (html, out_png, w, h, scale, env)
M.render_pdf = render_pdf      -- (htmls[], out_pdf, w, h, pt_per_px, env) 矢量 PDF，文字可选中
M.png_size   = png_size        -- (path) -> px_w, px_h（h=0 自动测高后靠它知道真实高度）
M.theme_css  = theme_css       -- (body_css, theme_name) -> <style> 内容（含 var() 展开）
-- 相对图片路径基准：md2png/pdf 的 run 会按 md 所在目录自动设；pages/inline HTML 场景由调用方设。
M.set_base_dir = function(dir) base_dir = dir or "" end
M.get_base_dir = function() return base_dir end

return M
