-- helper/lib/htmlmd.lua —— HTML → Markdown：DOM 走 libxml2（纯 FFI，零编译、零子进程）
--
-- 用途：DeepSeek Fetch 拿不到正文时（403/404/JS-only），web2png 用 core.http 抓原始 HTML，
--       再靠这里把「正文区域」抽成粗粒度 Markdown 喂给 md4c。
--
-- 为什么不再手写标签扫描：
--   手写版（遇引号跳过找 '>'、同名标签靠深度计数闭合）遇到畸形 HTML 只能猜；属性值里带
--   ">" 时（Wikipedia 的 data-mw='{"wt":"a > b"}'）正则会从属性中间断开，整段 JSON 变成
--   正文。libxml2 是 C 的真 HTML 解析器 —— libpoppler-glib 本身就依赖它，本机必在 ——
--   htmlReadMemory 一次建树，之后只做 DOM 遍历：嵌套、属性、实体、容错全由它负责，
--   Lua 侧只剩「节点 → Markdown」这一层。
--
-- cdef 手写（本机无 libxml2 开发头也能跑）：符号取自
--   nm -D --defined-only /lib/x86_64-linux-gnu/libxml2.so.2
--   htmlReadMemory@@LIBXML2_2.6.0 / xmlDocGetRootElement / xmlGetProp / xmlNodeGetContent
--   / xmlFreeDoc / xmlFree（xmlFree 在符号表里是 D 类数据符号 —— 一个函数指针变量，
--   不是函数。cdef 必须写成 `void (*xmlFree)(void*)`，取出指针再调；直接当函数调用
--   会跳到变量地址执行，段错误）
--
-- 已知取舍：不做 JS 渲染；<table> 只拍成 GFM 表格（列多时每格压成一行）；
--           相对链接（/wiki/xxx）降级成纯文本，只有 http(s) 绝对链接保留。

local okffi, ffi = pcall(require, "ffi")

local M = {}

if not okffi then
  M.to_md = function() return "" end
  M.available = function() return false end
  return M
end

pcall(ffi.cdef, [[
typedef struct _xmlNode xmlNode;
typedef struct _xmlDoc xmlDoc;
struct _xmlNode {
  void *_private;
  int type;
  const char *name;
  xmlNode *children, *last, *parent, *next, *prev;
  xmlDoc *doc;
  void *ns;
  char *content;
  void *properties;
  void *nsDef;
  void *psvi;
  unsigned short line, extra;
};
xmlDoc *htmlReadMemory(const char *buf, int size, const char *url, const char *enc, int opts);
xmlNode *xmlDocGetRootElement(const xmlDoc *doc);
void xmlFreeDoc(xmlDoc *doc);
char *xmlGetProp(const xmlNode *node, const char *name);
char *xmlNodeGetContent(const xmlNode *node);
void (*xmlFree)(void *ptr);
]])

local L
for _, nm in ipairs({ "libxml2.so.2", "libxml2.so" }) do
  local ok, lib = pcall(ffi.load, nm)
  if ok then L = lib; break end
end
if not L then
  M.to_md = function() return "" end
  M.available = function() return false end
  return M
end

-- HTML_PARSE_RECOVER|NOERROR|NOWARNING|NONET
local PARSE_OPTS = 1 + 32 + 64 + 2048
local ELEM, TEXT, CDATA = 1, 3, 4

-- xmlFree 是数据符号（函数指针变量）：取一次，之后当普通函数指针调用
local xfree = L.xmlFree

local function s_of(p) return p ~= nil and ffi.string(p) or nil end

-- 取属性（xmlGetProp 返回的内存必须 xmlFree，否则每次解析都泄漏）
local function prop(node, name)
  local p = L.xmlGetProp(node, name)
  if p == nil then return nil end
  local v = ffi.string(p)
  xfree(p)
  return v
end

-- 整棵子树的纯文本（<pre> 用）
local function content_of(node)
  local p = L.xmlNodeGetContent(node)
  if p == nil then return "" end
  local v = ffi.string(p)
  xfree(p)
  return v
end

-- 整块跳过的标签（内容一律不输出）
local SKIP = {
  script = true, style = true, noscript = true, template = true, iframe = true,
  svg = true, math = true, form = true, button = true, select = true, textarea = true,
  nav = true, aside = true, footer = true, header = true, menu = true, figure = true,
  head = true, title = true, meta = true, link = true, object = true, embed = true,
  canvas = true, audio = true, video = true, input = true, label = true, option = true,
}

