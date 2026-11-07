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
    }, M)
    self.approval = Approval.new({
        mode = ctx.settings.approval,
        memory = memory,
        session_id = ctx.session.id,
    })
    return self
end

function M:system_prompt()
    return self.prompt.system_prompt(self.ctx, { tools = self.tools:schemas() })
end

function M:ensure_system()
    local msgs = self.ctx.session.messages
    if #msgs == 0 or msgs[1].role ~= "system" then
        local msg = { role = "system", content = self:system_prompt() }
        table.insert(msgs, 1, msg)
        self.session:append(msg)
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

-- 压缩状态：{ baseline = 已折叠到第几条, digest = 摘要正文, block = 渲染块,
--              rearm_chars = 下次值得再压的规模 }
-- 优先存 KV（跨进程/重启可恢复）；没有 KV 时退回进程内。
-- 这个兜底不是可选项：状态一丢，baseline 归零，下一次请求就会把整段历史
-- 重新摘一遍 —— 每次请求多花一次摘要调用，比不压缩贵得多。
function M:compact_state()
    local st
    if self.memory and self.memory.get then
        st = self.memory:get("/agent/session", state_key(self.ctx.session.id))
    end
    if type(st) ~= "table" then st = self._compact_state end
    if type(st) ~= "table" or type(st.baseline) ~= "number" then return nil end
    if type(st.digest) ~= "string" or st.digest == "" then return nil end
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
    return self.memory:save_usage(ctx.session.id, ctx.session.usage)
end

function M:restore_usage()
    if not (self.memory and self.memory.load_usage) then return false end
    local ctx = self.ctx
    if not ctx then return false end
    return ctx:restore_usage(self.memory:load_usage(ctx.session.id))
end

function M:save_compact_state(st)
    self._compact_state = st
    if not (self.memory and self.memory.put) then return end
    local ttl = (self.memory.TTL and self.memory.TTL.long) or 0
    self.memory:put("/agent/session", state_key(self.ctx.session.id), st, ttl)
end

