-- lite 单元测试：context / config / tools / provider parser / agent loop。
local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local ok, fail = 0, 0
local function check(cond, name)
    if cond then
        ok = ok + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
    end
end

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- context
do
    local Context = require("context")
    local ctx = Context.new({ cwd = "/tmp", model = "deepseek-chat" })
    check(type(ctx.session) == "table" and type(ctx.view) == "table"
        and type(ctx.settings) == "table" and type(ctx.ui) == "table", "context slices")

    local seen = nil
    ctx:on("message", function(m) seen = m end)
    ctx:add_message({ role = "user", content = "hi" })
    check(#ctx.session.messages == 1 and seen and seen.content == "hi", "context message")
    check(ctx.ui.dirty == true, "context dirty")

    ctx:clear_dirty()
    check(ctx.ui.dirty == false, "context clear dirty")
    ctx:begin_turn()
    check(ctx.session.busy == true and ctx.view.status == "thinking", "context begin turn")
    ctx:end_turn()
    check(ctx.session.busy == false and ctx.view.status == "idle", "context end turn")
end

-- config
do
    local cfg = require("core.config").load({
        HOME = "/tmp",
        PWD = "/tmp",
        DEEPSEEK_MODEL = "deepseek-chat-x",
    })
    check(cfg.model == "deepseek-chat-x", "config env override")
    check(cfg.max_turns == 16, "config default max_turns")
end

-- tools
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local Tools = require("core.tools")
    local t = Tools.new({ cwd = dir })
    local okw = t:execute("write", { path = "a.txt", content = "hello\nworld\n" })
    check(okw:find("wrote", 1, true) ~= nil, "tools write")
    local r = t:execute("read", { path = "a.txt" })
    check(r:find("hello", 1, true) ~= nil, "tools read")
    local e = t:execute("edit", { path = "a.txt", old = "world", new = "lite" })
    check(e:find("edited", 1, true) ~= nil, "tools edit")
    check(t:execute("read", { path = "a.txt" }):find("lite", 1, true) ~= nil, "tools edit read")
    check(t:execute("bash", { command = "printf hi" }) == "hi", "tools bash")
    local abs, err = t:resolve("../escape")
    check(abs == nil and err ~= nil, "tools path escape")
    os.execute("rm -rf " .. shq(dir))
end

-- provider SSE parser
do
    local cjson = require("cjson")
    local P = require("core.provider")
    local p = P.new_parser()
    local function chunk(obj) return "data: " .. cjson.encode(obj) .. "\n\n" end
    P.feed(p, chunk({ choices = { { delta = { content = "Hel" } } } }))
    P.feed(p, chunk({ choices = { { delta = { content = "lo" } } } }))
    P.feed(p, chunk({ choices = { { delta = { tool_calls = {
        { index = 0, id = "call_1", type = "function",
          ["function"] = { name = "bash", arguments = '{"command":' } },
    } } } } }))
    P.feed(p, chunk({ choices = { { delta = { tool_calls = {
        { index = 0, ["function"] = { arguments = '"echo hi"}' } },
    } } } } }))
    P.feed(p, "data: [DONE]\n\n")
    local msg = P.finish(p)
    check(msg.content == "Hello", "provider content")
    check(msg.tool_calls and #msg.tool_calls == 1, "provider tool calls")
    check(msg.tool_calls[1]["function"].name == "bash", "provider tool name")
    check(msg.tool_calls[1]["function"].arguments == '{"command":"echo hi"}', "provider tool args")
end

-- agent loop（mock provider/tools/session）
do
    local Context = require("context")
    local Agent = require("core.agent")
    local ctx = Context.new({ cwd = "/tmp", max_turns = 4 })
    local calls = 0
    local provider = {
        stream = function(_, _, _, _)
            calls = calls + 1
            if calls == 1 then
                return {
                    role = "assistant", content = "",
                    tool_calls = { {
                        id = "call_1", type = "function",
                        ["function"] = { name = "bash", arguments = '{"command":"echo hi"}' },
                    } },
                }
            end
            return { role = "assistant", content = "done" }
        end,
    }
    local tools = {
        schemas = function() return {} end,
        execute = function(_, name, args) return "tool-ok:" .. tostring(args.command) end,
    }
    local session = { append = function() end, save = function() end }
    local agent = Agent.new(ctx, provider, tools, session)
    local text, err = agent:run("hi")
    check(err == nil and text == "done", "agent final")
    check(ctx.session.messages[1].role == "system", "agent system")
    check(ctx.session.messages[2].role == "user", "agent user")
    check(ctx.session.messages[3].role == "assistant", "agent assistant tool call")
    check(ctx.session.messages[4].role == "tool", "agent tool result")
    check(ctx.session.messages[4].content == "tool-ok:echo hi", "agent tool content")
    check(calls == 2, "agent loop count")
end

-- context window：只留最近轮次 + recall 提示
do
    local Context = require("context")
    local Agent = require("core.agent")
    local ctx = Context.new({ cwd = "/tmp", context_chars = 400, context_turns = 2 })
    ctx.session.messages = { { role = "system", content = "sys" } }
    for i = 1, 10 do
        ctx.session.messages[#ctx.session.messages + 1] = {
            role = "user", content = "question " .. i .. " " .. string.rep("x", 100),
        }
        ctx.session.messages[#ctx.session.messages + 1] = {
            role = "assistant", content = "answer " .. i .. " " .. string.rep("y", 100),
        }
    end
    local agent = Agent.new(ctx, {}, {}, {})
    local msgs, trimmed = agent:window_messages()
    check(trimmed == true, "window trimmed")
    check(msgs[1].role == "system" and msgs[1].content == "sys", "window keeps system")
    local users, note = 0, false
    for _, m in ipairs(msgs) do
        if m.role == "user" then users = users + 1 end
        if m.role == "system" and tostring(m.content):find("recall", 1, true) then note = true end
    end
    check(users <= 2, "window turns bound")
    check(note, "window recall hint")
end

-- memory
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local Memory = require("core.memory")
    local mem, merr = Memory.new({ dir = dir, max_mb = 32 })
    check(mem ~= nil, "memory open: " .. tostring(merr))
    if mem then
        check(mem:remember_fact("cpp", "move semantics", { "cpp" }) == true, "memory fact")
        local v = mem:get("/agent/knowledge", "cpp")
        check(v ~= nil and v.c == "move semantics", "memory get")
        check(#mem:recall("move", 5) >= 1, "memory recall")
        mem:remember_turn("s1", 1, "hello", "world")
        check(#mem:recall("hello", 5) >= 1, "memory turn")
        local st = mem:stats()
        check(st.count and st.count >= 2, "memory stats")
        mem:close()

        local mem2 = Memory.new({ dir = dir, max_mb = 32 })
        check(mem2 ~= nil, "memory reopen")
        if mem2 then
            check(mem2:get("/agent/knowledge", "cpp") ~= nil, "memory persist")
            mem2:close()
        end

        local mem3 = Memory.new({ dir = dir, max_mb = 32 })
        local Tools = require("core.tools")
        local t = Tools.new({ cwd = dir, memory = mem3 })
        local rr = t:execute("remember", { key = "py", content = "asyncio", tags = { "python" } })
        check(rr:find("remembered", 1, true) ~= nil, "tools remember")
        local rc = t:execute("recall", { query = "asyncio" })
        check(rc:find("asyncio", 1, true) ~= nil, "tools recall")
        mem3:close()
    end
    os.execute("rm -rf " .. shq(dir))
end

-- agent memory injection
do
    local Context = require("context")
    local Agent = require("core.agent")
    local ctx = Context.new({ cwd = "/tmp", max_turns = 2 })
    local captured
    local provider = {
        stream = function(msgs)
            captured = msgs
            return { role = "assistant", content = "ok" }
        end,
    }
    local tools = { schemas = function() return {} end, execute = function() end }
    local session = { append = function() end, save = function() end }
    local remembered = false
    local memory = {
        context = function() return "MEMORY-BLOCK" end,
        remember_turn = function() remembered = true end,
        tick = function() end,
    }
    local agent = Agent.new(ctx, provider, tools, session, memory)
    local text, err = agent:run("hi")
    check(err == nil and text == "ok", "agent memory answer")
    check(remembered, "agent remember turn")

    local mem_idx, user_idx
    for i, m in ipairs(captured or {}) do
        if m.role == "system" and m.content == "MEMORY-BLOCK" then mem_idx = i end
        if m.role == "user" then user_idx = i end
    end
    check(mem_idx ~= nil and user_idx ~= nil and mem_idx < user_idx, "agent memory order")
end

-- entry
check(loadfile(root .. "/lua/main.lua") ~= nil, "load lua/main.lua")

print(string.format("[unit] %d ok, %d fail", ok, fail))
os.exit(fail == 0 and 0 or 1)
