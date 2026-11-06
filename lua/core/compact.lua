-- 上下文压缩（低频 cache-reset 点）。
--
-- 参考 Reasonix `internal/runtime/agent/compact.go` 的核心判断：
--
--   Compaction is a low-frequency cache-reset point: the prompt grows
--   append-only until a maintenance boundary is crossed, then one
--   content-driven summary checkpoint is installed
--   (stable prefix + one structured digest + recent tail).
--
-- 关键在"低频"。每轮都裁一次 prompt，会让整段前缀位移，DeepSeek 的
-- prompt cache 每次都 miss，等于按全价重付整段历史——那比不裁还贵。
-- 所以这里只在**跨过阈值**时压一次，压完记下 baseline，之后继续 append-only。
--
-- 压缩后的 prompt 结构（三段）：
--
--   [system]                            <- 永远不变，缓存前缀的锚点
--   [<session_context> digest]          <- 一段结构化摘要，压完才变
--   [hoisted user turns]                <- 用户原话，逐字保留，不进摘要
--   [recent tail]                       <- 最近若干条原文，边界避开 tool result
--
-- 本模块只做纯计算（plan/serialize/render），真正的摘要调用由调用方通过
-- `summarize` 回调注入，这样单测不需要网络。

local Text = require("core.text")

local M = {}

-- 单位统一用**字符**（lite 的 budget 一直是字符），涉及"每次请求都付费"的
-- 固定段时再换算成 token 做提示。默认 64000 字符 ≈ 16k tokens。
local DEFAULTS = {
    -- 触发线：超过 budget 的这个比例才压一次。
    compact_ratio = 0.85,

    -- 近期原文尾巴：budget 的 10%，并夹在 [tail_min, tail_max]，且不超过 budget/2。
    -- 太小会把刚发生的工具结果挤进摘要，模型就得重读文件。
    tail_ratio = 0.10,
    tail_min = 8000,
    tail_max = 24000,

    -- 首条 user turn 钉住（它就是任务本身）。这段在固定前缀里，每次请求都付费，
    -- 所以必须有上限；超了就让它进摘要。
    pin_ratio = 0.05,
    pin_min = 1200,
    pin_max = 6000,

    -- 用户原话的独立预算：约束一旦被摘要丢掉就再也找不回来，
    -- 而它约束的代码还在工作区里、随时能重新看。
    keep_user_ratio = 0.10,
    keep_user_min = 4000,

    -- foldEconomics：折叠区太小就不值得多花一次摘要调用。
    min_fold_chars = 2000,
    min_fold_savings_ratio = 0.15,

    -- 单条消息的上限：触发线的这个比例（并夹一个绝对地板）。
    -- 最新一条消息在尾巴里是**无条件保留**的，所以它自己一旦超过触发线，
    -- 任何 tail_scale 都缩不下来 —— 折叠区"没东西可折"，压完还是超阈值。
    -- 这种时候只能对这条 tool 结果按预算截一刀（见 plan 里的 clip）。
    msg_ratio = 0.25,
    msg_min = 2000,

    -- 至少保留这么多条原文，否则摘要在语义上没意义。
    min_recent_keep = 2,
    -- 尾巴里最多保留这么多条 user 轮次；由 `context_turns` 覆盖。
    tail_turn_cap = 16,

    -- 送摘要时每条 tool 结果的上限（Pi 的 truncateForSummary 用 2000 字符）。
    summarize_tool_chars = 2000,
    -- 送摘要时单条 user/assistant 文本的上限。
    summarize_text_chars = 4000,

    -- 摘要本身也要有预算：摘要替代的是整段折叠区，如果它跟折叠区差不多大，
    -- 这次压缩就是净亏损（还多花了一次调用）。上限按 budget 的 10% 夹在
    -- [800, 6000]，超过 2 倍就拒绝这个检查点。
    digest_ratio = 0.10,
    digest_min = 800,
    digest_max = 6000,
}

M.DEFAULTS = DEFAULTS