-- 按 class/id 跳过的块（导航盒子、编辑链接、目录、信息框、参考文献……）
-- 用 Lua 模式（find 默认按模式匹配），% 是转义
local SKIP_ATTR = {
  "mw%-editsection", "mw%-jump%-link", "mw%-citation", "navbox", "infobox",
  "vertical%-navbox", "sidebar", "catlinks", "printfooter", "mw%-ref%-",
  "reference", "noprint", "metadata", "shortdescription", "hatnote",
  "^toc$", "-toc$", "mw%-indicator", "vector%-menu", "vector%-tabs",
  "vector%-sidebar", "vector%-header", "mw%-toc", "cookie", "banner",
}

-- 只有内容块才查 class/id：<body class="... vector-feature-..."> 这种皮肤外壳整块
-- 跳掉会把正文一起吃掉，所以根节点（html/body/article/main）不在名单里
local ATTR_CHECK = {
  p = true, div = true, section = true, article = true, ul = true, ol = true,
  li = true, table = true, dl = true, dd = true, dt = true, span = true,
  sup = true, sub = true, blockquote = true, td = true, th = true, figure = true,
}

local function interesting(attr)
  if not attr or attr == "" then return false end
  for _, p in ipairs(SKIP_ATTR) do
    if attr:find(p) then return true end
  end
  return false
end

-- 行内文本：折叠空白 + 转义 Markdown 结构符（块级标记是我们自己 emit 的，不走这里）
local ESC = { ["\\"] = "\\\\", ["*"] = "\\*", ["_"] = "\\_", ["`"] = "\\`",
              ["["] = "\\[", ["]"] = "\\]" }
local function esc(s)
  s = s:gsub("[ \t\r\n]+", " ")
  s = s:gsub("[\\*_`%[%]]", ESC)
  return s
end

local walk, inline_md

