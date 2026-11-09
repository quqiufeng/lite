-- helper/trending.lua —— GitHub Trending → Kami 排版 → 长图 PNG
--
-- 用法：
--   trending({})                                 默认 9 条，出 ~/trending.png（820x1420@2x）
--   trending({out="/tmp/t.png", width=820, height=1420, scale=2, limit=9, since="daily", lang="python"})
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
--
-- 依赖：curl（抓页面）、google-chrome --headless（出图）。都缺就报错，不降级。

local M = { schema = {
  name = "trending",
  description = "GitHub Trending 抓取 + Kami 排版 + 长图截图（PNG + HTML）",
  parameters = { type = "object", properties = {
    out    = { type = "string",  description = "PNG 输出路径，默认 ~/trending.png（同名 .html 一起写）" },
    width  = { type = "number",  description = "视口宽度，默认 820（低于 780 仓库名会折行）" },
    height = { type = "number",  description = "视口高度，默认 1420（9 条够用；加 limit 要同步加高）" },
    scale  = { type = "number",  description = "device scale factor，默认 2（retina）" },
    limit  = { type = "number",  description = "取前 N 条，默认 9" },
    since  = { type = "string",  description = "daily | weekly | monthly，默认 daily" },
    lang   = { type = "string",  description = "语言过滤，如 python / rust / go" },
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

-- 展开 CSS 里的 var(--x)：litehtml 不解析 CSS 变量。取 :root 块里的定义。
local function expand_vars(css)
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

local function esc(s)
  return (tostring(s or ""):gsub("[&<>]", function(c)
    return ({ ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" })[c]
  end))
end

-- 抓 HTML；curl 失败或空串直接抛，避免出空白图
local function fetch(url)
  local f = io.popen(('curl -sS -m 30 -A "Mozilla/5.0" %q 2>/dev/null'):format(url))
  if not f then error("无法启动 curl（检查是否安装）") end
  local h = f:read("*a"); f:close()
  if not h or #h < 2000 then error("抓取失败或返回过短: " .. url .. " (" .. tostring(h and #h) .. " bytes)") end
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
      if desc then desc = desc:gsub("<[^>]->", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "") end
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

function M.run(args, env)
  args = args or {}
  local home = os.getenv("HOME") or "/tmp"
  local out   = args.out or (home .. "/trending.png")
  if not out:match("%.png$") then error("out 必须以 .png 结尾: " .. out) end
  local width  = tonumber(args.width)  or 820
  local height = tonumber(args.height) or 1420
  local scale  = tonumber(args.scale)  or 2
  local limit  = tonumber(args.limit)  or 9
  if width < 780 then error("width 太小（" .. width .. "），19px 仓库名会折行；required: width >= 780") end

  local url = "https://github.com/trending"
  local qs = {}
  if args.since and args.since ~= "" then qs[#qs + 1] = "since=" .. args.since end
  if args.lang  and args.lang  ~= "" then url = url .. "/" .. args.lang end
  if #qs > 0 then url = url .. "?" .. table.concat(qs, "&") end

  local items = parse(fetch(url))
  if #items == 0 then error("解析到 0 条，GitHub 页面结构可能变了: " .. url) end
  while #items > limit do items[#items] = nil end

  local html = build_html(items, expand_vars(load_css(env)))
  local html_path = out:gsub("%.png$", ".html")
  local wf = assert(io.open(html_path, "w")); wf:write(html); wf:close()

  render_png(html, out, width, height, scale, env)
  local pf = io.open(out, "r")
  if not pf then error("出图失败: " .. out) end
  local sz = pf:seek("end"); pf:close()
  if sz < 10000 then error("出图过小（" .. sz .. " bytes），可能空白: " .. out) end

  return ("%d 条 · %.1fx%d @%dx · litehtml\nPNG: %s (%d KB)\nHTML: %s"):format(
    #items, width, height, scale, out, math.floor(sz / 1024), html_path)
end

return M
