-- [埋点] usage 出口：读侧的查询工具，账本来源见 memory:add_usage_day。
-- tokens：每日 token 用量账本。
-- 数据来自 memory 的 `/agent/usage` → `day/<YYYY-MM-DD>`（agent 每轮结束随
-- save_usage 累加落盘），所以跨会话、跨进程都是同一本账。
local function num(v) return math.floor(tonumber(v) or 0) end

local function rate(hit, miss)
    local t = num(hit) + num(miss)
    if t <= 0 then return "-" end
    return string.format("%.0f%%", num(hit) / t * 100)
end

local function kfmt(n)
    n = num(n)
    if n >= 1000000 then return string.format("%.2fM", n / 1000000) end
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(n)
end

local function delta(a, b)
    a, b = num(a), num(b)
    if b <= 0 then return "" end
    local d = (a - b) / b * 100
    return string.format(" %s%.0f%%", d >= 0 and "+" or "", d)
end

local function memory_of(env)
    if env and env.memory and env.memory.usage_days then return env.memory end
    error("tokens needs memory access (env.memory); run inside lite")
end

local M = {}

M.schema = {
    name = "tokens",
    description = "每日 token 消耗统计（prompt/completion/缓存命中率，按天聚合，可看今天 vs 昨天）",
    parameters = {
        type = "object",
        properties = {
            days = { type = "integer", description = "看最近几天，默认 7" },
        },
    },
}

function M.run(args, env)
    args = args or {}
    local mem = memory_of(env)
    local n = math.max(1, math.min(90, num(args.days) or 7))
    local rows = mem:usage_days(n)

    if #rows == 0 then
        return "还没有每日用量记录（本轮结束后 agent:save_usage 会写第一条）"
    end

    local out = {}
    out[1] = string.format("最近 %d 天 token 用量", n)
    out[2] = "日期         请求    prompt    output   缓存命中"
    local sum = { requests = 0, prompt = 0, completion = 0, cache_hit = 0, cache_miss = 0 }
    for _, r in ipairs(rows) do
        out[#out + 1] = string.format("%s %5d %9s %9s %7s",
            r.day or "-", num(r.requests), kfmt(r.prompt), kfmt(r.completion), rate(r.cache_hit, r.cache_miss))
        for k in pairs(sum) do sum[k] = sum[k] + num(r[k]) end
    end
    out[#out + 1] = string.format("合计         %5d %9s %9s %7s",
        sum.requests, kfmt(sum.prompt), kfmt(sum.completion), rate(sum.cache_hit, sum.cache_miss))

    -- 今天 vs 昨天：用户最常问的其实就这句
    local today = mem:usage_day()
    local day = os.date("%Y-%m-%d")
    local yday = mem:usage_day(os.date("%Y-%m-%d", os.time() - 86400))
    if today then
        local total = num(today.prompt) + num(today.completion)
        out[#out + 1] = string.format("今天 %s：%d 请求，%s tokens%s（对比昨天）",
            day, num(today.requests), kfmt(total), delta(total, yday and (num(yday.prompt) + num(yday.completion)) or 0))
    end
    return table.concat(out, "\n")
end

return M