-- 摘要提示词：固定小标题 + 明确禁止编造。抄 Reasonix 的结构，
-- 因为"能照着继续说下去"才是摘要的唯一验收标准。
M.DIGEST_PROMPT = [[You are compacting the earlier part of a coding agent's conversation to save context.
The agent keeps your summary alongside the user's own turns (kept verbatim) and the recent tail; your job is to fold the assistant/tool work into a briefing it can resume from.
Write under these exact headings, omitting a heading only if it has no content:

## Standing facts & constraints
Everything the user stated that still governs the work — names, paths, IDs, versions, tokens, preferences, and hard "never do X" rules — in their own words. Be exhaustive; this is the durable contract, so prefer over- to under-including.

## Goal
The user's request and intent.

## Decisions & rationale
Key choices made so far and why — so they are not re-litigated or reversed.

## Files & code
Files read or modified, with the specific facts that matter: signatures, line locations, data shapes, and exact edits applied. Be concrete; this is what lets the agent act without re-reading everything.

## Commands & outcomes
Commands run (builds, tests, git) and their relevant results — what passed, what failed, and the error text that matters.

## Errors & fixes
Problems hit and how they were resolved (or not), so the same dead ends are not repeated.

## Pending & next step
What is still in progress or unstarted, and the single most concrete next action to take.

Rules: be terse — bullet points and fragments, not prose. Preserve identifiers, paths, and numbers exactly. Do NOT invent anything not present in the messages; if something is unknown, leave it out rather than guessing.]]

