-- 帮助 / which-key 覆盖层。
local M = {}
M.__index = M

local ITEMS = {
    { "Enter", "send message" },
    { "Ctrl+J", "insert newline" },
    { "Tab", "complete file path" },
    { "Wheel/PgUp/PgDn", "scroll transcript" },
    { "Drag (left)", "select text · copy on release" },
    { "Ctrl+O", "expand/collapse last tool" },
    { "Ctrl+G", "open git diff" },
    { "Ctrl+T", "open todo list" },
    { "Ctrl+L", "redraw screen" },
    { "Esc ×2", "interrupt current response" },
    { "Ctrl+C", "cancel request / clear input" },
    { "Ctrl+D", "quit" },
    { "quit + Enter", "quit the TUI" },
    { "/session", "pick / new session" },
    { "/new", "start a new session" },
    { "/compact [pct]", "slide window to pct% of budget (history kept)" },
    { "/reload", "reload lua tools/ffi" },
    { "/reboot", "restart process, then auto-continue" },
    { "/exit", "quit (same as quit + Enter, Ctrl+D)" },
    { "?", "toggle this help" },
}

function M.new(opts)
    opts = opts or {}
    return setmetatable({
        width = opts.width or 80,
        height = opts.height or 24,
        scroll = 0,
    }, M)
end

function M:set_size(w, h)
    self.width, self.height = w, h
end

function M:handle(ev)
    local k = ev.key
    if k == "escape" then return "close" end
    if k == "char" and (ev.text == "q" or ev.text == "?") then return "close" end
    if k == "ctrl" and ev.char == "h" then return "close" end
    return nil
end

function M:render(screen, w, h)
    self:set_size(w, h)
    screen:line(1, " HELP ", "reverse", w)

    local body_h = math.max(1, h - 2)
    local shown = 0
    for _, item in ipairs(ITEMS) do
        if shown >= body_h then break end
        local y = 2 + shown
        screen:put(2, y, item[1], "cyan")
        screen:put(2 + 16, y, item[2], "default")
        shown = shown + 1
    end

    screen:line(h, " ? / q / Esc close ", "reverse", w)
end

return M
