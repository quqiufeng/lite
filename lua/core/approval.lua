-- 工具审批策略：auto / ask / deny + session 级 always allow。
local M = {}
M.__index = M

local READONLY = {
    read = true,
    recall = true,
    remember = true,
    todo = true,
}

local function normalize_mode(v)
    if v == nil then return "auto" end
    if type(v) == "boolean" then return v and "ask" or "auto" end
    v = tostring(v):lower()
    if v == "1" or v == "true" or v == "on" or v == "ask" then return "ask" end
    if v == "deny" then return "deny" end
    return "auto"
end

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({
        mode = normalize_mode(opts.mode),
        memory = opts.memory,
        session_id = opts.session_id,
        allow = {},
    }, M)
    self:load()
    return self
end

function M:load()
    if not self.memory or not self.session_id then return end
    if type(self.memory.get) ~= "function" then return end
    local saved = self.memory:get("/agent/session", self.session_id .. "/approvals")
    if type(saved) == "table" then
        for k, v in pairs(saved) do
            if v then self.allow[k] = true end
        end
    end
end

function M:remember(tool)
    self.allow[tool] = true
    if self.memory and self.session_id and type(self.memory.put) == "function" then
        local ttl = self.memory.TTL and self.memory.TTL.long or 0
        self.memory:put("/agent/session",
            self.session_id .. "/approvals", self.allow, ttl)
    end
end

function M:decide(tool)
    if READONLY[tool] then return "allow" end
    if self.allow[tool] then return "allow" end
    if self.mode == "ask" then return "ask" end
    if self.mode == "deny" then return "deny" end
    return "allow"
end

return M
