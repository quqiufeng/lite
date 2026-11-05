-- lite 内置图像库 FFI（liblite_image.so）：PNG/JPEG/WebP resize。
local ffi = require("ffi")

ffi.cdef[[
int lite_image_resize(const char *src, const char *dst, int width, int height, int force);
const char *lite_image_error(void);
]]

local root = os.getenv("LITE_ROOT")
local candidates = {
    root and (root:gsub("/+$", "") .. "/lib/liblite_image.so"),
    root and (root:gsub("/+$", "") .. "/build/liblite_image.so"),
    "liblite_image.so",
    "/usr/local/share/lite/lib/liblite_image.so",
    "/usr/local/lib/liblite_image.so",
}

local lib, load_err
for _, path in ipairs(candidates) do
    if path then
        local ok, h = pcall(ffi.load, path)
        if ok then lib = h; break end
        load_err = h
    end
end

if lib then load_err = nil end

local M = {}

function M.available()
    return lib ~= nil
end

function M.error()
    return load_err
end

function M.resize(src, dst, width, height, force)
    if not lib then return false, "liblite_image not available: " .. tostring(load_err) end
    local rc = lib.lite_image_resize(src, dst, width or 0, height or 0, force and 1 or 0)
    if rc ~= 0 then
        local msg = lib.lite_image_error()
        return false, msg ~= nil and ffi.string(msg) or "image resize failed"
    end
    return true
end

return M
