-- helper/trending.lua —— GitHub Trending → Kami 排版 → 长图 PNG
--
-- 用法：
--   trending({})                                 默认 9 条、月白色系，出 ~/trending.png（820 宽@2x）
--   trending({out="/tmp/t.png", width=820, height=1420, scale=2, limit=9, since="daily", lang="python"})
--   trending({theme="cinnabar"})                 换色系（默认 moon）：排版仍是 Kami，色值走 lua/gui/theme.lua
--                                                 （light/moon/bamboo/china/sepia/amber/mist/ochre/lotus/indigo/cinnabar/dark）
--
-- 坑（都踩过）：
--   1. HTML 必须一次成型，不要往旧文件追加 <style>；残留的 .page{max-width} 会让内容
--      超出视口，被 --hide-scrollbars 静默裁掉右半边。
--   2. .page 用 width:auto 铺满视口，宽度就不可能溢出。
--   3. 仓库名和统计要在同一行且不粘连：.row{display:flex;gap} + .repo{margin-right}。
--   4. 画布太窄时 19px 仓库名会折行 —— width 别低于 780。
--   5. 底部不要再加 <hr>：最后一条 li 自带 border-bottom，加了就是两条线。
--   6. 字号 = kami 原字号 ×1.2（h1 34→41, repo 16→19, desc 13.5→16, lede 17→20, 小字 12→14.5）。
--   7. os.date 里写 "%%m" 会输出字面量 "%m"，日期要用 "%Y-%m-%d"。
--   8. 描述文本要先剥标签再解实体（&amp; → &）：build_html 的 esc() 会再转义一次，
--      不解就把 "&amp;amp;" 印在图上；解码顺序 &amp; 必须放最后，否则 &amp;lt; 会被解两次。
--   9. 换主题只换 :root 一块（apply_theme），排版规则一律不动 —— 两条正交轴，别混改。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 依赖全景（四层，缺哪层报哪层，不降级；不用 Chrome/WebView/Node）
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ① 插件依赖（本文件自身的运行时）
--    · core.http       抓 https://github.com/trending（libcurl FFI，不 fork、不拼 shell）
--    · 解析器是本文件内的 parse()（纯 Lua gmatch，无外部库；页面结构一变就
--      返回空表，由调用方报错）
--    无 key、无网络代理配置；GitHub 挂了就直接报 http.get 的 rc/HTTP 状态。
--    别退回 io.popen("curl …")：core.http 顺手做了 ACCEPT_ENCODING(自动解 gzip)、
--    重定向、NOSIGNAL、SSL 校验，并把耗时记进 trace.prof 的 http.get —— popen 这些全没有，
--    且卡住只能靠 -m 等满 30s，取消不掉。
--
-- ② 编译依赖（出图后端 liblite_html.so，不进 helper/）
--    src/html/render.cpp → build/liblite_html.so，由 ./tools/build.sh 产出：
--      cmake + cc + /opt/litehtml/{include/litehtml.h, build-pic/liblitehtml.so}
--      /opt/litehtml/build-pic/src/gumbo/libgumbo.so.0   ← litehtml 靠它解析 HTML，dlopen 依赖
--      libcairo.so、libfontconfig.so                     ← CMakeLists.txt:62 显式链接
--    缺 .so 时本文件 error("缺 build/liblite_html.so，先跑 ./tools/build.sh")。
--    验收：./tools/check_deps.sh 会逐项 [OK]/[WARN] litehtml / libgumbo。
--
-- ③ 字体依赖（中文与 ★ 不出方框的唯一原因）
--    cairo "toy font API" 只按**族名**找字，不做字形回退 —— 一个族没有的字直接画 □。
--    所以 render.cpp 在 lite_html_render() 入口用 FcConfigAppFontAddFile 把仓库自带字体
--    塞进进程 fontconfig（只做一次，目录可用 LITE_HTML_FONT_DIR 覆盖，默认 helper/assets）：
--      helper/assets/DroidSansFallbackFull.ttf  族名 "Droid Sans Fallback"  中文全集兜底
--      helper/assets/DejaVuSansMono.ttf         族名 "DejaVu Sans Mono"     ★(U+2605) 等符号
--    族名可用 fc-scan --format '%{family}\n' <ttf> 查。换机器缺字体 → 中文/★ 静默变方框，
--    不会报错，所以 ./tools/check_deps.sh 里对这两个文件有专门检查。
--
-- ④ 样式依赖（排版底）
--    helper/assets/kami.css 是 Kami 模板（暖纸色、细线、字距）。本文件按相对路径找它
--    （helper_dir/assets/kami.css），读不到就退到内联 CSS_FALLBACK —— 仍能出图，只是不像 Kami。
--    两套 CSS 的族名写法不同，别搞混：
--      · kami.css        --serif/--mono 是**多值回退栈**，末尾兜 "Droid Sans Fallback" /
--                        首选取 "DejaVu Sans Mono" —— 依赖 ③ 把这两个族注册进 fontconfig，
--                        任一族存在即可出字。
--      · CSS_FALLBACK    只能写**单族名**：那是崩到兜底样式时的最小集合，没有注册保证，
--                        写多值会静默落回 Sans（★ 变空心框就是这么来的）。
--
-- 实现原理（一条直线，零子进程截图）
--    curl 抓 HTML → parse() 抠出 repo/desc/lang/star/today → 拼成一整份 HTML 字符串
--    （CSS 内联进 <style>，必须一次成型，见上文坑 1）→ render_png() 用 FFI 调
--    lite_html_render(html, out, w, h, scale)：litehtml 解析布局 → cairo 画到 image surface
--    → cairo_surface_write_to_png 直出 PNG。同一份 HTML 顺手写到同名 .html 便于调试。
--    scale=2 表示先按 2 倍像素画（retina），所以 PNG 实际是 w*2 × h*2。
--
-- 排查顺序：出方框 → 查 ③（字体+check_deps）；整张空白/右半截 → 查 ④（CSS 多值族名、
-- .page 宽度）；error 缺 .so → 查 ②（./tools/build.sh）；报 curl → 查 ①（网络）。

