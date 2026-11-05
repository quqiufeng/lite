-- 运行依赖检查：cjson 与 libcurl（DeepSeek HTTP）。
local M = {}

function M.check()
    local rows = {}
    local ok = true

    local ok_cjson, cjson = pcall(require, "cjson")
    rows[#rows + 1] = {
        name = "cjson",
        ok = ok_cjson,
        detail = ok_cjson and "loaded" or tostring(cjson),
    }
    if not ok_cjson then ok = false end

    local ffi = require("ffi")
    local ok_curl, curl = pcall(ffi.load, "curl")
    rows[#rows + 1] = {
        name = "libcurl",
        ok = ok_curl,
        detail = ok_curl and "loaded" or tostring(curl),
    }
    if not ok_curl then ok = false end

    local lua = rawget(_G, "jit") and jit.version or "Lua"
    rows[#rows + 1] = { name = "runtime", ok = true, detail = lua }

    return ok, rows
end

return M
