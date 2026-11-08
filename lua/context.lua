-- 全应用状态与事件。单一数据源：session / view / settings / ui。
local M = {}
M.__index = M

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({
        session = {
            id = opts.id or os.date("%Y%m%d-%H%M%S"),
            cwd = opts.cwd or os.getenv("PWD") or ".",
            model = opts.model or "deepseek-flash",
            messages = {},
            turn = 0,
            busy = false,
            todos = {},
            -- usage 累积：DeepSeek 的 prompt_cache_hit_tokens 是判断"前缀是否稳定"的
            -- 唯一硬指标。命中率低说明每轮 prompt 前缀都在变，缓存全废。
            usage = {
                requests = 0,
                prompt = 0,
                completion = 0,
                cache_hit = 0,
                cache_miss = 0,
                -- 可复用前缀命中率：hit / min(上一轮 prompt, 本轮 prompt)。
                -- 和 cache_hit/cache_miss 分开累积，避免被"每轮新增的工具输出"稀释。
                prefix_hit = 0,
                prefix_denom = 0,
                prefix_warned_turn = -1,
                last = nil,
            },
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
            context_chars = opts.context_chars or 64000,
            context_turns = opts.context_turns or 2,
            context_window = opts.context_window or 64000,
            reserve_tokens = opts.reserve_tokens or 8192,
            -- nil = 没显式配置，M:drop_first() 再回退 LITE_COMPACT → 默认丢弃优先
            compact = opts.compact,
            max_output_tokens = opts.max_output_tokens or 8192,
            token_budget = opts.token_budget or 0,
            input_tokens = nil,
            thinking = opts.thinking,
            reasoning_effort = opts.reasoning_effort,
            max_retries = opts.max_retries or 2,
            approval = opts.approval or "auto",
            debug_log = opts.debug_log,
        },
        ui = { dirty = true },
        listeners = {},
    }, M)
    -- provider 拿到流末尾 usage 后回调；挂在 settings 上是因为 opts 就是 ctx.settings。
    self.settings.on_usage = function(u) self:add_usage(u) end
    return self
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

-- 前缀命中率低于这个值就值得提示：说明每轮 prompt 的前缀在位移。
M.PREFIX_WARN_RATIO = 0.5
-- 前缀太短（首轮 / 短会话）时比值没有意义，低于这个 prompt token 数不告警。
M.PREFIX_WARN_MIN_PROMPT = 1500

-- 累积一次请求的 usage。DeepSeek 一次 agent 循环会发多个请求（每个工具轮一次），
-- 所以按请求累加，命中率 = cache_hit / (cache_hit + cache_miss)。
--
-- 同时算第二种口径：可复用前缀命中率 = hit / min(上一轮 prompt, 本轮 prompt)。
-- 前者会被"相对上一轮新增的部分"稀释 —— 一次 9KB 工具结果 ≈2.6k tokens 全部
-- 按 miss 计价，命中率自然掉到 50%，但前缀其实没坏。后者只看"上一轮那截里
-- 命中了多少"，掉下去才真的说明 system/tools/历史前缀被动过。
function M:add_usage(u)
    if type(u) ~= "table" then return end
    local s = self.session.usage
    if not s then return end
    local prompt = tonumber(u.prompt) or 0
    local hit = tonumber(u.cache_hit) or 0
    local miss = tonumber(u.cache_miss) or (prompt - hit)
    if miss < 0 then miss = 0 end
    local prev_prompt = s.last and s.last.prompt or nil

    -- hint 只能是"上一轮和本轮都存在的部分"，所以分母取两者的较小值。
    local denom = 0
    if prev_prompt and prev_prompt > 0 and prompt > 0 then
        denom = prev_prompt < prompt and prev_prompt or prompt
    end
    local reuse
    local got = 0
    if denom > 0 then
        got = hit < denom and hit or denom
        s.prefix_hit = (s.prefix_hit or 0) + got
        s.prefix_denom = (s.prefix_denom or 0) + denom
        reuse = got / denom
    end

    s.requests = s.requests + 1
    s.prompt = s.prompt + prompt
    s.completion = s.completion + (tonumber(u.completion) or 0)
    s.cache_hit = s.cache_hit + hit
    s.cache_miss = s.cache_miss + miss
    s.last = {
        prompt = prompt,
        completion = tonumber(u.completion) or 0,
        cache_hit = hit,
        cache_miss = miss,
        reuse = reuse,
        reuse_denom = denom,
        prev_prompt = prev_prompt,
    }
    self:emit("usage", s.last, s)

    -- 每个 turn 最多提示一次：一轮 agent 循环里会有多个请求，
    -- 前缀坏了的话每条都会低于阈值，重复提示只会刷屏。
    if reuse and denom >= M.PREFIX_WARN_MIN_PROMPT
        and reuse < M.PREFIX_WARN_RATIO
        and s.prefix_warned_turn ~= self.session.turn then
        s.prefix_warned_turn = self.session.turn
        self:emit("prefix_drop", {
            ratio = reuse,
            prompt = prompt,
            prev_prompt = prev_prompt,
            denom = denom,
            hit = got,
        })
    end
end

-- 把落盘的 usage 接回来（或清空：u 为 nil）。不这么做的话，恢复会话后状态栏
-- 从 0 开始算，"这一晚总共发了 700 次请求、前缀命中 99%"这种账目就跨不过进程边界。
-- 只接累计值 + 上一轮 prompt（给 add_usage 算可复用前缀的分母用），不接 last 里的
-- 命中明细 —— 那是"上一次请求"的快照，读到的是别人的，留着只会误导。
function M:restore_usage(u)
    local s = self.session and self.session.usage
    if not s then return false end
    local src = type(u) == "table" and u or {}
    for _, k in ipairs({ "requests", "prompt", "completion", "cache_hit",
        "cache_miss", "prefix_hit", "prefix_denom" }) do
        s[k] = math.floor(tonumber(src[k]) or 0)
    end
    local prev = math.floor(tonumber(src.last_prompt) or 0)
    s.last = prev > 0 and { prompt = prev, restored = true } or nil
    self:emit("usage", s.last, s)
    return true
end

-- 会话级缓存命中率（0~1）；没有任何请求时返回 nil。
-- 注意：这个值包含"新增内容"的 miss，工具输出多的时候会掉，属于正常现象；
-- 判断前缀是否稳定请用 prefix_ratio()。
function M:cache_ratio()
    local s = self.session and self.session.usage
    if not s then return nil end
    local total = (s.cache_hit or 0) + (s.cache_miss or 0)
    if total <= 0 then return nil end
    return s.cache_hit / total
end

-- 会话级"可复用前缀命中率"（0~1）；没有两轮以上的请求时返回 nil。
function M:prefix_ratio()
    local s = self.session and self.session.usage
    if not s then return nil end
    local denom = s.prefix_denom or 0
    if denom <= 0 then return nil end
    return (s.prefix_hit or 0) / denom
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
