-- tools/html_img_check.lua —— 图片链路回归：Markdown 出 <img> + 相对路径按 base_dir 解析
--
-- 这两条都真的坏过（用户报「pdf 不能插图」）：
--   ① helper/md2png.lua 的 md_to_html 压根没接 SPAN.IMG，Markdown 里的 ![](x.png)
--      一个字都不进 HTML —— 不是渲染器不认，是压根没有 <img>。
--   ② local base_dir 声明在 render_png 之后，函数体里读到的是同名**全局** nil，
--      于是 M.set_base_dir("/md/所在目录") 静默失效，相对图只能撞对 cwd 才出。
-- 断言挑「用户能看见的」：HTML 里有 img 标签；相对图在 PNG 里真的画出颜色。
local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local ffi = require("ffi")
local fails, total = 0, 0
local function check(ok, name)
  total = total + 1
  if not ok then fails = fails + 1; io.stderr:write("FAIL " .. name .. "\n") end
end

local so = root .. "/build/liblite_html.so"
local probe = io.open(so, "rb")
if not probe then
  io.stderr:write("SKIP html_img (缺 " .. so .. "，先 ./tools/build.sh)\n")
  os.exit(0)
end
probe:close()

-- ① Markdown → <img src alt>：src 来自 MD_ATTRIBUTE（只在 enter_span 回调期有效），
--    alt 来自随后的 text 回调，两者都丢了就等于「图没了，字也没了」。
local okmd, md = pcall(dofile, root .. "/helper/md2png.lua")
check(okmd, "md2png helper loads")
if okmd then
  local body = md.md_to_html("# t\n\n![图说](sub/photo.png)\n\n段落\n")
  check(body:find('<img src="sub/photo%.png" alt="图说">') ~= nil,
        "md_to_html emits img with src+alt")
  check(body:find("段落") ~= nil, "md_to_html keeps text after img")
  local empty = md.md_to_html("![]( )\n")
  check(empty:find("<img") == nil, "md_to_html drops img with empty src")
end

-- ② 相对路径按 base_dir 解析：在图所在目录之外的 cwd 下渲染，仍须画出颜色。
pcall(ffi.cdef, "int lite_html_set_base_dir(const char*);")
local lib = ffi.load(so)
pcall(ffi.cdef, [[
  typedef struct _cairo_surface cairo_surface_t;
  cairo_surface_t *cairo_image_surface_create(int, int, int);
  int cairo_surface_write_to_png(cairo_surface_t*, const char*);
  unsigned char *cairo_image_surface_get_data(cairo_surface_t*);
  void cairo_surface_mark_dirty(cairo_surface_t*);
  cairo_surface_t *cairo_image_surface_create_from_png(const char*);
  int cairo_image_surface_get_width(cairo_surface_t*);
  int cairo_image_surface_get_height(cairo_surface_t*);
  int cairo_image_surface_get_stride(cairo_surface_t*);
  void cairo_surface_destroy(cairo_surface_t*);
]])
local cairo = ffi.load("cairo")

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/lite-img-check"
os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir .. "/sub")
local png = dir .. "/sub/blue.png"
-- 造一张 40×20 纯蓝图（ARGB32 预乘：字节序 B,G,R,A）
local src = cairo.cairo_image_surface_create(0, 40, 20)
local d = cairo.cairo_image_surface_get_data(src)
for i = 0, 40 * 20 - 1 do
  d[i * 4], d[i * 4 + 1], d[i * 4 + 2], d[i * 4 + 3] = 255, 85, 0, 255
end
cairo.cairo_surface_mark_dirty(src)
cairo.cairo_surface_write_to_png(src, png)
cairo.cairo_surface_destroy(src)

local out = dir .. "/out.png"
lib.lite_html_set_base_dir(dir)
local html = "<html><body style='margin:0'><img src='sub/blue.png'></body></html>"
local buf = ffi.new("char[?]", #html + 1, html)
check(lib.lite_html_render(buf, out, 200, 0, 1) == 0, "render html with relative img")

local surf = cairo.cairo_image_surface_create_from_png(out)
local w, h = cairo.cairo_image_surface_get_width(surf), cairo.cairo_image_surface_get_height(surf)
local stride = cairo.cairo_image_surface_get_stride(surf)
local data = cairo.cairo_image_surface_get_data(surf)
local blue = 0
for y = 0, h - 1 do
  for x = 0, w - 1 do
    local o = y * stride + x * 4
    if data[o] > 200 and data[o + 1] < 130 and data[o + 2] < 80 then blue = blue + 1 end
  end
end
cairo.cairo_surface_destroy(surf)
-- 40×20=800 个源像素，画进 200 宽画布后仍应有几百个蓝点（真画了，不是虚线占位框）
check(blue > 400, "relative img painted (blue samples=" .. blue .. ")")
-- 无 CSS 约束时按**原始像素**摆（40×20），不做「撑满视口」：视口 200 宽只是画布宽
check(w == 200 and h == 20, "relative img keeps intrinsic size, canvas = viewport (" .. w .. "x" .. h .. ")")
os.remove(out)

-- ③ 边界：图不存在 / base_dir 指到不存在目录 → 不崩，仍出图（占位框），不把失败当成功
lib.lite_html_set_base_dir("/nonexistent-dir-xyz")
local h2 = "<html><body><img src='nope.png'></body></html>"
local ok_missing = pcall(function()
  return lib.lite_html_render(ffi.new("char[?]", #h2 + 1, h2), dir .. "/miss.png", 200, 0, 1)
end)
check(ok_missing, "missing img does not crash")
os.remove(dir .. "/miss.png")
os.execute("rm -rf " .. dir)

if fails > 0 then
  io.stderr:write(("FAIL html_img (%d/%d)\n"):format(fails, total))
  os.exit(1)
end
print("OK html_img (" .. total .. " checks)")
