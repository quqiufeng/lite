-- 底部状态栏：model / turn / cwd / memory / 状态。
local utf8 = require("tui.utf8")

local M = {}

local function short_cwd(cwd)
    local home = os.getenv("HOME")
    if home and home ~= "" and cwd:sub(1, #home) == home then
        cwd = "~" .. cwd:sub(#home + 1)
    end
    return cwd
end

function M.render(screen, y, w, ctx, info)
    info = info or {}
    local model = ctx.session.model or "?"
    local turn = ctx.session.turn or 0
    local cwd = short_cwd(ctx.session.cwd or ".")

    local status = info.status or ctx.view.status or "idle"
    if info.busy and status == "idle" then status = "thinking" end
    if info.spinner then status = info.spinner .. " " .. status end

    local left = string.format(" lite · %s · turn %d · %s ", model, turn, cwd)
    local mem = string.format(" mem:%d", info.mem or 0)
    if (info.hits or 0) > 0 then mem = mem .. string.format(" hit:%d", info.hits) end
    local todo = ""
    local todos = info.todos
    if todos and #todos > 0 then
        local done = 0
        for _, it in ipairs(todos) do
            if it.status == "completed" then done = done + 1 end
        end
        todo = string.format(" todo:%d/%d", done, #todos)
    end
    local right = mem .. todo .. " · " .. status .. " "
    local lw, rw = utf8.width_str(left), utf8.width_str(right)
    if lw + rw + 1 > w then
        local keep = math.max(1, w - rw - 2)
        local cut, cw = {}, 0
        local i = 1
        while i <= #left and cw < keep do
            local ch, ni, cp = utf8.decode(left, i)
            if not ch then break end
            cut[#cut + 1] = ch
            cw = cw + utf8.width(ch, cp)
            i = ni
        end
        left = table.concat(cut)
        lw = cw
    end

    local gap = math.max(0, w - lw - rw)
    screen:line(y, left .. string.rep(" ", gap) .. right, "reverse", w)
end

return M
