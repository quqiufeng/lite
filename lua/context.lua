-- 全应用状态与事件。单一数据源：session / view / settings / ui。
local M = {}
M.__index = M

function M.new(opts)
    opts = opts or {}
    return setmetatable({
        session = {
            id = opts.id or os.date("%Y%m%d-%H%M%S"),
            cwd = opts.cwd or os.getenv("PWD") or ".",
            model = opts.model or "deepseek-flash",
            messages = {},
            turn = 0,
            busy = false,
            todos = {},
        },
        view = {
            status = "idle",   -- idle | thinking | tool | error
            error = nil,
            stream = "",
        },
        settings = {
            api_key = opts.api_key,
            base_url = opts.base_url or "https://api.deepseek.com",
            model = opts.model or "deepseek-flash",
            temperature = opts.temperature or 0,
            max_turns = opts.max_turns or 16,
            context_chars = opts.context_chars or 8000,
            context_turns = opts.context_turns or 2,
            thinking = opts.thinking,
            reasoning_effort = opts.reasoning_effort,
            max_retries = opts.max_retries or 2,
            approval = opts.approval or "auto",
            debug_log = opts.debug_log,
        },
        ui = { dirty = true },
        listeners = {},
    }, M)
end

function M:on(evt, fn)
    local list = self.listeners[evt] or {}
    list[#list + 1] = fn
    self.listeners[evt] = list
    return function()
        for i, f in ipairs(list) do
            if f == fn then table.remove(list, i); break end
        end
    end
end

function M:emit(evt, ...)
    for _, fn in ipairs(self.listeners[evt] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then
            io.stderr:write("[context] listener error (" .. evt .. "): " .. tostring(err) .. "\n")
        end
    end
    if evt ~= "dirty" then
        self.ui.dirty = true
        self:emit("dirty")
    end
end

function M:touch()
    self:emit("dirty")
end

function M:clear_dirty()
    self.ui.dirty = false
end

function M:add_message(msg)
    self.session.messages[#self.session.messages + 1] = msg
    self:emit("message", msg)
    return msg
end

function M:set_status(status)
    self.view.status = status
    self:emit("status", status)
end

function M:set_stream(text)
    self.view.stream = text or ""
    self:emit("stream", self.view.stream)
end

function M:fail(err)
    self.view.error = tostring(err)
    self:set_status("error")
    self:emit("error", self.view.error)
end

function M:begin_turn()
    self.session.turn = self.session.turn + 1
    self.session.busy = true
    self.view.error = nil
    self:set_status("thinking")
    self:emit("turn_start", self.session.turn)
end

function M:end_turn()
    self.session.busy = false
    self:set_status("idle")
    self:emit("turn_end", self.session.turn)
end

return M
