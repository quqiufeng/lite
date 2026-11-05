-- TUI 入口：终端生命周期 + 异常恢复。
local Terminal = require("tui.terminal")

local M = {}

function M.run(ctx, agent, memory, opts)
    if not Terminal.is_tty() then
        return nil, "TUI requires a TTY (use --once for scripts)"
    end

    local term = Terminal.enter()
    local ok, err = pcall(function()
        require("tui.loop").run(ctx, agent, memory, opts)
    end)
    Terminal.leave(term)
    if not ok then return nil, err end
    return true
end

return M
