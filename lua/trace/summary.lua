-- engine 的 --json 结果 → 人读摘要（helper/trace.lua 落盘 JSON 时用）。
-- 字段名跟着 lua/trace/engine.lua 的 result 表走。
local M = {}

function M.render(mode, j)
    if type(j) ~= "table" then return "(engine 没给出可解析的 JSON)" end
    local L = {}
    local function add(f, ...) L[#L + 1] = f:format(...) end
    local lost = ""
    if (j.lost or 0) > 0 or (j.throttled or 0) > 0 then
        lost = ("（丢 %d / 限流 %d → ring_size 调大）"):format(j.lost or 0, j.throttled or 0)
    end
    local probes = table.concat(j.probes or {}, ",")
    if mode == "count" then
        add("%s  %d 次 / %gs (%.0f/s)", probes, j.count or 0, j.duration or 0, j.rate or 0)
    elseif mode == "latency" then
        add("%s events=%d paired=%d unpaired=%d%s", probes, j.events or 0,
            j.paired or 0, j.unpaired or 0, lost)
    elseif mode == "offcpu" then
        add("offcpu events=%d 配对=%d 阻塞=%d 被抢占=%d 未回切=%d%s", j.events or 0,
            j.matched or 0, j.blocked or 0, j.preempted or 0, j.unmatched or 0, lost)
    elseif mode == "oncpu" then
        add("oncpu %dHz 样本=%d 栈种类=%d%s", j.freq or 0, j.events or 0, j.stacks or 0, lost)
    elseif mode == "folded" then
        add("folded events=%d 栈种类=%d%s", j.events or 0, j.stacks or 0, lost)
    else
        add("samples events=%d%s", j.events or 0, lost)
    end
    local o = j.overall
    if o and o.count then
        add("  overall n=%d avg=%.1fus p50=%dus p99=%dus max=%.1fus",
            o.count, o.avg_us or 0, o.p50_us or 0, o.p99_us or 0, o.max_us or 0)
    end
    local n = 0
    for _, t in ipairs(j.top or {}) do
        if n >= 5 then break end
        n = n + 1
        local label = tostring(t.stack or t.key or t.comm or "?")
        if t.total_ms then
            add("  %8.1fms n=%-5d p99=%-6dus %s", t.total_ms, t.count or 0, t.p99_us or 0, label)
        else
            add("  n=%-5d avg=%7.1fus p99=%-6dus %s", t.count or 0, t.avg_us or 0,
                t.p99_us or 0, label)
        end
    end
    for _, c in ipairs(j.comms or {}) do
        if n >= 8 then break end
        n = n + 1
        add("  comm %s=%d", tostring(c.comm), c.count or 0)
    end
    return table.concat(L, "\n")
end

return M
