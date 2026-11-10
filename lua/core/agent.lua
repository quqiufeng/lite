-- Agent 循环：messages → provider → tool calls → messages。
local cjson = require("cjson")
local Prompt = require("core.prompt")
local Text = require("core.text")
local Approval = require("core.approval")
local Compact = require("core.compact")

local M = {}
M.__index = M

function M.new(ctx, provider, tools, session, memory)
    local self = setmetatable({
        ctx = ctx,
        provider = provider,
        tools = tools,
        session = session,
        memory = memory,
        prompt = Prompt,
        async = false,
        _failures = {},
    }, M)
    self.approval = Approval.new({
        mode = ctx.settings.approval,
        memory = memory,
        session_id = ctx.session.id,
    })
    -- [埋点] usage 第一站：包住 ctx 的回调，真 usage / 兜底估值都从这里流下来。
    -- 下一站 agent.track_usage_day → memory:add_usage_day（按天账本）。
    local settings = ctx.settings
    if settings and type(settings.on_usage) == "function" then
        local inner = settings.on_usage
        settings.on_usage = function(u, ...)
            inner(u, ...)
            self:track_usage_day(u)
        end
    end
    return self
end

-- [埋点] usage 第二站：按本地日期累加到内存桶（不逐请求写盘）。
function M:track_usage_day(u)
    if type(u) ~= "table" then return false end
    local day = os.date("%Y-%m-%d")
    local acc = self._usage_day
    if not acc or acc.day ~= day then
        acc = { day = day, requests = 0, prompt = 0, completion = 0, cache_hit = 0, cache_miss = 0 }
        self._usage_day = acc
    end
    for k in pairs(acc) do
        if k ~= "day" then acc[k] = acc[k] + (tonumber(u[k]) or 0) end
    end
    acc.requests = acc.requests + 1
    return true
end

-- [埋点] usage 第三站：把内存桶并进记忆（写成功后清零，失败留给下次，不丢账）。
-- 把当日增量并进记忆桶；写成功后清零，失败留着下次重试（不丢账）。
function M:flush_usage_day()
    local acc = self._usage_day
    if not acc or acc.requests <= 0 then return false end
    if not (self.memory and self.memory.add_usage_day) then return false end
    local ok = self.memory:add_usage_day(acc, acc.day)
    if ok then
        self._usage_day = { day = acc.day, requests = 0, prompt = 0, completion = 0, cache_hit = 0, cache_miss = 0 }
    end
    return ok
end

function M:system_prompt(active_tools)
    return self.prompt.system_prompt(self.ctx, {
        tools = active_tools or self.tools:schemas(),
    })
end

function M:ensure_system(active_tools)
    local msgs = self.ctx.session.messages
    local prompt = self:system_prompt(active_tools)
    local changed = false
    if #msgs == 0 or msgs[1].role ~= "system" then
        local msg = { role = "system", content = prompt }
        table.insert(msgs, 1, msg)
        self.session:append(msg)
        changed = true
    -- 旧会话恢复出来的是旧 system prompt；不刷新的话 prompt 改动永远不生效。
    -- 只替换内存中的首条，不重复 append；下个进程启动再刷新一次即可。
    elseif msgs[1].content ~= prompt then
        msgs[1] = { role = "system", content = prompt }
        changed = true
    end
    if changed and self.ctx.settings.debug then
        self.ctx.settings.debug:log("system_prompt", {
            content = prompt,
            bytes = #prompt,
            tools = active_tools and #active_tools or 0,
        })
    end
    -- 历史中意外混入的 system 消息（旧恢复逻辑会插在中间）也清掉。
    for i = #msgs, 2, -1 do
        if msgs[i].role == "system" then table.remove(msgs, i) end
    end
end

-- ---------------------------------------------------------------------------
-- 上下文压缩（低频 cache-reset）
--
-- 旧实现每轮都从最老整段切 msgs，前缀整体位移，DeepSeek 的 prompt cache 每轮
-- 都 miss —— 等于按全价重付整段历史。现在改成 Reasonix 的做法：prompt 一直
-- append-only，只在跨过阈值时压一次，压完记 baseline 继续追加。
-- ---------------------------------------------------------------------------

function M:compactor()
    if self._compactor then return self._compactor end
    local s = self.ctx.settings or {}
    local budget = tonumber(s.context_chars) or 64000

    -- 预算下限保护：压缩的可分配预算 = 预算 - 固定前缀（system + 钉住的首条 user）。
    -- system prompt 本身就有 4~5k 字符，预算设得比它大不了多少时，可分配空间
    -- 连"折叠区 + 尾巴"的最小值都不够 → 每次压缩都"nothing to fold" → 一路滑到
    -- 硬上限丢历史。实测 budget 9000 时 prompt 8195 → 1231，代价比不压缩大得多。
    -- 所以这里把预算抬到固定前缀的 3 倍（够放下摘要 + 尾巴 + 可折叠区）。
    local fixed = self:fixed_prefix_chars()
    local floor = math.floor(fixed * 3)
    if budget < floor then
        if not self._budget_warned and fixed > 0 then
            self._budget_warned = true
            self.ctx:emit("compact", {
                ok = false, reason = "budget raised",
                requested = budget, effective = floor, fixed_prefix = fixed,
            })
        end
        budget = floor
    end

    -- 只暴露两个用户真正能调的旋钮：总预算和尾巴轮数上限。
    -- 其余比例都在 compact.DEFAULTS 里，改代码/单测可以覆盖，
    -- 但不假装它们是用户可配置项（那样的开关永远走不到）。
    self._compactor = Compact.new({
        budget_chars = budget,
        tail_turn_cap = tonumber(s.context_turns) or nil,
    })
    return self._compactor
