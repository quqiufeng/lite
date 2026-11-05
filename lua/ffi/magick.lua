-- ImageMagick MagickWand FFI：lite 内置 resize 后端（无外部进程）。
local ffi = require("ffi")

ffi.cdef[[
typedef struct _MagickWand MagickWand;
void MagickWandGenesis(void);
MagickWand *NewMagickWand(void);
MagickWand *DestroyMagickWand(MagickWand *wand);
int MagickReadImage(MagickWand *wand, const char *filename);
int MagickWriteImage(MagickWand *wand, const char *filename);
int MagickResizeImage(MagickWand *wand, size_t columns, size_t rows, int filter, double blur);
size_t MagickGetImageWidth(MagickWand *wand);
size_t MagickGetImageHeight(MagickWand *wand);
int MagickSetImageCompressionQuality(MagickWand *wand, size_t quality);
]]

local root = os.getenv("LITE_ROOT")
local candidates = {
    root and (root:gsub("/+$", "") .. "/lib/libMagickWand-7.Q16HDRI.so"),
    root and (root:gsub("/+$", "") .. "/lib/libMagickWand-6.Q16.so.7"),
    "/lib/x86_64-linux-gnu/libMagickWand-7.Q16HDRI.so",
    "/usr/lib/x86_64-linux-gnu/libMagickWand-7.Q16HDRI.so",
    "/lib/x86_64-linux-gnu/libMagickWand-6.Q16.so.7",
    "/usr/lib/x86_64-linux-gnu/libMagickWand-6.Q16.so.7",
    "MagickWand-6.Q16",
    "MagickWand-7.Q16HDRI",
}

local lib, load_err
for _, path in ipairs(candidates) do
    if path then
        local ok, h = pcall(ffi.load, path)
        if ok then lib = h; break end
        load_err = h
    end
end

local M = {}

local inited = false
local LANCZOS = 22

function M.available()
    return lib ~= nil
end

function M.error()
    return load_err
end

-- force=true 且宽高都给定时精确拉伸；否则按比例缩放到 w/h 框内。
function M.resize(src, dst, width, height, force)
    if not lib then return false, "libMagickWand not available: " .. tostring(load_err) end
    local ok, err = pcall(function()
        if not inited then
            lib.MagickWandGenesis()
            inited = true
        end
        local wand = lib.NewMagickWand()
        if wand == nil then error("NewMagickWand failed") end
        local function done()
            lib.DestroyMagickWand(wand)
        end

        if lib.MagickReadImage(wand, src) == 0 then
            done()
            error("read image failed: " .. tostring(src))
        end

        local iw = tonumber(lib.MagickGetImageWidth(wand)) or 0
        local ih = tonumber(lib.MagickGetImageHeight(wand)) or 0
        if iw <= 0 or ih <= 0 then
            done()
            error("invalid image size: " .. tostring(src))
        end

        local w = tonumber(width) or 0
        local h = tonumber(height) or 0
        local tw, th
        if force and w > 0 and h > 0 then
            tw, th = math.floor(w), math.floor(h)
        else
            local sx = w > 0 and (w / iw) or math.huge
            local sy = h > 0 and (h / ih) or math.huge
            local scale = math.min(sx, sy)
            if scale == math.huge then
                done()
                error("width or height is required")
            end
            tw = math.max(1, math.floor(iw * scale + 0.5))
            th = math.max(1, math.floor(ih * scale + 0.5))
        end

        if lib.MagickResizeImage(wand, tw, th, LANCZOS, 1.0) == 0 then
            done()
            error("resize failed")
        end
        if lib.MagickSetImageCompressionQuality then
            pcall(function() lib.MagickSetImageCompressionQuality(wand, 90) end)
        end
        if lib.MagickWriteImage(wand, dst) == 0 then
            done()
            error("write image failed: " .. tostring(dst))
        end
        done()
    end)
    if not ok then return false, tostring(err) end
    return true
end

return M
