-- session 级待处理 prompt 队列（对应 opencode session_input），存 KV。
local cjson = require("cjson")

local M = {}
M.__index = M

function M.new(memory, session_id)
    return setmetatable({
        memory = memory,
        session_id = tostring(session_id or "session"),
        seq = 0,
    }, M)
end

function M:_prefix()
    return "/agent/session/" .. self.session_id .. "/input/"
end

function M:load()
    local out = {}
    if not self.memory then return out end
    for _, r in ipairs(self.memory:search_prefix(self:_prefix(), { max_results = 0 })) do
        local ok, data = pcall(cjson.decode, r.value)
        if ok and type(data) == "table" and data.text and data.text ~= "" then
            local n = tonumber(tostring(r.key):match("/(%d+)$")) or 0
            local key = string.format("%08d", n)
            if n > self.seq then self.seq = n end
            out[#out + 1] = { seq = key, text = data.text }
        end
    end
    return out
end

function M:add(text)
    if not self.memory or not text or text == "" then return nil end
    self.seq = self.seq + 1
    local key = string.format("%08d", self.seq)
    local ttl = self.memory.TTL and self.memory.TTL.long or 0
    self.memory:put("/agent/session",
        self.session_id .. "/input/" .. key, { text = text, ts = os.time() }, ttl)
    return key
end

function M:remove(seq)
    if self.memory and seq then
        self.memory:del("/agent/session", self.session_id .. "/input/" .. tostring(seq))
    end
end

return M