local function emit(ctx, s)
  if s ~= "" then ctx.out[#ctx.out + 1] = s end
end

local function br(ctx)
  if ctx.inline then emit(ctx, " ") else emit(ctx, "\n\n") end
end

-- <table>：收集每个 <tr> 的单元格节点，再决定怎么拍
--   · 单格 / 单行的布局表（lua.org 那种老式整页排版）→ 透传块级内容，别压成表格行
--   · 真表格 → GFM 表格（第一行当表头）
local function render_table(node, ctx)
  local rows = {}
  local function collect(n)
    while n ~= nil do
      if n.type == ELEM then
        local nm = s_of(n.name):lower()
        if nm == "tr" then
          local cells, c = {}, n.children
          while c ~= nil do
            if c.type == ELEM then
              local cn = s_of(c.name):lower()
              if cn == "td" or cn == "th" then cells[#cells + 1] = c end
            end
            c = c.next
          end
          if #cells > 0 then rows[#rows + 1] = cells end
        else
          collect(n.children)
        end
      end
      n = n.next
    end
  end
  collect(node.children)

  if #rows == 0 then return end
  local maxc = 0
  for _, r in ipairs(rows) do if #r > maxc then maxc = #r end end

  -- 布局表：单元格里是块级内容，直接走 walk 保留标题/段落/列表
  if maxc < 2 or #rows < 2 then
    if ctx.inline then
      local t = {}
      for _, r in ipairs(rows) do
        for _, cell in ipairs(r) do t[#t + 1] = inline_md(cell.children, ctx) end
      end
      emit(ctx, " " .. table.concat(t, " · ") .. " ")
      return
    end
    for _, r in ipairs(rows) do
      for _, cell in ipairs(r) do
        walk(cell.children, ctx)
        emit(ctx, "\n")
      end
    end
    return
  end

  local function text(cell)
    local s = inline_md(cell.children, ctx):gsub("|", "\\|")
    return s ~= "" and s or " "
  end

  if ctx.inline then
    local t = {}
    for _, r in ipairs(rows) do
      local c = {}
      for _, cell in ipairs(r) do c[#c + 1] = text(cell) end
      t[#t + 1] = table.concat(c, " · ")
    end
    emit(ctx, " " .. table.concat(t, "; ") .. " ")
    return
  end

  local out = { "\n\n" }
  local function line(r)
    local t = {}
    for i = 1, maxc do
      t[i] = (r[i] and r[i].type == ELEM) and text(r[i]) or " "
    end
    return "| " .. table.concat(t, " | ") .. " |\n"
  end
  out[#out + 1] = line(rows[1])
  local sep = {}
  for i = 1, maxc do sep[i] = "---" end
  out[#out + 1] = "| " .. table.concat(sep, " | ") .. " |\n"
  for i = 2, #rows do out[#out + 1] = line(rows[i]) end
  out[#out + 1] = "\n"
  emit(ctx, table.concat(out))
end

local function el(node, name, ctx)
  if SKIP[name] then return end

  if ATTR_CHECK[name] then
    local attr = (prop(node, "class") or "") .. " " .. (prop(node, "id") or "")
    if attr ~= " " and interesting(attr) then return end
  end

  -- 代码块：整体取文本，占位后由 to_md 原样还原（不折叠空白、不转义）
  if name == "pre" then
    local code = content_of(node):gsub("\n+$", ""):gsub("^\n+", "")
    if code == "" then return end
    ctx.npre = ctx.npre + 1
    -- 存裸围栏，前后空行由还原时统一补：restore 放在空白折叠之后，代码缩进才不被吃掉
    ctx.pre[ctx.npre] = "```\n" .. code .. "\n```"
    emit(ctx, "\x01" .. ctx.npre .. "\x01")
    return
  end

  local h = name:match("^h(%d)$")
  if h then
    br(ctx)
    if not ctx.inline then emit(ctx, ("#"):rep(tonumber(h)) .. " ") end
    walk(node.children, ctx)
    br(ctx)
    return
  end

  if name == "a" then
    local text = inline_md(node.children, ctx)
    local href = prop(node, "href")
    if ctx.links and href and text ~= "" and href:match("^https?://") then
      emit(ctx, "[" .. text .. "](" .. href .. ")")
    else
      emit(ctx, text)
    end
    return
  end

  if name == "em" or name == "i" then
    local text = inline_md(node.children, ctx)
    emit(ctx, text ~= "" and ("*" .. text .. "*") or "")
    return
  end

  if name == "strong" or name == "b" then
    local text = inline_md(node.children, ctx)
    emit(ctx, text ~= "" and ("**" .. text .. "**") or "")
    return
  end

  if name == "code" or name == "kbd" or name == "samp" then
    local text = content_of(node):gsub("[ \t\r\n]+", " ")
    emit(ctx, text ~= "" and ("`" .. text .. "`") or "")
    return
  end

  if name == "br" then emit(ctx, "\n") return end
  if name == "hr" then br(ctx); if not ctx.inline then emit(ctx, "---") end; br(ctx) return end
  if name == "img" then
    local alt = prop(node, "alt")
    if alt and alt ~= "" and ctx.inline then emit(ctx, alt) end
    return
  end

  if name == "table" then render_table(node, ctx) return end

  if name == "ul" or name == "ol" then
    if not ctx.inline then emit(ctx, "\n") end
    local i, c = 0, node.children
    while c ~= nil do
      if c.type == ELEM and s_of(c.name):lower() == "li" then
        i = i + 1
        local bullet = (name == "ol") and (i .. ". ") or "- "
        -- 第一项不再多吃一个换行（开头已经 emit 过），否则嵌套列表被空行截断
        emit(ctx, (i == 1 and "" or "\n") .. ("  "):rep(ctx.depth) .. bullet)
        ctx.depth = ctx.depth + 1
        walk(c.children, ctx)
        ctx.depth = ctx.depth - 1
      end
      c = c.next
    end
    -- 嵌套列表收尾不留空行，否则父级的下一项被当成新列表
    if not ctx.inline and ctx.depth == 0 then emit(ctx, "\n") end
    return
  end

  if name == "dt" then br(ctx); emit(ctx, "**"); walk(node.children, ctx); emit(ctx, "**"); return end
  if name == "dd" then emit(ctx, "\n  "); walk(node.children, ctx); return end

  -- 块级容器：前后空行；inline 模式下退化成空格
  if name == "p" or name == "div" or name == "section" or name == "article"
     or name == "main" or name == "blockquote" or name == "dl"
     or name == "body" or name == "html" or name == "span" or name == "sup"
     or name == "sub" or name == "font" or name == "center" or name == "small" then
    if name == "span" or name == "sup" or name == "sub" then
      walk(node.children, ctx)
      return
    end
    br(ctx)
    walk(node.children, ctx)
    br(ctx)
    return
  end

  -- 其余内联元素（<abbr>/<time>/<mark>/<u>…）直接透传内容
  walk(node.children, ctx)
end

walk = function(node, ctx)
  while node ~= nil do
    local t = node.type
    if t == TEXT or t == CDATA then
      local c = node.content
      if c ~= nil then emit(ctx, esc(ffi.string(c))) end
    elseif t == ELEM then
      el(node, (s_of(node.name) or ""):lower(), ctx)
    end
    node = node.next
  end
end

inline_md = function(node, parent)
  local ctx = { out = {}, pre = {}, npre = 0, depth = 0, inline = true,
                links = parent and parent.links }
  walk(node, ctx)
  local s = table.concat(ctx.out)
  s = s:gsub("[ \t]+", " ")
  s = s:gsub(" *\n *", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

-- 深度优先找一个满足条件的元素
local function dfs(node, pred)
  while node ~= nil do
    if node.type == ELEM and pred(node) then return node end
    if node.children ~= nil then
      local r = dfs(node.children, pred)
      if r ~= nil then return r end
    end
    node = node.next
  end
end

-- 正文容器：mw-content-text → article → main → body → 根
local function main_region(root)
  local n = dfs(root, function(x)
    local id = prop(x, "id")
    return id == "mw-content-text" or id == "content" or id == "main"
  end)
  if n then return n end
  for _, tag in ipairs({ "article", "main", "body" }) do
    n = dfs(root, function(x) return (s_of(x.name) or ""):lower() == tag end)
    if n then return n end
  end
  return root
end

M.available = function() return true end

-- HTML → Markdown。返回字符串；无 libxml2 时返回 ""（调用方自行降级）
function M.to_md(html, opts)
  if type(html) ~= "string" or html == "" then return "" end

  -- encoding 传 NULL 让 libxml2 自己探测（meta charset / BOM）：很多老站声明
  -- iso-8859-1，写死 "UTF-8" 会把 é 之类解码成乱码
  local doc = L.htmlReadMemory(html, #html, "input.html", nil, PARSE_OPTS)
  if doc == nil then return "" end

  local root = L.xmlDocGetRootElement(doc)
  local ok, md = pcall(function()
    local region = main_region(root)
    local ctx = { out = {}, pre = {}, npre = 0, depth = 0,
                  links = type(opts) == "table" and opts.links == true }
    walk(region.children ~= nil and region.children or region, ctx)
    local s = table.concat(ctx.out)

    -- 折叠空白：只吃行内运行的多空格与行尾空格，行首缩进要留着（嵌套列表靠它）
    s = s:gsub("(%S)[ \t]+", "%1 ")
    s = s:gsub("[ \t]+\n", "\n")
    s = s:gsub("\n%-[ \t]*\n", "\n")            -- 空列表项
    s = s:gsub("\n\n\n+", "\n\n")
    s = s:gsub("^[\n ]+", ""):gsub("[\n ]+$", "")
    for _ = 1, 5 do
      local n
      s, n = s:gsub("\n[#|]+[ \t]*\n", "\n")
      s = s:gsub("^[#|]+[ \t]*\n", "")
      if n == 0 then break end
    end
    s = s:gsub("\n\n\n+", "\n\n")
    s = s:gsub("%s+([·•][,;]?)", " %1")          -- 面包屑「a · b · c」保持一行

    -- 尾部噪声段（参考文献/外部链接不构成卡片内容）。Lua 模式没有 | 交替，逐个找
    local TAIL = { "References", "External links", "See also", "Notes",
                   "Further reading", "Bibliography", "Footnotes" }
    for _, h in ipairs(TAIL) do
      local cut = s:find("\n\n## ?" .. h .. "\n")
      if cut and cut > #s * 0.3 then s = s:sub(1, cut - 1) end
    end

    -- 还原 <pre> 占位放在最后：代码缩进/空行不参与上面的折叠
    s = s:gsub("\x01(%d+)\x01", function(k)
      local code = ctx.pre[tonumber(k)]
      return code and ("\n\n" .. code .. "\n\n") or ""
    end)

    -- 围栏外最多留一个空行；围栏内原样（代码里的空行不能塌）
    local lines, blank, fence = {}, 0, false
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
      if line:match("^```") then
        fence = not fence
        lines[#lines + 1] = line
        blank = 0
      elseif fence then
        lines[#lines + 1] = line
      elseif line:match("^%s*$") then
        blank = blank + 1
        if blank == 1 and #lines > 0 then lines[#lines + 1] = "" end
      else
        blank = 0
        lines[#lines + 1] = line
      end
    end
    s = table.concat(lines, "\n")
    s = s:gsub("^[\n ]+", ""):gsub("[\n ]+$", "")
    return s
  end)
  L.xmlFreeDoc(doc)
  if not ok then
    -- 默认静默降级（web2png 会回退 plain 文本）；LITE_HTMLMD_DEBUG=1 时把错抛出来
    if os.getenv("LITE_HTMLMD_DEBUG") == "1" then error(md, 2) end
    return ""
  end
  return md
end

return M
