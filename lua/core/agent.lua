-- Agent 循环：messages → provider → tool calls → messages。
local cjson = require("cjson")

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
    return table.concat({
        "You are lite, a concise terminal coding agent.",
        "Workspace: " .. self.ctx.session.cwd,
        "Use the provided tools to inspect and modify files.",
        "Prefer read/edit over rewriting whole files.",
        "bash is auto-approved but keep commands scoped to the workspace.",
        "Keep only recent, relevant context in the prompt; older turns live in local memory.",
        "Use recall when you need details from earlier in this project.",
        "When done, answer briefly in the user's language.",
    }, "\n")
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
function M:window_messages()
    local ctx = self.ctx
    local msgs = ctx.session.messages
    local budget = tonumber(ctx.settings.context_chars) or 32000
    local max_turns = tonumber(ctx.settings.context_turns) or 16

    local starts = {}
    for i, m in ipairs(msgs) do
        if m.role == "user" then starts[#starts + 1] = i end
    end
    if #starts == 0 then return msgs, false end

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
        return msgs, false
    end

    local out = {}
    for i = 1, keep_from - 1 do
        if msgs[i].role == "system" then out[#out + 1] = msgs[i] end
    end
    if trimmed then
        out[#out + 1] = {
            role = "system",
            content = "Earlier conversation is stored in local memory; use recall if needed.",
        }
    end
    for i = keep_from, #msgs do out[#out + 1] = msgs[i] end
    return out, trimmed
end

-- 把相关记忆插入到最近一条 user 之前（不写入会话）。
function M:request_messages(text)
    local msgs = self:window_messages()
    if not self.memory then return msgs end
    local block = self.memory:context(text or "", { limit = 8, max_chars = 2400 })
    if block == "" then return msgs end

    local last_user
    for i = #msgs, 1, -1 do
        if msgs[i].role == "user" then last_user = i; break end
    end

    local out = {}
    for i = 1, #msgs do
        if i == last_user then
            out[#out + 1] = { role = "system", content = block }
        end
        out[#out + 1] = msgs[i]
    end
    if not last_user then
        out[#out + 1] = { role = "system", content = block }
    end
    return out
end

local function decode_args(s)
    if not s or s == "" then return {} end
    local ok, v = pcall(cjson.decode, s)
    if ok and type(v) == "table" then return v end
    return nil
end

function M:run(text)
    local ctx = self.ctx
    self:ensure_system()

    local user = { role = "user", content = text }
    ctx:add_message(user)
    self.session:append(user)

    local tool_notes = {}

    for _ = 1, ctx.settings.max_turns do
        ctx:begin_turn()
        local assistant, err = self.provider.stream(
            self:request_messages(text),
            self.tools:schemas(),
            ctx.settings,
            function(delta) ctx:emit("delta", delta) end)

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

return M