local M = { schema = {
  name = "trending",
  description = "GitHub Trending 抓取 + Kami 排版 + 长图截图（PNG + HTML）",
  parameters = { type = "object", properties = {
    out    = { type = "string",  description = "PNG 输出路径，默认 ~/trending.png（同名 .html 一起写）" },
    width  = { type = "number",  description = "视口宽度，默认 820（低于 780 仓库名会折行）" },
    height = { type = "number",  description = "图像高度，默认 0 = 自动测高（按条目数量撑满，加 limit 不用手动调高）" },
    scale  = { type = "number",  description = "device scale factor，默认 2（retina）" },
    limit  = { type = "number",  description = "取前 N 条，默认 9" },
    since  = { type = "string",  description = "daily | weekly | monthly，默认 daily" },
    lang   = { type = "string",  description = "语言过滤，如 python / rust / go" },
    theme  = { type = "string",  description = "色系（light/moon/bamboo/china/sepia/amber/mist/ochre/lotus/indigo/cinnabar/dark），默认 moon 月白（theme.lua:M.CARD_DEFAULT）；排版不变，只换色系令牌" },
  } },
} }

local CSS_FALLBACK = [[
/* 令牌对齐 kami.css 模板；--serif/--mono 只写单一族名：
   cairo toy font API 不认多值列表，写栈会静默落回 Sans（★ 变空心框就是这来的） */
:root{--parchment:#f5f4ed;--ivory:#faf9f5;--ink:#2b2a26;--muted:#6b665c;
  --stone:#9a948a;--hairline:#e4dfd3;--tint:#f1efe6;--brand:#1B365D;
  --serif:"TsangerJinKai02";--mono:"Maple Mono NF CN"}
body{background:var(--parchment);color:var(--ink);font-family:var(--serif)}
]]

-- 色系令牌的唯一真源是 lua/gui/theme.lua（light 与上面 kami.css 的 :root 逐值相同）。
-- 给 theme 就把 :root 整块换掉，其余排版规则（字号/字距/细线）一个字不动 ——
-- 这样"排版 = Kami"和"色系 = 传统色"是两条独立轴，可以任意组合。
-- expand_vars 只认第一个 :root，所以必须替换而不是追加第二段 <style>。
-- 实现在 lua/gui/theme.lua:M.apply，md2png/web2png 用同一份 —— 别在这儿再写一遍。
local function theme_mod()
  local ok, th = pcall(require, "gui.theme")
  if ok and th.apply and th.expand then return th end
  return nil
