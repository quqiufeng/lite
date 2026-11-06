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
    -- 缓存命中率：唯一能说明"前缀是否稳定"的指标。低于 50% 说明每轮 prompt
    -- 都在整体位移，等于按 miss 价重付整段历史。
    local cache = ""
    if type(info.cache) == "number" then
        local pct = math.floor(info.cache * 100 + 0.5)
        if pct > 100 then pct = 100 end
        if pct < 0 then pct = 0 end
        cache = string.format(" cache:%d%%", pct)
    end
    local todo = ""
    local todos = info.todos
    if todos and #todos > 0 then
        local done = 0
        for _, it in ipairs(todos) do
            if it.status == "completed" then done = done + 1 end
        end
        todo = string.format(" todo:%d/%d", done, #todos)
    end
    -- 估算的 prompt token 占预算的比例：判断"离压缩还远不远"最直接的数字。
    -- 用真实 usage 校准过，不是纯字符估算。
    local ctxpct = ""
    local probe = info.ctxeng
    if type(probe) == "table" and probe.line and probe.line > 0 and probe.used then
        local p = math.floor(probe.used / probe.line * 100 + 0.5)
        if p > 999 then p = 999 end
        if p >= 60 then
            ctxpct = string.format(" ctx:%d%%", p)
        end
    end
    local queued = (info.queue or 0) > 0 and string.format(" queue:%d", info.queue) or ""
    local right = mem .. cache .. ctxpct .. todo .. queued .. " · " .. status .. " "
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
