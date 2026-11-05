-- 文件路径补全：token 解析 + 候选/公共前缀（不做 IO，便于测试）。
local M = {}

function M.token(line, cx)
    local prefix = tostring(line or ""):sub(1, math.max(0, (cx or 1) - 1))
    local token = prefix:match("([%w%._%-/]*)$") or ""
    return token, #prefix - #token + 1
end

local function common_prefix(list)
    if #list == 0 then return "" end
    local c = list[1]
    for i = 2, #list do
        local n = list[i]
        local j = 1
        while j <= #c and j <= #n and c:sub(j, j) == n:sub(j, j) do j = j + 1 end
        c = c:sub(1, j - 1)
        if c == "" then break end
    end
    return c
end

function M.candidates(names, prefix)
    prefix = tostring(prefix or "")
    local out = {}
    for _, n in ipairs(names or {}) do
        if #n >= #prefix and n:sub(1, #prefix) == prefix then
            out[#out + 1] = n
        end
    end
    return out, common_prefix(out)
end

return M
