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

local function cdef()
  if pcall(ffi.typeof, "MD_PARSER") then return end
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
    int lite_html_render(const char*, const char*, int, int, double);
  ]]
end

local function md_to_html(src)
  cdef()
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

  local cb_enter_span = ffi.cast("int (*)(int,void*,void*)", function(t)
    if t == SPAN.EM then emit("<em>") elseif t == SPAN.STRONG then emit("<strong>")
    elseif t == SPAN.DEL then emit("<del>") elseif t == SPAN.CODE then emit("<code>") end
    return 0
  end)
  local cb_leave_span = ffi.cast("int (*)(int,void*,void*)", function(t)
    if t == SPAN.EM then emit("</em>") elseif t == SPAN.STRONG then emit("</strong>")
    elseif t == SPAN.DEL then emit("</del>") elseif t == SPAN.CODE then emit("</code>") end
    return 0
  end)
  -- MD_TEXTTYPE: 0=NORMAL 1=NULLCHAR 2=BR 3=SOFTBR 4=HTML 5=ENTITY 6=CODE
  local cb_text = ffi.cast("int (*)(int,const char*,unsigned,void*)", function(tt, p, n)
    local s = ffi.string(p, n)
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

local function render_png(html, out, w, h, scale, env)
  local cands = { "build/liblite_html.so",
                  ((env and env.helper_dir) or "helper") .. "/../build/liblite_html.so" }
  local lib
  for _, p in ipairs(cands) do
    local ok, l = pcall(ffi.load, p)
    if ok then lib = l break end
  end
  if not lib then
    -- 安装版：$LITE_ROOT/build/ 里除了 liblite_html.so 还必须躺着它的私有依赖
    -- liblitehtml.so.0 + libgumbo.so.0（同一目录 $ORIGIN 自解析，由 tools/package.sh 带入）。
    -- 只缺后两者时 dlopen 报的是 "libgumbo.so.0: cannot open shared object"，别误判成没编译。
    error("缺 " .. cands[1] .. " / " .. cands[2] .. "\n"
      .. "  源码树：./tools/build.sh\n"
      .. "  安装版：./tools/release.sh（打包会带上 liblitehtml.so.0 + libgumbo.so.0）\n"
      .. "  自检：./tools/check_deps.sh | grep lite_html")
  end
  if lib.lite_html_render(html, out, w, h, scale) ~= 0 then
    error("lite_html_render 失败（检查 PNG 路径可写、字体目录 helper/assets 存在）")
  end
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

return M
