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
    check(cfg.max_turns == 256, "config default max_turns")
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

    -- usage：DeepSeek 把用量放在流末尾的独立 chunk 里，那条 choices 是空数组。
    -- 旧实现只处理 choices[1]，整条 usage 被丢掉 → 命中率无从观测。
    local pu = P.new_parser()
    local usage_events = 0
    local seen
    for _, c in ipairs({
        chunk({ choices = { { delta = { content = "hi" } } } }),
        chunk({ choices = { { delta = {}, finish_reason = "stop" } } }),
        chunk({ choices = {}, usage = {
            prompt_tokens = 12000, completion_tokens = 30, total_tokens = 12030,
            prompt_cache_hit_tokens = 11000, prompt_cache_miss_tokens = 1000,
        } }),
    }) do
        for _, ev in ipairs(P.feed(pu, c)) do
            if ev.type == "usage" then
                usage_events = usage_events + 1
                seen = ev.usage
            end
        end
    end
    check(usage_events == 1, "provider usage event once")
    check(seen and seen.prompt == 12000, "provider usage prompt")
    check(seen and seen.cache_hit == 11000, "provider usage cache hit")
    check(seen and seen.cache_miss == 1000, "provider usage cache miss")
    check(P.finish(pu).content == "hi", "provider usage chunk does not break content")

    -- OpenAI 风格的 prompt_tokens_details.cached_tokens 也要认
    local pu2 = P.new_parser()
    for _, ev in ipairs(P.feed(pu2, chunk({ choices = {}, usage = {
        prompt_tokens = 5000, completion_tokens = 1,
        prompt_tokens_details = { cached_tokens = 4000 },
    } }))) do
        if ev.type == "usage" then seen = ev.usage end
    end
    check(seen and seen.cache_hit == 4000 and seen.cache_miss == 1000,
        "provider usage openai style")
end

-- usage 累积与命中率
do
    local Ctx = require("context")
    local ctx = Ctx.new({ api_key = "x" })
    check(ctx:cache_ratio() == nil, "cache_ratio nil when unused")
    check(type(ctx.settings.on_usage) == "function", "on_usage wired")
    ctx:add_usage({ prompt = 12000, completion = 30, cache_hit = 11000, cache_miss = 1000 })
    ctx:add_usage({ prompt = 8000, completion = 10, cache_hit = 0, cache_miss = 8000 })
    local s = ctx.session.usage
    check(s.requests == 2, "usage requests accumulated")
    check(s.prompt == 20000 and s.completion == 40, "usage tokens accumulated")
    check(s.cache_hit == 11000 and s.cache_miss == 9000, "usage cache accumulated")
    local r = ctx:cache_ratio()
    check(r and math.abs(r - 0.55) < 1e-9, "cache_ratio value")
    -- 缺 cache_miss 字段时按 prompt-hit 推
    ctx:add_usage({ prompt = 1000, cache_hit = 250 })
    check(ctx.session.usage.cache_miss == 9750, "usage miss derived from prompt")
end

