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
                -- 每请求 miss 归因：命中率 84% 到底是"新增内容本来就不可缓存"还是
                -- "窗口 trim 把前缀打断后重传"，只看累计值永远分不开。这里把
                -- reset 之后第一条请求单独记一栏，剩下的算 clean。
                miss_after_reset = 0,
                req_after_reset = 0,
                miss_clean = 0,
                req_clean = 0,
                -- 位移账（只记真丢了消息的 trim）：次数的分母有了，才好算
                -- 「平均位移 / 每次 trim 换回多少 miss」，而不是拿 reset 频次当成本。
                dropped_msgs = 0,
                dropped_chars = 0,
                trim_events = 0,
                -- 最近 N 条逐请求明细（{p=prompt,m=miss,r=reset种类}），只用于事后
                -- 复盘抖动，不进 prompt、不影响派发；会被 save_usage 一起落盘。
                miss_ring = {},
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
            context_chars = opts.context_chars or 120000,
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
-- 逐请求明细环形缓冲的长度。24 条足够看出"刚 trim 完的那几条 miss 有多高"，
-- 又不至于让 usage 每次落盘的 JSON 膨胀（每条 ~30 字节）。
M.MISS_RING = 24

-- 往环形缓冲追加一条逐请求明细；超长丢最旧的。
-- h/q 是给归因用的旁证：h = 落到这条时的 reset_hard 快照（真 trim 才会 +1），
-- q = 请求序号。r 只说明"标志位当时被设过"，h 才说明"那一刻真的 trim 过"；
-- 两者不一致就是标志位残留（或别的 note_cache_reset 抢先设了），不是真新基座。
local function push_miss(s, entry)
    local ring = s.miss_ring
    if type(ring) ~= "table" then
        ring = {}
        s.miss_ring = ring
    end
    entry.h = s.reset_hard or 0
    entry.q = (s.requests or 0) + 1
    -- 位移量随条目一起存：事后复盘能直接算 miss/位移，不用再去翻 last_reset
    -- （它是快照，被后续 reset 覆盖）。dc=丢弃字符，dm=丢弃条数。
    if entry.r then
        local lr = s.last_reset
        entry.dc = tonumber(lr and lr.chars) or 0
        entry.dm = tonumber(lr and lr.dropped) or 0
    end
    ring[#ring + 1] = entry
    local over = #ring - M.MISS_RING
    if over > 0 then
        for _ = 1, over do table.remove(ring, 1) end
    end
end
-- 前缀太短（首轮 / 短会话）时比值没有意义，低于这个 prompt token 数不告警。
M.PREFIX_WARN_MIN_PROMPT = 1500

-- 累积一次请求的 usage。DeepSeek 一次 agent 循环会发多个请求（每个工具轮一次），
-- 所以按请求累加，命中率 = cache_hit / (cache_hit + cache_miss)。
--
-- 同时算第二种口径：可复用前缀命中率 = hit / min(上一轮 prompt, 本轮 prompt)。
-- 前者会被"相对上一轮新增的部分"稀释 —— 一次 9KB 工具结果 ≈2.6k tokens 全部
-- 按 miss 计价，命中率自然掉到 50%，但前缀其实没坏。后者只看"上一轮那截里
-- 命中了多少"，掉下去才真的说明 system/tools/历史前缀被动过。
-- u.cache_hit/cache_miss 只有 provider 真回了 usage 才有；走 estimate_usage 兜底
-- 的那份（estimated=true，见 provider.lua）压根不知道命中了多少。这时把它当成
-- "全 miss" 会把命中率凭空拉低（网关不返 usage 的晚上能显示成 0%），所以：
-- 没拿到真值的请求只计 requests/prompt/completion，缓存两栏**不记**。
local function cache_known(u)
    if type(u) ~= "table" or u.estimated then return false end
    return u.cache_hit ~= nil or u.cache_miss ~= nil
end

function M:add_usage(u)
    if type(u) ~= "table" then return end
    local s = self.session.usage
    if not s then return end
    local prompt = tonumber(u.prompt) or 0
    local known = cache_known(u)
    local hit = known and (tonumber(u.cache_hit) or 0) or 0
    -- reset 标记在请求发出前由 note_cache_reset 埋下，这里消费掉：只有紧跟
    -- reset 的那一条请求吃「位移 miss」（新基座第一次预填充），再往后新基座的
    -- 单元已经落盘，又照常命中。注意位移 miss ≠ 整窗 miss：固定段照样命中，
    -- 只有位移点之后的旧单元接不上，所以这一栏的均值反映的是**平均位移量**。
    local pending = s._pending_reset
    s._pending_reset = nil
    if not known then
        -- 保留"这一轮有多少次请求没拿到 usage"的可见性，别让统计变成无声的谎。
        s.usage_unknown = (s.usage_unknown or 0) + 1
        s.requests = s.requests + 1
        s.prompt = s.prompt + prompt
        s.completion = s.completion + (tonumber(u.completion) or 0)
        -- miss 未知的请求只进环形缓冲、不进 clean/reset 两栏的均值：
        -- 把"不知道"当成 0 miss 会把归因结论往"trim 无害"方向拉。
        push_miss(s, { p = prompt, u = 1, r = pending })
        local last = {
            prompt = prompt,
            completion = tonumber(u.completion) or 0,
            estimated = true,
            cache_unknown = true,
            prev_prompt = s.last and s.last.prompt or nil,
        }
        s.last = last
        self:emit("usage", last, s)
        return
    end
    local miss = tonumber(u.cache_miss) or (prompt - hit)
    if miss < 0 then miss = 0 end
    local prev_prompt = s.last and s.last.prompt or nil

    -- 二分归因：紧跟 reset 的那条 vs 其余。两条都记 miss 总量和请求数，
    -- 均值相减就是"trim 一次平均白付多少 token"。
    if pending then
        s.miss_after_reset = (s.miss_after_reset or 0) + miss
        s.req_after_reset = (s.req_after_reset or 0) + 1
    else
        s.miss_clean = (s.miss_clean or 0) + miss
        s.req_clean = (s.req_clean or 0) + 1
    end
    push_miss(s, { p = prompt, m = miss, r = pending })

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

-- 前缀被 reset 的原因分三类，代价与频率完全不同，统计时必须分开看：
--   fold        —— 摘要压缩（LITE_COMPACT=1 的老策略），低频、一次性，压完还能命中新基座；
--   hard_window —— 丢弃优先（默认）下的硬上限兜底，把窗口前沿往后挪一段；
--   window      —— 手动 /compact N 的窗口滑动，每个请求都在动，命中率必然低。
-- 三者的缓存代价都**不是**「整窗作废」：官方规则下缓存前缀是互相独立的完整单元，
-- system+tools+摘要那一段照样命中，被作废的只是位移点之后、按旧偏移落盘的单元。
-- 代价量级 ≈ 位移量（丢了多少字符），所以这里除了计次还累计 chars ——
-- 判断「这轮命中率为什么掉」要看 miss/位移 的比值，不是 reset 的频次。
-- 混成一个数的话，命中率一抖根本看不出是哪种，也就无从判断该调哪个旋钮。
function M:note_cache_reset(kind, info)
    local s = self.session and self.session.usage
    if not s then return false end
    local k = tostring(kind or "?")
    if k == "fold" then
        s.reset_fold = (s.reset_fold or 0) + 1
    elseif k == "hard_window" then
        s.reset_hard = (s.reset_hard or 0) + 1
    elseif k == "window" then
        s.reset_window = (s.reset_window or 0) + 1
    else
        s.reset_other = (s.reset_other or 0) + 1
    end
    info = type(info) == "table" and info or {}
    -- 位移账：只累计真正丢了消息的那几次（dropped>0），否则重试之类零位移的 reset
    -- 会把「平均位移」摊薄。
    local n_dropped = tonumber(info.dropped) or 0
    if n_dropped > 0 then
        s.dropped_msgs = (s.dropped_msgs or 0) + n_dropped
        s.dropped_chars = (s.dropped_chars or 0) + (tonumber(info.chars) or 0)
        s.trim_events = (s.trim_events or 0) + 1
    end
    -- 埋标记给下一次 add_usage：只有紧跟 reset 的那条请求是新基座的第一次预填充。
    -- 连发两次（理论上不该有）留最后一个，种类以便覆盖真实 culprit。
    s._pending_reset = k
    s.last_reset = {
        kind = k,
        dropped = tonumber(info.dropped) or 0,
        chars = tonumber(info.chars) or 0,
        ts = os.time(),
        turn = self.session.turn,
    }
    return true
end

-- 把落盘的 usage 接回来（或清空：u 为 nil）。不这么做的话，恢复会话后状态栏
-- 从 0 开始算，"这一晚总共发了 700 次请求、前缀命中 99%"这种账目就跨不过进程边界。
-- 只接累计值 + 上一轮 prompt（给 add_usage 算可复用前缀的分母用），不接 last 里的
-- 命中明细 —— 那是"上一次请求"的快照，读到的是别人的，留着只会误导。
-- miss_ring 例外：它是**本会话的历史**不是快照，跨 /reboot 接回来才有连续样本；
-- 但 _pending_reset 不接（重启后的第一条请求前缀是重建的，不该冒充 trim 造成）。
function M:restore_usage(u)
    local s = self.session and self.session.usage
    if not s then return false end
    local src = type(u) == "table" and u or {}
    for _, k in ipairs({ "requests", "prompt", "completion", "cache_hit",
        "cache_miss", "prefix_hit", "prefix_denom",
        "miss_after_reset", "req_after_reset", "miss_clean", "req_clean",
        "dropped_msgs", "dropped_chars", "trim_events",
        "reset_fold", "reset_hard", "reset_window", "reset_other", "usage_unknown",
        "reset_epoch_requests" }) do
        s[k] = math.floor(tonumber(src[k]) or 0)
    end
    -- reset_* 是后加的字段：老快照里一个都没有，直接拿它跟累计 requests 相除
    -- 会把分母算大（把 trim 率算小）。这种情况把起点定在"接回来的那一刻"，
    -- 之后新增的请求才进分母。
    if s.reset_epoch_requests == 0
        and src.reset_fold == nil and src.reset_hard == nil
        and src.reset_window == nil and s.requests > 0 then
        s.reset_epoch_requests = s.requests
    end
    local ring = type(src.miss_ring) == "table" and src.miss_ring or nil
    if ring then
        local keep = {}
        local from = #ring - M.MISS_RING + 1
        if from < 1 then from = 1 end
        for i = from, #ring do keep[#keep + 1] = ring[i] end
        s.miss_ring = keep
    end
    local prev = math.floor(tonumber(src.last_prompt) or 0)
    s.last = prev > 0 and { prompt = prev, restored = true } or nil
    s.last_reset = type(src.last_reset) == "table" and src.last_reset or nil
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

-- 前缀 reset 频率（0~1）+ 分账明细。分母是"从 reset 开始计数那一刻到现在"的
-- 请求数，不是整个会话的累计 requests —— 两者混用的后果是 trim 率被低估一半以上。
-- 没有起点（全新会话，reset 计数与 requests 同时起算）时退化成 requests。
function M:reset_stats()
    local s = self.session and self.session.usage
    if not s then return nil end
    local since = s.reset_epoch_requests or 0
    local reqs = math.max(0, (s.requests or 0) - since)
    local fold = s.reset_fold or 0
    local hard = s.reset_hard or 0
    local window = s.reset_window or 0
    local other = s.reset_other or 0
    local total = fold + hard + window + other
    return {
        requests = reqs,
        resets = total,
        ratio = reqs > 0 and (total / reqs) or nil,
        fold = fold, hard_window = hard, window = window, other = other,
        epoch_requests = since,
        -- 二分归因：紧跟 reset 那条 vs 其余的平均 miss。注意差值的正确读法是
        -- 「平均位移换来的额外 miss」—— 官方规则下位移 miss 不是整窗 miss，
        -- 别把这个差当成窗口大小。
        miss_after_reset = (s.req_after_reset or 0) > 0
            and (s.miss_after_reset / s.req_after_reset) or nil,
        miss_clean = (s.req_clean or 0) > 0 and (s.miss_clean / s.req_clean) or nil,
        n_after_reset = s.req_after_reset or 0,
        n_clean = s.req_clean or 0,
        -- 位移账：一次 trim 平均挪动多少（字符），以及「miss/位移」的比值。
        -- 比值接近 1 = 代价就是位移本身（正常，无解也不必解）；
        -- 远大于 1 = 位移之外还有别的东西在破前缀（system 字节变了/tools 顺序变了）。
        trim_events = s.trim_events or 0,
        dropped_msgs = s.dropped_msgs or 0,
        dropped_chars = s.dropped_chars or 0,
        trim_chars_avg = (s.trim_events or 0) > 0
            and ((s.dropped_chars or 0) / s.trim_events) or nil,
    }
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
