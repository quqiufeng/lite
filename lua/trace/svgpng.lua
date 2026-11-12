-- SVG -> PNG：cairo + librsvg 的 LuaJIT FFI 绑定，零 Python、零 Chrome、零子进程
-- 自包含单文件（只用 ffi + 系统 libcairo/librsvg），可整份拷给别的项目
-- 用法：local png = require("svgpng")
--       local ok, info = png.render(svg_string, "/tmp/x.png")     -- 尺寸取自 SVG 根元素
--       local ok, info = png.render(svg_string, "/tmp/x.png", 2)  -- 2 倍图
-- 说明：
--   * 尺寸只认 SVG 根元素上的 width/height（我们自己的出图脚本一定写全），缺了报错不猜
--   * 文本靠 fontconfig 解析字体族，CJK 用系统已装的 Noto Sans CJK，不再有 TTC index 那套
--   * librsvg 忽略 <script>，可交互 SVG 直接当静态图渲染，不需要另画一套绘图代码
local ffi = require("ffi")

ffi.cdef[[
typedef struct _cairo_surface cairo_surface_t;
typedef struct _cairo cairo_t;
cairo_surface_t *cairo_image_surface_create(int format, int width, int height);
cairo_t         *cairo_create(cairo_surface_t *target);
int              cairo_surface_write_to_png(cairo_surface_t *surface, const char *filename);
void             cairo_destroy(cairo_t *cr);
void             cairo_surface_destroy(cairo_surface_t *surface);
void             cairo_scale(cairo_t *cr, double sx, double sy);
const char      *cairo_status_to_string(int status);

typedef struct _RsvgHandle RsvgHandle;
typedef struct { double x, y, width, height; } RsvgRectangle;
typedef struct _GError { unsigned int domain; int code; char *message; } GError;

RsvgHandle *rsvg_handle_new_from_data(const unsigned char *data, size_t len, GError **error);
int         rsvg_handle_render_document(RsvgHandle *handle, cairo_t *cr,
                                        const RsvgRectangle *viewport, GError **error);
void        g_object_unref(void *object);
void        g_error_free(GError *error);
]]

local CAIRO_FORMAT_ARGB32 = 0
local M = {}
local lib = {}

local function load_first(names)
  for _, n in ipairs(names) do
    local ok, h = pcall(ffi.load, n)
    if ok then return h, n end
  end
end

local function ensure()
  if lib.cairo and lib.rsvg then return true end
  local c, cname = load_first({ "cairo", "libcairo.so.2", "libcairo.so" })
  if not c then
    return nil, "加载 libcairo 失败（装 libcairo2）；不出 PNG 的话用 .svg 输出即可"
  end
  local r, rname = load_first({ "rsvg-2.so.2", "librsvg-2.so.2", "librsvg-2.so" })
  if not r then
    return nil, "加载 librsvg 失败（装 librsvg2-2）；不出 PNG 的话用 .svg 输出即可"
  end
  lib.cairo, lib.cairo_name = c, cname
  lib.rsvg, lib.rsvg_name = r, rname
  return true
end

local function svg_dims(svg)
  local root = svg:sub(1, 4000):match("<svg%s[^>]*>")
  if not root then return nil, "不是 SVG：找不到 <svg ...> 根元素" end
  local w = tonumber(root:match('width%s*=%s*"([%d%.]+)"'))
  local h = tonumber(root:match('height%s*=%s*"([%d%.]+)"'))
  if not w or not h then return nil, "SVG 根元素缺 width/height" end
  return math.ceil(w), math.ceil(h)
end

local function take_gerror(e)
  if e[0] == nil then return nil end
  local msg = e[0].message ~= nil and ffi.string(e[0].message) or "未知错误"
  lib.rsvg.g_error_free(e[0])
  e[0] = nil
  return msg
end

-- render(svg, out_path[, scale]) -> true, {w,h} | nil, err
function M.render(svg, out, scale)
  local ok, err = ensure()
  if not ok then return nil, err end
  if type(svg) ~= "string" or #svg == 0 then return nil, "空 SVG" end
  local w, h = svg_dims(svg)
  if not w then return nil, h end
  scale = scale or 1
  local pw, ph = math.floor(w * scale + 0.5), math.floor(h * scale + 0.5)

  local e = ffi.new("GError*[1]")
  local handle = lib.rsvg.rsvg_handle_new_from_data(svg, #svg, e)
  if handle == nil then return nil, "解析 SVG 失败: " .. (take_gerror(e) or "?") end

  local surf = lib.cairo.cairo_image_surface_create(CAIRO_FORMAT_ARGB32, pw, ph)
  if surf == nil then
    lib.rsvg.g_object_unref(handle)
    return nil, "创建画布失败 (" .. pw .. "x" .. ph .. ")"
  end
  local cr = lib.cairo.cairo_create(surf)
  if cr == nil then
    lib.cairo.cairo_surface_destroy(surf)
    lib.rsvg.g_object_unref(handle)
    return nil, "创建 cairo 上下文失败"
  end

  if scale ~= 1 then lib.cairo.cairo_scale(cr, scale, scale) end
  local vp = ffi.new("RsvgRectangle", { 0, 0, w, h })
  local rendered = lib.rsvg.rsvg_handle_render_document(handle, cr, vp, e)
  local render_err = take_gerror(e)

  local status = 0
  if rendered ~= 0 and render_err == nil then
    status = lib.cairo.cairo_surface_write_to_png(surf, out)
  end
  lib.cairo.cairo_destroy(cr)
  lib.cairo.cairo_surface_destroy(surf)
  lib.rsvg.g_object_unref(handle)

  if rendered == 0 then return nil, "渲染失败: " .. (render_err or "?") end
  if status ~= 0 then
    return nil, "写 PNG 失败(" .. ffi.string(lib.cairo.cairo_status_to_string(status)) .. "): " .. out
  end
  return true, { w = pw, h = ph, scale = scale }
end

-- 诊断用：实际的 .so 名字；没装则先返回 nil
function M.backend()
  local ok = ensure()
  if not ok then return nil end
  return lib.cairo_name, lib.rsvg_name
end

return M
