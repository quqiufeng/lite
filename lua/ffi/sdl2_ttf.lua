local ffi = require("ffi")
local sdl = require("ffi.sdl2")

ffi.cdef [[
typedef struct _TTF_Font TTF_Font;
typedef struct SDL_Color { uint8_t r, g, b, a; } SDL_Color;

int TTF_Init(void);
void TTF_Quit(void);
TTF_Font *TTF_OpenFont(const char *file, int ptsize);
TTF_Font *TTF_OpenFontIndex(const char *file, int ptsize, long index);
void TTF_CloseFont(TTF_Font *font);
SDL_Surface *TTF_RenderUTF8_Blended(TTF_Font *font, const char *text, SDL_Color fg);
int TTF_SizeUTF8(TTF_Font *font, const char *text, int *w, int *h);
void TTF_SetFontHinting(TTF_Font *font, int mode);
void TTF_SetFontOutline(TTF_Font *font, int outline);
]]

local lib = ffi.load("SDL2_ttf")

local M = {}

function M.init()
    return lib.TTF_Init() == 0
end

function M.quit()
    lib.TTF_Quit()
end

-- index: .ttc 字体集合里的子字体序号(SDL2_ttf 8 位上是 long);0/省略 = 第一个
function M.open(path, size, index)
    if index and index > 0 then
        return lib.TTF_OpenFontIndex(path, size, ffi.cast("long", index))
    end
    return lib.TTF_OpenFont(path, size)
end

function M.close(font)
    if font then lib.TTF_CloseFont(font) end
end

-- 汉字在 hinting=NONE 下笔画全是半透明灰边(实心像素仅 16%),NORMAL 翻倍到 30%
-- 0=NONE 1=LIGHT 2=NORMAL 3=MONO
function M.hinting(font, mode)
    if font then lib.TTF_SetFontHinting(font, mode or 2) end
end

-- outline=N 把笔画加粗 N 像素(同色描边):楷体 22px 细笔靠 AA 只有半透明灰,
-- 加 1px 实心描边后才不"发虚";尺寸会多出 2N,取宽高时要减回去
function M.outline(font, n)
    if font then lib.TTF_SetFontOutline(font, n or 0) end
end

function M.size(font, text)
    local w = ffi.new("int[1]")
    local h = ffi.new("int[1]")
    if lib.TTF_SizeUTF8(font, text, w, h) ~= 0 then return 0, 0 end
    return tonumber(w[0]), tonumber(h[0])
end

-- 返回 SDL_Surface(调用方负责 free);需要后处理 alpha 的走这个
function M.render_surface(font, text, r, g, b, a)
    local color = ffi.new("SDL_Color")
    color.r, color.g, color.b, color.a = r, g, b, a or 255
    return lib.TTF_RenderUTF8_Blended(font, text, color)
end

ffi.cdef[[
struct lite_ttf_surf { uint32_t flags; void *format; int w, h, pitch; void *pixels; };
]]

-- alpha 增益:楷体小字号抗锯齿边缘太淡(实侧 faint<40 占 19%),整行看着"发虚"。
-- 对混合后的 alpha 做 (a/255)^(1/gain);gain=2 时 faint 降到 6%,字重明显变实。
function M.alpha_gain(surf, gain)
    if surf == nil or gain == nil or gain == 1 then return surf end
    local s = ffi.cast("struct lite_ttf_surf *", surf)
    if s.pixels == nil or s.w <= 0 or s.h <= 0 then return surf end
    local bpp = math.floor(s.pitch / s.w)
    if bpp < 2 then return surf end
    local px = ffi.cast("uint8_t *", s.pixels)
    local lut = ffi.new("uint8_t[256]")
    local inv = 1 / gain
    for i = 0, 255 do lut[i] = math.floor((i / 255) ^ inv * 255 + 0.5) end
    local st, w, h, off = s.pitch, s.w, s.h, bpp - 1
    for y = 0, h - 1 do
        local row = px + y * st
        for x = 0, w - 1 do
            local p = row + x * bpp + off
            p[0] = lut[p[0]]
        end
    end
    return surf
end

function M.render_texture(ren, font, text, r, g, b, a, gain)
    local surf = M.render_surface(font, text, r, g, b, a)
    if surf == nil then return nil end
    M.alpha_gain(surf, gain)
    local tex = sdl.create_texture_from_surface(ren, surf)
    sdl.free_surface(surf)
    return tex
end

return M
