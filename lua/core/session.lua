-- 会话持久化：JSONL，一条消息一行。
local cjson = require("cjson")

local M = {}
M.__index = M

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.new(ctx, opts)
    opts = opts or {}
    local base = opts.dir
    if not base then
        base = (os.getenv("XDG_DATA_HOME") or ((os.getenv("HOME") or ".") .. "/.local/share"))
            .. "/lite/sessions"
    end
    local self = setmetatable({
        ctx = ctx,
        dir = base,
        path = base .. "/" .. tostring(ctx.session.id) .. ".jsonl",
    }, M)
    os.execute("mkdir -p " .. shq(base))
    return self
end

function M:append(msg)
    local f = io.open(self.path, "a")
    if not f then return false end
    local ok, line = pcall(cjson.encode, msg)
    if ok then f:write(line, "\n") end
    f:close()
    return ok
end

function M:save()
    local tmp = self.path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    for _, msg in ipairs(self.ctx.session.messages) do
        local ok, line = pcall(cjson.encode, msg)
        if ok then f:write(line, "\n") end
    end
    f:close()
    os.rename(tmp, self.path)
    return true
end

function M:load()
    local f = io.open(self.path, "r")
    if not f then return {} end
    local out = {}
    for line in f:lines() do
        if line ~= "" then
            local ok, msg = pcall(cjson.decode, line)
            if ok then out[#out + 1] = msg end
        end
    end
    f:close()
    return out
end

return M
