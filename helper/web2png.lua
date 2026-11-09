-- helper/web2png.lua —— URL → 资料卡片 PNG（取正文 → 卡片模板 → 长图）
--
-- 用法：
--   web2png({url="https://example.com/post"})
--   web2png({url="...", out="/tmp/card.png", width=760, scale=2, title="自定义标题"})
--   web2png({url="...", max_chars=3000})     # 正文截断长度（默认 6000 字）
--
-- 链路：
--   ① 取正文：有 DEEPSEEK_API_KEY → helper/lib/deepseek.lua 的 /v1/tools/fetch（干净 Markdown）；
--      没 key → require("core.http") GET 原始 HTML，去掉 script/style/标签后按段落拼文本（降级但可用）。
--   ② Markdown → HTML 片段：helper/lib/md4c.lua（md4c FFI）。
--   ③ 模板：kicker 域名 + h1 标题 + meta（来源/日期/字数）+ 分隔线 + 正文 + 页脚。
--      样式全部内联，cairo toy font 只认单族名，禁止写字体栈。
--   ④ 出图：build/liblite_html.so 的 lite_html_render(html, out, w, h, scale)；
--      h <= 0 = 自动测高（src/html/render.cpp 先布局拿 content_h 再定高度），卡片不裁剪不留白。
-- 坑：
--   - helper_dir 跟着插件走（cwd/helper 或 $LITE_ROOT/helper），共享库一律 dofile(dir.."/lib/x.lua")。
--   - 密钥只读环境变量（+ ~/.env 回退走 webdav.M.env），不打印、不内置。
--   - 工具返回值必须是字符串，返回 table 会被 tostring 成 "table: 0x..."。
local ffi = require("ffi")

local M = { schema = {
  name = "web2png",
  description = "URL → 资料卡片长图 PNG（DeepSeek Fetch 取正文，md4c+litehtml 出图，零 Chrome）",
  parameters = { type = "object", properties = {
    url   = { type = "string",  description = "网页地址（必填，http/https）" },
    out   = { type = "string",  description = "PNG 输出路径，默认 ~/card-<域名>.png（同名 .html 一起写）" },
    title = { type = "string",  description = "覆盖卡片标题（默认用网页 title）" },
    width = { type = "number",  description = "卡片宽度，默认 760" },
    scale = { type = "number",  description = "device scale factor，默认 2" },
    max_chars = { type = "number", description = "正文最多保留多少字，默认 6000（超出按段落截断）" },
  }, required = { "url" } },
} }

