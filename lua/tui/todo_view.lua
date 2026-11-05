-- 全屏 todo 列表覆盖层。
local M = {}
M.__index = M

local MARK = {
    pending = { "[ ]", "default" },
    in_progress = { "[~]", "cyan" },
    completed = { "[x]", "green" },
    cancelled = { "[-]", "gray" },
}

function M.new(items, opts)
    opts = opts or {}
    return setmetatable({
        items = items or {},
        width = opts.width or 80,
        height = opts.height or 24,
        scroll = 0,
    }, M)
end

function M:set_items(items)
    self.items = items or {}
    self:_clamp()
end

function M:set_size(w, h)
    self.width, self.height = w, h
    self:_clamp()
end

function M:_body_h()
    return math.max(1, self.height - 2)
end

function M:_clamp()
    local max_scroll = math.max(0, #self.items - self:_body_h())
    if self.scroll > max_scroll then self.scroll = max_scroll end
    if self.scroll < 0 then self.scroll = 0 end
end

function M:handle(ev)
    local k = ev.key
    if k == "escape" then return "close" end
    if k == "char" then
        if ev.text == "q" then return "close" end
        if ev.text == "j" then self.scroll = self.scroll + 1
        elseif ev.text == "k" then self.scroll = self.scroll - 1
        elseif ev.text == "g" then self.scroll = 0
        elseif ev.text == "G" then self.scroll = #self.items
        end
    elseif k == "up" then
        self.scroll = self.scroll - 1
    elseif k == "down" then
        self.scroll = self.scroll + 1
    elseif k == "pgup" then
        self.scroll = self.scroll - self:_body_h()
    elseif k == "pgdown" then
        self.scroll = self.scroll + self:_body_h()
    elseif k == "home" then
        self.scroll = 0
    elseif k == "end" then
        self.scroll = #self.items
    elseif k == "ctrl" and ev.char == "t" then
        return "close"
    end
    self:_clamp()
end

function M:render(screen, w, h)
    self:set_size(w, h)
    local done, total = 0, #self.items
    for _, it in ipairs(self.items) do
        if it.status == "completed" then done = done + 1 end
    end

    screen:line(1, string.format(" TODOS  %d/%d ", done, total), "reverse", w)

    if total == 0 then
        screen:put(2, 2, "No todos. Ask the agent to plan a multi-step task.", "gray")
    else
        local body_h = self:_body_h()
        for k = 1, body_h do
            local idx = self.scroll + k
            local it = self.items[idx]
            if not it then break end
            local mark = MARK[it.status] or MARK.pending
            screen:put(1, 1 + k, string.format("%s %s", mark[1], it.content or ""), mark[2])
        end
    end

    screen:line(h, " j/k scroll · PgUp/PgDn · q close ", "reverse", w)
end

return M
