-- 工具审批覆盖层：once / always / reject。
local M = {}
M.__index = M

local function arg_text(args)
    if type(args) ~= "table" then return "" end
    if args.command then return tostring(args.command) end
    if args.path then return tostring(args.path) end
    if args.query then return tostring(args.query) end
    if args.items then return string.format("%d todos", #args.items) end
    return ""
end

function M.new(req, opts)
    opts = opts or {}
    return setmetatable({
        req = req or {},
        width = opts.width or 80,
        height = opts.height or 24,
    }, M)
end

function M:set_size(w, h)
    self.width, self.height = w, h
end

function M:handle(ev)
    local k = ev.key
    if k == "enter" then return "once" end
    if k == "escape" then return "reject" end
    if k == "char" then
        local c = tostring(ev.text or ""):lower()
        if c == "y" then return "once" end
        if c == "a" then return "always" end
        if c == "n" or c == "q" then return "reject" end
    elseif k == "ctrl" and ev.char == "c" then
        return "reject"
    end
    return nil
end

function M:render(screen, w, h)
    self:set_size(w, h)
    screen:line(1, " APPROVAL REQUIRED ", "reverse", w)

    local name = tostring(self.req.name or "tool")
    local detail = arg_text(self.req.args)
    screen:put(2, 3, "tool: " .. name, "yellow")
    if detail ~= "" then
        screen:put(2, 4, "args: " .. detail, "default")
    end

    screen:put(2, math.max(6, math.min(h - 2, 8)),
        "[y] allow once    [a] always allow    [n]/Esc reject", "cyan")
    screen:line(h, " Enter = allow once · Esc = reject ", "reverse", w)
end

return M