local CARD_CSS = [[
body{margin:0;background:#ecebe4;color:#2b2a26;font-family:"Noto Sans CJK SC";font-size:16px;line-height:1.7}
.card{margin:24px;background:#fbfaf5;border:1px solid #ddd8ca;padding:40px 46px 30px 46px}
.kicker{font-size:12.5px;letter-spacing:2px;color:#a8672b;margin-bottom:14px}
h1{font-size:30px;line-height:1.32;color:#1B365D;margin:0 0 16px 0}
.meta{font-size:13px;color:#8a8578;margin-bottom:22px}
.rule{border-top:1px solid #ddd8ca;margin:0 0 22px 0}
.body p{margin:.8em 0}
h2{font-size:21px;color:#1B365D;margin:1.3em 0 .5em 0;line-height:1.35}
h3{font-size:18px;color:#1B365D;margin:1.2em 0 .4em 0}
strong{color:#1B365D}
a{color:#1B365D;text-decoration:none}
ul,ol{margin:.7em 0;padding-left:1.5em}li{margin:.3em 0}
blockquote{margin:1em 0;padding:.2em 1em;border-left:3px solid #a8672b;color:#6b665c;background:#f3f0e6}
code{font-family:"DejaVu Sans Mono";font-size:13.5px;background:#f1efe6;padding:1px 5px;border-radius:3px}
pre{background:#f1efe6;border:1px solid #e4dfd3;border-radius:5px;padding:12px 14px;overflow:hidden}
pre code{background:none;padding:0;font-size:13px;line-height:1.5}
table{border-collapse:collapse;margin:1em 0;width:100%}
th,td{border:1px solid #e4dfd3;padding:6px 10px;text-align:left;font-size:14px}
th{background:#f1efe6;color:#1B365D}
hr{border:0;border-top:1px solid #ddd8ca;margin:1.4em 0}
.tfoot{border-top:1px solid #ddd8ca;margin-top:26px;padding-top:12px;font-size:12px;color:#a39d8e}
]]

local function dir_of(env)
  return (env and env.helper_dir) or "helper"
end

local function plain(s)
  if type(s) ~= "string" then return "" end
  s = s:gsub("<!%-%-.-%-%->", " ")
  s = s:gsub("<(script[^>]*)>.-</script%s*>", " ")
  s = s:gsub("<style[^>]*>.-</style%s*>", " ")
  s = s:gsub("<br%s*/?>", "\n")
  s = s:gsub("</p%s*>", "\n\n")
  s = s:gsub("<[^>]+>", " ")
  s = s:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<")
       :gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'")
  s = s:gsub("[ \t]+", " "):gsub("%s*\n%s*", "\n")
  return s:gsub("^\n+", ""):gsub("\n+$", "")
end

-- 取正文：返回 title, markdown 正文, 来源标签（fetch | curl）
local function grab(url, dir)
  local key = os.getenv("DEEPSEEK_API_KEY") or os.getenv("LITE_DEEPSEEK_API_KEY")
  if not key then
    local ok, wd = pcall(dofile, dir .. "/lib/webdav.lua")
    if ok and wd and wd.env then key = wd.env("DEEPSEEK_API_KEY") end
  end
  if key and key ~= "" then
    local ok, body = pcall(function()
      local ds = dofile(dir .. "/lib/deepseek.lua")
      local data, err = ds.request("/v1/tools/fetch", { url = url })
      if not data then error(err or "fetch failed") end
      return data
    end)
    if ok and type(body) == "table" and type(body.content) == "string" and body.content ~= "" then
      return body.title, body.content, "DeepSeek Fetch"
    end
  end

  -- 降级：原始 GET（静态页够用；JS 渲染页只能拿到壳）
  local http = require("core.http")
  local rc, status, html = http.get(url, { "User-Agent: Mozilla/5.0 (lite web2png)" })
  if rc ~= 0 then error("抓取失败：curl rc=" .. tostring(rc) .. "（" .. tostring(status) .. "）；url=" .. url) end
  if status ~= 200 then error("抓取失败：HTTP " .. tostring(status) .. "；url=" .. url) end
  html = html or ""
  local title = html:match("<title[^>]*>(.-)</title%s*>")
  title = title and plain(title):gsub("%s+", " ")
  local ok, hmd = pcall(dofile, dir .. "/lib/htmlmd.lua")
  if ok and hmd and hmd.to_md then
    local md = hmd.to_md(html)
    if md ~= "" then return title, md, "curl GET" end
  end
  return title, plain(html), "curl GET"
end

-- 按段落截断，尽量停在完整句子/段落上
local function clip(md, max_chars)
  if not max_chars or max_chars <= 0 or #md <= max_chars then return md, #md, false end
  local cut = md:sub(1, max_chars)
  local para = cut:match("^(.*%.\n)\n") or cut:match("^(.*\n)\n")
  if para and #para > max_chars * 0.5 then cut = para end
  return cut .. "\n\n……（正文已截断，原文 " .. #md .. " 字）", #cut, true
end

local function load_render(dir)
  pcall(ffi.cdef, [[
    int lite_html_render(const char*, const char*, int, int, double);
    const char* lite_html_error(void);
  ]])
  local cands = { "build/liblite_html.so",
                  dir .. "/../build/liblite_html.so",
                  dir .. "/../lib/liblite_html.so" }
  for _, p in ipairs(cands) do
    local ok, l = pcall(ffi.load, p)
    if ok then return l end
  end
  return nil
end

local function human_size(p)
  local f = io.open(p, "rb")
  if not f then return 0 end
  local n = f:seek("end")
  f:close()
  return n or 0
end

function M.run(args, env)
  local url = args.url
  if type(url) ~= "string" or url == "" then
    return "error: web2png needs a `url` string (http/https). required: url"
  end
  if not url:match("^https?://[^/%s]+") then
    return "error: `url` must start with http:// or https:// and include a host; got " .. url:sub(1, 120)
  end
  local dir = dir_of(env)
  local width = tonumber(args.width) or 760
  local scale = tonumber(args.scale) or 2
  local max_chars = tonumber(args.max_chars) or 6000
  local host = url:match("^%a+://([^/%?#]+)") or "page"

  local title, body, src = grab(url, dir)
  title = args.title or (title ~= "" and title) or host
  local text_chars = #body
  local truncated
  body, _, truncated = clip(body, max_chars)

  local mdlib = dofile(dir .. "/lib/md4c.lua")
  local body_html, rc = mdlib.to_html(body)
  if rc < 0 then return "error: md_parse failed rc=" .. tostring(rc) end

  local home = os.getenv("HOME") or "/tmp"
  local out = args.out or (home .. "/card-" .. host:gsub("[^%w%.%-]", "_") .. ".png")
  local now = os.date("%Y-%m-%d %H:%M")
  local html = table.concat({
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>", CARD_CSS, "</style></head><body>",
    "<div class=\"card\">",
    "<div class=\"kicker\">资料卡片 · ", mdlib.esc(host:upper()), "</div>",
    "<h1>", mdlib.esc(title), "</h1>",
    "<div class=\"meta\">", mdlib.esc(src), " · ", now, " · ", text_chars, " 字",
    truncated and "（已截断）" or "", "</div>",
    "<div class=\"rule\"></div>",
    "<div class=\"body\">", body_html, "</div>",
    "<div class=\"tfoot\">", mdlib.esc(url), "　·　lite 资料卡片</div>",
    "</div></body></html>",
  })

  local lib = load_render(dir)
  if not lib then
    return "error: 缺 build/liblite_html.so，先跑 ./tools/build.sh（然后重试同一调用）"
  end
  local hp = out:gsub("%.png$", "") .. ".html"
  local hf = io.open(hp, "wb") if hf then hf:write(html) hf:close() end

  -- h = 0 → 自动测高（lite_html_render 里 h <= 0 = 先布局拿 content_h，再定高度）
  if lib.lite_html_render(html, out, width, 0, scale) ~= 0 then
    return "error: lite_html_render failed for url=" .. url .. " out=" .. out
      .. "（检查输出目录可写、helper/assets 字体存在）"
  end

  local size = human_size(out)
  return string.format("卡片 %s（%d 字，%s）\nPNG → %s（%.1f KB）\nHTML → %s",
    title, text_chars, src, out, size / 1024, hp)
end

return M
