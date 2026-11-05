-- 可选 JSONL 调试日志：provider / agent / serve 事件。
local cjson = require("cjson")

local M = {}
M.__index = M

function M.new(path)
    if not path or path == "" then return nil end
    local f, err = io.open(path, "a")
    if not f then return nil, err end
    return setmetatable({ f = f, path = path }, M)
end

function M:log(event, data)
    if not self.f then return end
    local rec = { ts = os.time(), event = event }
    if type(data) == "table" then
        for k, v in pairs(data) do rec[k] = v end
    elseif data ~= nil then
        rec.data = tostring(data)
    end
    local ok, s = pcall(cjson.encode, rec)
    if ok then
        self.f:write(s, "\n")
        self.f:flush()
    end
end

function M:close()
    if self.f then
        self.f:close()
        self.f = nil
    end
end

return M