-- 真正发给模型的视图：system + [摘要块] + baseline 之后的原文。
-- 摘要块位置固定（紧跟 system），所以两轮之间前缀稳定，缓存能命中。
function M:view_messages()
    local all = self.ctx.session.messages
    local st = self:compact_state()
    local out = {}
    if all[1] and all[1].role == "system" then out[1] = all[1] end
    if st and st.block and st.block ~= "" then
        out[#out + 1] = { role = "system", content = st.block }
    end
    local from = st and (st.baseline or 0) or 0
    if from < 0 then from = 0 end
    -- 还没压过时 baseline=0，但第 1 条 system 上面已经单独放过了，
    -- 不跳过就会把整段 system prompt 发两遍（多付一份输入 token）。
    if from < 1 and all[1] and all[1].role == "system" then from = 1 end
    -- 单条就超预算的 tool 结果：发出去时按 msg_cap 截一刀，原文不动
    -- （transcript / KV 里仍是全的）。cap 只由 budget 决定，所以同一条
    -- 消息每次算出来的裁剪结果一样 —— 前缀缓存照样命中。
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
    return out
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

-- 超阈值才压一次。返回 true 表示这次真的压了（调用方应重建视图）。
function M:maybe_compact(stream, reserve)
    local c = self:compactor()
    local st = self:compact_state()
    local view = self:view_messages()
    local used = Compact.total(view) + (tonumber(reserve) or 0)

    -- 触发线 + 迟滞线取较大者。压完的基座若本身就贴着触发线，
    -- 不设迟滞就会"下一条消息又触发"，每轮压一次。
    local line = c:trigger()
    if st and type(st.rearm_chars) == "number" and st.rearm_chars > line then
        line = st.rearm_chars
    end
    self._compact_probe = {
        used = used, line = line,
        est_tokens = self:estimate_tokens(used),
        tok_per_char = self:tok_per_char(),
    }
    if used <= line then return false end

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
        content = string.format(
            "<session_context>\nPrompt hit the hard size ceiling; %d older message(s) were"
                .. " dropped without being summarized. Use recall(query, limit) if you need them.\n"
                .. "</session_context>", dropped),
    }
    for i = start, n do out[#out + 1] = msgs[i] end
    return out, true, dropped
end

-- 组装发出去的完整消息列表：视图 + 召回块 + todo 块。
--
-- opts.inject_context：每个用户轮**只在第一次请求**注入这两个块，工具循环的后续请求不注入
-- （模型早已见过，重复注入既打断前缀缓存又白花 token）。
-- 两个块**追加到最末尾**而不是插在会话中间 —— 原因与实测见下面 "追加到最末尾" 那段注释
-- 以及 design.md §8.31。
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
        })
        self.ctx:emit("memory", items or {})
    end

    local todo_block = inject and self.prompt.todos_block(self.ctx.session.todos) or ""
    local reserve = #block + #todo_block + 200

    -- 先在超阈值时压一次；压不动就靠硬上限兜底。
    self:maybe_compact(stream, reserve)
    local msgs = self:view_messages()

    local c = self:compactor()
    local used = Compact.total(msgs) + reserve
    if used > math.floor(c.budget * 2) then
        local trimmed, dropped
        msgs, trimmed, dropped = self:hard_window(msgs, math.floor(c.budget * 0.8))
        if trimmed then
            self.ctx:emit("compact", {
                ok = false, reason = "hard ceiling", dropped = dropped,
                kept_digest = (self:compact_state() ~= nil),
            })
        end
    end

    if block == "" and todo_block == "" then
        -- 没有额外块时请求就是这个规模，直接记下来校准。
        self._last_request_chars = Compact.total(msgs)
        return msgs
    end

    -- 追加到**最末尾**，不要插在中间。
    --
    -- 这些块每轮内容都不同（召回结果随 query 变、todo 随进度变）。插在会话中间
    -- 会把后面所有消息整体位移，DeepSeek 的前缀缓存从插入点往后全部失效。
    -- 实测（真实 API，同一底座）：插在最后一条 user 之前，下一轮命中 71%；
    -- 追加到末尾，同一轮命中 97% —— 差的就是被位移的那段历史。
    -- 末尾放 system 消息 DeepSeek 接受（已验证）。
    local out = {}
    for i = 1, #msgs do out[#out + 1] = msgs[i] end
    if block ~= "" then
        out[#out + 1] = { role = "system", content = block }
    end
    if todo_block ~= "" then
        out[#out + 1] = { role = "system", content = todo_block }
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

local STOP_NOTE = table.concat({
    "<session_context>",
    "工具循环已停止：%s。现在没有可用工具，不要再请求工具调用。",
    "请立刻用中文收口，不要再解释这条指令：",
    "1) 已完成什么（写出具体文件/命令/结论，别写过程）；",
    "2) 还有什么没做；",
    "3) 下一步建议（可执行的一两句）。",
    "</session_context>",
}, "\n")

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
    msgs[#msgs + 1] = { role = "user", content = string.format(STOP_NOTE, why) }

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

function M:_loop(text, stream)
    local ctx = self.ctx
    self._text = text
    self:ensure_system()

    local user = { role = "user", content = text }
    ctx:add_message(user)
    self.session:append(user)

    local tool_notes = {}
    local last_sig, repeat_n = nil, 0

    for iter = 1, ctx.settings.max_turns do
        ctx:begin_turn()
        local assistant, err = stream(
            -- 只有本轮第一次请求注入召回/todo 块，后续工具轮复用同一前缀。
            self:request_messages(text, stream, { inject_context = (iter == 1) }),
            self.tools:schemas(),
            ctx.settings,
            function(delta) ctx:emit("delta", delta) end,
            function(delta) ctx:emit("reasoning", delta) end)

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
                result = "error: invalid tool arguments JSON"
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
                if decision == "allow" then
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
            ctx:emit("tool_result", name, result)
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
    end

    return self:_finalize(stream, string.format("used all %d tool-loop turns", ctx.settings.max_turns))
end

-- 阻塞入口：--once / 单测。
function M:run(text)
    self.async = false
    return self:_loop(text, function(messages, tools, opts, on_delta, on_reasoning)
        return self.provider.stream(messages, tools, opts, on_delta, on_reasoning)
    end)
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
