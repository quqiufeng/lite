-- Agent 循环：messages → provider → tool calls → messages。
local cjson = require("cjson")
local Prompt = require("core.prompt")

local M = {}
M.__index = M

function M.new(ctx, provider, tools, session, memory)
    return setmetatable({
        ctx = ctx,
        provider = provider,
        tools = tools,
        session = session,
        memory = memory,
    }, M)
end

function M:system_prompt()
    return Prompt.system_prompt(self.ctx, { tools = self.tools:schemas() })
end

function M:ensure_system()
    local msgs = self.ctx.session.messages
    if #msgs == 0 or msgs[1].role ~= "system" then
        local msg = { role = "system", content = self:system_prompt() }
        table.insert(msgs, 1, msg)
        self.session:append(msg)
    end
end

-- 控制当前 prompt 规模：保留 system + 最近若干轮，超出预算的旧轮次
-- 已持久化在本地记忆里，可让模型用 recall 找回。
function M:window_messages(reserve)
    local ctx = self.ctx
    local msgs = ctx.session.messages
    local budget = tonumber(ctx.settings.context_chars) or 32000
    budget = math.max(500, budget - (tonumber(reserve) or 0))
    local max_turns = tonumber(ctx.settings.context_turns) or 16

    local starts = {}
    for i, m in ipairs(msgs) do
        if m.role == "user" then starts[#starts + 1] = i end
    end
    if #starts == 0 then return msgs, false, {} end

    local keep_from = starts[1]
    local used, turns, trimmed = 0, 0, false
    for i = #msgs, 1, -1 do
        local m = msgs[i]
        local size = #(m.content or "") + 80
        if m.tool_calls then
            for _, tc in ipairs(m.tool_calls) do
                local fn = tc["function"] or {}
                size = size + 80 + #(fn.arguments or "")
            end
        end
        if used + size > budget then trimmed = true; break end
        used = used + size
        if m.role == "user" then
            turns = turns + 1
            if turns > max_turns then trimmed = true; break end
            keep_from = i
        end
    end

    if keep_from == starts[1] and not trimmed then
        return msgs, false, {}
    end

    local out, dropped = {}, {}
    for i = 1, keep_from - 1 do
        if msgs[i].role == "system" then
            out[#out + 1] = msgs[i]
        else
            dropped[#dropped + 1] = msgs[i]
        end
    end
    if trimmed then
        out[#out + 1] = {
            role = "system",
            content = "Earlier conversation is stored in local memory; use recall if needed.",
        }
    end
    for i = keep_from, #msgs do out[#out + 1] = msgs[i] end
    return out, trimmed, dropped
end

local function one_line(s, n)
    s = tostring(s or ""):gsub("%s+", " ")
    if #s > n then s = s:sub(1, n) .. "..." end
    return s
end

function M:update_context_block(dropped)
    if not (self.memory and self.memory.get and self.memory.put) then return "" end
    local lines = {}
    for _, m in ipairs(dropped or {}) do
        if m.role == "user" or m.role == "assistant" then
            local text = one_line(m.content, 300)
            if text ~= "" then
                lines[#lines + 1] = (m.role == "user" and "U: " or "A: ") .. text
            end
        end
    end
    if #lines == 0 then return "" end

    local digest = table.concat(lines, "\n")
    if #digest > 2000 then digest = digest:sub(-2000) end
    local ttl = self.memory.TTL and self.memory.TTL.long or 0
    self.memory:put("/agent/session", self.ctx.session.id .. "/context", {
        digest = digest,
        baseline = #(dropped or {}),
        updated = os.time(),
    }, ttl)

    return "<session_context>\nEarlier conversation digest (older messages omitted; use recall for details):\n"
        .. digest .. "\n</session_context>"
end

function M:load_context_block()
    if not (self.memory and self.memory.get) then return "" end
    local saved = self.memory:get("/agent/session", self.ctx.session.id .. "/context")
    if type(saved) ~= "table" or not saved.digest or saved.digest == "" then return "" end
    return "<session_context>\nEarlier conversation digest (older messages omitted; use recall for details):\n"
        .. saved.digest .. "\n</session_context>"
end

-- 把相关记忆插入到最近一条 user 之前（不写入会话）。
function M:request_messages(text)
    local block = ""
    if self.memory then
        local query = Prompt.recall_query(text, self.ctx.session.messages)
        local items
        block, items = self.memory:context(query, {
            limit = 8,
            max_chars = 2400,
            session_id = self.ctx.session.id,
        })
        self.ctx:emit("memory", items or {})
    end

    local todo_block = Prompt.todos_block(self.ctx.session.todos)
    local base_reserve = #block + #todo_block + 200
    local msgs, trimmed, dropped = self:window_messages(base_reserve)

    local context_block = ""
    if self.memory then
        if trimmed then
            context_block = self:update_context_block(dropped)
        else
            context_block = self:load_context_block()
        end
        if context_block ~= "" then
            local msgs2, trimmed2, dropped2 = self:window_messages(base_reserve + #context_block)
            msgs = msgs2
            if trimmed2 then
                local ctx2 = self:update_context_block(dropped2)
                if ctx2 ~= "" then context_block = ctx2 end
            end
        end
    end

    if block == "" and todo_block == "" and context_block == "" then return msgs end

    local last_user
    for i = #msgs, 1, -1 do
        if msgs[i].role == "user" then last_user = i; break end
    end

    local function insert_at(out, i)
        if context_block ~= "" then
            out[#out + 1] = { role = "system", content = context_block }
        end
        if block ~= "" then
            out[#out + 1] = { role = "system", content = block }
        end
        if todo_block ~= "" then
            out[#out + 1] = { role = "system", content = todo_block }
        end
    end

    local out = {}
    for i = 1, #msgs do
        if i == last_user then insert_at(out, i) end
        out[#out + 1] = msgs[i]
    end
    if not last_user then insert_at(out, nil) end
    return out
end

local function decode_args(s)
    if not s or s == "" then return {} end
    local ok, v = pcall(cjson.decode, s)
    if ok and type(v) == "table" then return v end
    return nil
end

function M:_loop(text, stream)
    local ctx = self.ctx
    self:ensure_system()

    local user = { role = "user", content = text }
    ctx:add_message(user)
    self.session:append(user)

    local tool_notes = {}

    for _ = 1, ctx.settings.max_turns do
        ctx:begin_turn()
        local assistant, err = stream(
            self:request_messages(text),
            self.tools:schemas(),
            ctx.settings,
            function(delta) ctx:emit("delta", delta) end,
            function(delta) ctx:emit("reasoning", delta) end)

        if not assistant then
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
            end
            ctx:end_turn()
            return answer
        end

        for _, tc in ipairs(calls) do
            local fn = tc["function"] or {}
            local name = fn.name or ""
            local args = decode_args(fn.arguments)
            local result
            if args == nil then
                result = "error: invalid tool arguments JSON"
            else
                ctx:set_status("tool")
                ctx:emit("tool_start", name, args)
                result = self.tools:execute(name, args)
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
        end
        if self.memory then self.memory:tick() end
        ctx:set_status("thinking")
    end

    local err = "max turns reached"
    ctx:fail(err)
    ctx:end_turn()
    return nil, err
end

-- 阻塞入口：--once / 单测。
function M:run(text)
    return self:_loop(text, function(messages, tools, opts, on_delta, on_reasoning)
        return self.provider.stream(messages, tools, opts, on_delta, on_reasoning)
    end)
end

-- 协程入口：TUI 驱动，yield {kind="http", req=...}。
function M:run_async(text)
    return coroutine.create(function()
        return self:_loop(text, function(messages, tools, opts, on_delta, on_reasoning)
            return self.provider.stream_async(messages, tools, opts, on_delta, on_reasoning)
        end)
    end)
end

return M