end

-- 固定前缀的字符数：system prompt + 首条 user（钉住的那条）。
-- 这段每次请求都付费，且不能被压缩掉，所以它是预算的地板。
function M:fixed_prefix_chars()
    local msgs = self.ctx.session.messages or {}
    local n = 0
    if msgs[1] and msgs[1].role == "system" then
        n = Compact.msg_chars(msgs[1])
    end
    return n
end

local function state_key(session_id)
    return tostring(session_id) .. "/compact"
end

local function msg_anchor(m)
    if type(m) ~= "table" then return nil end
    local text = Text.content_text(m.content)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
    local ids = {}
    for _, tc in ipairs(m.tool_calls or {}) do ids[#ids + 1] = tostring(tc.id or "") end
    return { role = m.role, hash = h, bytes = #text, ids = table.concat(ids, ",") }
end

local function anchor_matches(m, a)
    if type(m) ~= "table" or type(a) ~= "table" then return false end
    if m.role ~= a.role then return false end
    local text = Text.content_text(m.content)
    if #text ~= a.bytes then return false end
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
    if h ~= a.hash then return false end
    local ids = {}
    for _, tc in ipairs(m.tool_calls or {}) do ids[#ids + 1] = tostring(tc.id or "") end
    return table.concat(ids, ",") == a.ids
end

-- 压缩状态：{ baseline = 已折叠到第几条, digest = 摘要正文, block = 渲染块,
--              rearm_chars = 下次值得再压的规模 }
-- 优先存 KV（跨进程/重启可恢复）；没有 KV 时退回进程内。
-- 这个兜底不是可选项：状态一丢，baseline 归零，下一次请求就会把整段历史
-- 重新摘一遍 —— 每次请求多花一次摘要调用，比不压缩贵得多。
function M:compact_state()
    -- 进程内状态就是最新值（save_compact_state 同步写这里），先用它，
    -- 只有新进程/尚无状态时才回落到 KV，避免每个请求都 get+解码一次。
    local st = self._compact_state
    if type(st) ~= "table" and self.memory and self.memory.get then
        st = self.memory:get("/agent/session", state_key(self.ctx.session.id))
    end
    if type(st) ~= "table" then return nil end
    if type(st.baseline) ~= "number" then return nil end
    if type(st.digest) ~= "string" or st.digest == "" then return nil end
    if type(st.digest) == "string" and Compact.sanitize_digest then
        st.digest = Compact.sanitize_digest(st.digest)
    end
    if type(st.block) == "string" and Compact.sanitize_block then
        st.block = Compact.sanitize_block(st.block)
    end
    -- baseline 是数组下标，跨重启会失效；有 anchor 就按消息内容重新定位。
    -- 找不到锚点说明它已经被 raw_keep 截掉，digest 已覆盖更老内容，从
    -- system 后重新开始，绝不能把当前 user 切掉。
    local msgs = self.ctx.session.messages or {}
    local total = #msgs
    if st.anchor then
        local found
        for i = 1, total do
            if anchor_matches(msgs[i], st.anchor) then found = i end
        end
        st.baseline = found or 1
    elseif total > 0 and (st.baseline or 0) >= total then
        st.baseline = 1
    end
    return st
end

-- usage 落盘/恢复。挂在 agent 上而不是 context 上：context 不认识 memory，
-- memory 又只在 agent 手里。调用点只有"一轮结束"和"会话装载"两处，不逐请求写
-- —— 工具循环里一轮能发几十次请求，逐次落盘等于每轮几十次 fsync。
-- 存 permanent TTL 且 key 不在召回白名单（只放 fact/turn/working），不会进 prompt。
function M:save_usage()
    if not (self.memory and self.memory.save_usage) then return false end
    local ctx = self.ctx
    if not ctx then return false end
    local ok = self.memory:save_usage(ctx.session.id, ctx.session.usage)
    self:flush_usage_day()
    return ok
end

function M:restore_usage()
    if not (self.memory and self.memory.load_usage) then return false end
    local ctx = self.ctx
    if not ctx then return false end
    return ctx:restore_usage(self.memory:load_usage(ctx.session.id))
end

function M:save_compact_state(st)
    self._compact_state = st
    if type(st) == "table" and type(st.baseline) == "number" then
        st.anchor = msg_anchor(self.ctx.session.messages[st.baseline])
    end
    if not (self.memory and self.memory.put) then return end
    local ttl = (self.memory.TTL and self.memory.TTL.long) or 0
    self.memory:put("/agent/session", state_key(self.ctx.session.id), st, ttl)
end

-- 发给 API 的消息必须满足 tool_calls/tool 配对：assistant 的每个 id
-- 都要有紧随其后的 tool 结果。恢复窗口/预算裁剪可能从中间切开，
-- 这里做最后一道结构修复，宁可少一条旧消息，也不能让整个请求 400。
local function repair_tool_pairs(msgs)
    local out = {}
    local i = 1
    while i <= #msgs do
        local m = msgs[i]
        if m.role == "tool" then
            -- 前面没有对应 assistant 的孤儿 tool 结果
            i = i + 1
        elseif m.role == "assistant" and type(m.tool_calls) == "table"
            and #m.tool_calls > 0 then
            local j = i + 1
            local tools = {}
            while j <= #msgs and msgs[j].role == "tool" do
                tools[#tools + 1] = msgs[j]
                j = j + 1
            end
            local expected, got = {}, {}
            for _, tc in ipairs(m.tool_calls) do
                local id = tc.id or tc["tool_call_id"]
                if id then expected[id] = true end
            end
            for _, t in ipairs(tools) do
                if expected[t.tool_call_id] then got[t.tool_call_id] = true end
            end
            local complete = true
            for id in pairs(expected) do
                if not got[id] then complete = false end
            end
            if complete then
                out[#out + 1] = m
                for _, t in ipairs(tools) do out[#out + 1] = t end
            end
            i = j
        else
            out[#out + 1] = m
            i = i + 1
        end
    end
    return out
end

-- 真正发给模型的视图：system + [摘要块] + 动态尾部窗口。
--
-- baseline 只是 compact checkpoint 的锚点，不再直接作为唯一 slice 下标：
-- 从当前消息数组末尾按预算向前装，当前 user 消息永远最后、永远保留。
-- baseline 无效（重启只恢复了最近 N 条）时从 system 后重新开始；有 digest
-- 时再按预算向前滑，避免旧绝对下标把新消息截掉。
function M:view_messages(opts)
    opts = opts or {}
    local all = self.ctx.session.messages
    local st = self:compact_state()
    local out = {}
    if all[1] and all[1].role == "system" then out[1] = all[1] end
    if st and st.block and st.block ~= "" then
        out[#out + 1] = { role = "system", content = st.block }
    end

    local from = st and (st.baseline or 0) or 0
    if from < 0 then from = 0 end
    if from > 0 and from >= #all then from = 1 end
    if from < 1 and all[1] and all[1].role == "system" then from = 1 end

    local last_user
    for i = #all, 1, -1 do
        if all[i].role == "user" then last_user = i; break end
    end

    -- 动态窗口：有 digest 时才可以丢弃未折叠的旧尾巴；没有 digest 的
    -- 普通会话仍保留完整历史，交给 hard_window/compact 兜底。
    if opts.budget and st and st.block and st.block ~= "" then
        local head = Compact.total(out) + (tonumber(opts.reserve) or 0)
        local budget = math.max(1, (tonumber(opts.budget) or 0) - head)
        local start, used = #all + 1, 0
        for i = #all, from + 1, -1 do
            local chars = Compact.msg_chars(all[i])
            if used + chars > budget and start <= #all then break end
            used = used + chars
            start = i
        end
        -- 当前 turn 的 user 必须保留，即使尾部 tool 输出把它挤出预算。
        if last_user and last_user > from and start > last_user then
            start = last_user
        end
        -- tool result 不能脱离它的 assistant 调用；向前补齐配对。
        while start > from + 1 and all[start] and all[start].role == "tool" do
            start = start - 1
        end
        if start <= #all then from = start - 1 end
    end

    -- 恢复的最近消息可能从 tool 结果中间开始；没有前面的 assistant
    -- tool_calls 时，开头的 tool 消息是孤儿，必须丢掉，否则真实 API
    -- 会报 "insufficient tool messages following tool_calls"。
    while from < #all and all[from + 1] and all[from + 1].role == "tool" do
        from = from + 1
    end

    local clips
    if from < #all then clips = self:compactor():clips(all) end
    for i = from + 1, #all do
        local cap = clips and clips[i]
        if cap then
            out[#out + 1] = Compact.clip_message(all[i], cap)
        else
            out[#out + 1] = all[i]
        end
    end
    return repair_tool_pairs(out)
end

-- 摘要调用：走和主循环同一个 stream（sync 或 async 协程），
-- 刻意不传 tools —— 摘要用不到工具定义，带上只是白付 schema 的 token，
-- 而且它本来就不和主对话共享缓存前缀（opencode 的结论）。
function M:summarize(text, prompt, stream)
    if type(stream) ~= "function" then return nil, "no stream" end
    local opts = {}
    for k, v in pairs(self.ctx.settings or {}) do opts[k] = v end
    opts.temperature = 0
    opts.on_usage = self.ctx.settings and self.ctx.settings.on_usage or nil
    -- 摘要不该带上 thinking，否则输出预算被思考吃掉。
    opts.thinking = false
    opts.reasoning_effort = nil
    local msgs = {
        { role = "system", content = tostring(prompt or Compact.DIGEST_PROMPT) },
        { role = "user", content = text },
    }
    local assistant, err = stream(msgs, {}, opts, nil, nil)
    if not assistant then return nil, err end
    local out = tostring(assistant.content or "")
    if out == "" then return nil, "empty summary" end
    return out, nil
end

-- chars→tokens 校准比例；没有真实 usage 时返回 nil（调用方退回经验值）。
function M:tok_per_char()
    local u = self.ctx.session and self.ctx.session.usage
    local last = u and u.last
    if not last or not last.prompt or last.prompt <= 0 then return nil end
    if not self._last_request_chars or self._last_request_chars <= 0 then return nil end
    return last.prompt / self._last_request_chars
end

-- 上次请求的估算 token 数（用于诊断；没有校准数据时用经验值）。
function M:estimate_tokens(chars)
    local r = self:tok_per_char() or Compact.DEFAULT_TOK_PER_CHAR
    return math.floor((chars or 0) * r)
end

-- 丢弃优先（默认）：不摘要，靠 hard_window 从最新往回装，更老的整条丢，
-- 需要时让模型自己 recall。settings.compact=true（LITE_COMPACT=1）恢复旧策略。
function M:drop_first()
    if self._drop_first ~= nil then return self._drop_first end
    local v = (self.ctx.settings or {}).compact
    if v == nil then
        local e = os.getenv("LITE_COMPACT")
        if e == nil then
            v = false
        else
            e = tostring(e):lower()
            v = (e == "1" or e == "true" or e == "on" or e == "yes")
        end
    end
    self._drop_first = (v ~= true)
    return self._drop_first
end

-- /compact：手动把窗口滑到 budget*keep（默认 0.6），返回收缩统计。
-- 只影响发出去的请求，session.messages 与记忆一条不删 —— 这是和其他 agent 的区别：
-- 我们「压缩」= 只读缩小的窗口，老的还在记忆里，recall 就能捞回来。
-- keep=nil 表示解除，回到自动策略。
function M:manual_window(keep)
    local c = self:compactor()
    if keep == nil then
        self._window_keep = nil
        return { keep = nil, before = 0, after = 0, dropped = 0 }
    end
    keep = math.max(0.1, math.min(1, tonumber(keep) or 0.6))
    self._window_keep = keep
    local msgs = self:view_messages({ budget = c.budget })
    local before = Compact.total(msgs)
    local kept, _, dropped = self:hard_window(msgs, math.floor(c.budget * keep))
    local after = Compact.total(kept)
    return { keep = keep, before = before, after = after, dropped = dropped,
        budget = c.budget, total = #self.ctx.session.messages }
end

-- 超阈值才压一次。返回 true 表示这次真的压了（调用方应重建视图）。
function M:maybe_compact(stream, reserve, force)
    if not force and self:drop_first() then return false end
    local c = self:compactor()
    local st = self:compact_state()
    local view = self:view_messages()
    local used = Compact.total(view) + (tonumber(reserve) or 0)

    -- 触发线 + 迟滞线取较大者。压完的基座若本身就贴着触发线，
    -- 不设迟滞就会"下一条消息又触发"，每轮压一次。
    local line = c:trigger()
    -- 参考 Pi/opencode：窗口减去 reserve 也是触发线；取更早的那个。
    local window = tonumber(self.ctx.settings.context_window) or 0
    local reserve_tokens = tonumber(self.ctx.settings.reserve_tokens) or 0
    if window > reserve_tokens and window > 0 then
        local ratio = self:tok_per_char()
        if ratio and ratio > 0 then
            local token_chars = math.floor((window - reserve_tokens) / ratio)
            if token_chars > 0 and token_chars < line then line = token_chars end
        end
    end
    if st and type(st.rearm_chars) == "number" and st.rearm_chars > line then
        line = st.rearm_chars
    end
    self._compact_probe = {
        used = used, line = line,
        est_tokens = self:estimate_tokens(used),
        tok_per_char = self:tok_per_char(),
    }
    if used <= line and not force then return false end

    local summarize = function(text, prompt)
        return self:summarize(text, prompt, stream)
    end
    local res = c:fold(self.ctx.session.messages, summarize, {
        previous_digest = st and st.digest or nil,
    })
    if not res.ok then
        self.ctx:emit("compact", { ok = false, reason = res.reason,
            used = used, line = line, plan = res.plan })
        return false
    end
    -- 新 baseline 必须真的有推进，否则下次还会重复压同一段。
    if st and res.baseline <= (st.baseline or 0) then
        self.ctx:emit("compact", { ok = false, reason = "no progress" })
        return false
    end

    self:save_compact_state({
        baseline = res.baseline,
        digest = res.digest,
        block = res.block,
        rearm_chars = res.rearm_chars,
        updated = os.time(),
        v = 2,
    })
    self.ctx:emit("compact", {
        ok = true, stats = res.stats, baseline = res.baseline,
        rearm_chars = res.rearm_chars,
    })
    -- 压缩后历史变短，插件若在外部存了索引/镜像，这里重建一次。
    if self:has_hooks("on_compact") then
        self.tools:on_compact({ stats = res.stats, baseline = res.baseline })
    end
    return true
end

-- 硬安全上限：只在压缩没能把 prompt 拉回预算内时兜底。
-- 这是物理边界，不是策略——触发它说明有 bug 或单条消息本身超预算。
--
-- 关键：必须**保住已有的 digest**。view_messages() 的输出是
-- [system, 摘要块, ...历史]，早期的实现在这里只留 msgs[1] 再加一条丢弃提示，
-- 于是摘要被一起扔掉 —— 结果是小预算下压缩失败 → 走硬上限 → 历史被清空
-- 且连摘要都不剩（实测 prompt 8195 → 1231，模型得从头再来）。那比不压更差。
--
-- 返回 (msgs, trimmed, dropped_count)。trimmed=false 表示无可丢弃。
function M:hard_window(msgs, budget)
    local n = #msgs
    -- 前导的固定段：system prompt 与紧随其后的摘要块（view_messages 的布局）。
    -- 这些是压缩的产物，比中间的原始消息便宜得多，必须保留。
    local lead = 0
    if msgs[1] and msgs[1].role == "system" then lead = 1 end
    while lead < n and msgs[lead + 1].role == "system"
        and Compact.is_digest and Compact.is_digest(msgs[lead + 1]) do
        lead = lead + 1
    end

    -- 从最新往回装，直到预算用完
    local start = n + 1
    local acc = 0
    for i = n, lead + 1, -1 do
        local c = Compact.msg_chars(msgs[i])
        if (n - i + 1) > 2 and acc + c > budget then break end
        acc = acc + c
        start = i
    end
    -- 当前 turn 的 user 不能因为尾部太大被丢弃。
    local last_user
    for i = n, lead + 1, -1 do
        if msgs[i].role == "user" then last_user = i; break end
    end
    if last_user and start > last_user then start = last_user end
    -- 尾巴不能以孤立的 tool 结果开头（对应的 tool_calls 被丢了会 400）
    while start > lead + 1 and start <= n and msgs[start].role == "tool" do
        start = start - 1
    end

    local dropped = start - 1 - lead
    if dropped < 1 then return msgs, false, 0 end

    local out = {}
    for i = 1, lead do out[#out + 1] = msgs[i] end
    out[#out + 1] = {
        role = "system",
        -- 文案不带条数：同一丢弃窗口内字节稳定，前缀缓存不至于每轮全失效。
        content = "<session_context>\nPrompt hit the hard size ceiling; older message(s) were"
            .. " dropped without being summarized. Use recall(query, limit) if you need them.\n"
            .. "</session_context>",
    }
    for i = start, n do out[#out + 1] = msgs[i] end
    return repair_tool_pairs(out), true, dropped
end

-- 组装发出去的完整消息列表：视图 + 召回块。
--
-- opts.inject_context：每个用户轮**只在第一次请求**注入召回块，工具循环的后续请求不注入
-- （模型早已见过，重复注入既打断前缀缓存又白花 token）。
-- 召回块**追加到最末尾**而不是插在会话中间 —— 原因与实测见下面 "追加到最末尾" 那段注释
-- 以及 design.md D1。todo 是工具状态，不自动注入 prompt。
function M:request_messages(text, stream, opts)
    opts = opts or {}
    local inject = opts.inject_context ~= false
    local block = ""
    if inject and self.memory then
        local query = self.prompt.recall_query(text, self.ctx.session.messages)
        local items
        block, items = self.memory:context(query, {
            limit = 8,
            max_chars = 2400,
            session_id = self.ctx.session.id,
            -- 自命中闸门：query 就是最新这句用户原文，所以刚落盘的自己 100% 命中；
            -- 最近两条 msg（本轮这句 + 上一条）原文都在窗口里，召回等于把 prompt
            -- 再抄一遍。实测每轮稳定白占 2~3 个名额（上限 8）。
            skip_text = text,
            skip_recent = 2,
        })
        self.ctx:emit("memory", items or {})
    end

    local reserve = #block + 200
    -- 时钟 + 轮次预算：每轮都变，只能放末尾（见下）。
    local rt = self.prompt.runtime_block(self.ctx, {
        turn = opts.turn, max_turns = opts.max_turns,
    })
    reserve = reserve + #rt + 4
    self:maybe_compact(stream, reserve, opts.force_compact)
    local c = self:compactor()
    local msgs = self:view_messages({ budget = c.budget, reserve = reserve })
    local used = Compact.total(msgs) + reserve
    local drop_first = self:drop_first()
    -- 丢弃优先时硬线就设在触发线：不做有损摘要，超了直接从最新往回装。
    local ceiling = drop_first and c:trigger() or math.floor(c.budget * 2)
    if used > ceiling then
        local trimmed, dropped
        -- 保留比例：LITE_KEEP_RATIO（0.3~0.95），默认丢弃优先 0.6（丢约 40% 历史）。
        local keep = tonumber(os.getenv("LITE_KEEP_RATIO") or "")
        if not keep or keep < 0.3 or keep > 0.95 then
            keep = drop_first and 0.6 or 0.8
        end
        -- /compact 手动窗口：窗口从最新往回只装 budget*keep，且**每个请求都滑动**，
        -- 老消息不删不摘要，留在 session/记忆里靠 recall 取回。
        if self._window_keep then
            keep = self._window_keep
            ceiling = math.floor(c.budget * keep)
        end
        msgs, trimmed, dropped = self:hard_window(msgs,
            math.floor(c.budget * keep))
        if trimmed then
            self.ctx:emit("compact", {
                ok = false, reason = "hard ceiling", dropped = dropped,
                kept_digest = (self:compact_state() ~= nil),
            })
        end
    end

    -- 追加到**最末尾**，不要插在中间。
    --
    -- 召回内容每轮不同（随 query 变）。插在会话中间会把后面所有消息整体位移，
    -- DeepSeek 的前缀缓存从插入点往后全部失效。实测（真实 API，同一底座）：
    -- 插在最后一条 user 之前，下一轮命中 71%；追加到末尾，同一轮命中 97% ——
    -- 差的就是被位移的那段历史。末尾放 system 消息 DeepSeek 接受（已验证）。
    local out = {}
    for i = 1, #msgs do out[#out + 1] = msgs[i] end
    if block ~= "" then
        out[#out + 1] = { role = "system", content = block }
    end
    -- 时钟 + 剩余轮次：同一套理由，只能追加在末尾；模型每轮都能看到自己还剩几次工具调用。
    -- 上下文预算同理（用组装后的真实规模算），拼在同一块里，保证每轮只有一个尾部 system。
    if rt ~= "" then
        -- 不再播报上下文预算：丢窗口优先时它是纯噪声（模型每轮看到 100% 只会浪费 tokens）。
        -- 需要时设 LITE_BUDGET_HINT=1 恢复。
        if os.getenv("LITE_BUDGET_HINT") == "1" then
            local bd = self.prompt.budget_block(self.ctx, { used = Compact.total(out), budget = c.budget })
            if bd ~= "" then rt = rt .. "\n" .. bd end
        end
        out[#out + 1] = { role = "system", content = rt }
    end
    -- 本次真正发出去的规模，供下一轮用真实 usage 反推 chars→tokens。
    self._last_request_chars = Compact.total(out)
    return out
end

local function decode_args(s)
    if not s or s == "" then return {} end
    local ok, v = pcall(cjson.decode, s)
    if ok and type(v) == "table" then return v end
    return nil
end

-- 同一批工具调用连续重复这么多次，就认为模型卡住了（同一命令反复跑，结果不变）。
-- 手写循环在 128 轮里烧掉几十万 token 是常态，越早熔断越好。
M.REPEAT_LIMIT = 4
M.RESULT_REPEAT_LIMIT = 3

-- 不同命令可能产生同一结果（反复 git log/ls）。只比较调用参数抓不到；
-- 用「工具名 + 结果哈希」做无进展检测。
local function result_sig(name, result)
    local s = tostring(result or "")
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return tostring(name) .. ":" .. h .. ":" .. #s
end

local STOP_NOTE = table.concat({
    "<session_context>",
    "工具循环已停止：%s。现在没有可用工具，不要再请求工具调用。",
    "用户原问题：%s",
    "先检查上下文中已有的 tool 结果；能用就用最新结果，只有确实没有可用数据时才说无法回答。",
    "直接回答这个问题，先给结论（是/否/状态/版本），不要复述历史：",
    "1) 结论；",
    "2) 只列必要的一两条证据；",
    "3) 仅当确实需要时再给下一步。",
    "</session_context>",
}, "\n")

-- 用户中断（Esc×2）后收尾：把悬空的 tool_calls 补成"已取消"结果。
--
-- 不补的话那条 assistant 会被 view_messages 整块丢掉，模型下一轮只看到
-- 「请用 bash 跑 sleep 45」这条 user 指令、看不到自己已经回过，于是把刚被
-- 中断的工具原样再发一遍 —— 用户的感觉就是「Esc 没生效 / 输入没反应」。
function M:abort(reason)
    local ctx = self.ctx
    local msgs = ctx.session.messages
    local note = "[cancelled by user]" .. (reason and (" " .. tostring(reason)) or "")
    for i = #msgs, 1, -1 do
        local m = msgs[i]
        if m.role == "user" then
            return 0 -- 最近一条 user 之后没有悬空工具块
        elseif m.role == "assistant" and type(m.tool_calls) == "table"
            and #m.tool_calls > 0 then
            local got = {}
            local j = i + 1
            while j <= #msgs and msgs[j].role == "tool" do
                got[msgs[j].tool_call_id] = true
                j = j + 1
            end
            local filled, at = 0, j
            for _, tc in ipairs(m.tool_calls) do
                local id = tc.id or tc["tool_call_id"]
                if id and not got[id] then
                    local msg = { role = "tool", tool_call_id = id, content = note }
                    table.insert(msgs, at, msg)
                    self.session:append(msg)
                    at = at + 1
                    filled = filled + 1
                end
            end
            return filled
        end
    end
    return 0
end

-- 循环被迫结束时，再要一次"不带工具"的收尾。
--
-- 直接 return nil, "max turns reached" 会把前面几十轮做完的事情全丢掉 ——
-- 用户只看到一句报错，得自己翻会话才知道跑到哪了。收尾请求不带 tools
-- （模型没有工具可调，只能说话），把结论落地成一条普通 assistant 消息。
-- 这额外一次请求是全新前缀，但只发生一次，值得。
function M:_finalize(stream, why)
    local ctx = self.ctx
    local msgs = self:view_messages()
    -- 用 user 而不是在末尾插 system：有些网关对"system 必须在最前面"较真，
    -- 这个请求要是 400 了，前面几十轮的结果就彻底丢了。
    local question = tostring(self._text or ""):sub(1, 500)
    msgs[#msgs + 1] = { role = "user", content = string.format(STOP_NOTE, why, question) }

    ctx:emit("turn_limit", { reason = why, turns = ctx.settings.max_turns })
    -- 工具轮结束时没有 end_turn（busy 还挂着），别再叠一个 turn_start。
    if not ctx.session.busy then ctx:begin_turn() end
    ctx:set_status("thinking")
    local assistant, err = stream(msgs, nil, ctx.settings,
        function(delta) ctx:emit("delta", delta) end,
        function(delta) ctx:emit("reasoning", delta) end)
    if not assistant then
        ctx:end_turn()
        return nil, err
    end
    local answer = assistant.content or ""
    if answer:match("^%s*$") then
        -- 模型有时仍然只回一个空串/又一次工具调用，至少别让用户看到空白。
        answer = string.format("（工具循环已停止：%s。这一轮没能收口，请说\"继续\"让我接着做。）", why)
        assistant.content = answer
    end
    ctx:add_message(assistant)
    self.session:append(assistant)
    ctx:emit("assistant", assistant)
    if self.memory then
        self.memory:remember_turn(ctx.session.id, ctx.session.turn, self._text or "", answer, {})
        self.memory:tick()
        self:save_usage()
    end
    ctx:end_turn()
    return answer
end

-- 同一调用（工具+原参数）反复失败时，直说“这么重试不会变”，
-- 免得模型第三、四轮继续把一模一样的参数再发一遍。
local FAIL_NOTE_KEEP = 200

function M:_failure_note(name, raw_args, result)
    local key = tostring(name) .. "\0" .. tostring(raw_args or "")
    local rec = self._failures[key]
    local ok = type(result) == "string" and not result:match("^error")
    if ok then
        -- 后来成功了：这个坑不用写进程序性记忆。
        self._failures[key] = nil
        if rec and rec.n > 1 then
            return string.format("\n[recovered after %d failed attempts]", rec.n)
        end
        return ""
    end
    if not rec then
        local size = 0
        for _ in pairs(self._failures) do size = size + 1 end
        if size >= 100 then self._failures = {} end
        rec = { name = name, args = tostring(raw_args or ""), n = 0,
                head = tostring(result):gsub("%s+", " "):sub(1, FAIL_NOTE_KEEP) }
        self._failures[key] = rec
    end
    rec.n = rec.n + 1
    if rec.n < 2 then return "" end
    return string.format(
        "\n[this exact call has now failed %d times; the error will not change] "
            .. "Change the arguments, fix the cause, or use another tool instead of resending it.",
        rec.n)
end

-- 插件 hook 判定：没有插件声明该 hook 时整条分支都不进（纯内建场景零开销）。
function M:has_hooks(kind)
    local t = self.tools
    if not t or type(t.has_hooks) ~= "function" then return false end
    return t:has_hooks(kind) and true or false
end

-- 一次 run 收口只通知一次：--once 直接调；TUI 由 main 退出时调。
function M:session_end()
    if self._session_ended then return end
    self._session_ended = true
    -- 程序性记忆：只写“付出过代价、后来也没解决”的坑，
    -- 一次就通的随机失败不写，免得污染知识库。
    local lessons, n = {}, 0
    for _, rec in pairs(self._failures or {}) do
        if rec.n >= 2 then
            n = n + 1
            if n <= 3 then
                lessons[#lessons + 1] = string.format(
                    "- `%s %s` failed %d times in a row: %s",
                    rec.name, rec.args:gsub("%s+", " "):sub(1, 80), rec.n, rec.head)
            end
        end
    end
    if #lessons > 0 and self.memory and type(self.memory.remember_fact) == "function" then
        self.memory:remember_fact(
            "fail/" .. os.date("%Y%m%d-%H%M%S"),
            "Tool calls that kept failing this session (avoid repeating verbatim):\n"
                .. table.concat(lessons, "\n"),
            { "agent", "failure" })
    end
    if self:has_hooks("on_session_end") then
        local s = self.ctx and self.ctx.session or {}
        self.tools:on_session_end({
            id = s.id, turn = s.turn, busy = s.busy,
        })
    end
end

function M:_loop(text, stream)
    local ctx = self.ctx
    -- on_user_turn：插件可以在进模型前改写本轮输入（补环境信息、加前缀等）。
    if self:has_hooks("on_user_turn") then
        local t = self.tools:on_user_turn(text)
        if type(t) == "string" and t ~= "" then text = t end
    end
    self._text = text
    local request_tools = self.tools:schemas()
    self:ensure_system(request_tools)

    local user = { role = "user", content = text }
    ctx:add_message(user)
    self.session:append(user)

    local tool_notes = {}
    local last_sig, repeat_n = nil, 0
    local result_counts, repeated_result = {}, 0
    local overflow_retried = false
    local max_turns = ctx.settings.max_turns
    local token_budget = tonumber(ctx.settings.token_budget) or 0

    local function request_stream(inject, force, turn)
        local req = self:request_messages(text, stream, {
            inject_context = inject,
            force_compact = force,
            turn = turn or 1,
            max_turns = max_turns,
        })
        -- outputLimit：让 provider 知道本轮输入大概占了多少 token。
        ctx.settings.input_tokens = self:estimate_tokens(Compact.total(req))
        return stream(req, request_tools, ctx.settings,
            function(delta) ctx:emit("delta", delta) end,
            function(delta) ctx:emit("reasoning", delta) end)
    end

    for iter = 1, max_turns do
        if token_budget > 0 then
            local u = ctx.session.usage
            if (u.prompt or 0) + (u.completion or 0) >= token_budget then
                local answer = string.format(
                    "（已达到 token 预算 %d：本任务已发 %d 请求、%d prompt tokens。提高 LITE_TOKEN_BUDGET 后继续。）",
                    token_budget, u.requests or 0, u.prompt or 0)
                ctx:add_message({ role = "assistant", content = answer })
                self.session:append({ role = "assistant", content = answer })
                ctx:emit("assistant", { role = "assistant", content = answer })
                ctx:end_turn()
                if self.memory then self:save_usage() end
                return answer
            end
        end
        ctx:begin_turn()
        local assistant, err = request_stream(iter == 1, false, iter)

        -- 参考 opencode：provider 明确报上下文过长时，强制压一次再重试。
        if not assistant and not overflow_retried
            and self.provider.context_overflow and self.provider.context_overflow(err) then
            overflow_retried = true
            self:save_usage()
            local compacted = self:maybe_compact(stream, 0, true)
            local retry_msgs
            if compacted then
                retry_msgs = self:request_messages(text, stream, {
                    inject_context = (iter == 1),
                })
            else
                local c = self:compactor()
                local trimmed
                retry_msgs, trimmed = self:hard_window(self:view_messages(),
                    math.floor(c.budget * 0.7))
                if not trimmed then retry_msgs = nil end
            end
            if retry_msgs then
                ctx.settings.input_tokens = self:estimate_tokens(Compact.total(retry_msgs))
                assistant, err = stream(retry_msgs, self.tools:schemas(), ctx.settings,
                    function(delta) ctx:emit("delta", delta) end,
                    function(delta) ctx:emit("reasoning", delta) end)
            end
        end

        if not assistant then
            -- 报错前也要落一次账：这一轮已经发出去的请求（含被计费的 miss）
            -- 不能因为最后一步失败就从统计里消失。
            self:save_usage()
            ctx:fail(err)
            ctx:end_turn()
            return nil, err
        end

        ctx:add_message(assistant)
        self.session:append(assistant)
        ctx:emit("assistant", assistant)

        local calls = assistant.tool_calls
        if not calls or #calls == 0 then
            local answer = assistant.content or ""
            if answer:match("^%s*$") then
                answer = "（模型没有返回内容。）"
                assistant.content = answer
            end
            if self.memory then
                self.memory:remember_turn(ctx.session.id, ctx.session.turn, text, answer, tool_notes)
                self.memory:tick()
                self:save_usage()
            end
            ctx:end_turn()
            return answer
        end

        local sig = {}
        for _, tc in ipairs(calls) do
            local fn = tc["function"] or {}
            sig[#sig + 1] = tostring(fn.name) .. "\0" .. tostring(fn.arguments)
            local name = fn.name or ""
            local args = decode_args(fn.arguments)
            local result
            if args == nil then
                -- 把原发参数串和该工具的必填项回传，模型能自己修好这条调用。
                local raw = tostring(fn.arguments or "")
                -- 保留头尾：截断总是发生在尾部，只看开头会误判成"语法写错"。
                local shown = raw
                if #raw > 400 then
                    shown = raw:sub(1, 200) .. " …[" .. #raw .. " bytes]… " .. raw:sub(-160)
                end
                result = "error: invalid tool arguments JSON (" .. #raw .. " bytes); you sent: " .. shown
                local req = {}
                if self.tools.required_args then req = self.tools:required_args(name) end
                if #req > 0 then
                    result = result .. "; required: " .. table.concat(req, ", ")
                end
                if assistant.finish == "length" then
                    -- 真因是 max_tokens 截断，不是语法错误：必须说清楚，否则模型
                    -- 会把同一段内容原样再发一遍，每次都断在同一位置。
                    local cap = self.ctx and self.ctx.settings
                        and self.ctx.settings.max_output_tokens or nil
                    result = result .. ". THE OUTPUT WAS CUT OFF BY max_tokens"
                        .. (cap and (" (" .. tostring(cap) .. ")") or "")
                        .. ": the JSON is incomplete, retrying verbatim will fail again. "
                        .. "Send a much smaller payload and finish the file in several calls: "
                        .. "write the first section, then append the rest."
                else
                    result = result .. ". Send valid JSON with these keys."
                end
            else
                ctx:set_status("tool")
                ctx:emit("tool_start", name, args)

                local function run_tool()
                    if self.async and name == "bash" and self.tools.start_bash then
                        local proc, perr = self.tools:start_bash(args.command or "")
                        if not proc then return "error: " .. tostring(perr) end
                        local out = coroutine.yield({ kind = "proc", proc = proc })
                        return tostring(out or "")
                    end
                    return self.tools:execute(name, args)
                end

                local decision = self.approval:decide(name)
                -- before_tool：插件 veto 优先于审批，命中就跳过执行（不改策略状态）。
                local veto = nil
                if self:has_hooks("before_tool") then
                    veto = self.tools:before_tool(name, args)
                end
                if veto then
                    result = "error: " .. tostring(veto)
                elseif decision == "allow" then
                    result = run_tool()
                elseif decision == "deny" then
                    result = "error: tool call denied by policy"
                elseif not self.async then
                    result = "error: approval required (non-interactive)"
                else
                    local answer = coroutine.yield({
                        kind = "approval", name = name, args = args,
                    })
                    if answer == "always" then self.approval:remember(name) end
                    if answer == "once" or answer == "always" then
                        result = run_tool()
                    else
                        result = "error: tool call rejected by user"
                    end
                end
            end
            -- after_tool：插件可改写工具结果（脱敏、截断、附加摘要）。
            if self:has_hooks("after_tool") then
                local r = self.tools:after_tool(name, args, result)
                if r ~= nil then result = r end
            end
            -- 同一参数反复失败：在结果尾巴把话说死，别再原样重发。
            local fnote = self:_failure_note(name, fn.arguments, result)
            if fnote ~= "" then result = tostring(result) .. fnote end
            ctx:emit("tool_result", name, result)
            local rs = result_sig(name, result)
            local rn = (result_counts[rs] or 0) + 1
            result_counts[rs] = rn
            if rn > repeated_result then repeated_result = rn end
            tool_notes[#tool_notes + 1] = {
                name = name,
                args = fn.arguments or "",
                result = tostring(result):sub(1, 400),
            }

            local msg = {
                role = "tool",
                tool_call_id = tc.id or "",
                content = result,
            }
            ctx:add_message(msg)
            self.session:append(msg)

            local att = self.tools.take_attachment and self.tools:take_attachment()
            if att then
                -- 图片只能放在 user 消息；不落 KV（base64 可能超过 1MB value 限制）。
                local image_msg = {
                    role = "user",
                    content = {
                        { type = "text", text = "[image read: " .. tostring(att.path or "") .. "]" },
                        { type = "image_url", image_url = {
                            url = "data:" .. tostring(att.mime or "image/png") .. ";base64," .. tostring(att.data or ""),
                        } },
                    },
                }
                ctx:add_message(image_msg)
                ctx:emit("image", { path = att.path, mime = att.mime })
            end
        end
        if self.memory then self.memory:tick() end
        ctx:set_status("thinking")

        -- 卡住检测：同一批工具调用连续第 REPEAT_LIMIT 次，结果也不会变，
        -- 继续跑只是空烧 token。
        local cur = table.concat(sig, "\1")
        if cur == last_sig then
            repeat_n = repeat_n + 1
        else
            last_sig, repeat_n = cur, 1
        end
        if repeat_n >= M.REPEAT_LIMIT then
            local why = string.format("the same tool calls repeated %d times in a row", repeat_n)
            return self:_finalize(stream, why)
        end
        if repeated_result >= M.RESULT_REPEAT_LIMIT then
            local why = string.format("the same tool result repeated %d times", repeated_result)
            return self:_finalize(stream, why)
        end
    end

    return self:_finalize(stream, string.format("used all %d tool-loop turns", max_turns))
end

-- 阻塞入口：--once / 单测。
function M:run(text)
    self.async = false
    local answer, err = self:_loop(text, function(messages, tools, opts, on_delta, on_reasoning)
        return self.provider.stream(messages, tools, opts, on_delta, on_reasoning)
    end)
    self:session_end()
    return answer, err
end

-- 协程入口：TUI 驱动，yield {kind="http", req=...}。
function M:run_async(text)
    self.async = true
    return coroutine.create(function()
        return self:_loop(text, function(messages, tools, opts, on_delta, on_reasoning)
            return self.provider.stream_async(messages, tools, opts, on_delta, on_reasoning)
        end)
    end)
end

return M