-- 可复用前缀命中率：hit / min(上一轮 prompt, 本轮 prompt)
-- 这是"前缀有没有位移"的口径；cache_ratio 会被新增的工具输出稀释。
do
    local Ctx = require("context")

    local function fresh()
        local seen = {}
        local ctx = Ctx.new({ api_key = "x" })
        ctx:on("prefix_drop", function(d) seen[#seen + 1] = d end)
        return ctx, seen
    end

    local ctx, drops = fresh()
    -- 首轮没有"上一轮"，无法判断可复用前缀
    ctx:add_usage({ prompt = 10000, cache_hit = 0, cache_miss = 10000 })
    check(ctx.session.usage.prefix_denom == 0, "prefix denom 0 on first request")
    check(ctx:prefix_ratio() == nil, "prefix_ratio nil on single request")
    check(#drops == 0, "no prefix warning on first request")

    -- 第二轮：前缀 10000 全命中，新增 3000 按 miss 计价。
    -- cache_ratio 只有 71%，但前缀其实完全复用。
    ctx:add_usage({ prompt = 13000, cache_hit = 10000, cache_miss = 3000 })
    local one = ctx.session.usage.prefix_denom
    check(one == 10000, "prefix denom = min(prev, now)")
    check(ctx.session.usage.prefix_hit == 10000, "prefix hit capped by denom")
    check(ctx:prefix_ratio() == 1, "prefix_ratio perfect reuse")
    local cr = ctx:cache_ratio()
    check(cr and math.abs(cr - (10000 / 23000)) < 1e-9, "cache_ratio diluted by new tokens")
    check(#drops == 0, "no prefix warning when prefix reused")

    -- 上一轮比本轮长（压缩/裁剪）：分母取本轮
    local ctx2 = fresh()
    ctx2:add_usage({ prompt = 40000, cache_hit = 0, cache_miss = 40000 })
    ctx2:add_usage({ prompt = 8000, cache_hit = 7900, cache_miss = 100 })
    check(ctx2.session.usage.prefix_denom == 8000, "prefix denom = now when now smaller")
    check(ctx2:prefix_ratio() == 7900 / 8000, "prefix_ratio uses now as denom")

    -- 前缀真坏了：只有 20% 命中，且超过告警门槛 → 每个 turn 只报一次
    local ctx3, drops = fresh()
    ctx3.session.turn = 5
    ctx3:add_usage({ prompt = 20000, cache_hit = 0, cache_miss = 20000 })
    ctx3:add_usage({ prompt = 20000, cache_hit = 4000, cache_miss = 16000 })
    check(#drops == 1, "prefix drop warned once")
    local d = drops[1]
    check(d and math.abs(d.ratio - 0.2) < 1e-9, "prefix drop ratio")
    check(d and d.prev_prompt == 20000 and d.prompt == 20000, "prefix drop prompts recorded")
    ctx3:add_usage({ prompt = 20000, cache_hit = 4000, cache_miss = 16000 })
    check(#drops == 1, "prefix drop warned at most once per turn")
    ctx3.session.turn = 6
    ctx3:add_usage({ prompt = 20000, cache_hit = 4000, cache_miss = 16000 })
    check(#drops == 2, "prefix drop warns again on the next turn")

    -- 短会话（低于 PREFIX_WARN_MIN_PROMPT）不告警，避免启动时噪音
    local ctx4, drops = fresh()
    ctx4:add_usage({ prompt = 500, cache_hit = 0, cache_miss = 500 })
    ctx4:add_usage({ prompt = 500, cache_hit = 0, cache_miss = 500 })
    check(ctx4:prefix_ratio() == 0, "prefix_ratio 0 when nothing reused")
    check(#drops == 0, "no prefix warning for short prompts")
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

-- 循环被迫结束：收尾请求（不带 tools）+ 重复调用熔断
do
    local Context = require("context")
    local Agent = require("core.agent")

    -- 1) max_turns 用尽：最后一次请求不要 tools，且结论落地
    local ctx = Context.new({ cwd = "/tmp", max_turns = 3 })
    local reqs, events, results = {}, {}, {}
    local provider = {
        stream = function(msgs, tools)
            reqs[#reqs + 1] = { tools = tools, n = #msgs, last = msgs[#msgs] }
            if tools then
                return {
                    role = "assistant", content = "",
                    tool_calls = { {
                        id = "c" .. #reqs, type = "function",
                        ["function"] = { name = "bash", arguments = '{"command":"ls"}' },
                    } },
                }
            end
            return { role = "assistant", content = "总结：已看目录，下一步装依赖。" }
        end,
    }
    local tool_seq = 0
    local tools = {
        schemas = function() return { { type = "function" } } end,
        execute = function(_, name, args)
            tool_seq = tool_seq + 1
            return "ok:" .. tostring(args.command) .. ":" .. tool_seq
        end,
    }
    local session = { append = function(_, m) results[#results + 1] = m end, save = function() end }
    ctx:on("turn_limit", function(info) events[#events + 1] = info end)
    local agent = Agent.new(ctx, provider, tools, session)
    local text, err = agent:run("hi")

    check(err == nil, "turn limit no error")
    check(text == "总结：已看目录，下一步装依赖。", "turn limit keeps conclusions")
    check(#reqs == 4, "turn limit one extra request")
    check(reqs[1].tools ~= nil and reqs[3].tools ~= nil, "turn limit tool requests have tools")
    check(reqs[4].tools == nil, "turn limit finalize without tools")
    check(reqs[4].last.role == "user" or reqs[4].last.role == "system", "turn limit finalize appends note")
    check(type(reqs[4].last.content) == "string"
        and reqs[4].last.content:find("used all 3 tool-loop turns", 1, true) ~= nil,
        "turn limit note explains why")
    check(reqs[4].last.content:find("用户原问题：hi", 1, true) ~= nil,
        "turn limit note includes original question")
    check(#events == 1 and events[1].turns == 3, "turn limit event")
    check(events[1] and events[1].reason:find("used all 3", 1, true) ~= nil, "turn limit reason")
    local last = ctx.session.messages[#ctx.session.messages]
    check(last.role == "assistant" and last.content == text, "turn limit answer is a session message")

    -- 2) 同一批工具调用连续重复 → 熔断，不等 max_turns
    local ctx2 = Context.new({ cwd = "/tmp", max_turns = 128 })
    local n2, ev2, final2 = 0, {}, nil
    local provider2 = {
        stream = function(msgs, tools)
            n2 = n2 + 1
            if tools then
                return {
                    role = "assistant", content = "",
                    tool_calls = { {
                        id = "x" .. n2, type = "function",
                        ["function"] = { name = "bash", arguments = '{"command":"sleep 1"}' },
                    } },
                }
            end
            final2 = "卡住了，我停下来汇报。"
            return { role = "assistant", content = final2 }
        end,
    }
    ctx2:on("turn_limit", function(info) ev2[#ev2 + 1] = info end)
    local agent2 = Agent.new(ctx2, provider2, tools, { append = function() end, save = function() end })
    local t2, e2 = agent2:run("go")
    check(e2 == nil and t2 == final2, "repeat breaker keeps conclusions")
    check(Agent.REPEAT_LIMIT == 4 and n2 == 5, "repeat breaker stops early")
    check(#ev2 == 1 and ev2[1].reason:find("repeated", 1, true) ~= nil, "repeat breaker reason")

    -- 3) 命令不同但结果相同 → 无进展熔断
    local ctx4 = Context.new({ cwd = "/tmp", max_turns = 64 })
    local n4, ev4, final4 = 0, {}, nil
    local provider4 = {
        stream = function(msgs, tools)
            n4 = n4 + 1
            if tools then
                return {
                    role = "assistant", content = "",
                    tool_calls = { {
                        id = "z" .. n4, type = "function",
                        ["function"] = { name = "bash", arguments = '{"command":"echo ' .. n4 .. '"}' },
                    } },
                }
            end
            final4 = "结果没有变化，停了。"
            return { role = "assistant", content = final4 }
        end,
    }
    local flat_tools = {
        schemas = function() return { { type = "function" } } end,
        execute = function() return "same output" end,
    }
    ctx4:on("turn_limit", function(info) ev4[#ev4 + 1] = info end)
    local agent4 = Agent.new(ctx4, provider4, flat_tools, { append = function() end, save = function() end })
    local t4, e4 = agent4:run("go")
    check(e4 == nil and t4 == final4, "result repeat breaker keeps conclusions")
    check(Agent.RESULT_REPEAT_LIMIT == 3 and n4 == 4, "result repeat breaker stops early")
    check(#ev4 == 1 and ev4[1].reason:find("result repeated", 1, true) ~= nil,
        "result repeat breaker reason")

    -- 4) 不同的工具调用不算卡住
    local ctx3 = Context.new({ cwd = "/tmp", max_turns = 6 })
    local n3, ev3 = 0, 0
    local provider3 = {
        stream = function(msgs, tools)
            n3 = n3 + 1
            if tools then
                return {
                    role = "assistant", content = "",
                    tool_calls = { {
                        id = "y" .. n3, type = "function",
                        ["function"] = { name = "bash", arguments = '{"command":"echo ' .. n3 .. '"}' },
                    } },
                }
            end
            return { role = "assistant", content = "done" }
        end,
    }
    ctx3:on("turn_limit", function(info)
        ev3 = ev3 + 1
        if info.reason:find("repeated", 1, true) then check(false, "distinct calls must not trip breaker") end
    end)
    local agent3 = Agent.new(ctx3, provider3, tools, { append = function() end, save = function() end })
    agent3:run("go")
    check(n3 == 7 and ev3 == 1, "distinct calls run to turn limit")
end

-- context_turns：作为近期尾巴的 user 轮数上限
do
    local Context = require("context")
    local Agent = require("core.agent")
    local Compact = require("core.compact")
    local ctx = Context.new({ cwd = "/tmp", context_chars = 20000, context_turns = 4 })
    ctx.session.messages = { { role = "system", content = "sys" } }
    for i = 1, 12 do
        ctx.session.messages[#ctx.session.messages + 1] = {
            role = "user", content = "question " .. i .. " " .. string.rep("x", 400),
        }
        ctx.session.messages[#ctx.session.messages + 1] = {
            role = "assistant", content = "answer " .. i .. " " .. string.rep("y", 400),
        }
    end
    local agent = Agent.new(ctx, {}, {}, {})
    local c = agent:compactor()
    check(c.tail_turn_cap == 4, "context_turns wired into tail turn cap")

    local p = c:plan(ctx.session.messages)
    local users = 0
    for i = p.start, #ctx.session.messages do
        if ctx.session.messages[i].role == "user" then users = users + 1 end
    end
    check(users <= 4, "tail respects context_turns turn cap")
    check(users >= 1, "tail keeps at least one turn")

    -- 尾巴受字符预算约束
    check(p.tail_chars <= c:tail_budget(p.avail) + 200, "tail respects char budget")

    -- 尾巴绝不以孤立的 tool 结果开头
    check(ctx.session.messages[p.start].role ~= "tool", "tail not orphan tool")
end

-- compact.lua 纯逻辑：尾巴对齐 / 用户原话预算 / 摘要输入裁剪
do
    local C = require("core.compact")
    local function mk(n)
        local m = { { role = "system", content = string.rep("s", 1500) }, { role = "user", content = "TASK" } }
        for i = 1, n do
            m[#m + 1] = { role = "user", content = "q" .. i .. " " .. string.rep("q", 200) }
            m[#m + 1] = { role = "assistant", content = "", tool_calls = { { id = "c" .. i,
                type = "function", ["function"] = { name = "bash", arguments = '{"command":"ls"}' } } } }
            m[#m + 1] = { role = "tool", tool_call_id = "c" .. i, content = string.rep("x", 1200) }
            m[#m + 1] = { role = "tool", tool_call_id = "c" .. i, content = string.rep("y", 1200) }
        end
        return m
    end
    local msgs = mk(30)

    -- 扫预算：尾巴永远不以 tool 开头
    local bad = 0
    for budget = 8000, 200000, 997 do
        local c = C.new({ budget_chars = budget })
        local p = c:plan(msgs)
        if p.ok and msgs[p.start].role == "tool" then bad = bad + 1 end
    end
    check(bad == 0, "compact tail never starts with tool result")

    local c = C.new({ budget_chars = 40000 })
    local p = c:plan(msgs)
    check(#p.kept_user > 0, "compact hoists user turns")
    local kept_chars = 0
    for _, m in ipairs(p.kept_user) do kept_chars = kept_chars + C.msg_chars(m) end
    check(kept_chars <= c:keep_user_budget(p.avail), "compact user turns within budget")

    -- 逐字保留的用户消息不能重复进摘要输入
    local text = c:serialize(p.region, p.keep)
    local dup = false
    for _, m in ipairs(p.kept_user) do
        if text:find(m.content, 1, true) then dup = true end
    end
    check(not dup, "compact does not duplicate hoisted user turns")

    -- 送摘要的 tool 结果要截断
    local longest = 0
    for line in text:gmatch("[^\n]+") do
        if line:find("^%[Tool result%]") then longest = math.max(longest, #line) end
    end
    check(longest <= c.summarize_tool_chars + 200, "compact clips tool results for summary")

    -- 地板值必须按预算夹住（小预算不能被绝对地板吃光）
    local tiny = C.new({ budget_chars = 2000 })
    check(tiny:keep_user_budget() <= 500, "keep_user budget clamped by window")
    check(tiny:tail_budget() <= math.floor(2000 / 2), "tail budget clamped by window")
    check(tiny:pin_cap() <= math.floor(2000 / 8), "pin cap clamped by window")

    -- 压缩后规模必须把**固定前缀**算进去，否则迟滞线低于实际大小，
    -- 下一条消息就再次触发压缩（每轮压一次，缓存全毁）。
    local seen_prompt
    local ok_fold = c:fold(msgs, function(_, prompt)
        seen_prompt = prompt
        return "## Goal\nx"
    end)
    check(ok_fold.ok, "compact fold ok")
    -- fold 必须真的把长度约束传下去，而不是只在 digest_prompt() 里存在
    check(seen_prompt and seen_prompt:find("Hard limit", 1, true) ~= nil,
        "compact fold passes length-constrained prompt")
    check(seen_prompt and seen_prompt:find(tostring(c:digest_max_chars()), 1, true) ~= nil,
        "compact fold prompt carries digest cap number")
    local pinned_chars = 0
    for i = 1, ok_fold.plan.head do pinned_chars = pinned_chars + C.msg_chars(msgs[i]) end
    check(pinned_chars > 0, "compact plan has pinned prefix")
    check(ok_fold.stats.after_chars >= pinned_chars,
        "compact after_chars includes pinned prefix")
    check(ok_fold.rearm_chars > ok_fold.stats.after_chars,
        "compact rearm is above post-fold size")

    -- 摘要失败要优雅降级，不能抛错
    local r = c:fold(msgs, function() return nil, "boom" end)
    check(not r.ok and tostring(r.reason):find("summarize failed", 1, true) ~= nil,
        "compact degrades on summarize failure")

    -- 摘要长度约束写进提示词（模型对具体数字敏感，对 "terse" 不敏感）
    check(c:digest_max_chars() >= 800, "compact digest cap floor")
    check(c:digest_prompt():find("Hard limit", 1, true) ~= nil,
        "compact digest prompt has hard limit")

    -- 摘要比折叠区小不了多少 => 拒绝检查点（净亏损，还多花一次调用）
    local huge_digest = string.rep("z", c:digest_max_chars() * 3)
    local rj = c:fold(msgs, function() return huge_digest end)
    check(not rj.ok and rj.rejected == true, "compact rejects oversized digest")

    -- 最新一条消息超大时，尾巴绝不能变成空的：丢掉它等于丢掉"刚才发生了什么"
    local big = { { role = "system", content = "sys" }, { role = "user", content = "TASK" } }
    for i = 1, 6 do
        big[#big + 1] = { role = "user", content = "u" .. i }
        big[#big + 1] = { role = "assistant", content = string.rep("A", 5000) }
        big[#big + 1] = { role = "tool", tool_call_id = "c" .. i, content = string.rep("T", 5000) }
    end
    local pc = C.new({ budget_chars = 12000 })
    local pb = pc:plan(big, { tail_scale = 1 })
    check(pb.ok, "compact plans with oversized tail messages")
    check(pb.start <= #big, "compact keeps the newest message in the tail")
    check(pb.tail_chars > 0, "compact tail is never empty")

    -- 单条 tool 结果本身就超预算：按 msg_cap 截一刀，且发出去的视图里
    -- 那条消息确实短了，原文不动
    local giant = string.rep("G", 18000)
    local gm = { { role = "system", content = "sys" }, { role = "user", content = "TASK" },
                 { role = "tool", tool_call_id = "g1", content = giant } }
    local gc = C.new({ budget_chars = 64000 })
    local gcap = gc:msg_cap()
    check(gcap > 0 and gcap < #giant, "compact msg_cap is below a huge tool result")
    local gp = gc:plan(gm, { tail_scale = 1 })
    check(gp.clip and gp.clip[3] == gcap, "compact plan clips a huge tool result")
    check(gp.clip_n == 1 and gp.clipped_chars == C.msg_chars(gm[3]) - gcap,
        "compact plan reports clipped chars")
    local gclips = gc:clips(gm)
    check(gclips and gclips[3] == gcap, "compact clips() maps absolute index")
    local gv = C.clip_message(gm[3], gclips[3])
    check(#gv.content <= gcap, "compact clip_message shrinks the tool result")
    check(gv.content:sub(1, 4) == "GGGG", "compact clip keeps the head")
    check(#gm[3].content == #giant, "compact clip leaves the original intact")
    check(gv.tool_call_id == "g1", "compact clip keeps tool_call_id")
    -- 非 tool 消息永不被截：assistant 的 tool_calls 是配对的，user 原话是约束
    local am = { { role = "system", content = "s" }, { role = "user", content = "TASK" },
                 { role = "assistant", content = giant },
                 { role = "user", content = giant } }
    check(gc:clips(am) == nil, "compact never clips assistant/user messages")
    -- 钉住的前缀不动
    local pm = { { role = "system", content = "s" }, { role = "user", content = "TASK" },
                 { role = "tool", tool_call_id = "p", content = giant } }
    check(gc:clips(pm)[3] == gcap, "compact clips tool messages after the pinned head")
    -- 截断标记要能指路（告诉模型重跑窄一点的命令）
    local clipped = C._clip_mid(giant, gcap)
    check(clipped:find("re-run the command narrower", 1, true) ~= nil,
        "compact clip marker tells the model what to do")

    -- 尾巴"没东西可折"时逐级缩小尾巴重试，并把试过的倍数报出来
    local short = { { role = "system", content = "s" }, { role = "user", content = "TASK" },
                    { role = "assistant", content = string.rep("A", 300) },
                    { role = "tool", tool_call_id = "c", content = string.rep("T", 300) } }
    local rs = pc:fold(short, function() return "## Goal\nx" end)
    check(not rs.ok, "compact refuses to fold a short session")
    check(tostring(rs.reason):find("tail scales tried", 1, true) ~= nil,
        "compact reports tail scales tried")
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

        -- 召回白名单：原始 transcript（/<sid>/msg/<seq>）和 <sid>/meta 不进 prompt。
        -- 旧行为会把 msg 的原始 JSON 当文本拼进记忆块，一条就吃掉整个字符预算。
        mem:ensure_session("s3", "/proj", "m")
        -- 真实 transcript 就是 session.lua append 写下的 /<sid>/msg/<seq> 原始 JSON；
        -- 直接写一条，避免白名单断言在「没有 msg 键」时空转成永真。
        mem:put("/agent/session", "s3/msg/00000001",
            { role = "user", content = "needle raw transcript" }, 0)
        mem:put("/agent/session", "s3/msg/00000002",
            { role = "assistant", content = "needle raw assistant" }, 0)
        mem:put("/agent/session", "s3/msg/00000003",
            { role = "tool", content = "needle raw tool output" }, 0)
        for i = 1, 4 do
            mem:remember_turn("s3", i, "needle question " .. i, "needle answer " .. i)
        end
        local ml = mem:recall("needle", 20)
        local msg_leak, meta_leak, no_kind, bad_text, turns, raw_user = false, false, false, false, 0, false
        for _, it in ipairs(ml) do
            if it.key:find("/msg/", 1, true) then
                if it.kind == "user" and it.text == "needle raw transcript" then
                    raw_user = true
                else
                    msg_leak = true
                end
            end
            if it.key:find("/meta", 1, true) then meta_leak = true end
            if not it.kind then no_kind = true end
            if it.text:find('{"role"', 1, true) or it.text:find('"content"', 1, true) then
                bad_text = true
            end
            if it.kind == "turn" then turns = turns + 1 end
        end
        check(not msg_leak, "recall whitelist: non-user raw transcript not injected")
        check(raw_user, "recall whitelist: user transcript preserved")
        check(not meta_leak, "recall whitelist: session meta not injected")
        check(not no_kind, "recall whitelist: every item tagged with kind")
        check(not bad_text, "recall whitelist: no raw json in item text")
        check(turns <= 2, "recall budget: at most 2 turns")

        -- 加权评分：事实(tag 命中高权重)排在轮次之前，轮次不再挤满记忆块。
        mem:remember_fact("needle-fact", "needle canonical fact text", { "needle" })
        mem:remember_turn("s3", 5, "needle", "needle")
        local wl = mem:recall("needle", 20)
        local first_fact = nil
        for i, it in ipairs(wl) do
            if it.kind == "fact" then first_fact = i break end
        end
        check(first_fact ~= nil and first_fact < 4, "recall weight: fact ranks before turns")
        check(mem:get("/agent/knowledge", "needle-fact") ~= nil, "recall weight: fact stored")

        -- 不可解析的 JSON（写一半 / 二进制尾巴）必须跳过，不能当文本注入。
        local fcache = require("ffi.cache")
        fcache.set(mem.h, "/agent/knowledge/broken-needle", '{"c":"needle half",', 0)
        local broken_seen, broken_raw = false, false
        for _, it in ipairs(mem:recall("needle", 20)) do
            if it.key:find("broken-needle", 1, true) then
                broken_seen = true
                broken_raw = it.text:find('{"c"', 1, true) ~= nil
            end
        end
        check(not broken_seen and not broken_raw, "recall: unparseable entry skipped")

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

        -- usage 落盘：进程一退，"这一晚发了多少请求、前缀命中多少"就没了。
        -- 只存累计值 + 上一轮 prompt，重开进程要能原样接回来。
        local memU = Memory.new({ dir = dir, max_mb = 32 })
        check(memU ~= nil, "usage: reopen for persist")
        if memU then
            check(memU:load_usage("s9") == nil, "usage: absent before save")
            local uok = memU:save_usage("s9", {
                requests = 12, prompt = 34000, completion = 900,
                cache_hit = 30000, cache_miss = 4000,
                prefix_hit = 29000, prefix_denom = 30000,
                last = { prompt = 2800, reuse = 0.98 },
            })
            check(uok == true, "usage: save writes")
            memU:close()
        end

        local memU2 = Memory.new({ dir = dir, max_mb = 32 })
        local u = memU2 and memU2:load_usage("s9")
        check(type(u) == "table" and u.requests == 12 and u.prompt == 34000
            and u.cache_hit == 30000 and u.last_prompt == 2800,
            "usage: survives reopen")

        -- 装回 context：累计值原样接回，last 只留上一轮 prompt 当分母。
        local Uctx = require("context")
        local c = Uctx.new({ api_key = "x" })
        c.session.id = "s9"
        check(c:restore_usage(u) == true, "usage: restore ok")
        check(c.session.usage.requests == 12 and c.session.usage.prompt == 34000,
            "usage: restore cumulative")
        check(c.session.usage.last and c.session.usage.last.prompt == 2800
            and c.session.usage.last.restored == true,
            "usage: restore keeps prev prompt")
        -- 接回后第一个请求就能算可复用前缀，不必两轮暖场：分母 += min(2800, 3000)。
        local denom0 = c.session.usage.prefix_denom
        check(denom0 == 30000, "usage: restore keeps cumulative prefix denom")
        c:add_usage({ prompt = 3000, cache_hit = 2700, cache_miss = 300 })
        check(c.session.usage.prefix_denom - denom0 == 2800,
            "usage: restored prev feeds denom")
        check(c.session.usage.last.prev_prompt == 2800, "usage: restored prev is visible")
        -- nil = 清空（切到新会话时不能带着别的会话的账）
        check(c:restore_usage(nil) == true, "usage: restore nil ok")
        check(c.session.usage.requests == 0 and c.session.usage.last == nil,
            "usage: restore nil clears")
        if memU2 then memU2:close() end

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

    -- 陈旧索引自愈：mem.idx 里的哈希节点指向已被覆盖（标记 DELETED）的条目时，
    -- 必须丢弃索引并按 pool 重建，而不是让 cache_get 返回 nil —— 这是记忆链断裂的根因。
    do
        local dir = dir .. "-staleidx"
        os.execute("mkdir -p " .. shq(dir))
        local mem = Memory.new({ dir = dir, max_mb = 32 })
        check(mem ~= nil, "staleidx: seed open")
        if mem then
            mem:remember_fact("keep", "v1", { "t" })
            mem:close()
        end
        local sf = io.open(dir .. "/mem.idx", "rb")
        local stale = sf and sf:read("*a") or ""
        if sf then sf:close() end
        check(#stale > 0, "staleidx: index file written")

        local mem2 = Memory.new({ dir = dir, max_mb = 32 })
        check(mem2 ~= nil, "staleidx: reopen for overwrite")
        if mem2 then
            mem2:remember_fact("keep", "v2", { "t" })
            mem2:close()
        end
        local wf = assert(io.open(dir .. "/mem.idx", "wb"))
        wf:write(stale)
        wf:close()

        local mem3 = Memory.new({ dir = dir, max_mb = 32 })
        check(mem3 ~= nil, "staleidx: reopen over stale index")
        if mem3 then
            local v = mem3:get("/agent/knowledge", "keep")
            check(v ~= nil, "staleidx: stale index discarded, entry readable")
            if v then
                check(v.c == "v2", "staleidx: rebuilt entry carries latest value")
            end
            mem3:close()
        end
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
                -- 「自己下载部署、拷到 dist」：copy 是真拷贝，models 是拷模型
                check(txt:find("copy)", 1, true) ~= nil
                    and txt:find("cp -f", 1, true) ~= nil,
                    "ort_link.sh can copy (not just symlink) into lib/")
                check(txt:find("install_models", 1, true) ~= nil
                    and txt:find("ppocr_keys_v1.txt", 1, true) ~= nil,
                    "ort_link.sh deploys OCR models")
                check(txt:find("paddleocr.bj.bcebos.com", 1, true) ~= nil,
                    "ort_link.sh tells where to download models")
            end

            -- README 依赖章节必须说清：默认不打包 + 自己下载部署 + 拷到 dist
            do
                local f = io.open(root .. "/README.md", "r")
                local txt = f and f:read("*a") or ""
                if f then f:close() end
                check(txt:find("默认不打包", 1, true) ~= nil,
                    "README says optional parts are not packaged")
                check(txt:find("models/ocr/", 1, true) ~= nil,
                    "README tells where to put OCR models")
                check(txt:find("ort_link.sh copy", 1, true) ~= nil,
                    "README tells how to deploy onnxruntime into dist")
                check(txt:find("329 MB", 1, true) ~= nil
                    or txt:find("329MB", 1, true) ~= nil,
                    "README documents the 329MB CUDA provider cost")
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
    -- 召回块追加在末尾，不插在中间：插在中间会把后续消息整体位移，
    -- 让 DeepSeek 的前缀缓存从插入点往后全部失效。
    check(mem_idx ~= nil and user_idx ~= nil, "agent memory injected")
    check(mem_idx > user_idx, "agent memory block goes last, not mid-conversation")
    check(mem_idx == #captured, "agent memory block is the final message")
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

-- system prompt 每轮只发一次：还没压过时 baseline=0，视图里第 1 条 system
-- 曾被重复追加一遍（整段 system 付两份输入 token）
do
    local Context = require("context")
    local Agent = require("core.agent")
    local ctx = Context.new({ cwd = "/tmp", max_turns = 1 })
    local got = nil
    local provider = {
        stream = function(msgs)
            got = msgs
            return { role = "assistant", content = "ok" }
        end,
    }
    local toolset = { schemas = function() return {} end, execute = function() end }
    local agent = Agent.new(ctx, provider, toolset, { append = function() end })
    agent:run("hi")
    check(got and #got == 2 and got[1].role == "system" and got[2].role == "user",
        "system prompt is sent once")
end

-- agent 上下文压缩：三段式（pinned prefix + digest + 近期尾巴）
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local Context = require("context")
    local Agent = require("core.agent")
    local Memory = require("core.memory")

    local mem = assert(Memory.new({ dir = dir, max_mb = 16 }))
    local ctx = Context.new({ cwd = "/tmp", context_chars = 8000, max_turns = 1 })
    -- 20 条 500 字的往返，折叠区必然超过 min_fold_chars
    for i = 1, 20 do
        ctx.session.messages[#ctx.session.messages + 1] = {
            role = "user", content = "question " .. i .. " " .. string.rep("x", 480),
        }
        ctx.session.messages[#ctx.session.messages + 1] = {
            role = "assistant", content = "answer " .. i .. " " .. string.rep("y", 480),
        }
    end

    local calls, captured, saw_prompt, saw_tools = 0, nil, nil, nil
    local provider = {
        stream = function(msgs, tools)
            calls = calls + 1
            if calls == 1 then
                -- 第一次是摘要调用：检查它拿到的提示词和 tools
                saw_prompt = msgs[1].content
                saw_tools = tools
                return { role = "assistant", content = "## Goal\ntest-digest" }
            end
            captured = msgs
            return { role = "assistant", content = "ok" }
        end,
    }
    local toolset = { schemas = function() return {} end, execute = function() end }
    local session = { append = function() end }
    local agent = Agent.new(ctx, provider, toolset, session, mem)
    local _, err = agent:run("latest question")
    check(err == nil, "compact run")

    -- 摘要用的是结构化小标题提示词，且**不带 tools**（省 schema token）
    check(saw_prompt and saw_prompt:find("## Standing facts", 1, true) ~= nil,
        "compact summary prompt is structured")
    check(saw_prompt and saw_prompt:find("Do NOT invent", 1, true) ~= nil,
        "compact summary prompt forbids invention")
    check(type(saw_tools) == "table" and #saw_tools == 0, "compact summary sends no tools")

    -- 状态落在 /compact，包含 baseline / digest / block
    local st = mem:get("/agent/session", ctx.session.id .. "/compact")
    check(type(st) == "table" and type(st.baseline) == "number",
        "compact state stored")
    check(st and st.digest == "## Goal\ntest-digest", "compact digest is model output")
    check(st and st.baseline >= 2, "compact baseline advanced")

    -- 注入的块紧跟 system，位置固定 => 前缀稳定、缓存可命中
    check(captured and captured[1].role == "system", "compact keeps system first")
    check(captured and type(captured[2].content) == "string"
        and captured[2].content:find("<session_context>", 1, true) ~= nil,
        "compact digest injected right after system")

    -- 被折叠的旧消息不能再出现在 prompt 里
    local leaked = false
    for _, m in ipairs(captured or {}) do
        if m.role == "user" and tostring(m.content):find("question 1 ", 1, true) then
            leaked = true
        end
    end
    check(not leaked, "compact does not resend folded messages")

    -- 单条消息超预算：只截 tool 结果的视图，原文不动
    -- 巨型 tool 结果整条塞进 prompt 会把窗口撑爆，压尾巴也救不回来
    do
        local Compactor = require("core.compact")
        local inst = Compactor.new({ budget_chars = 8000 })
        local huge = "line:1 ok\n" .. string.rep("z", 20000) .. "\nline:20000 boom\n"
        local msgs = {
            { role = "system", content = "sys" },
            { role = "user", content = "run it" },
            { role = "assistant", content = "", tool_calls = {
                { id = "c1", type = "function",
                    ["function"] = { name = "bash", arguments = "{}" } } } },
            { role = "tool", tool_call_id = "c1", content = huge },
            { role = "assistant", content = "done" },
        }
        local cap = inst:msg_cap()
        local clips = inst:clips(msgs)
        check(clips and clips[4] == cap, "compact clips oversized tool result")
        local view = Compactor.clip_message(msgs[4], cap)
        check(#view.content <= cap and #view.content > cap * 0.9,
            "clipped tool result fits the cap")
        check(view.content:find("line:1 ok", 1, true) ~= nil
            and view.content:find("truncated", 1, true) ~= nil
            and view.content:find("boom", 1, true) ~= nil,
            "clip keeps head and tail")
        check(#msgs[4].content == #huge and msgs[4].content == huge,
            "clip leaves the original message untouched")
        check(inst:clips({ msgs[1], msgs[2] }) == nil, "no clip without a tool result")
    end

    -- 第二轮不该再压（低频！重复压会打断缓存前缀）
    local before = calls
    local reask = function()
        calls = calls + 1
        return { role = "assistant", content = "## Goal\nsecond" }
    end
    agent:request_messages("another question", reask)
    check(calls == before, "compact is low frequency")

    mem:close()
    os.execute("rm -rf " .. shq(dir))
end

-- 预算地板：预算小于固定前缀的若干倍时自动抬高
-- 否则可分配空间连"折叠区 + 尾巴"都不够，每次压缩都 "nothing to fold"，
-- 一路滑到硬上限丢历史 —— 实测 budget 9000 时 prompt 8195 → 1231。
do
    local Context = require("context")
    local Agent = require("core.agent")
    local ctx = Context.new({ cwd = "/tmp", context_chars = 300, max_turns = 1 })
    for i = 1, 6 do
        ctx.session.messages[#ctx.session.messages + 1] = {
            role = "user", content = "question " .. i .. " " .. string.rep("x", 40),
        }
        ctx.session.messages[#ctx.session.messages + 1] = {
            role = "assistant", content = "answer " .. i .. " " .. string.rep("y", 40),
        }
    end
    local provider = {
        stream = function() return { role = "assistant", content = "ok" } end,
    }
    local toolset = { schemas = function() return {} end, execute = function() end }
    local agent = Agent.new(ctx, provider, toolset, { append = function() end })
    agent:ensure_system()

    local events = {}
    ctx:on("compact", function(info) events[#events + 1] = info end)
    local msgs = agent:request_messages("hi", provider.stream)

    local fixed = agent:fixed_prefix_chars()
    check(fixed > 0, "budget floor: fixed prefix measured")
    check(agent:compactor().budget >= fixed * 3, "budget floor: budget raised above fixed prefix")

    local raised = false
    for _, e in ipairs(events) do
        if e.reason == "budget raised" then raised = true end
    end
    check(raised, "budget floor: raise is reported")

    -- 抬高后不该再触发硬上限丢历史
    local hit_ceiling = false
    for _, e in ipairs(events) do
        if e.reason == "hard ceiling" then hit_ceiling = true end
    end
    check(not hit_ceiling, "budget floor: no hard ceiling after raise")
    local users = 0
    for _, m in ipairs(msgs) do if m.role == "user" then users = users + 1 end end
    check(users >= 6, "budget floor: history preserved")
end

-- 硬上限兜底：压缩救不回来时才丢最老消息，但**必须保住已有 digest**
do
    local Context = require("context")
    local Agent = require("core.agent")
    local ctx = Context.new({ cwd = "/tmp", context_chars = 9000, max_turns = 1 })
    local agent = Agent.new(ctx, { stream = function() end },
        { schemas = function() return {} end }, { append = function() end })
    agent:ensure_system()

    local view = {
        { role = "system", content = "SYSTEM-PROMPT" },
        { role = "system", content = "<session_context>\n## Goal\nDIGEST-MARKER\n</session_context>" },
    }
    for i = 1, 20 do
        view[#view + 1] = { role = "user", content = "q" .. i .. string.rep("x", 800) }
        view[#view + 1] = { role = "assistant", content = string.rep("a", 800) }
    end

    local out, trimmed, dropped = agent:hard_window(view, 6000)
    check(trimmed == true, "hard ceiling trims")
    check(dropped and dropped > 0, "hard ceiling reports dropped count")
    check(#out < #view, "hard ceiling shrinks prompt")

    local has_sys, has_digest = false, false
    for _, m in ipairs(out) do
        if m.content == "SYSTEM-PROMPT" then has_sys = true end
        if type(m.content) == "string" and m.content:find("DIGEST-MARKER", 1, true) then
            has_digest = true
        end
    end
    check(has_sys, "hard ceiling keeps system prompt")
    -- 丢掉 digest 等于白压一次，还让模型失去全部历史
    check(has_digest, "hard ceiling keeps existing digest")
    check(out[#out].role ~= "tool", "hard ceiling tail alignment")
end

-- chars→tokens 校准：用真实 usage 反推，不能纯靠经验值
do
    local C = require("core.compact")
    check(math.abs(C.tok_per_char(nil, 0, 0) - C.DEFAULT_TOK_PER_CHAR) < 1e-9,
        "tok_per_char falls back to default")
    local r1 = C.tok_per_char(nil, 10000, 3000)
    check(math.abs(r1 - 0.3) < 1e-9, "tok_per_char first observation")
    local r2 = C.tok_per_char(r1, 10000, 4000)
    check(r2 > r1 and r2 < 0.4, "tok_per_char smooths toward new observation")
    -- 离谱比例（图片占位、协议开销抖动）要丢掉，不能污染估算
    check(math.abs(C.tok_per_char(0.3, 10000, 999999) - 0.3) < 1e-9,
        "tok_per_char rejects absurd ratio")
end

-- agent 侧的 token 估算与探针
do
    local Context = require("context")
    local Agent = require("core.agent")
    local Compact = require("core.compact")
    local ctx = Context.new({ cwd = "/tmp", context_chars = 64000, max_turns = 1 })
    local agent = Agent.new(ctx, { stream = function() end },
        { schemas = function() return {} end }, { append = function() end })
    agent:ensure_system()
    check(agent:tok_per_char() == nil, "tok_per_char nil without usage")
    -- 没有校准数据时用经验值
    check(agent:estimate_tokens(3500) > 0, "estimate_tokens works without usage")

    -- 喂一条真实 usage：15000 字符 → 5000 tokens
    agent._last_request_chars = 15000
    ctx:add_usage({ prompt = 5000, completion = 1, cache_hit = 0, cache_miss = 5000 })
    local r = agent:tok_per_char()
    check(r and math.abs(r - 5000 / 15000) < 1e-9, "tok_per_char from real usage")
    check(agent:estimate_tokens(30000) == math.floor(30000 * r),
        "estimate_tokens uses calibration")
end

-- 前缀稳定性：工具轮之间只允许"追加"，不允许位移
-- 这是缓存命中率的硬约束；踩过的坑是召回块插在中间导致命中从 97% 掉到 31%。
do
    local Context = require("context")
    local Agent = require("core.agent")
    local ctx = Context.new({ cwd = "/tmp", context_chars = 64000, max_turns = 4 })

    local snaps = {}
    local provider = {
        stream = function(msgs)
            snaps[#snaps + 1] = msgs
            if #snaps == 1 then
                return { role = "assistant", content = "", tool_calls = { { id = "c1",
                    type = "function", ["function"] = { name = "bash", arguments = '{"command":"ls"}' } } } }
            end
            return { role = "assistant", content = "done" }
        end,
    }
    local toolset = {
        schemas = function() return {} end,
        execute = function() return "tool-output" end,
    }
    local memory = {
        context = function() return "<retrieved_memory>轮次相关记忆</retrieved_memory>" end,
        remember_turn = function() end,
        tick = function() end,
    }
    local agent = Agent.new(ctx, provider, toolset, { append = function() end }, memory)
    agent:run("do it")

    check(#snaps >= 2, "prefix stability: two requests captured")
    local a, b = snaps[1], snaps[2]
    -- a 的最后一条是召回块，b 的前 #a-1 条必须与 a 逐条相同
    local stable = #a - 1
    local same = true
    for i = 1, stable do
        if a[i] ~= b[i] then
            if a[i].role ~= b[i].role or a[i].content ~= b[i].content then same = false end
        end
    end
    check(same, "prefix stability: messages never shift between tool rounds")

    -- 召回块只能出现一次（首个请求），后续工具轮不再重复注入
    local blocks_in_b = 0
    for _, m in ipairs(b) do
        if m.role == "system" and type(m.content) == "string"
            and m.content:find("<retrieved_memory>", 1, true) then
            blocks_in_b = blocks_in_b + 1
        end
    end
    check(blocks_in_b == 0, "prefix stability: recall block not re-injected in tool rounds")
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

-- tui status prefix reuse
do
    local Status = require("tui.status")
    local S = require("tui.screen")
    local Context = require("context")
    local ctx = Context.new({ cwd = "/tmp", model = "m" })
    local s = S.new(80, 1)
    Status.render(s, 1, 80, ctx, { mem = 0, cache = 0.5, reuse = 0.97 })
    local txt = s:snapshot_text()
    check(txt:find("cache:50%", 1, true) ~= nil, "tui status cache pct")
    check(txt:find("reuse:97%", 1, true) ~= nil, "tui status prefix reuse pct")

    local s2 = S.new(80, 1)
    Status.render(s2, 1, 80, ctx, { mem = 0, cache = 0.5 })
    check(s2:snapshot_text():find("reuse:", 1, true) == nil, "tui status no reuse before 2nd turn")
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

-- session retention: raw transcript capped, old messages dropped
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. shq(dir))
    local Memory = require("core.memory")
    local Context = require("context")
    local Session = require("core.session")
    local mem = assert(Memory.new({ dir = dir, max_mb = 16 }))
    local ctx = Context.new({ cwd = "/tmp", id = "ret" })
    mem:ensure_session("ret", "/tmp", "m")
    local s = Session.new(ctx, {
        dir = dir, id = "ret", memory = mem,
        raw_keep = 3, tool_store_chars = 20, prune_every = 1,
    })
    s:append({ role = "user", content = "keep user forever" })
    for i = 1, 5 do
        s:append({ role = "tool", tool_call_id = "c" .. i,
            content = string.rep("x", 100) .. i })
    end
    local user = mem:get("/agent/session", "ret/msg/00000001")
    check(user and user.role == "user" and user.content == "keep user forever",
        "session user message retained")
    check(mem:get("/agent/session", "ret/msg/00000002") == nil, "session tool retention drop")
    local kept = mem:get("/agent/session", "ret/msg/00000004")
    check(kept and kept.role == "tool" and #kept.content < 100
        and kept.content:sub(-3) == "…", "session tool result clipped")
    local loaded = s:load()
    check(#loaded == 4, "session jsonl retains user + recent")
    local dropped = mem:prune_session_messages("ret", 2)
    check(dropped >= 1 and #mem:session_messages("ret", 10) == 3,
        "session prune messages")
    check(mem:get("/agent/session", "ret/msg/00000001") ~= nil, "session prune keeps user")
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

-- 工具输出裁剪：head+tail 双端保留
do
    local Tools = require("core.tools")
    check(type(Tools.limit_output) == "function", "limit_output exported")
    check(Tools.BASH_MAX_OUT >= 32 * 1024, "bash cap >= 32KB")

    -- 未超限时逐字节原样返回
    local small = "abc\ndef\n"
    check(Tools.limit_output(small, 1024) == small, "limit_output passthrough")

    -- 超限：头、尾、marker 都在；编译错误常出现在尾部
    local body = string.rep("HEAD\n", 500) .. string.rep("MID\n", 20000)
        .. "TAIL: error: undefined symbol foo\n"
    local out = Tools.limit_output(body, Tools.BASH_MAX_OUT)
    check(#out <= Tools.BASH_MAX_OUT + 200, "limit_output respects cap")
    check(out:sub(1, 4) == "HEAD", "limit_output keeps head")
    check(out:find("TAIL: error", 1, true) ~= nil, "limit_output keeps tail")
    check(out:find("truncated", 1, true) ~= nil, "limit_output marks truncation")
    check(#out < #body, "limit_output actually shrinks")
end

-- 状态栏缓存命中率
do
    local Status = require("tui.status")
    local Ctx = require("context")
    local ctx = Ctx.new({ api_key = "x" })
    local captured
    local screen = { line = function(_, _, text) captured = text end }
    Status.render(screen, 24, 120, ctx, { mem = 1, cache = 0.8712 })
    check(captured:find("cache:87%%") ~= nil, "status cache pct")
    Status.render(screen, 24, 120, ctx, { mem = 1 })
    check(captured:find("cache:", 1, true) == nil, "status hides unknown cache")

    -- 上下文占用：只有接近触发线（>=60%）才显示，避免状态栏噪声
    Status.render(screen, 24, 120, ctx, { mem = 1, ctxeng = { used = 40000, line = 54400 } })
    check(captured:find("ctx:74%%") ~= nil, "status shows context pressure")
    Status.render(screen, 24, 120, ctx, { mem = 1, ctxeng = { used = 5000, line = 54400 } })
    check(captured:find("ctx:", 1, true) == nil, "status hides low context pressure")
    Status.render(screen, 24, 120, ctx, { mem = 1, ctxeng = nil })
    check(captured:find("ctx:", 1, true) == nil, "status hides ctxeng without probe")
end

-- entry
check(loadfile(root .. "/lua/main.lua") ~= nil, "load lua/main.lua")

print(string.format("[unit] %d ok, %d fail", ok, fail))
os.exit(fail == 0 and 0 or 1)
