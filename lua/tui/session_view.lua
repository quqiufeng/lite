-- 会话选择覆盖层：/session。
local M = {}
M.__index = M

function M.new(sessions, opts)
    opts = opts or {}
    local items = { { id = nil, label = "+ New session", preview = "" } }
    for _, s in ipairs(sessions or {}) do
        items[#items + 1] = { id = s.id, label = s.id, preview = s.preview or "" }
    end

    local selected = 1
    for i, it in ipairs(items) do
        if it.id and it.id == opts.current then selected = i; break end
    end

    return setmetatable({
        items = items,
        selected = selected,
        current = opts.current,
        width = opts.width or 80,
        height = opts.height or 24,
        scroll = 0,
    }, M)
end

function M:set_size(w, h)
    self.width, self.height = w, h
end

function M:_body_h()
    return math.max(1, self.height - 2)
end

function M:_clamp()
    local body = self:_body_h()
    local max_scroll = math.max(0, #self.items - body)
    if self.selected < self.scroll + 1 then self.scroll = self.selected - 1 end
    if self.selected > self.scroll + body then self.scroll = self.selected - body end
    if self.scroll < 0 then self.scroll = 0 end
    if self.scroll > max_scroll then self.scroll = max_scroll end
end

function M:handle(ev)
    local k = ev.key
    if k == "escape" then return { action = "cancel" } end
    if k == "char" then
        if ev.text == "q" then return { action = "cancel" } end
        if ev.text == "j" then self.selected = self.selected + 1
        elseif ev.text == "k" then self.selected = self.selected - 1
        elseif ev.text == "g" then self.selected = 1
        elseif ev.text == "G" then self.selected = #self.items
        end
    elseif k == "up" then
        self.selected = self.selected - 1
    elseif k == "down" then
        self.selected = self.selected + 1
    elseif k == "pgup" then
        self.selected = self.selected - self:_body_h()
    elseif k == "pgdown" then
        self.selected = self.selected + self:_body_h()
    elseif k == "home" then
        self.selected = 1
    elseif k == "end" then
        self.selected = #self.items
    elseif k == "enter" then
        local it = self.items[self.selected]
        if not it then return nil end
        if it.id then return { action = "select", id = it.id } end
        return { action = "new" }
    elseif k == "ctrl" and ev.char == "c" then
        return { action = "cancel" }
    end

    if self.selected < 1 then self.selected = 1 end
    if self.selected > #self.items then self.selected = #self.items end
    self:_clamp()
    return nil
end

function M:render(screen, w, h)
    self:set_size(w, h)
    self:_clamp()

    screen:line(1, " SESSIONS ", "reverse", w)
    local body = self:_body_h()
    for k = 1, body do
        local idx = self.scroll + k
        local it = self.items[idx]
        if not it then break end
        local y = 1 + k
        local mark = (it.id and it.id == self.current) and "* " or "  "
        local label = mark .. it.label
        if it.preview and it.preview ~= "" then
            label = label .. "  " .. it.preview
        end
        if idx == self.selected then
            screen:line(y, " " .. label, "reverse", w)
        else
            screen:put(1, y, " " .. label, it.id and "default" or "cyan")
        end
    end

    screen:line(h, " Enter select · j/k scroll · Esc cancel ", "reverse", w)
end

return M