local function cfg_get(opts, key)
    local v = opts and opts[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

-- 一条消息的规模估算。system/tool 也一样走这里，保证预算口径统一。
-- 80 是对 role/分隔符/JSON 括号等框架开销的粗略补偿。
local function msg_chars(m)
    if type(m) ~= "table" then return 0 end
    local n = 80
    local c = m.content
    if type(c) == "string" then
        n = n + #c
    elseif type(c) == "table" then
        for _, part in ipairs(c) do
            if type(part) == "table" then
                if part.type == "text" and type(part.text) == "string" then
                    n = n + #part.text
                elseif part.type == "image_url" then
                    -- 图片按占位符计：真实开销是 token，不在字符预算里。
                    n = n + 200
                end
            end
        end
    end
    if type(m.tool_calls) == "table" then
        for _, tc in ipairs(m.tool_calls) do
            local fn = type(tc) == "table" and tc["function"] or nil
            n = n + 80
            if type(fn) == "table" then n = n + #tostring(fn.arguments or "") end
        end
    end
    return n
end

M.msg_chars = msg_chars

-- chars → tokens 校准（Reasonix 的 tokPerChar）。
--
-- 没有本地 tokenizer，但每次请求的真实 usage 就给了答案：
--   ratio = prompt_tokens / 实际发出的字符数
-- 用它把字符预算翻译成模型窗口里的真实占用，估算就不会随时间漂。
-- 首轮没有数据时退回经验值（中英混排约 3.5 字符/token）。
local DEFAULT_TOK_PER_CHAR = 1 / 3.5

function M.tok_per_char(prev_ratio, est_chars, actual_tokens)
    if not est_chars or est_chars <= 0 or not actual_tokens or actual_tokens <= 0 then
        return prev_ratio or DEFAULT_TOK_PER_CHAR
    end
    local observed = actual_tokens / est_chars
    -- 离谱值直接丢（图片占位符、空 content 之类会让比例失真）
    if observed <= 0 or observed > 2 then return prev_ratio or DEFAULT_TOK_PER_CHAR end
    if not prev_ratio then return observed end
    -- 指数平滑：单次观测有噪声（prompt_tokens 含协议开销）
    return prev_ratio * 0.7 + observed * 0.3
end

M.DEFAULT_TOK_PER_CHAR = DEFAULT_TOK_PER_CHAR

function M.total(msgs)
    local n = 0
    for _, m in ipairs(msgs or {}) do n = n + msg_chars(m) end
    return n
end

function M.new(opts)
    opts = opts or {}
    local budget = tonumber(opts.budget_chars) or 64000
    if budget < 500 then budget = 500 end
    local self = {}
    for k, v in pairs(DEFAULTS) do self[k] = cfg_get(opts, k) end
    self.budget = budget
    return setmetatable(self, { __index = M })
end

-- 摘要允许的最大字符数。
function M:digest_max_chars()
    local n = math.floor(self.budget * self.digest_ratio)
    if n < self.digest_min then n = self.digest_min end
    if n > self.digest_max then n = self.digest_max end
    return n
end

-- 在固定小标题后面补一条硬性长度约束。摘要模型对"ter se"这种形容词
-- 不敏感，对具体数字敏感。
function M:digest_prompt(max_chars)
    local n = max_chars or self:digest_max_chars()
    return M.DIGEST_PROMPT .. "\n\nHard limit: the entire summary must stay under "
        .. tostring(n) .. " characters. Drop lower-value bullets rather than exceed it."
end

function M:trigger()
    return math.max(1, math.floor(self.budget * self.compact_ratio))
end

-- 单条消息的字符上限。一条消息吃掉的窗口不该超过触发线的 1/4：
-- 再大就等于"这条消息自己就是一个会话"，尾巴里放不下第二条，
-- 压缩也就无从下手（最坏情况：每轮都白花一次摘要调用，最后滑到硬上限）。
function M:msg_cap()
    local n = math.floor(self:trigger() * self.msg_ratio)
    if n < self.msg_min then n = self.msg_min end
    return n
end

-- 发出去时的视图裁剪表：绝对下标 → 目标字符数。纯函数（只看 msgs + budget），
-- 所以 view_messages 每轮都能重算，不必把 clip 落进 KV。cap 只由 budget 决定，
-- 每条消息的裁剪结果因此是稳定的 —— 前缀缓存照样命中。
-- 只截 tool：assistant 的 tool_calls 是配对结构（截了会断），
-- user 原话是约束（截了就找不回来）。钉住的前缀（system + 首条 user）不动。
function M:clips(msgs)
    msgs = msgs or {}
    local head = self:pinned_len(msgs)
    local cap = self:msg_cap()
    local out
    for i = head + 1, #msgs do
        local m = msgs[i]
        if type(m) == "table" and m.role == "tool" and msg_chars(m) > cap then
            out = out or {}
            out[i] = cap
        end
    end
    return out
end

-- 复制一条消息并按 cap 截其 content。原文不动（transcript / KV 里还是全的）。
function M.clip_message(m, cap)
    if type(m) ~= "table" or not cap then return m end
    local c = m.content
    if type(c) ~= "string" then
        if type(c) ~= "table" then return m end
        local parts, changed = {}, false
        for i, part in ipairs(c) do
            parts[i] = part
            if type(part) == "table" and part.type == "text"
                and type(part.text) == "string" and #part.text > cap then
                local p2 = {}
                for k, v in pairs(part) do p2[k] = v end
                p2.text = M._clip_mid(part.text, cap)
                parts[i] = p2
                changed = true
            end
        end
        if not changed then return m end
        local copy = {}
        for k, v in pairs(m) do copy[k] = v end
        copy.content = parts
        return copy
    end
    if #c <= cap then return m end
    local copy = {}
    for k, v in pairs(m) do copy[k] = v end
    copy.content = M._clip_mid(c, cap)
    return copy
end

-- 近期原文尾巴预算。三个约束叠起来：
--   1. budget 的 tail_ratio，夹在 [tail_min, tail_max]
--   2. 不超过 budget/2（尾巴不能吃掉一半预算）
--   3. 不超过触发线的一半（尾巴撑到触发线就永远没东西可折叠了）
-- 注意 floor 必须先按 budget 夹一次：小预算下 32K 的绝对地板会让尾巴
-- 直接吃掉整个窗口，压完还是超阈值 —— 于是每轮都压，缓存全毁。
-- （Reasonix 的 recentTailBudget 注释：Smaller synthetic windows drop the
--  32K floor so the tail cannot alone exceed the window.）
function M:tail_budget(avail)
    avail = avail or self.budget
    local floor_min = self.tail_min
    local cap_third = math.floor(avail / 3)
    if floor_min > cap_third then floor_min = cap_third end
    local n = math.floor(avail * self.tail_ratio)
    if n < floor_min then n = floor_min end
    if n > self.tail_max then n = self.tail_max end
    local half = math.floor(avail / 2)
    if half > 0 and n > half then n = half end
    local t = self:trigger()
    if t > 0 and n > math.floor(t / 2) then n = math.floor(t / 2) end
    if n < 1 then n = 1 end
    return n
end

-- 首条 user turn 的钉住上限。同样受 window guard 约束：这段在固定前缀里，
-- 每次请求都付费，不能因为地板值就把小窗口吃掉。
function M:pin_cap()
    local floor_min = self.pin_min
    local cap_eighth = math.floor(self.budget / 8)
    if floor_min > cap_eighth then floor_min = cap_eighth end
    local n = math.floor(self.budget * self.pin_ratio)
    if n < floor_min then n = floor_min end
    if n > self.pin_max then n = self.pin_max end
    if n < 1 then n = 1 end
    return n
end

-- 用户原话的独立预算。上限硬性小于 budget/4：它是"每次请求都付费"的固定成本，
-- 和尾巴、摘要一起构成压缩后的基座，基座不能逼近触发线。
function M:keep_user_budget(avail)
    avail = avail or self.budget
    local floor_min = self.keep_user_min
    local cap_quarter = math.floor(avail / 4)
    if floor_min > cap_quarter then floor_min = cap_quarter end
    local n = math.floor(avail * self.keep_user_ratio)
    if n < floor_min then n = floor_min end
    if n > cap_quarter then n = cap_quarter end
    if n < 1 then n = 1 end
    return n
end

-- 钉住的前缀长度：system（+ 首条 user，如果它就是任务且不大）。
function M:pinned_len(msgs)
    local i = 0
    local n = #msgs
    if i < n and msgs[i + 1].role == "system" then i = i + 1 end
    if i < n and msgs[i + 1].role == "user" then
        local u = msgs[i + 1]
        if not M.is_digest(u) and msg_chars(u) <= self:pin_cap() then
            i = i + 1
        end
    end
    return i
end

-- 计算"发出去时这条消息实际占多少字符"。cap 只对 tool 结果生效：
-- 超预算的单条 tool 结果会被 _clip_mid 截到 cap，所以算尾巴时按截后算，
-- 否则一条 30KB 的输出就把尾巴撑爆，fold 直接判成"没东西可折"。
local function capped_chars(m, cap)
    local c = msg_chars(m)
    if cap and m.role == "tool" and c > cap then return cap + 80 end
    return c
end

-- 尾巴起点：从最新往回累加，超预算就停；然后**向前回退**避开孤立的 tool result。
-- 尾巴以 tool 消息开头是错的——它对应的 assistant tool_calls 被摘掉了，
-- 很多 provider 会直接 400。
-- turn_cap：尾巴里最多保留多少条 user 轮次（`context_turns` 的语义，是**上限**
-- 不是下限：下限会让短会话永远压不动，长会话尾巴大得离谱）。
-- cap：单条 tool 结果的字符上限（见 msg_cap/_clip_mid）。
function M:tail_start(msgs, head, budget, turn_cap, cap)
    local n = #msgs
    local start = n + 1
    local acc = 0
    local users = 0
    -- min_recent_keep 允许尾巴**略微**超预算（否则每条消息都很大的会话里
    -- 尾巴会一条都留不下），但溢出量封顶 budget/2：不封顶的话两条 6KB 的
    -- 工具结果就能把整个窗口吃光，压缩永远没有可折叠区。
    local overflow_cap = math.floor(budget / 2)
    local overflow = 0
    -- 最新一条**无条件**保留。丢掉它等于丢掉"刚才发生了什么"，
    -- 那是任何摘要都补不回来的（多数场景下它就是用户当前的问题）。
    if n > head then
        acc = capped_chars(msgs[n], cap)
        start = n
        if msgs[n].role == "user" and turn_cap and turn_cap > 0 then users = 1 end
    end
    for i = n - 1, head + 1, -1 do
        local m = msgs[i]
        local c = capped_chars(m, cap)
        local within_min = (n - i + 1) <= self.min_recent_keep
        if acc + c > budget then
            if not within_min then break end
            if overflow + c > overflow_cap then break end
            overflow = overflow + c
        end
        if m.role == "user" and turn_cap and turn_cap > 0 then
            users = users + 1
            if users > turn_cap then break end
        end
        acc = acc + c
        start = i
    end
    -- start == n+1 表示一条都放不下（会话太短），交给调用方的 min 检查兜底。
    while start > head + 1 and start <= n and msgs[start].role == "tool" do
        start = start - 1
    end
    return start, acc
end

-- 是否是压缩摘要消息（避免把摘要再喂给摘要，无限套娃）。
function M.is_digest(m)
    if type(m) ~= "table" then return false end
    local c = m.content
    if type(c) ~= "string" then return false end
    return c:find("<session_context>", 1, true) ~= nil
        or c:find("<compaction-summary>", 1, true) ~= nil
end
M.digest_message = M.is_digest

-- 纯计划：算出 head / start / 折叠区 / 判定是否值得压。不调用模型。
function M:plan(msgs, popts)
    msgs = msgs or {}
    local tail_scale = (popts and tonumber(popts.tail_scale)) or 1
    local n = #msgs
    local used = M.total(msgs)
    local plan = {
        total_chars = used,
        budget = self.budget,
        trigger = self:trigger(),
        n = n,
        over = used > self:trigger(),
        ok = false,
    }
    if n == 0 then
        plan.reason = "empty"
        return plan
    end

    local head = self:pinned_len(msgs)
    -- 固定前缀（system + 钉住的首条 user）每次请求都付费，不能算进
    -- "可分配预算"里，否则尾巴和用户原话会把窗口挤爆。
    local pinned = 0
    for i = 1, head do pinned = pinned + msg_chars(msgs[i]) end
    local avail = math.max(1000, self.budget - pinned)
    plan.pinned_chars = pinned
    plan.avail = avail

    local tail_budget = math.floor(self:tail_budget(avail) * tail_scale)
    if tail_budget < 200 then tail_budget = 200 end
    -- cap 先算：tail_start 要按"截后"的字符数累加，否则一条 30KB 的
    -- tool 结果会让尾巴一进来就超预算，plan 直接放弃折叠。
    local cap = self:msg_cap()
    local start = self:tail_start(msgs, head, tail_budget, self.tail_turn_cap, cap)
    plan.tail_scale = tail_scale
    plan.tail_budget = tail_budget
    plan.head = head
    plan.start = start

    -- 尾巴里"单条就撑爆预算"的 tool 结果：按 msg_cap 截一刀。
    -- 最新一条在尾巴里是无条件保留的，它超预算时 plan 只会一路给出
    -- "nothing to fold"/"would not shrink"，而 fold 每轮都要先花一次
    -- 摘要调用才被拒 —— 白花钱还什么都没省下。
    -- 只截 tool：assistant 的 tool_calls 是配对结构（截了会断），
    -- user 原话是约束（截了就找不回来了）。
    local clip, tail_chars, clip_n, clip_saved = nil, 0, 0, 0
    for i = start, n do
        local raw = msg_chars(msgs[i])
        if msgs[i].role == "tool" and raw > cap then
            clip = clip or {}
            clip[i] = cap
            clip_n = clip_n + 1
            clip_saved = clip_saved + (raw - cap)
        end
        tail_chars = tail_chars + capped_chars(msgs[i], cap)
    end
    plan.clip = clip
    plan.clip_n = clip_n
    plan.clipped_chars = clip_saved
    plan.tail_chars = tail_chars

    if start - 1 - head < 1 then
        plan.reason = "nothing to fold"
        return plan
    end

    -- 折叠区：[head+1, start-1]
    local region = {}
    for i = head + 1, start - 1 do region[#region + 1] = msgs[i] end
    local region_chars = M.total(region)

    -- foldEconomics：折叠区太小，省下来的还不够一次摘要调用的成本。
    if region_chars < self.min_fold_chars then
        plan.reason = string.format("fold too small (%d < %d chars)",
            region_chars, self.min_fold_chars)
        plan.region_chars = region_chars
        return plan
    end

    -- 用户原话：按预算逐条提升为"逐字保留"，超出预算的才进摘要。
    -- 老的优先——它比新的熬过了更多次折叠。
    local keep, kept, dropped = {}, {}, {}
    local ubudget = self:keep_user_budget(avail)
    for i, m in ipairs(region) do
        if m.role == "user" and not M.is_digest(m) then
            local c = msg_chars(m)
            if c <= ubudget then
                keep[i] = true
                ubudget = ubudget - c
                kept[#kept + 1] = m
            else
                dropped[#dropped + 1] = m
            end
        end
    end

    plan.region = region
    plan.region_chars = region_chars
    plan.keep = keep
    plan.kept_user = kept
    plan.dropped_user = dropped

    -- 收益判断：折叠区的增量收益要够大，否则不值得多花一次摘要调用。
    local saved = region_chars - M.total(kept)
    plan.savings = saved
    if saved <= 0 then
        plan.reason = "no savings"
        return plan
    end
    if saved < region_chars * self.min_fold_savings_ratio then
        plan.reason = string.format("savings too small (%d of %d chars)", saved, region_chars)
        return plan
    end

    plan.ok = true
    return plan
end

-- 把消息渲染成给摘要模型看的文本。刻意**不带 tool 定义**、不带 reasoning，
-- 也不带图片（opencode 的结论：摘要用不到，而且它们已经不在同一段缓存前缀里）。
-- skip：{ [index] = true } 表示这条已经逐字保留，不重复送。
function M:serialize(region, skip)
    local parts = {}
    for i, m in ipairs(region or {}) do
        if not (skip and skip[i]) then
            local role = m.role
            if role == "user" then
                local t = Text.content_text(m.content)
                if t ~= "" then
                    parts[#parts + 1] = "[User]: " .. M._clip(t, self.summarize_text_chars)
                end
            elseif role == "assistant" then
                local t = Text.content_text(m.content)
                if t ~= "" then
                    parts[#parts + 1] = "[Assistant]: " .. M._clip(t, self.summarize_text_chars)
                end
                if type(m.tool_calls) == "table" and #m.tool_calls > 0 then
                    local calls = {}
                    for _, tc in ipairs(m.tool_calls) do
                        local fn = tc["function"] or {}
                        local args = tostring(fn.arguments or "")
                        calls[#calls + 1] = string.format("%s(%s)",
                            tostring(fn.name or "?"), M._clip(args, 400))
                    end
                    parts[#parts + 1] = "[Assistant tool calls]: " .. table.concat(calls, "; ")
                end
            elseif role == "tool" then
                local t = Text.content_text(m.content)
                if t ~= "" then
                    parts[#parts + 1] = "[Tool result]: " .. M._clip(t, self.summarize_tool_chars)
                end
            end
        end
    end
    return table.concat(parts, "\n\n")
end

-- 只截头部（摘要用，不需要看尾部——尾部已经在原文尾巴里了）。
function M._clip(s, n)
    s = tostring(s or "")
    if #s <= n then return s end
    return s:sub(1, n) .. string.format("\n[... %d chars truncated]", #s - n)
end

-- 截中间：头 2/3 + 尾 1/3。这里动的是**留在尾巴里的原文**，两头都有用
-- （开头是"这条命令在干什么"，结尾是错误/结论），所以不能像摘要那样只留头部。
-- marker 要写明怎么办，否则模型只会看着半截输出瞎猜。
function M._clip_mid(s, n)
    s = tostring(s or "")
    if #s <= n then return s end
    local marker = string.format(
        "\n... [%d chars truncated: this single result exceeded the context budget;"
            .. " re-run the command narrower, or use head/tail] ...\n", #s - n)
    local keep = n - #marker
    if keep < 64 then
        marker = "\n... [truncated to fit the context budget] ...\n"
        keep = math.max(0, n - #marker)
    end
    local head = math.floor(keep * 2 / 3)
    local tail = keep - head
    local out = s:sub(1, head) .. marker
    if tail > 0 then out = out .. s:sub(#s - tail + 1) end
    return out
end

-- 渲染成注入 prompt 的 system 块。
function M:render(digest, kept_user)
    local lines = {
        "<session_context>",
        "Earlier conversation was folded into this briefing. Details are still in local"
            .. " memory; call recall(query, limit) when you need the raw text again.",
        "",
        tostring(digest or ""),
    }
    if kept_user and #kept_user > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## User messages kept verbatim"
        for _, m in ipairs(kept_user) do
            local t = Text.content_text(m.content)
            if t ~= "" then lines[#lines + 1] = "- " .. t end
        end
    end
    lines[#lines + 1] = "</session_context>"
    return table.concat(lines, "\n")
end

-- 高层入口：计划 + 摘要 + 渲染。返回 result 表（永不抛错）。
--   summarize(text, prompt) -> digest, err   由调用方注入（agent 用 provider）
--   opts.previous_digest   上一次的摘要，会和新证物一起合并成新摘要
-- 返回 { ok, reason, block, stats, baseline, plan }
function M:fold(msgs, summarize, opts)
    opts = opts or {}
    -- 尾巴吃掉整个窗口时（每条消息都很大），折叠区会"没东西可折"。
    -- 这时先把尾巴缩小重试，而不是直接放弃 —— 放弃就会一路滑到硬上限，
    -- 白丢历史还不留摘要。opencode 的 SHRINK_STEPS 是同一个思路。
    local plan, tried
    local scales = opts.tail_scales or { 1, 0.5, 0.25 }
    for _, sc in ipairs(scales) do
        plan = self:plan(msgs, { tail_scale = sc })
        tried = tried and (tried .. "," .. tostring(sc)) or tostring(sc)
        if plan.ok then break end
    end
    if not plan or not plan.ok then
        return {
            ok = false,
            reason = (plan and plan.reason or "not worth folding") .. " (tail scales tried: " .. tostring(tried) .. ")",
            plan = plan,
        }
    end
    if type(summarize) ~= "function" then
        return { ok = false, reason = "no summarizer", plan = plan }
    end

    local text = self:serialize(plan.region, plan.keep)
    if text == "" then
        return { ok = false, reason = "empty fold region", plan = plan }
    end
    -- 上一次的摘要在 lite 里存在 KV（不在 transcript 里），所以不会被
    -- 自动卷进折叠区。必须显式合并，否则每次压完就丢一段历史。
    -- 对应 opencode 的 "[previous compaction][transcript]" 拼法。
    local prev = opts.previous_digest
    if type(prev) == "string" and prev ~= "" then
        text = "[Previous digest — merge it into the new one]\n" .. prev
            .. "\n\n[Transcript since that digest]\n" .. text
    end

    local cap = self:digest_max_chars()
    local digest, err = summarize(text, self:digest_prompt(cap))
    if not digest or digest == "" then
        return { ok = false, reason = "summarize failed: " .. tostring(err), plan = plan }
    end
    digest = tostring(digest):gsub("%s+$", "")
    -- 检查点验收：摘要比折叠区小不了多少的话，这次折叠是净亏损。
    -- 拒绝比留下一个"看起来压过了"的假结果好 —— 后者会一直占着 prompt。
    if #digest > cap * 2 then
        return {
            ok = false, plan = plan, rejected = true,
            reason = string.format("digest too large (%d chars > %d cap)", #digest, cap),
        }
    end

    local block = self:render(digest, plan.kept_user)
    -- 迟滞（hysteresis）：压完的基座 = system + digest + 逐字保留 + 尾巴。
    -- 如果这个基座本身就已经逼近触发线，下一条消息就会再次触发压缩 ——
    -- 那是"每轮压一次"，比不压更贵。所以记一个 rearm 线：只有重新长过
    -- 这条线才值得再压一次。这样每次压缩至少买到 ~10% 预算的增长空间。
    local digest_chars = #block
    -- 注意要加上 plan.pinned_chars：view 的规模是"钉住前缀 + 摘要 + 逐字保留 + 尾巴"，
    -- 漏掉固定前缀会让 rearm 低于实际大小，迟滞失效、每轮重复压缩。
    local base_after = (plan.pinned_chars or 0) + digest_chars
        + M.total(plan.kept_user) + plan.tail_chars
    local margin = math.max(self.min_fold_chars * 2, math.floor(self.budget * 0.10))
    local rearm = base_after + margin

    -- 最本质的验收：折叠后必须比折叠前小。变大说明这次压缩是负收益。
    if base_after >= plan.total_chars then
        return {
            ok = false, plan = plan, rejected = true,
            reason = string.format("fold would not shrink the prompt (%d -> %d chars)",
                plan.total_chars, base_after),
        }
    end

    return {
        ok = true,
        block = block,
        digest = digest,
        plan = plan,
        -- 尾巴里需要截断的消息（绝对下标 → 目标字符数）。视图层照这个剪，
        -- 原文不动：raw 消息还在 transcript 和 KV 里，只是发出去时装不下。
        clip = plan.clip,
        rearm_chars = rearm,
        -- baseline = 折叠到第几条（含）。下次只有一个更大的 baseline 才值得再压。
        baseline = plan.start - 1,
        stats = {
            before_chars = plan.total_chars,
            region_chars = plan.region_chars,
            after_chars = base_after,
            digest_chars = digest_chars,
            saved_chars = plan.region_chars - digest_chars,
            kept_user = #plan.kept_user,
            dropped_user = #plan.dropped_user,
            clipped = plan.clip_n or 0,
            clipped_chars = plan.clipped_chars or 0,
        },
    }
end

return M
