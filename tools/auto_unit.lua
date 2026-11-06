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
    local ctx = Context.new({ cwd = "/tmp", model = "deepseek-flash" })
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
        LITE_ENV_FILE = "/dev/null",
        DEEPSEEK_MODEL = "deepseek-flash-x",
    })
    check(cfg.model == "deepseek-flash-x", "config env override")
    check(cfg.max_turns == 128, "config default max_turns")
    check(cfg.max_retries == 2, "config max retries")
    check(cfg.approval == "auto", "config approval")

    local cfg2 = require("core.config").load({
        HOME = "/tmp",
        PWD = "/tmp",
        LITE_ENV_FILE = "/dev/null",
        LITE_THINKING = "1",
        LITE_REASONING_EFFORT = "high",
    })
    check(cfg2.thinking == true and cfg2.reasoning_effort == "high", "config thinking")
end

-- config .env
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local envf = dir .. "/.env"
    local f = io.open(envf, "w")
    f:write("DEEPSEEK_API_KEY=sk-test\n# comment\nDEEPSEEK_MODEL='m1'\n")
    f:close()

    local cfg = require("core.config").load({
        HOME = "/tmp", PWD = dir, LITE_ENV_FILE = envf,
    })
    check(cfg.api_key == "sk-test", "config dotenv key")
    check(cfg.model == "m1", "config dotenv quote")

    local cfg2 = require("core.config").load({
        HOME = "/tmp", PWD = dir, LITE_ENV_FILE = envf, DEEPSEEK_MODEL = "override",
    })
    check(cfg2.model == "override", "config env over dotenv")
    os.execute("rm -rf " .. shq(dir))

    -- 向上查找父目录 .env
    local root = os.tmpname()
    os.remove(root)
    os.execute("mkdir -p " .. shq(root .. "/sub"))
    local upfile = io.open(root .. "/.env", "w")
    upfile:write("DEEPSEEK_API_KEY=sk-up\n")
    upfile:close()
    local up = require("core.config").load({ HOME = "/tmp", PWD = root .. "/sub" })
    check(up.api_key == "sk-up", "config dotenv parent")

    -- 全局 ~/.config/lite/.env
    local home = os.tmpname()
    os.remove(home)
    os.execute("mkdir -p " .. shq(home .. "/.config/lite"))
    local gfile = io.open(home .. "/.config/lite/.env", "w")
    gfile:write("DEEPSEEK_API_KEY=sk-global\n")
    gfile:close()
    local glob = require("core.config").load({ HOME = home, PWD = home })
    check(glob.api_key == "sk-global", "config dotenv global")

    -- 父级 .env 没有 key 时，应由全局 .env 补齐
    local hfile = io.open(home .. "/.env", "w")
    hfile:write("OTHER=1\n")
    hfile:close()
    local merged = require("core.config").load({ HOME = home, PWD = home })
    check(merged.api_key == "sk-global", "config dotenv merge")
    os.execute("rm -rf " .. shq(root) .. " " .. shq(home))
end

