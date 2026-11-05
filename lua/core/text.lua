-- UTF-8 校验/清洗：把非法字节或 surrogate 替换成 U+FFFD。
local M = {}

local REPL = "\239\191\189"

function M.sanitize(s)
    s = tostring(s or "")
    local out, fixed = {}, 0
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        if b < 0x80 then
            out[#out + 1] = s:sub(i, i)
            i = i + 1
        else
            local len, valid = 0, false
            if b >= 0xC2 and b <= 0xDF then
                len = 2
                local b2 = s:byte(i + 1)
                valid = b2 ~= nil and b2 >= 0x80 and b2 <= 0xBF
            elseif b >= 0xE0 and b <= 0xEF then
                len = 3
                local b2, b3 = s:byte(i + 1), s:byte(i + 2)
                if b2 and b3 and b3 >= 0x80 and b3 <= 0xBF then
                    if b == 0xE0 then valid = b2 >= 0xA0 and b2 <= 0xBF
                    elseif b == 0xED then valid = b2 >= 0x80 and b2 <= 0x9F
                    else valid = b2 >= 0x80 and b2 <= 0xBF end
                end
            elseif b >= 0xF0 and b <= 0xF4 then
                len = 4
                local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
                if b2 and b3 and b4
                    and b3 >= 0x80 and b3 <= 0xBF
                    and b4 >= 0x80 and b4 <= 0xBF then
                    if b == 0xF0 then valid = b2 >= 0x90 and b2 <= 0xBF
                    elseif b == 0xF4 then valid = b2 >= 0x80 and b2 <= 0x8F
                    else valid = b2 >= 0x80 and b2 <= 0xBF end
                end
            end

            if valid then
                out[#out + 1] = s:sub(i, i + len - 1)
                i = i + len
            else
                out[#out + 1] = REPL
                fixed = fixed + 1
                i = i + 1
            end
        end
    end
    return table.concat(out), fixed
end

function M.valid(s)
    local _, fixed = M.sanitize(s)
    return fixed == 0
end

-- 提取消息文本：content 可能是字符串或 OpenAI content parts 数组。
function M.content_text(content)
    if type(content) == "string" then return content end
    if type(content) ~= "table" then return "" end
    local texts = {}
    for _, part in ipairs(content) do
        if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
            texts[#texts + 1] = part.text
        end
    end
    if #texts > 0 then return table.concat(texts, "\n") end
    for _, part in ipairs(content) do
        if type(part) == "table" and part.type == "image_url" then return "[image]" end
    end
    return ""
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.base64(s)
    local bit = require("bit")
    local out = {}
    local i = 1
    while i <= #s do
        local a = s:byte(i) or 0
        local b = s:byte(i + 1)
        local c = s:byte(i + 2)
        local v = bit.bor(bit.lshift(a, 16), bit.lshift(b or 0, 8), c or 0)
        out[#out + 1] = B64:sub(bit.band(bit.rshift(v, 18), 63) + 1, bit.band(bit.rshift(v, 18), 63) + 1)
        out[#out + 1] = B64:sub(bit.band(bit.rshift(v, 12), 63) + 1, bit.band(bit.rshift(v, 12), 63) + 1)
        out[#out + 1] = b and B64:sub(bit.band(bit.rshift(v, 6), 63) + 1, bit.band(bit.rshift(v, 6), 63) + 1) or "="
        out[#out + 1] = c and B64:sub(bit.band(v, 63) + 1, bit.band(v, 63) + 1) or "="
        i = i + 3
    end
    return table.concat(out)
end

return M
