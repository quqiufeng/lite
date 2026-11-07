-- UTF-8 遍历 + 终端显示宽度（libc wcwidth）。
local ffi = require("ffi")

pcall(ffi.cdef, [[
int wcwidth(int c);
char *setlocale(int category, const char *locale);
]])

local M = {}

local LC_CTYPE = 0
local locale_ready = false

local function ensure_locale()
    if not locale_ready then
        pcall(ffi.C.setlocale, LC_CTYPE, "")
        locale_ready = true
    end
end

-- 返回 char, next_index, codepoint；非法/不完整返回 nil。
function M.decode(s, i)
    local b1 = s:byte(i)
    if not b1 then return nil end
    if b1 < 0x80 then
        return string.char(b1), i + 1, b1
    end

    local n, cp
    if b1 < 0xC0 then
        return nil
    elseif b1 < 0xE0 then
        n, cp = 2, b1 - 0xC0
    elseif b1 < 0xF0 then
        n, cp = 3, b1 - 0xE0
    else
        n, cp = 4, b1 - 0xF0
    end

    for k = 1, n - 1 do
        local b = s:byte(i + k)
        if not b then return nil end
        if b < 0x80 or b >= 0xC0 then return nil end
        cp = cp * 64 + (b - 0x80)
    end
    return s:sub(i, i + n - 1), i + n, cp
end

-- 单个字符的显示宽度（组合字符按 0 处理，异常回退 1）。
function M.width(ch, cp)
    ensure_locale()
    if not cp then
        local _, _, c = M.decode(ch, 1)
        cp = c
    end
    if not cp then return 1 end
    local w = ffi.C.wcwidth(cp)
    if w < 0 then return 1 end
    return w
end

function M.width_str(s)
    ensure_locale()
    local w, i = 0, 1
    while i <= #s do
        local ch, ni, cp = M.decode(s, i)
        if not ch then
            i = i + 1
            w = w + 1
        else
            w = w + M.width(ch, cp)
            i = ni
        end
    end
    return w
end

-- 字符数（不是字节数）。
function M.len(s)
    local n, i = 0, 1
    while i <= #s do
        local ch, ni = M.decode(s, i)
        if not ch then
            i = i + 1
        else
            i = ni
        end
        n = n + 1
    end
    return n
end

return M