end

local function apply_theme(css, name)
  local th = theme_mod()
  if not th then return css end
  return th.apply(css, name)
end

-- kami.css 是排版底，缺了就用兜底最小样式（仍能出图，只是不像 Kami）
local function load_css(env)
  local dirs = { (env and env.helper_dir) or "helper",
                 ((env and env.cwd) or ".") .. "/helper" }
  for _, d in ipairs(dirs) do
    local p = d .. "/assets/kami.css"
    local f = io.open(p, "r")
    if f then local s = f:read("*a"); f:close(); return s end
  end
  return CSS_FALLBACK
end

-- 展开 CSS 里的 var(--x)：litehtml 不解析 CSS 变量。实现同在 lua/gui/theme.lua:M.expand。
local function expand_vars(css)
  local th = theme_mod()
  if not th then return css end
  return th.expand(css)
end

local function esc(s)
  return (tostring(s or ""):gsub("[&<>]", function(c)
    return ({ ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" })[c]
  end))
end

-- 抓 HTML；rc≠0 / 非 200 / 过短都直接抛，避免出空白图。
-- 4MB 上限：trending 页面带内联 SVG 与整段 CSS，实测 ~300KB，留足余量（默认 1MB 会截断）。
local function fetch(url)
  local http = require("core.http")
  local rc, status, body = http.get(url, { "User-Agent: Mozilla/5.0" }, 4 * 1024 * 1024, 30)
  if rc ~= 0 then
    error(("抓取失败: curl rc=%s（%s）；url=%s"):format(tostring(rc), tostring(body), url))
  end
  if status ~= 200 then error(("抓取失败: HTTP %s；url=%s"):format(tostring(status), url)) end
  local h = body or ""
  if #h < 2000 then error("抓取失败或返回过短: " .. url .. " (" .. #h .. " bytes)") end
  return h
end

-- article 块内逐个字段抽；trending 页面结构变了这里会返回空表，由调用方报错
local function parse(html)
  local items = {}
  for art in html:gmatch('<article class="Box%-row[^"]*"(.-)</article>') do
    local repo = art:match('<h2 class="[^"]*">%s*<a[^>]-href="/([^"]+)"')
    local desc = art:match('<p class="[^"]*">(.-)</p>')
    local lang = art:match('<span itemprop="programmingLanguage">([^<]+)</span>')
    local star = art:match("([%d,]+)[^%d]-stars today")
    if repo then
      -- 先剥标签再解实体：esc() 出图时会再转义一次，这里不解就成 &amp;amp; → 图上印 "&amp;"
      if desc then
        desc = desc:gsub("<[^>]->", "")
          :gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">")
          :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&amp;", "&")
          :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      end
      items[#items + 1] = { repo = repo, desc = desc or "", lang = lang or "—", star = star or "0" }
    end
  end
  return items
end

local function build_html(items, css)
  local li = {}
  for _, v in ipairs(items) do
    li[#li + 1] = ([[<li><div class="row"><span class="repo">%s</span><span class="stat">+%s <span class="star">★</span> <span class="dim">%s</span></span></div><div class="desc">%s</div></li>]])
      :format(esc(v.repo), esc(v.star), esc(v.lang), esc(v.desc))
  end
  return ([[<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<style>%s</style>
<style>
html,body{margin:0;padding:0;background:var(--parchment)}
.page{max-width:none;width:auto;margin:0;padding:32px 34px 36px}
.head{align-items:baseline}
.eyebrow{font-size:14.5px;letter-spacing:1.8px}
.head .meta{font-size:14.5px}
h1{font-size:41px;margin:5px 0 0}
hr.hairline{margin:17px 0 20px}
.lede{font-size:20px;margin:0 0 14px}
ol.tr{list-style:none;padding-left:0;margin:0;counter-reset:t}
ol.tr li{counter-increment:t;position:relative;padding:15px 0 16px 50px;border-bottom:1px solid var(--hairline)}
ol.tr li::before{content:counter(t);position:absolute;left:0;top:16px;font-family:var(--mono);font-size:14.5px;color:var(--stone)}
.row{display:block}
.repo{margin-right:14px;font-size:19px;font-weight:500;line-height:1.3}
.stat{font-family:var(--mono);font-size:14.5px;color:var(--brand);white-space:nowrap}
.dim{color:var(--stone)}
.desc{font-size:16px;line-height:1.55;margin-top:5px;color:#5a5a52}
</style></head><body>
<div class="page">
  <div class="head">
    <div><div class="eyebrow">GITHUB TRENDING</div><h1>GitHub 今日热门</h1></div>
    <div class="meta">%s</div>
  </div>
  <hr class="hairline">
  <p class="lede">今日 GitHub Trending 前 %d 个项目。</p>
  <ol class="tr">%s</ol>
</div></body></html>]]):format(css, os.date("%Y-%m-%d · %A"), #items, table.concat(li))
end

-- 出图后端：只有一个，自带的 liblite_html.so（litehtml + cairo，零子进程、零 Chrome）。
local function render_png(html, out, width, height, scale, env)
  local root = (env and env.cwd) or "."
  local lib
  for _, p in ipairs({ root .. "/build/liblite_html.so",
                       ((env and env.helper_dir) or "helper") .. "/../build/liblite_html.so" }) do
    local f = io.open(p, "rb")
    if f then f:close(); lib = p; break end
  end
  if not lib then error("缺 build/liblite_html.so，先跑 ./tools/build.sh") end
  local ffi = require("ffi")
  ffi.cdef[[int lite_html_render(const char*,const char*,int,int,double);
            const char* lite_html_error(void);]]
  local L = ffi.load(lib)
  if L.lite_html_render(html, out, width, height, scale) ~= 0 then
    error("出图失败: " .. tostring(ffi.string(L.lite_html_error())))
  end
end

-- 只产 HTML（不出图）：pdf 的 template="trending" 走这条，保证两边是**同一份模板**。
-- 返回 html, 条数, 源 url。
function M.build(args, env)
  args = args or {}
  local limit = tonumber(args.limit) or 9
  local url = "https://github.com/trending"
  local qs = {}
  if args.since and args.since ~= "" then qs[#qs + 1] = "since=" .. args.since end
  if args.lang  and args.lang  ~= "" then url = url .. "/" .. args.lang end
  if #qs > 0 then url = url .. "?" .. table.concat(qs, "&") end

  local items = parse(fetch(url))
  if #items == 0 then error("解析到 0 条，GitHub 页面结构可能变了: " .. url) end
  while #items > limit do items[#items] = nil end

  local html = build_html(items, expand_vars(apply_theme(load_css(env), args.theme)))
  return html, #items, url
end

function M.run(args, env)
  args = args or {}
  local home = os.getenv("HOME") or "/tmp"
  local out   = args.out or (home .. "/trending.png")
  if not out:match("%.png$") then error("out 必须以 .png 结尾: " .. out) end
  local width  = tonumber(args.width)  or 820
  local height = tonumber(args.height) or 0 -- 0 = 自动测高
  local scale  = tonumber(args.scale)  or 2
  if width < 780 then error("width 太小（" .. width .. "），19px 仓库名会折行；required: width >= 780") end

  local html, nitems = M.build(args, env)
  local html_path = out:gsub("%.png$", ".html")
  local wf = assert(io.open(html_path, "w")); wf:write(html); wf:close()

  render_png(html, out, width, height, scale, env)
  local pf = io.open(out, "r")
  if not pf then error("出图失败: " .. out) end
  local sz = pf:seek("end"); pf:close()
  if sz < 10000 then error("出图过小（" .. sz .. " bytes），可能空白: " .. out) end

  -- 读 PNG IHDR 拿真实像素尺寸（h=0 自动测高时才知道最终高度）
  local pw, ph = (function()
    local f2 = io.open(out, "rb")
    if not f2 then return width * scale, 0 end
    local d = f2:read(24) f2:close()
    if not d or #d < 24 then return width * scale, 0 end
    local b = { d:byte(17, 24) }
    local function be(i) return ((b[i] * 256 + b[i+1]) * 256 + b[i+2]) * 256 + b[i+3] end
    return be(1), be(5)
  end)()

  return ("%d 条 · %dx%d @%dx · litehtml\nPNG: %s (%d KB)\nHTML: %s"):format(
    nitems, pw, ph, scale, out, math.floor(sz / 1024), html_path)
end

return M
