-- helper/lib/md4c.lua —— Markdown → HTML 片段（libmd4c FFI，零子进程）
-- 供 md2png / web2png 共用；插件扫描只平铺看 helper/*.lua，子目录不当插件。
--
-- 用法：local md = dofile(dir .. "/lib/md4c.lua"); local html, rc = md.to_html(src)
-- 依赖：libmd4c.so.0（系统已装）；本机无 md4c.h，cdef 按 `nm -D --defined-only` 手写。
-- 坑：abi_version 必须 = 0；结构体字段顺序不能错，否则崩在回调里。
local ffi = require("ffi")

local M = {}

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
  ]]
end

local function esc(s)
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
  return s
end
M.esc = esc

local function load_md4c()
  cdef()
  for _, so in ipairs({ "libmd4c.so.0", "libmd4c.so", "md4c" }) do
    local ok, l = pcall(ffi.load, so)
    if ok then return l end
  end
  return nil
end

-- 返回 html 片段, rc（rc<0 才是失败）
function M.to_html(src)
  local md = load_md4c()
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

return M
