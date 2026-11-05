-- 任务列表：规范化 / 持久化 / TUI-prompt 渲染。
local M = {}
M.__index = M

local MAX_ITEMS = 50
local VALID = {
    pending = true,
    in_progress = true,
    completed = true,
    cancelled = true,
}

local MARK = {
    pending = "[ ]",
    in_progress = "[~]",
    completed = "[x]",
    cancelled = "[-]",
}

local function normalize(items)
    local out = {}
    if type(items) ~= "table" then return out end
    for _, it in ipairs(items) do
        if type(it) == "table" then
            local content = tostring(it.content or ""):gsub("%s+", " ")
            content = content:gsub("^%s+", ""):gsub("%s+$", "")
            if content ~= "" then
                local status = tostring(it.status or "pending")
                if not VALID[status] then status = "pending" end
                out[#out + 1] = { content = content:sub(1, 500), status = status }
                if #out >= MAX_ITEMS then break end
            end
        end
    end
    return out
end

function M.new(ctx, memory)
    local self = setmetatable({ ctx = ctx, memory = memory }, M)
    self:load()
    return self
end

function M:load()
    if not self.ctx then return {} end
    if type(self.ctx.session.todos) ~= "table" then self.ctx.session.todos = {} end
    if not self.memory then return self.ctx.session.todos end

    local id = self.ctx.session.id
    local saved = id and self.memory:get("/agent/session", id .. "/todos") or nil
    local items = type(saved) == "table" and (saved.items or (saved[1] and saved)) or {}
    self.ctx.session.todos = normalize(items)
    return self.ctx.session.todos
end

function M:get()
    return (self.ctx and self.ctx.session.todos) or {}
end

function M:set(items)
    local list = normalize(items)
    if self.ctx then
        self.ctx.session.todos = list
        self.ctx:emit("todos", list)
    end
    if self.memory then
        local ttl = self.memory.TTL and self.memory.TTL.long or 0
        if self.ctx and self.ctx.session.id then
            self.memory:put("/agent/session",
                self.ctx.session.id .. "/todos", { items = list, ts = os.time() }, ttl)
        else
            self.memory:put("/agent/working", "todos", { items = list, ts = os.time() }, ttl)
        end
    end
    local done, total = M.count(list)
    return string.format("todo updated: %d/%d completed\n%s", done, total, M.render(list))
end

function M.count(list)
    local done, total = 0, #(list or {})
    for _, it in ipairs(list or {}) do
        if it.status == "completed" then done = done + 1 end
    end
    return done, total
end

function M.render(list)
    local lines = {}
    for _, it in ipairs(list or {}) do
        lines[#lines + 1] = string.format("%s %s", MARK[it.status] or "[ ]", it.content)
    end
    return table.concat(lines, "\n")
end

function M.mark(status)
    return MARK[status] or "[ ]"
end

M.normalize = normalize
M.MAX_ITEMS = MAX_ITEMS

return M