-- prompt assembly
do
    local Prompt = require("core.prompt")
    local Context = require("context")
    local ctx = Context.new({ cwd = "/tmp", model = "m" })
    local tools = {
        { type = "function", ["function"] = { name = "bash", description = "run commands" } },
    }
    local sp = Prompt.system_prompt(ctx, { tools = tools })
    check(sp:find("You are lite", 1, true) ~= nil, "prompt preamble")
    check(sp:find("<tools>", 1, true) ~= nil
        and sp:find("- bash: run commands", 1, true) ~= nil, "prompt tools")
    check(sp:find("<rules>", 1, true) ~= nil, "prompt rules")
    check(sp:find("<native>", 1, true) ~= nil and sp:find("lite_helper", 1, true) ~= nil,
        "prompt native flow")
    check(sp:find("<memory>", 1, true) ~= nil, "prompt memory policy")
    check(sp:find("<cwd>", 1, true) ~= nil and sp:find("/tmp", 1, true) ~= nil, "prompt cwd")

    local items = { { key = "/agent/knowledge/x", text = "LITE-42", score = 1 } }
    local block = Prompt.memory_block(items, { max_chars = 300 })
    check(block:find("LITE-42", 1, true) ~= nil, "prompt memory item")
    check(block:find("recall", 1, true) ~= nil, "prompt memory recall hint")
    check(sp:find("images are attached", 1, true) ~= nil, "prompt image rule")

    local msgs = {
        { role = "user", content = "previous question" },
        { role = "user", content = "what" },
    }
    local q = Prompt.recall_query("what", msgs)
    check(q:find("previous question", 1, true) ~= nil, "prompt recall query")

    local tb = Prompt.todos_block({
        { content = "a", status = "pending" },
        { content = "b", status = "completed" },
    })
    check(tb:find("<todos>", 1, true) ~= nil
        and tb:find("[x] b", 1, true) ~= nil
        and tb:find("[ ] a", 1, true) ~= nil, "prompt todos block")
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
    local di = e:find("diff --git ", 1, true)
    check(di ~= nil, "tools edit diff")
    if di then
        local D = require("tui.diff")
        local ef = D.parse(e:sub(di))
        check(#ef == 1 and ef[1].path == "a.txt", "tools edit diff parse")
        check(ef[1].additions == 1 and ef[1].deletions == 1, "tools edit diff counts")
    end
    check(t:execute("read", { path = "a.txt" }):find("lite", 1, true) ~= nil, "tools edit read")
    check(t:execute("bash", { command = "printf hi" }) == "hi", "tools bash")
    check(t:execute("bash", { command = "luajit -e 'print(6*7)'" }):find("42", 1, true) ~= nil,
        "tools bundled luajit")
    local abs, err = t:resolve("../escape")
    check(abs == nil and err ~= nil, "tools path escape")
    os.execute("rm -rf " .. shq(dir))
end

-- tools read: text / directory / image / binary
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir .. "/sub"))
    local Tools = require("core.tools")
    local t = Tools.new({ cwd = dir })

    local f = assert(io.open(dir .. "/t.txt", "wb"))
    f:write("a\nb\n")
    f:close()
    local read_desc
    for _, s in ipairs(t:schemas()) do
        if s["function"].name == "read" then read_desc = s["function"].description end
    end
    check(read_desc and read_desc:find("image", 1, true) ~= nil,
        "tools read image schema")

    local txt = t:read("t.txt")
    check(txt:find("1: a", 1, true) ~= nil and txt:find("2: b", 1, true) ~= nil,
        "tools read lines")

    local list = t:read(".")
    check(list:find("sub/", 1, true) ~= nil and list:find("t.txt", 1, true) ~= nil,
        "tools read directory")

    local png = string.char(0x89) .. "PNG\r\n" .. string.char(26) .. "\n" .. "image-bytes"
    local pf = assert(io.open(dir .. "/img.png", "wb"))
    pf:write(png)
    pf:close()
    local img = t:read("img.png")
    check(img:find("Image read successfully", 1, true) ~= nil, "tools read image")
    local att = t:take_attachment()
    check(att and att.mime == "image/png" and #att.data > 0, "tools read image attachment")

    local bf = assert(io.open(dir .. "/bin.dat", "wb"))
    bf:write(string.char(0, 1, 2, 3))
    bf:close()
    check(t:read("bin.dat"):find("binary file", 1, true) ~= nil, "tools read binary")

    os.execute("rm -rf " .. shq(dir))
end

-- async proc
do
    local Proc = require("core.proc")
    local p, perr = Proc.new("echo hi; sleep 0.1", { timeout = 5 })
    check(p ~= nil, "proc start: " .. tostring(perr))
    if p then
        local out
        for _ = 1, 100 do
            local done, o = p:poll()
            out = o
            if done then break end
            os.execute("sleep 0.05")
        end
        check(out:find("hi", 1, true) ~= nil, "proc output")
        check(p.exit_code == 0, "proc exit")
    end

    local q = assert(Proc.new("sleep 5", { timeout = 5 }))
    os.execute("sleep 0.05")
    local cancelled = q:cancel()
    check(cancelled:find("cancelled", 1, true) ~= nil, "proc cancel")
end

-- tools sandbox / symlink escape
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local outside = os.tmpname()
    os.remove(outside)
    os.execute("mkdir -p " .. shq(outside))

    local Tools = require("core.tools")
    local Sandbox = require("core.sandbox")
    local t = Tools.new({ cwd = dir })

    local ap, aerr = t:start_bash("echo async")
    check(ap ~= nil, "tools start_bash: " .. tostring(aerr))
    if ap then
        local out
        for _ = 1, 100 do
            local done, o = ap:poll()
            out = o
            if done then break end
            os.execute("sleep 0.05")
        end
        check(out:find("async", 1, true) ~= nil, "tools start_bash output")
    end

    os.execute("ln -s " .. shq(outside) .. " " .. shq(dir .. "/link"))
    local abs, err = t:resolve("link/x")
    check(abs == nil and err ~= nil, "tools symlink escape")
    local blocked = t:execute("write", { path = "link/x", content = "bad" })
    check(blocked:find("error", 1, true) ~= nil, "tools symlink write blocked")

    if Sandbox.available() then
        local st = Tools.new({ cwd = dir, sandbox = true })
        local out = st:execute("bash", { command = "echo hi > in.txt; pwd" })
        check(out:find(dir, 1, true) ~= nil, "tools sandbox pwd")
        local f = io.open(dir .. "/in.txt", "r")
        check(f ~= nil, "tools sandbox inside write")
        if f then f:close() end

        local marker = outside .. "/escaped"
        st:execute("bash", { command = "echo x > " .. shq(marker) })
        local ef = io.open(marker, "r")
        check(ef == nil, "tools sandbox outside write")
        if ef then ef:close() end
    end

    os.execute("rm -rf " .. shq(dir) .. " " .. shq(outside))
end

-- todo tool + persistence
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))

    local Context = require("context")
    local Tools = require("core.tools")
    local Memory = require("core.memory")

    local mem = assert(Memory.new({ dir = dir, max_mb = 16 }))
    local ctx = Context.new({ cwd = dir })
    local t = Tools.new({ cwd = dir, ctx = ctx, memory = mem })
    local out = t:execute("todo", {
        items = {
            { content = "step 1", status = "in_progress" },
            { content = "step 2", status = "completed" },
            { content = "bad", status = "bogus" },
        },
    })
    check(out:find("1/3", 1, true) ~= nil, "todo summary")
    check(#ctx.session.todos == 3 and ctx.session.todos[3].status == "pending", "todo normalize")
    mem:close()

    local mem2 = assert(Memory.new({ dir = dir, max_mb = 16 }))
    local ctx2 = Context.new({ cwd = dir })
    ctx2.session.id = ctx.session.id
    Tools.new({ cwd = dir, ctx = ctx2, memory = mem2 })
    check(#ctx2.session.todos == 3 and ctx2.session.todos[1].content == "step 1",
        "todo persisted")
    mem2:close()
    os.execute("rm -rf " .. shq(dir))
end

-- provider SSE parser
do
    local cjson = require("cjson")
    local P = require("core.provider")
    local p = P.new_parser()
    local function chunk(obj) return "data: " .. cjson.encode(obj) .. "\n\n" end
    P.feed(p, chunk({ choices = { { delta = { content = "Hel" } } } }))
    -- 新版 API 思考阶段 content 可能为 null；应忽略而不是崩溃。
    P.feed(p, chunk({ choices = { { delta = {
        content = cjson.null, reasoning_content = "thinking...",
    } } } }))
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
    check(table.concat(p.reasoning) == "thinking...", "provider reasoning")
    check(msg.tool_calls and #msg.tool_calls == 1, "provider tool calls")
    check(msg.tool_calls[1]["function"].name == "bash", "provider tool name")
    check(msg.tool_calls[1]["function"].arguments == '{"command":"echo hi"}', "provider tool args")
    check(P.retryable("HTTP 429: rate limit"), "provider retry 429")
    check(P.retryable("HTTP 500: boom"), "provider retry 500")
    check(not P.retryable("HTTP 401: auth"), "provider no retry 401")
    check(P.retryable("http error: timeout"), "provider retry network")
end

-- utf8 sanitize / debug log
do
    local T = require("core.text")
    local s, n = T.sanitize("hello \255 world")
    check(n == 1 and s:find("hello", 1, true) ~= nil, "text invalid byte")
    local ok, n2 = T.sanitize("ok ✓")
    check(n2 == 0 and ok == "ok ✓", "text valid utf8")
    local _, n3 = T.sanitize("\237\160\128")
    check(n3 > 0, "text surrogate")
    check(T.base64("abc") == "YWJj", "text base64")

    local Debug = require("core.debug")
    local path = os.tmpname()
    local d = assert(Debug.new(path))
    d:log("test", { a = 1 })
    d:close()
    local f = assert(io.open(path))
    local line = f:read("*l")
    f:close()
    os.remove(path)
    check(line and line:find('"event":"test"', 1, true) ~= nil, "debug log")
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
        local locked, lerr = Memory.new({ dir = dir, max_mb = 32 })
        check(locked == nil and lerr ~= nil, "memory lock")
        local reader = Memory.new({ dir = dir, max_mb = 32, readonly = true })
        check(reader ~= nil, "memory readonly lock")
        if reader then reader:close() end
        check(mem:remember_fact("cpp", "move semantics", { "cpp" }) == true, "memory fact")
        local v = mem:get("/agent/knowledge", "cpp")
        check(v ~= nil and v.c == "move semantics", "memory get")
        check(#mem:recall("move", 5) >= 1, "memory recall")
        local block, items = mem:context("move semantics", { limit = 5 })
        check(type(block) == "string" and #items >= 1, "memory context items")
        check(mem:remember_fact("project", "项目代号是 LITE-42", { "项目" }) == true,
            "memory fact cjk")
        check(#mem:recall("项目代号", 5) >= 1, "memory recall cjk")
        mem:ensure_session("s1", "/proj", "m")
        mem:ensure_session("s2", "/proj", "m")
        mem:remember_turn("s1", 1, "hello", "world")
        check(#mem:recall("hello", 5) >= 1, "memory turn")
        mem:remember_turn("s2", 1, "alpha two", "answer two")
        local s1items = mem:recall("alpha", 10, { session_id = "s1" })
        local leaked = false
        for _, it in ipairs(s1items) do
            if it.key:find("/agent/session/s2/", 1, true) then leaked = true end
        end
        check(not leaked, "memory session scope")

        -- 工作记忆：会话级隔离；目录级 /agent/working（wake 等运行态）不进 recall
        mem:remember_working("wtask", "s1 的临时任务 zebra", nil, "s1")
        mem:put("/agent/working", "wake", { runs = 9, last_answer = "zebra wake" }, 0)
        local w1 = mem:recall("zebra", 10, { session_id = "s1" })
        local w2 = mem:recall("zebra", 10, { session_id = "s2" })
        local function has(items, sub)
            for _, it in ipairs(items) do
                if it.key:find(sub, 1, true) then return true end
            end
            return false
        end
        check(has(w1, "/agent/session/s1/working/wtask"), "working session scoped")
        check(not has(w2, "/agent/session/s1/working/"), "working no cross session")
        check(not has(w1, "/agent/working/"), "working runtime state not injected")
        check(not has(w2, "/agent/working/"), "working runtime state not injected (s2)")
        check(#mem:recall("alpha", 10, { session_id = "s2" }) >= 1,
            "memory session include")
        local sm, max_turn = mem:session_messages("s2", 10)
        check(#sm == 2 and sm[1].content == "alpha two"
            and sm[2].content == "answer two", "memory session messages")
        check(max_turn == 1, "memory session max turn")
        local list = mem:list_sessions("/proj", 5)
        check(#list == 2, "memory list sessions")
        check(mem:session_meta("s1").title == "hello", "memory session meta")
        check(#mem:list_sessions("/other", 5) == 0, "memory list sessions cwd")
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

    -- 头部损坏自愈：mem.bin 的 magic 被写坏时，backup 后以空库启动，而不是硬失败。
    do
        local dir = dir .. "-corrupt"
        os.execute("mkdir -p " .. shq(dir))
        local mem = Memory.new({ dir = dir, max_mb = 32 })
        check(mem ~= nil, "corrupt: seed open")
        if mem then
            mem:remember_fact("keep", "should be backed up", { "t" })
            mem:close()
        end
        local f = assert(io.open(dir .. "/mem.bin", "r+b"))
        f:seek("set", 0)
        f:write("XXXX")
        f:close()

        local healed = Memory.new({ dir = dir, max_mb = 32 })
        check(healed ~= nil, "corrupt: mem.bin header self-heals on open")
        if healed then
            check(healed:get("/agent/knowledge", "keep") == nil, "corrupt: starts empty")
            healed:remember_fact("after", "works again", { "t" })
            check(healed:get("/agent/knowledge", "after") ~= nil, "corrupt: writable after heal")
            healed:close()
        end
        check(os.execute("ls " .. shq(dir) .. " | grep -q 'mem.bin.corrupt-'") == 0
            or os.execute("ls " .. shq(dir) .. " | grep -q 'mem.bin.corrupt-'") == true,
            "corrupt: backup file kept")
        os.execute("rm -rf " .. shq(dir))
    end

    os.execute("rm -rf " .. shq(dir))
end

-- native image resize
do
    local Image = require("ffi.image")
    if Image.available() then
        local dir = os.tmpname()
        os.remove(dir)
        os.execute("mkdir -p " .. shq(dir))
        local function unhex(s)
            return (s:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
        end
        local png_hex = "89504e470d0a1a0a0000000d49484452000000040000000208060000007fa87d630000001349444154789c63e41291fbcf80049818d0000025b4013f4c5aa1c90000000049454e44ae426082"
        local f = assert(io.open(dir .. "/in.png", "wb"))
        f:write(unhex(png_hex))
        f:close()

        local Tools = require("core.tools")
        local t = Tools.new({ cwd = dir })
        local out = t:execute("resize", { path = "in.png", width = 2, height = 1, force = true, output = "out.png" })
        check(out:find("resized", 1, true) ~= nil, "tools resize png")
        local of = io.open(dir .. "/out.png", "rb")
        local png = of and of:read("*a") or ""
        if of then of:close() end
        local w = #png >= 24 and (png:byte(17) * 16777216 + png:byte(18) * 65536 + png:byte(19) * 256 + png:byte(20)) or 0
        local h = #png >= 24 and (png:byte(21) * 16777216 + png:byte(22) * 65536 + png:byte(23) * 256 + png:byte(24)) or 0
        check(w == 2 and h == 1, "tools resize png size")

        local aspect = t:execute("resize", { path = "in.png", width = 2, output = "aspect.png" })
        check(aspect:find("resized", 1, true) ~= nil, "tools resize aspect")
        local af = io.open(dir .. "/aspect.png", "rb")
        local apng = af and af:read("*a") or ""
        if af then af:close() end
        local aw = #apng >= 24 and (apng:byte(17) * 16777216 + apng:byte(18) * 65536 + apng:byte(19) * 256 + apng:byte(20)) or 0
        local ah = #apng >= 24 and (apng:byte(21) * 16777216 + apng:byte(22) * 65536 + apng:byte(23) * 256 + apng:byte(24)) or 0
        check(aw == 2 and ah == 1, "tools resize aspect size")

        -- 临时目录（截图默认落点）可读可写：输入在 /tmp，产物也留在同处，不搬回仓库
        local outside = dir .. "-ext.png"
        local ef = assert(io.open(outside, "wb"))
        ef:write(unhex(png_hex))
        ef:close()
        local ext = t:execute("resize", { path = outside, width = 2 })
        check(ext:find("resized", 1, true) ~= nil, "tools resize temp input")
        check(ext:find(dir .. "-ext-2xauto.png", 1, true) ~= nil,
            "tools resize temp output stays in temp")
        os.remove(outside)
        os.remove(dir .. "-ext-2xauto.png")

        -- 白名单外的路径仍然拒绝（workspace 与 /tmp 之外）
        local denied = t:execute("resize", { path = "in.png", width = 2, output = "/etc/lite-x.png" })
        check(denied:find("error:", 1, true) ~= nil, "tools resize rejects outside path")

        local jpg = t:execute("resize", { path = "in.png", width = 2, height = 1, force = true, output = "out.jpg" })
        check(jpg:find("resized", 1, true) ~= nil, "tools resize jpeg encode")
        local jf = io.open(dir .. "/out.jpg", "rb")
        local jhead = jf and jf:read(3) or ""
        if jf then jf:close() end
        check(jhead:byte(1) == 0xFF and jhead:byte(2) == 0xD8 and jhead:byte(3) == 0xFF,
            "tools resize jpeg magic")
        local jpg2 = t:execute("resize", { path = "out.jpg", width = 4, height = 2, force = true, output = "out2.jpg" })
        check(jpg2:find("resized", 1, true) ~= nil, "tools resize jpeg decode")

        local webp = t:execute("resize", { path = "in.png", width = 2, height = 1, force = true, output = "out.webp" })
        check(webp:find("resized", 1, true) ~= nil, "tools resize webp encode")
        local wf = io.open(dir .. "/out.webp", "rb")
        local whead = wf and wf:read(12) or ""
        if wf then wf:close() end
        check(whead:sub(1, 4) == "RIFF" and whead:sub(9, 12) == "WEBP", "tools resize webp magic")
        local webp2 = t:execute("resize", { path = "out.webp", width = 4, height = 2, force = true, output = "out2.webp" })
        check(webp2:find("resized", 1, true) ~= nil, "tools resize webp decode")

        os.execute("rm -rf " .. shq(dir))
    else
        print("SKIP native image resize (liblite_image not built)")
    end
end

-- lua hot reload
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local Tools = require("core.tools")
    local Prompt = require("core.prompt")
    local t = Tools.new({ cwd = dir })
    t.image_native = { old = true }
    local agent = {
        tools = t,
        prompt = Prompt,
        system_prompt = function() return "reloaded system" end,
    }
    local ctx = { session = { messages = { { role = "system", content = "old" } } } }
    local ok, err = require("core.reload").lua(agent, ctx)
    check(ok, "reload lua: " .. tostring(err))
    check(type(t.schemas) == "function", "reload tools methods")
    check(t.image_native == nil, "reload clears image cache")
    check(agent.prompt == require("core.prompt"), "reload prompt module")
    check(ctx.session.messages[1].content == "reloaded system", "reload system prompt")
    os.execute("rm -rf " .. shq(dir))
end

-- read image from temp dir
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local function unhex(h)
        return (h:gsub("..", function(c) return string.char(tonumber(c, 16)) end))
    end
    local png_hex = "89504e470d0a1a0a0000000d49484452000000040000000208060000007fa87d630000001349444154789c63e41291fbcf80049818d0000025b4013f4c5aa1c90000000049454e44ae426082"
    local img = os.tmpname()
    local f = assert(io.open(img, "wb"))
    f:write(unhex(png_hex))
    f:close()
    local Tools = require("core.tools")
    local t = Tools.new({ cwd = dir })
    local out = t:read(img)
    check(out:find("Image read", 1, true) ~= nil, "read temp image")
    local att = t:take_attachment()
    check(att and att.mime == "image/png", "read temp image attachment")
    local txt = img .. ".txt"
    local tf = io.open(txt, "wb")
    tf:write("outside")
    tf:close()
    local denied = t:read(txt)
    check(denied:find("outside workspace", 1, true) ~= nil, "read temp text denied")
    os.remove(img)
    os.remove(txt)
    os.execute("rm -rf " .. shq(dir))
end

-- OCR (optional system PP-OCRv4)
do
    local sample = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/../testdata/ocr_sample.png"
    local sf = io.open(sample, "rb")
    local OCR = require("ffi.ocr")
    local ready = OCR.ready()
    if sf and ready then
        local bytes = sf:read("*a")
        sf:close()
        local img = os.tmpname() .. ".png"
        local f = assert(io.open(img, "wb"))
        f:write(bytes)
        f:close()
        local dir = os.tmpname()
        os.remove(dir)
        os.execute("mkdir -p " .. shq(dir))
        local Tools = require("core.tools")
        local t = Tools.new({ cwd = dir })
        local out = t:execute("ocr", { path = img })
        check(#out > 20 and (out:find("Wordcard", 1, true) ~= nil or out:find("时代", 1, true) ~= nil),
            "tools ocr")
        local with_boxes = t:execute("ocr", { path = img, boxes = true })
        check(with_boxes:find('"x"', 1, true) ~= nil, "tools ocr boxes")
        -- 初始化不应把 ONNX Runtime 的 CUDA 缺库报错漏到进程输出里。
        -- 随包只有 CPU 版 onnxruntime，回退是预期行为；那几行红色 ERROR 会
        -- 被误读成「OCR 坏了」。噪声在进程流（libocr 写 stdout，ORT 写 stderr），
        -- 所以必须开子进程抓 2>&1，不能只检查工具返回值。
        do
            local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
            local script = root .. "/../ocr_quiet_probe.lua"
            local sf2 = io.open(script, "w")
            if sf2 then
                sf2:write(string.format([[
package.path = %q .. "/lua/?.lua;" .. %q .. "/lua/?/init.lua;" .. package.path
local ok = require("ffi.ocr").ready()
io.write(ok and "READY\n" or "NOTREADY\n")
]], root, root))
                sf2:close()
                local h = io.popen(shq(root .. "/tools/lite-lua") .. " " .. shq(script) .. " 2>&1")
                local text = h and h:read("*a") or ""
                if h then h:close() end
                os.remove(script)
                check(text:find("READY", 1, true) ~= nil, "ocr init succeeds in subprocess")
                local noisy = text:find("ONNXRuntimeError", 1, true)
                    or text:find("provider_bridge_ort", 1, true)
                    or text:find("libonnxruntime_providers_cuda", 1, true)
                    or text:find("Failed to load shared library", 1, true)
                check(not noisy, "ocr init quiet on missing CUDA provider")

                -- backend 行必须与实测一致：链接了 CUDA provider 就不能还报 CPU
                if text:find("CUDA enabled", 1, true) then
                    check(text:find("backend: CUDA", 1, true) ~= nil,
                        "ocr backend line says CUDA when CUDA enabled")
                else
                    check(text:find("backend: CPU", 1, true) ~= nil,
                        "ocr backend line says CPU when CUDA unavailable")
                end
            end

            -- ort_link.sh 默认 CPU 优先：OCR 只需 CPU，GPU 版会挂 CUDA EP
            do
                local f = io.open(root .. "/tools/ort_link.sh", "r")
                local txt = f and f:read("*a") or ""
                if f then f:close() end
                check(txt:find("LITE_ORT_PREFER", 1, true) ~= nil,
                    "ort_link.sh exposes CPU/GPU preference")
                check(txt:find("providers_cuda", 1, true) ~= nil
                    and txt:find("ort_variant", 1, true) ~= nil,
                    "ort_link.sh classifies CPU vs GPU variant")
                check(txt:find("libonnxruntime.so.1.%%*", 1, true) ~= nil
                    or txt:find("libonnxruntime.so.1.", 1, true) ~= nil,
                    "ort_link.sh handles pip layout (no .so.1 symlink)")
                -- 「有 GPU 用 GPU、没有用 CPU」：auto 策略 + GPU 可用性探测
                check(txt:find("auto", 1, true) ~= nil
                    and txt:find("resolve_prefer", 1, true) ~= nil,
                    "ort_link.sh supports auto preference")
                check(txt:find("gpu_usable", 1, true) ~= nil
                    and txt:find("nvidia-smi", 1, true) ~= nil,
                    "ort_link.sh probes GPU usability")
                -- 选 CPU 时必须摘掉 provider，否则运行时仍会挂 CUDA EP
                check(txt:find("rm -f \"$PROVIDER\"", 1, true) ~= nil,
                    "ort_link.sh detaches CUDA provider for cpu mode")
            end

            -- CUDA provider 走软链接，不打包；实体文件会膨胀 tarball
            do
                local pkg = io.open(root .. "/tools/package.sh", "r")
                local script = pkg and pkg:read("*a") or ""
                if pkg then pkg:close() end
                check(script:find("providers_cuda", 1, true) ~= nil
                    and script:find("continue", 1, true) ~= nil,
                    "package.sh skips CUDA provider")
                -- onnxruntime 核心库 25MB，占包一半；默认不打包，靠 ort_link.sh 接
                check(script:find("libonnxruntime.so.1", 1, true) ~= nil,
                    "package.sh is aware of onnxruntime core lib")
                check(script:find("LITE_DIST_WITH_ORT", 1, true) ~= nil,
                    "package.sh has escape hatch for bundling ORT")
                check(script:find("ORT_VERSION", 1, true) ~= nil,
                    "package.sh records required ORT version")
                -- OCR 模型 14.8MB、可选能力，默认也不随包
                check(script:find("LITE_DIST_WITH_OCR", 1, true) ~= nil,
                    "package.sh has escape hatch for bundling OCR models")
            end
        end
        os.remove(img)
        os.execute("rm -rf " .. shq(dir))
    else
        if sf then sf:close() end
        print("SKIP tools ocr (OCR/onnxruntime/model unavailable)")
    end
end

-- OCR 可选性：模型缺失时报错必须可操作，不能是 cdata NULL；
-- 且其余工具不受影响（dist 默认不带模型）
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
    local script = dir .. "/probe.lua"
    local f = assert(io.open(script, "w"))
    f:write(string.format([[
package.path = %q .. "/lua/?.lua;" .. %q .. "/lua/?/init.lua;" .. package.path
local OCR = require("ffi.ocr")
local ok, err = OCR.ready()
if ok then io.write("READY\n") else io.write("ERR " .. tostring(err) .. "\n") end
]], root, root))
    f:close()

    local h = io.popen("env LITE_OCR_MODELS=/nonexistent/missing LITE_ROOT="
        .. shq(root) .. " " .. shq(root .. "/tools/lite-lua") .. " " .. shq(script)
        .. " 2>&1")
    local text = h and h:read("*a") or ""
    if h then h:close() end
    os.remove(script)
    os.execute("rm -rf " .. shq(dir))

    check(text:find("ERR", 1, true) ~= nil, "ocr missing models reports error")
    check(text:find("optional", 1, true) ~= nil,
        "ocr missing models hint says optional")
    check(text:find("cdata", 1, true) == nil,
        "ocr missing models does not leak cdata NULL")
end

-- X11 capture (only with a live display)
do
    local display = os.getenv("DISPLAY")
    if display and display ~= "" then
        local ok, x11 = pcall(require, "x11")
        if ok then
            local img = os.tmpname() .. ".png"
            local captured, err = x11.capture_screen(img)
            check(captured, "x11 capture: " .. tostring(err))
            local f = io.open(img, "rb")
            local head = f and f:read(8) or ""
            if f then f:close() end
            check(head == "\137PNG\13\10\26\10", "x11 capture png")
            os.remove(img)

            -- 窗口定位：字段齐全 + 多匹配不静默挑一个
            local wins = x11.windows()
            check(#wins > 0, "x11 windows non-empty")
            local has_meta = false
            for _, w in ipairs(wins) do
                if w.class ~= nil or w.pid ~= nil then has_meta = true end
            end
            check(has_meta, "x11 windows carry class/pid")

            local act = x11.resolve({ active = true })
            check(act ~= nil, "x11 resolve active")
            if act then
                check(act.viewable == true, "x11 resolved window viewable")
            end
            local none, cand = x11.resolve({ class = "__no_such_class__" })
            check(none == nil and #cand == 0, "x11 resolve unknown class empty")
            -- 用一个必然多匹配的查询：所有可 view 的窗口
            local multi, list = x11.resolve({ viewable = true })
            if #wins > 1 then
                check(multi == nil and #list >= 1, "x11 resolve ambiguous returns candidates")
            end
        else
            print("SKIP x11 capture (module unavailable)")
        end
    else
        print("SKIP x11 capture (no DISPLAY)")
    end
end

-- native helper build/run
do
    local has_cc = os.execute("command -v cc >/dev/null 2>&1") == 0
    if has_cc then
        local dir = os.tmpname()
        os.remove(dir)
        os.execute("mkdir -p " .. shq(dir))
        local Tools = require("core.tools")
        local t = Tools.new({ cwd = dir })
        local code = [[
#include <stdlib.h>
#include <stdio.h>
char *lite_helper(const char *input) {
    char *out = malloc(128);
    snprintf(out, 128, "native:%s", input ? input : "");
    return out;
}
void lite_helper_free(char *p) { free(p); }
]]
        local built = t:execute("native", { action = "build", name = "echo", code = code })
        check(built:find("built native helper", 1, true) ~= nil, "native build")
        local ran = t:execute("native", { action = "run", name = "echo", input = "x" })
        check(ran == "native:x", "native run")
        local listed = t:execute("native", { action = "list" })
        check(listed:find("echo.c", 1, true) ~= nil, "native list")
        local bad = t:execute("native", { action = "run", name = "missing" })
        check(bad:find("not built", 1, true) ~= nil, "native missing")
        local traversal = t:execute("native", { action = "run", name = "../escape" })
        check(traversal:find("invalid helper name", 1, true) ~= nil, "native name guard")

        local lua_code = [[
local M = {}
function M.run(args, env)
    return env.call("echo", args.value or "")
end
return M
]]
        local wrapped = t:execute("native", {
            action = "wrap", name = "echo_tool", lua = lua_code,
            description = "echo helper",
            parameters = { type = "object", properties = { value = { type = "string" } } },
        })
        check(wrapped:find("installed helper tool", 1, true) ~= nil, "native wrap")
        local found = false
        for _, schema in ipairs(t:schemas()) do
            if schema["function"].name == "echo_tool" then found = true end
        end
        check(found, "native schema discovered")
        check(t:execute("echo_tool", { value = "wrapped" }) == "native:wrapped", "native helper call")
        os.execute("rm -rf " .. shq(dir))
    else
        print("SKIP native helper (cc missing)")
    end
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

-- approval policy
do
    local A = require("core.approval")
    local ask = A.new({ mode = "ask" })
    check(ask:decide("read") == "allow", "approval readonly")
    check(ask:decide("bash") == "ask", "approval ask")
    ask:remember("bash")
    check(ask:decide("bash") == "allow", "approval always")
    check(A.new({ mode = "deny" }):decide("write") == "deny", "approval deny")
    check(A.new({ mode = "auto" }):decide("bash") == "allow", "approval auto")

    local V = require("tui.approval_view")
    local S = require("tui.screen")
    local v = V.new({ name = "bash", args = { command = "echo hi" } }, { width = 60, height = 12 })
    local s = S.new(60, 12)
    v:render(s, 60, 12)
    local txt = s:snapshot_text()
    check(txt:find("APPROVAL", 1, true) ~= nil
        and txt:find("bash", 1, true) ~= nil
        and txt:find("echo hi", 1, true) ~= nil, "approval view render")
    check(v:handle({ key = "char", text = "a" }) == "always", "approval view always")
    check(v:handle({ key = "escape" }) == "reject", "approval view reject")
end

-- agent approval yield
do
    local Context = require("context")
    local Agent = require("core.agent")
    local ctx = Context.new({ cwd = "/tmp", max_turns = 2, approval = "ask" })
    local calls, executed = 0, false
    local provider = {
        stream_async = function()
            calls = calls + 1
            if calls == 1 then
                return {
                    role = "assistant", content = "",
                    tool_calls = { { id = "c1", type = "function",
                        ["function"] = { name = "bash", arguments = '{"command":"echo hi"}' } } },
                }
            end
            return { role = "assistant", content = "done" }
        end,
    }
    local tools = {
        schemas = function() return {} end,
        execute = function() executed = true; return "ok" end,
    }
    local session = { append = function() end }
    local agent = Agent.new(ctx, provider, tools, session)
    local co = agent:run_async("hi")
    local ok, y = coroutine.resume(co)
    check(ok and y and y.kind == "approval" and y.name == "bash", "agent approval yield")
    local ok2, y2 = coroutine.resume(co, "once")
    check(ok2 and executed and coroutine.status(co) == "dead" and y2 == "done",
        "agent approval once")
end

-- agent async proc yield
do
    local Context = require("context")
    local Agent = require("core.agent")
    local ctx = Context.new({ cwd = "/tmp", max_turns = 2 })
    local calls = 0
    local provider = {
        stream_async = function()
            calls = calls + 1
            if calls == 1 then
                return {
                    role = "assistant", content = "",
                    tool_calls = { { id = "c1", type = "function",
                        ["function"] = { name = "bash", arguments = '{"command":"echo hi"}' } } },
                }
            end
            return { role = "assistant", content = "done" }
        end,
    }
    local tools = {
        schemas = function() return {} end,
        execute = function() error("should use start_bash") end,
        start_bash = function(_, command) return { command = command } end,
    }
    local session = { append = function() end }
    local agent = Agent.new(ctx, provider, tools, session)
    local co = agent:run_async("hi")
    local ok, y = coroutine.resume(co)
    check(ok and y and y.kind == "proc", "agent proc yield")
    local ok2, y2 = coroutine.resume(co, "async-output")
    check(ok2 and coroutine.status(co) == "dead" and y2 == "done", "agent proc resume")
end

-- agent image attachment message
do
    local Context = require("context")
    local Agent = require("core.agent")
    local ctx = Context.new({ cwd = "/tmp", max_turns = 2 })
    local calls, captured = 0, nil
    local provider = {
        stream_async = function(msgs)
            calls = calls + 1
            if calls == 1 then
                return {
                    role = "assistant", content = "",
                    tool_calls = { { id = "c1", type = "function",
                        ["function"] = { name = "read", arguments = '{"path":"img.png"}' } } },
                }
            end
            captured = msgs
            return { role = "assistant", content = "done" }
        end,
    }
    local tools = {
        schemas = function() return {} end,
        execute = function() return "Image read successfully" end,
        take_attachment = function()
            return { mime = "image/png", data = "AAAA", path = "/tmp/img.png" }
        end,
    }
    local session = { append = function() end }
    local agent = Agent.new(ctx, provider, tools, session)
    local co = agent:run_async("hi")
    local ok = coroutine.resume(co)
    check(ok and coroutine.status(co) == "dead", "agent image run")

    local found = false
    for _, m in ipairs(captured or {}) do
        if m.role == "user" and type(m.content) == "table" then
            for _, p in ipairs(m.content) do
                if p.type == "image_url" then found = true end
            end
        end
    end
    check(found, "agent image message")
end

-- agent reasoning event
do
    local Context = require("context")
    local Agent = require("core.agent")
    local ctx = Context.new({ cwd = "/tmp", max_turns = 1 })
    local got = ""
    ctx:on("reasoning", function(t) got = got .. t end)

    local provider = {
        stream = function(_, _, _, on_delta, on_reasoning)
            on_reasoning("r1")
            on_delta("a")
            return { role = "assistant", content = "a" }
        end,
    }
    local tools = { schemas = function() return {} end, execute = function() end }
    local session = { append = function() end }
    local agent = Agent.new(ctx, provider, tools, session)
    local text, err = agent:run("hi")
    check(err == nil and text == "a" and got == "r1", "agent reasoning event")
end

-- agent context digest
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local Context = require("context")
    local Agent = require("core.agent")
    local Memory = require("core.memory")

    local mem = assert(Memory.new({ dir = dir, max_mb = 16 }))
    local ctx = Context.new({ cwd = "/tmp", context_chars = 300, context_turns = 1, max_turns = 1 })
    for i = 1, 6 do
        ctx.session.messages[#ctx.session.messages + 1] = {
            role = "user", content = "question " .. i .. " " .. string.rep("x", 40),
        }
        ctx.session.messages[#ctx.session.messages + 1] = {
            role = "assistant", content = "answer " .. i .. " " .. string.rep("y", 40),
        }
    end

    local captured
    local provider = {
        stream = function(msgs)
            captured = msgs
            return { role = "assistant", content = "ok" }
        end,
    }
    local tools = { schemas = function() return {} end, execute = function() end }
    local session = { append = function() end }
    local agent = Agent.new(ctx, provider, tools, session, mem)
    local _, err = agent:run("latest question")
    check(err == nil, "agent context run")

    local found = false
    for _, m in ipairs(captured or {}) do
        if m.role == "system" and tostring(m.content):find("<session_context>", 1, true) then
            found = true
        end
    end
    check(found, "agent context digest injected")
    check(mem:get("/agent/session", ctx.session.id .. "/context") ~= nil,
        "agent context digest stored")
    mem:close()
    os.execute("rm -rf " .. shq(dir))
end

-- agent todos injection
do
    local Context = require("context")
    local Agent = require("core.agent")
    local ctx = Context.new({ cwd = "/tmp", max_turns = 1 })
    ctx.session.todos = { { content = "ship it", status = "in_progress" } }

    local captured
    local provider = {
        stream = function(msgs)
            captured = msgs
            return { role = "assistant", content = "ok" }
        end,
    }
    local tools = { schemas = function() return {} end, execute = function() end }
    local session = { append = function() end }
    local agent = Agent.new(ctx, provider, tools, session)
    agent:run("hi")

    local found = false
    for _, m in ipairs(captured or {}) do
        if m.role == "system"
            and tostring(m.content):find("<todos>", 1, true)
            and tostring(m.content):find("ship it", 1, true) then
            found = true
        end
    end
    check(found, "agent todos injected")
end

-- agent + real KV memory injection
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))

    local Memory = require("core.memory")
    local Context = require("context")
    local Agent = require("core.agent")
    local mem = assert(Memory.new({ dir = dir, max_mb = 16 }))
    mem:remember_fact("project.code", "LITE-42", { "project" })

    local ctx = Context.new({ cwd = "/tmp", max_turns = 1 })
    local captured
    local provider = {
        stream = function(msgs)
            captured = msgs
            return { role = "assistant", content = "LITE-42" }
        end,
    }
    local tools = { schemas = function() return {} end, execute = function() end }
    local session = { append = function() end }
    local agent = Agent.new(ctx, provider, tools, session, mem)

    local text, err = agent:run("What is the project code?")
    check(err == nil and text == "LITE-42", "agent real memory answer")

    local found = false
    for _, m in ipairs(captured or {}) do
        if m.role == "system" and tostring(m.content):find("LITE-42", 1, true) then
            found = true
        end
    end
    check(found, "agent real memory injected")
    mem:close()

    local mem2 = assert(Memory.new({ dir = dir, max_mb = 16 }))
    check(#mem2:recall("LITE-42", 5) >= 1, "agent real memory persisted")
    mem2:close()
    os.execute("rm -rf " .. shq(dir))
end

-- tui utf8
do
    local u = require("tui.utf8")
    check(u.width_str("abc") == 3, "tui utf8 ascii width")
    check(u.width_str("中文") == 4, "tui utf8 cjk width")
    local ch, ni = u.decode("中x", 1)
    check(ch == "中" and ni == 4, "tui utf8 decode")
end

-- tui input
do
    local I = require("tui.input")
    local inp = I.new()
    local evs = inp:feed("\27[Aa\3\27[200~x\ny\27[201~")
    check(#evs == 4, "tui input events")
    check(evs[1].key == "up", "tui input up")
    check(evs[2].key == "char" and evs[2].text == "a", "tui input char")
    check(evs[3].key == "ctrl" and evs[3].char == "c", "tui input ctrl")
    check(evs[4].key == "paste" and evs[4].text == "x\ny", "tui input paste")

    local evs_tab = I.new():feed("\9")
    check(#evs_tab == 1 and evs_tab[1].key == "tab", "tui input tab")

    local evs_esc = I.new():feed("\27\27")
    check(#evs_esc == 2 and evs_esc[1].key == "escape" and evs_esc[2].key == "escape",
        "tui input double escape")

    local evs_wheel = I.new():feed("\27[<64;10;5M\27[<65;10;5M")
    check(#evs_wheel == 2 and evs_wheel[1].key == "wheel" and evs_wheel[1].dy == 1
        and evs_wheel[2].key == "wheel" and evs_wheel[2].dy == -1, "tui input mouse wheel")

    local evs_x10 = I.new():feed("\27[M\96\42\42\27[M\97\42\42")
    check(#evs_x10 == 2 and evs_x10[1].key == "wheel" and evs_x10[1].dy == 1
        and evs_x10[2].key == "wheel" and evs_x10[2].dy == -1, "tui input x10 wheel")

    local evs2 = inp:feed("\27[")
    check(#evs2 == 0, "tui input partial")
    evs2 = inp:feed("5~")
    check(#evs2 == 1 and evs2[1].key == "pgup", "tui input partial complete")
end

-- tui composer
do
    local C = require("tui.composer")
    local c = C.new()
    c:insert("hello\nworld")
    check(c:get_text() == "hello\nworld", "tui composer multiline")
    check(c.cy == 2 and c.cx == 6, "tui composer cursor")
    c:backspace()
    check(c:get_text() == "hello\nworl", "tui composer backspace")
    c:home()
    c:insert("> ")
    check(c.lines[2] == "> worl", "tui composer insert midline")
    c:up()
    c:end_()
    c:insert("!")
    check(c.lines[1] == "hello!", "tui composer up")
    c:clear()
    check(c:is_empty(), "tui composer clear")
    c:insert("中文")
    c:backspace()
    check(c:get_text() == "中", "tui composer cjk backspace")
end

-- tui screen
do
    local S = require("tui.screen")
    local s = S.new(10, 3)
    s:put(1, 1, "abc", "default")
    s:put(1, 2, "中文", "cyan")
    s:line(3, "status", "reverse", 10)
    local txt = s:snapshot_text()
    check(txt:find("abc", 1, true) == 1, "tui screen put")
    check(txt:find("中文", 1, true) ~= nil, "tui screen cjk")
    check(txt:find("status", 1, true) ~= nil, "tui screen line")
    local frame = s:render()
    check(frame:find("\27[1;1H", 1, true) ~= nil, "tui screen render")
    s:invalidate()
    check(s.prev[1] == nil, "tui screen invalidate")
end

-- tui transcript
do
    local T = require("tui.transcript")
    local S = require("tui.screen")
    local t = T.new()
    t:add("user", "hi")
    t:stream_append("hello ")
    t:stream_append("world")
    t:end_stream()
    t:reasoning_append("think carefully")
    t:end_reasoning()
    t:tool_start("bash", { command = "echo hi" })
    t:tool_result("bash", "hi")
    t:tool_start("edit", { path = "a.txt" })
    t:tool_result("edit", "edited a.txt\ndiff --git a/a.txt b/a.txt\n"
        .. "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-world\n+lite")
    local function line_text(l)
        if l.text then return l.text end
        local s = {}
        for _, c in ipairs(l.cells or {}) do s[#s + 1] = c.text end
        return table.concat(s)
    end

    local lines = t:build_lines(40)
    check(#lines > 0, "tui transcript lines")
    local saw_diff = false
    for _, l in ipairs(lines) do
        if line_text(l):find("-world", 1, true) then saw_diff = true end
    end
    check(saw_diff, "tui transcript diff expand")
    local found = false
    for _, l in ipairs(lines) do
        if line_text(l):find("hello world", 1, true) then found = true end
    end
    check(found, "tui transcript stream")
    local saw_reason = false
    for _, l in ipairs(lines) do
        if line_text(l):find("think carefully", 1, true) and l.style == "gray" then
            saw_reason = true
        end
    end
    check(saw_reason, "tui transcript reasoning")
    check(t:build_lines(40) == lines, "tui transcript cache")
    t:reasoning_append(".")
    check(t:build_lines(40) ~= lines, "tui transcript cache invalidate")

    t:add("queued", "later")
    local qlines = t:build_lines(40)
    local saw_queued = false
    for _, l in ipairs(qlines) do
        if line_text(l):find("⏳ later", 1, true) then saw_queued = true end
    end
    check(saw_queued, "tui transcript queued")
    t.blocks[#t.blocks].kind = "user"
    local ulines = t:build_lines(40)
    local saw_user = false
    for _, l in ipairs(ulines) do
        if line_text(l):find("› later", 1, true) then saw_user = true end
    end
    check(saw_user, "tui transcript queued becomes user")

    local s = S.new(30, 6)
    t:render(s, 1, 1, 30, 4)
    check(t.total > 0, "tui transcript render total")
    t:scroll_up(2)
    check(t.scroll >= 0, "tui transcript scroll")
end

-- agent coroutine
do
    local Context = require("context")
    local Agent = require("core.agent")
    local ctx = Context.new({ cwd = "/tmp", max_turns = 2 })
    local provider = {
        stream_async = function(_, _, _, on_delta)
            on_delta("hi")
            local a, e = coroutine.yield({ kind = "http", req = { fake = true } })
            return a, e
        end,
    }
    local tools = { schemas = function() return {} end, execute = function() end }
    local session = { append = function() end }
    local agent = Agent.new(ctx, provider, tools, session)
    local co = agent:run_async("x")
    local ok, y = coroutine.resume(co)
    check(ok and y and y.kind == "http", "agent async yield")
    local ok2, y2 = coroutine.resume(co, { role = "assistant", content = "done" }, nil)
    check(ok2 and coroutine.status(co) == "dead", "agent async done")
    check(y2 == "done", "agent async answer")
end

-- tui diff parse / pair / intraline
do
    local D = require("tui.diff")
    local patch = table.concat({
        "diff --git a/foo.lua b/foo.lua",
        "index 111..222 100644",
        "--- a/foo.lua",
        "+++ b/foo.lua",
        "@@ -1,3 +1,4 @@",
        " local a = 1",
        "-local b = 2",
        "+local b = 3",
        "+local c = 4",
        " return a",
    }, "\n") .. "\n"

    local files = D.parse(patch)
    check(#files == 1, "diff parse files")
    check(files[1].path == "foo.lua", "diff parse path")
    check(files[1].additions == 2 and files[1].deletions == 1, "diff parse counts")
    check(#files[1].hunks == 1, "diff parse hunks")

    local rows = D.pair(files[1].hunks[1])
    check(#rows == 4, "diff pair rows")
    check(rows[1].kind == "ctx", "diff pair ctx")
    check(rows[2].kind == "change"
        and rows[2].left.text == "local b = 2"
        and rows[2].right.text == "local b = 3", "diff pair change")
    check(rows[3].kind == "add" and rows[3].right.text == "local c = 4", "diff pair add")
    check(rows[4].kind == "ctx", "diff pair tail ctx")

    local segs = D.intraline("local b = 2", "local b = 3")
    local ltxt, rtxt, lchg, rchg = "", "", false, false
    for _, s in ipairs(segs.left) do
        ltxt = ltxt .. s.text
        if s.changed then lchg = true end
    end
    for _, s in ipairs(segs.right) do
        rtxt = rtxt .. s.text
        if s.changed then rchg = true end
    end
    check(ltxt == "local b = 2", "diff intraline left")
    check(rtxt == "local b = 3", "diff intraline right")
    check(lchg and rchg, "diff intraline changed")

    local added = D.parse("diff --git a/new.txt b/new.txt\nnew file mode 100644\n"
        .. "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,1 @@\n+hi\n")
    check(added[1].status == "added" and added[1].additions == 1, "diff parse added")

    local renamed = D.parse("diff --git a/old.lua b/new.lua\nsimilarity index 90%\n"
        .. "rename from old.lua\nrename to new.lua\n")
    check(renamed[1].status == "renamed" and renamed[1].path == "new.lua", "diff parse rename")
end

-- diff layout / virtualization
do
    local D = require("tui.diff")
    local L = require("tui.diff_layout")
    local S = require("tui.screen")
    local patch = table.concat({
        "diff --git a/a.lua b/a.lua",
        "--- a/a.lua",
        "+++ b/a.lua",
        "@@ -1,3 +1,4 @@",
        " local x=1",
        "-old line",
        "+new line",
        "+added line",
        " tail",
    }, "\n") .. "\n"
    local files = D.parse(patch)

    local u = L.new(files, "unified", 60)
    check(u.total == 7 and #u.rows == 7, "diff layout unified rows")
    local idx, skip = u:row_at(3)
    check(idx ~= nil and idx >= 1 and skip >= 0, "diff layout row_at")
    check(u:next_hunk(0, 1) ~= nil, "diff layout next hunk")

    local sp = L.new(files, "split", 60)
    check(sp.left_w > 0 and sp.right_w > 0, "diff layout split widths")
    local s = S.new(60, 8)
    sp:render(s, 1, 1, 7, 0)
    local txt = s:snapshot_text()
    check(txt:find("│", 1, true) ~= nil, "diff layout split gutter")
    check(txt:find("old line", 1, true) ~= nil
        and txt:find("new line", 1, true) ~= nil, "diff layout split content")

    local parts = {
        "diff --git a/big b/big",
        "--- a/big",
        "+++ b/big",
        "@@ -1,10000 +1,10000 @@",
    }
    for i = 1, 10000 do parts[#parts + 1] = " line " .. i end
    local big = D.parse(table.concat(parts, "\n") .. "\n")
    local t0 = os.clock()
    local bl = L.new(big, "unified", 80)
    local dt = os.clock() - t0
    check(bl.total >= 10000, "diff layout big total")
    check(bl:row_at(9000) ~= nil, "diff layout big row_at")
    check(dt < 5, "diff layout big build time")
end

-- diff view
do
    local D = require("tui.diff")
    local V = require("tui.diff_view")
    local S = require("tui.screen")
    local patch = table.concat({
        "diff --git a/a.lua b/a.lua",
        "--- a/a.lua",
        "+++ b/a.lua",
        "@@ -1,3 +1,4 @@",
        " local x=1",
        "-old line",
        "+new line",
        "+added line",
        " tail",
    }, "\n") .. "\n"
    local files = D.parse(patch)

    local v = V.new(files, { width = 120, height = 10, mode = "split" })
    check(v.mode == "split", "diff view split")
    v:handle({ key = "tab" })
    check(v.mode == "unified", "diff view toggle unified")
    v:handle({ key = "tab" })
    check(v.mode == "split", "diff view toggle split")
    check(v:handle({ key = "char", text = "q" }) == "close", "diff view close")
    check(v:handle({ key = "escape" }) == "close", "diff view escape")

    local narrow = V.new(files, { width = 80, height = 10, mode = "split" })
    check(narrow.mode == "unified", "diff view narrow unified")
    narrow:handle({ key = "tab" })
    check(narrow.mode == "unified", "diff view narrow no split")

    local s = S.new(120, 10)
    v:render(s, 120, 10)
    local txt = s:snapshot_text()
    check(txt:find("DIFF", 1, true) ~= nil, "diff view render")
    check(txt:find("a.lua", 1, true) ~= nil, "diff view file header")
end

-- tui full screen snapshot
do
    local S = require("tui.screen")
    local T = require("tui.transcript")
    local C = require("tui.composer")
    local Status = require("tui.status")
    local Context = require("context")

    local ctx = Context.new({ cwd = "/tmp/demo", model = "deepseek-flash" })
    ctx.session.turn = 2

    local t = T.new()
    t:add("user", "hello")
    t:stream_append("world")
    t:end_stream()
    t:tool_start("bash", { command = "pwd" })
    t:tool_result("bash", "/tmp/demo")

    local c = C.new()
    c:insert("next question")

    local s = S.new(80, 20)
    t:render(s, 1, 1, 80, 14)
    c:render(s, 1, 15, 80, "default", 3)
    Status.render(s, 20, 80, ctx, { mem = 6, hits = 2, status = "idle" })

    local txt = s:snapshot_text()
    check(txt:find("hello", 1, true) ~= nil, "tui screen user")
    check(txt:find("world", 1, true) ~= nil, "tui screen assistant")
    check(txt:find("● bash", 1, true) ~= nil, "tui screen tool")
    check(txt:find("next question", 1, true) ~= nil, "tui screen composer")
    check(txt:find("mem:6 hit:2", 1, true) ~= nil, "tui screen status")
end

-- tui status memory hits
do
    local Status = require("tui.status")
    local S = require("tui.screen")
    local Context = require("context")
    local ctx = Context.new({ cwd = "/tmp", model = "m" })
    local s = S.new(80, 1)
    Status.render(s, 1, 80, ctx, {
        mem = 5,
        hits = 2,
        todos = {
            { content = "a", status = "completed" },
            { content = "b", status = "pending" },
        },
        queue = 3,
    })
    local txt = s:snapshot_text()
    check(txt:find("hit:2", 1, true) ~= nil, "tui status memory hits")
    check(txt:find("todo:1/2", 1, true) ~= nil, "tui status todos")
    check(txt:find("queue:3", 1, true) ~= nil, "tui status queue")
end

-- tui todo view
do
    local V = require("tui.todo_view")
    local S = require("tui.screen")
    local v = V.new({
        { content = "a", status = "completed" },
        { content = "b", status = "pending" },
    }, { width = 40, height = 6 })
    local s = S.new(40, 6)
    v:render(s, 40, 6)
    local txt = s:snapshot_text()
    check(txt:find("TODOS", 1, true) ~= nil, "todo view header")
    check(txt:find("[x] a", 1, true) ~= nil, "todo view completed")
    check(txt:find("[ ] b", 1, true) ~= nil, "todo view pending")
    check(v:handle({ key = "char", text = "q" }) == "close", "todo view close")
end

-- tui markdown
do
    local MD = require("tui.markdown")
    local lines = MD.render(table.concat({
        "# Title",
        "",
        "```lua",
        "print(1)",
        "```",
        "- item **bold** `code`",
    }, "\n"))

    local has_heading, has_code, has_bold, has_inline = false, false, false, false
    for _, line in ipairs(lines) do
        for _, seg in ipairs(line.segs or {}) do
            if seg.style == "heading" and seg.text:find("Title", 1, true) then has_heading = true end
            if seg.style == "code_block" and seg.text:find("print", 1, true) then has_code = true end
            if seg.style == "bold" and seg.text == "bold" then has_bold = true end
            if seg.style == "code" and seg.text == "code" then has_inline = true end
        end
    end
    check(has_heading and has_code and has_bold and has_inline, "tui markdown render")

    local cells = MD.wrap(lines[#lines], 20)
    local plain = {}
    for _, c in ipairs(cells[1] or {}) do plain[#plain + 1] = c.text end
    check(table.concat(plain):find("item", 1, true) ~= nil, "tui markdown wrap")

    local T = require("tui.transcript")
    local t = T.new()
    t:stream_append("# Hi\n\n```lua\nx=1\n```")
    t:end_stream()
    local tl = t:build_lines(40)
    local heading, code = false, false
    for _, line in ipairs(tl) do
        if line.cells then
            local s, styles = {}, {}
            for _, c in ipairs(line.cells) do
                s[#s + 1] = c.text
                styles[c.style] = true
            end
            local text = table.concat(s)
            if text:find("Hi", 1, true) and styles.heading then heading = true end
            if text:find("x=1", 1, true) and styles.code_block then code = true end
        end
    end
    check(heading and code, "tui transcript markdown")
end

-- session recent ids
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local Context = require("context")
    local Session = require("core.session")

    local ctx = Context.new({ cwd = "/tmp", id = "s1" })
    local s1 = Session.new(ctx, { dir = dir })
    s1:append({ role = "system", content = "<cwd>\n/tmp\n</cwd>" })
    s1:append({ role = "user", content = "one" })
    local s2 = Session.new(ctx, { dir = dir, id = "s2" })
    s2:append({ role = "system", content = "<cwd>\n/tmp\n</cwd>" })
    s2:append({ role = "user", content = "two" })

    local ids = Session.recent_ids(dir, 5)
    local seen = {}
    for _, id in ipairs(ids) do seen[id] = true end
    check(seen.s1 and seen.s2, "session recent ids")
    local loaded = s1:load()
    check(#loaded == 2 and loaded[2].content == "one", "session load")
    local clean = Session.clean(loaded)
    check(#clean == 1 and clean[1].content == "one", "session clean")
    check(#Session.for_cwd("/tmp", 5, dir) == 2, "session for cwd")
    check(#Session.for_cwd("/other", 5, dir) == 0, "session for cwd mismatch")
    check(type(Session.new_id()) == "string", "session new id")
    os.execute("rm -rf " .. shq(dir))
end

-- Session.from_memory: 恢复只认 mem.bin；KV 空时即使全局 JSONL 有同名会话也不返回
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local Context = require("context")
    local Session = require("core.session")
    local Memory = require("core.memory")
    local ctx = Context.new({ cwd = "/tmp/kvonly", id = "kv1" })

    -- 只写 JSONL，不写 KV
    local s = Session.new(ctx, { dir = dir, id = "kv1" })
    s:append({ role = "system", content = "<cwd>\n/tmp/kvonly\n</cwd>" })
    s:append({ role = "user", content = "jsonl only" })

    local mem = Memory.new({ dir = dir, max_mb = 32 })
    check(mem ~= nil, "from_memory: memory open")
    if mem then
        check(Session.from_memory(mem, "/tmp/kvonly", 5) == nil,
            "from_memory: ignores jsonl only")
        mem:close()
    end
    os.execute("rm -rf " .. shq(dir))
end

-- session for_cwd: 父目录不得命中子目录的会话（子串匹配的老 bug）
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local Context = require("context")
    local Session = require("core.session")

    local ctx = Context.new({ cwd = "/tmp/proj", id = "p1" })
    -- 有 <cwd> 段：精确比对
    local a = Session.new(ctx, { dir = dir, id = "p1" })
    a:append({ role = "system", content = "x\n<cwd>\n/tmp/proj\n</cwd>" })
    a:append({ role = "user", content = "hi" })
    -- 老会话没有 <cwd> 段：退回边界匹配
    local b = Session.new(ctx, { dir = dir, id = "p2" })
    b:append({ role = "system", content = "workdir is /tmp/proj now" })
    b:append({ role = "user", content = "yo" })

    check(#Session.for_cwd("/tmp/proj", 5, dir) == 2, "session cwd exact")
    check(#Session.for_cwd("/tmp/proj/", 5, dir) == 2, "session cwd trailing slash")
    check(#Session.for_cwd("/tmp", 5, dir) == 0, "session cwd parent not matched")
    check(#Session.for_cwd("/tmp/pro", 5, dir) == 0, "session cwd prefix not matched")
    os.execute("rm -rf " .. shq(dir))
end

-- session messages / todos in KV
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local Memory = require("core.memory")
    local Context = require("context")
    local Session = require("core.session")
    local Todos = require("core.todos")

    local mem = assert(Memory.new({ dir = dir, max_mb = 16 }))
    local ctx = Context.new({ cwd = "/tmp", id = "kv1" })
    mem:ensure_session("kv1", "/tmp", "m")

    local s = Session.new(ctx, { dir = dir, memory = mem })
    s:append({ role = "user", content = "hi" })
    s:append({
        role = "assistant", content = "ok",
        tool_calls = { { id = "c1", type = "function",
            ["function"] = { name = "bash", arguments = "{}" } } },
    })
    local msgs = mem:session_messages("kv1", 10)
    check(#msgs == 2 and msgs[2].tool_calls and msgs[2].tool_calls[1].id == "c1",
        "session messages kv")
    check(mem:session_message_count("kv1") == 2, "session message count")
    s:append({ role = "user", content = "third" })
    check(mem:session_message_count("kv1") == 3, "session message count tail")
    local tail = mem:session_messages("kv1", 2)
    check(#tail == 2 and tail[2].content == "third", "session messages tail")

    local t = Todos.new(ctx, mem)
    t:set({ { content = "a", status = "pending" } })
    check(#ctx.session.todos == 1, "todos session set")
    ctx.session.id = "kv2"
    mem:ensure_session("kv2", "/tmp", "m")
    Todos.new(ctx, mem)
    check(#ctx.session.todos == 0, "todos session isolated")
    mem:close()
    os.execute("rm -rf " .. shq(dir))
end

-- session input queue
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local Memory = require("core.memory")
    local Inputs = require("core.inputs")

    local mem = assert(Memory.new({ dir = dir, max_mb = 16 }))
    local q = Inputs.new(mem, "sid")
    local k1 = q:add("one")
    q:add("two")
    local items = q:load()
    check(#items == 2 and items[1].text == "one" and items[2].text == "two",
        "inputs load")
    q:remove(k1)
    local items2 = Inputs.new(mem, "sid"):load()
    check(#items2 == 1 and items2[1].text == "two", "inputs remove")
    mem:close()
    os.execute("rm -rf " .. shq(dir))
end

-- tui complete / help
do
    local C = require("tui.complete")
    local token, start = C.token("edit src/ma", 12)
    check(token == "src/ma" and start == 6, "complete token")
    local matches, common = C.candidates({ "a.txt", "abc.txt", "src/" }, "a")
    check(#matches == 2 and common == "a", "complete candidates")

    local Composer = require("tui.composer")
    local c = Composer.new()
    c:insert("src/ma")
    c:replace_token(1, "src/main.lua")
    check(c:get_text() == "src/main.lua", "composer replace token")

    local V = require("tui.help_view")
    local S = require("tui.screen")
    local v = V.new({ width = 40, height = 10 })
    local s = S.new(40, 10)
    v:render(s, 40, 10)
    local txt = s:snapshot_text()
    check(txt:find("HELP", 1, true) ~= nil and txt:find("Ctrl+G", 1, true) ~= nil, "help view render")
    check(v:handle({ key = "char", text = "?" }) == "close", "help view close")

    local SV = require("tui.session_view")
    local sv = SV.new({
        { id = "s1", preview = "hello" },
        { id = "s2", preview = "world" },
    }, { current = "s1", width = 40, height = 8 })
    local ss = S.new(40, 8)
    sv:render(ss, 40, 8)
    local st = ss:snapshot_text()
    check(st:find("SESSIONS", 1, true) ~= nil
        and st:find("+ New session", 1, true) ~= nil, "session view render")
    local r = sv:handle({ key = "enter" })
    check(r and r.action == "select" and r.id == "s1", "session view select")
    local r2 = SV.new({}, { current = nil, width = 40, height = 8 }):handle({ key = "enter" })
    check(r2 and r2.action == "new", "session view new")
end

-- tui snapshot
do
    local Snap = require("tui.snapshot")
    local Context = require("context")
    local ctx = Context.new({ cwd = "/tmp", model = "m" })
    local txt = Snap.render(ctx, {
        messages = {
            { role = "user", content = "hi" },
            { role = "assistant", content = "hello" },
        },
        text = "draft",
        width = 50,
        height = 12,
    })
    check(txt:find("lite TUI", 1, true) ~= nil, "tui snapshot hint")
    check(txt:find("hi", 1, true) ~= nil and txt:find("hello", 1, true) ~= nil,
        "tui snapshot transcript")
    check(txt:find("draft", 1, true) ~= nil, "tui snapshot composer")
end

-- scheduler (unattended wake)
do
    local S = require("core.scheduler")
    local fired, last_run = 0, nil
    local s = S.new({
        every = 10,
        task = "check ci",
        start_at = 100,
        can = function() return true end,
        submit = function(_, run) fired = fired + 1; last_run = run end,
    })
    check(s:tick(105) == false, "scheduler not due")
    check(s:tick(110) == true and fired == 1 and last_run == 1, "scheduler due")
    check(s:tick(110) == false, "scheduler no duplicate")
    check(s:tick(125) == true and fired == 2, "scheduler next")
    s.max_runs = 2
    check(s:tick(140) == false, "scheduler max runs")
    local p = s:build_prompt(3)
    check(p:find("Task: check ci", 1, true) ~= nil
        and p:find("Scheduled wake #3", 1, true) ~= nil, "scheduler prompt")

    local blocked = S.new({
        every = 1, task = "x", start_at = 0,
        can = function() return false end,
        submit = function() error("should not submit") end,
    })
    check(blocked:tick(10) == false, "scheduler blocked")
end

-- scheduler persistence
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local Memory = require("core.memory")
    local S = require("core.scheduler")

    local mem = assert(Memory.new({ dir = dir, max_mb = 16 }))
    local s = S.new({
        every = 5, task = "x", start_at = 0, memory = mem,
        can = function() return true end, submit = function() end,
    })
    s:tick(5)
    s:set_answer("done")
    mem:close()

    local mem2 = assert(Memory.new({ dir = dir, max_mb = 16 }))
    local s2 = S.new({ every = 5, task = "x", start_at = 0, memory = mem2 })
    s2:load()
    check(s2.runs == 1 and s2.last_answer == "done", "scheduler persisted")
    mem2:close()
    os.execute("rm -rf " .. shq(dir))
end

-- entry
check(loadfile(root .. "/lua/main.lua") ~= nil, "load lua/main.lua")

print(string.format("[unit] %d ok, %d fail", ok, fail))
os.exit(fail == 0 and 0 or 1)
