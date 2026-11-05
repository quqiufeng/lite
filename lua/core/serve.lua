-- lite serve：headless agent + TCP JSONL 事件广播；attach 客户端消费。
local cjson = require("cjson")
local Context = require("context")
local Tools = require("core.tools")
local Session = require("core.session")
local Provider = require("core.provider")
local Agent = require("core.agent")
local Memory = require("core.memory")
local http = require("core.http")
local net = require("core.net")
local Scheduler = require("core.scheduler")
local Inputs = require("core.inputs")
local Signal = require("core.signal")
local Text = require("core.text")

local M = {}

local VERSION = "0.1.1"
local REPLAY_MAX = 500

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function read_text(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a") or ""
    f:close()
    return s
end

local function git_diff(cwd)
    local function run(args)
        local p = io.popen("cd " .. shq(cwd) .. " && git --no-pager " .. args
            .. " 2>/dev/null", "r")
        if not p then return "" end
        local s = p:read("*a") or ""
        p:close()
        return s
    end
    local s = run("diff --no-color --no-ext-diff -U3")
    if s == "" then
        s = run("diff --cached --no-color --no-ext-diff -U3")
    end
    return s
end

function M.run(opts)
    opts = opts or {}
    local config = opts.config or require("core.config").load()
    local host = opts.host or "127.0.0.1"
    local port = tonumber(opts.port) or 8765

    local wake = tonumber(opts.wake) or tonumber(os.getenv("LITE_WAKE_SEC")) or 0
    local wake_max = tonumber(opts.max_runs) or tonumber(os.getenv("LITE_WAKE_MAX")) or 0
    local task = opts.task or os.getenv("LITE_WAKE_TASK")
    if not task or task == "" then
        local file = opts.task_file or os.getenv("LITE_WAKE_TASK_FILE")
        if (not file or file == "") and wake > 0 then
            file = tostring(config.cwd) .. "/.lite/wake.md"
        end
        if file and file ~= "" then task = read_text(file) end
    end
    if wake > 0 and (not task or task == "") then
        return nil, "--wake requires --task, --task-file, or .lite/wake.md"
    end

    if not config.api_key or config.api_key == "" then
        return nil, "missing DEEPSEEK_API_KEY"
    end

    local ctx = Context.new({
        cwd = config.cwd,
        model = config.model,
        base_url = config.base_url,
        api_key = config.api_key,
        temperature = config.temperature,
        max_turns = config.max_turns,
        context_chars = config.context_chars,
        context_turns = config.context_turns,
        thinking = config.thinking,
        reasoning_effort = config.reasoning_effort,
        max_retries = config.max_retries,
        approval = config.approval,
    })
    local memory, merr = Memory.new({
        dir = config.memory_dir or config.cwd,
        max_mb = config.memory_mb,
        flush_sec = config.memory_flush,
    })
    if not memory then return nil, merr end

    local multi, mlerr = http.multi_new()
    if not multi then
        memory:close()
        return nil, mlerr
    end
    ctx.settings.multi = multi
    local logger = require("core.debug").new(config.debug_log)
    if logger then ctx.settings.debug = logger end

    local restored_turn = 0
    for _, meta in ipairs(memory:list_sessions(config.cwd, 1)) do
        local msgs, max_turn = memory:session_messages(meta.id, 50)
        if #msgs > 0 then
            ctx.session.id = meta.id
            ctx.session.messages = msgs
            restored_turn = max_turn or meta.turns or 0
            break
        end
    end
    ctx.session.turn = restored_turn
    memory:ensure_session(ctx.session.id, config.cwd, config.model)

    local tools = Tools.new({
        cwd = config.cwd,
        memory = memory,
        ctx = ctx,
        sandbox = config.sandbox,
        sandbox_net = config.sandbox_net,
    })
    if tools.todos then tools.todos:load() end
    local msg_count = memory:session_message_count(ctx.session.id)
    local session = Session.new(ctx, {
        memory = memory,
        seq = math.max(#ctx.session.messages, msg_count),
    })
    local agent = Agent.new(ctx, Provider, tools, session, memory)

    local server, serr = net.listen(host, port)
    if not server then
        memory:close()
        http.multi_free(multi)
        return nil, serr
    end

    io.write(string.format("lite serve listening on %s:%d\n", server.host, server.port))
    io.write(string.format("PORT=%d\n", server.port))
    io.flush()

    local clients = {}
    local replay = {}
    local queue = {}
    local inputs = Inputs.new(memory, ctx.session.id)
    local busy = false
    local co, active_req
    local scheduler
    local pending_approval
    local active_proc
    local approval_seq = 0
    local approval_deadline
    local last_hits = 0

    local function encode(obj)
        local ok, s = pcall(cjson.encode, obj)
        return ok and s or nil
    end

    local function send_obj(fd, obj)
        local s = encode(obj)
        if s then net.send(fd, s .. "\n") end
    end

    local function broadcast(obj)
        local s = encode(obj)
        if not s then return end
        local line = s .. "\n"
        for fd in pairs(clients) do
            if not net.send(fd, line) then
                clients[fd] = nil
                net.close(fd)
            end
        end
    end

    local function push(ev)
        replay[#replay + 1] = ev
        if #replay > REPLAY_MAX then table.remove(replay, 1) end
        broadcast(ev)
    end

    ctx:on("delta", function(text) push({ type = "delta", text = text }) end)
    ctx:on("reasoning", function(text) push({ type = "reasoning", text = text }) end)
    ctx:on("assistant", function(msg)
        push({ type = "assistant", content = msg.content or "" })
    end)
    ctx:on("tool_start", function(name, args)
        push({ type = "tool_start", name = name, args = args })
    end)
    ctx:on("tool_result", function(name, result)
        push({ type = "tool_result", name = name, result = tostring(result or ""):sub(1, 8000) })
    end)
    ctx:on("error", function(err) push({ type = "error", error = tostring(err) }) end)
    ctx:on("status", function(status) push({ type = "status", status = status }) end)
    ctx:on("turn_start", function(turn) push({ type = "turn_start", turn = turn }) end)
    ctx:on("turn_end", function(turn) push({ type = "turn_end", turn = turn }) end)
    ctx:on("memory", function(items)
        last_hits = #(items or {})
        push({ type = "memory", hits = last_hits })
    end)
    ctx:on("todos", function(items)
        push({ type = "todos", items = items or {} })
    end)
    ctx:on("image", function(info)
        push({ type = "image", path = info.path, mime = info.mime })
    end)

    local function state_obj()
        local stats = memory:stats()
        return {
            type = "state",
            busy = busy,
            turn = ctx.session.turn,
            status = ctx.view.status,
            model = ctx.session.model,
            cwd = ctx.session.cwd,
            mem = stats.count or 0,
            hits = last_hits,
            todos = ctx.session.todos or {},
            queued = #queue,
            approval = pending_approval,
            wake = scheduler and {
                runs = scheduler.runs,
                every = scheduler.every,
                next_run = scheduler:next_run(),
                task = scheduler.task,
            } or nil,
        }
    end

    local start_next
    local resume_agent

    local function on_resume(ok, y)
        if not ok then
            busy = false
            co = nil
            active_req = nil
            if scheduler then scheduler:set_answer("error: " .. tostring(y)) end
            push({ type = "error", error = tostring(y) })
            memory:sync()
            push(state_obj())
            start_next()
            return
        end
        if coroutine.status(co) == "dead" then
            local answer = type(y) == "string" and y or ""
            if scheduler then scheduler:set_answer(answer) end
            busy = false
            co = nil
            active_req = nil
            memory:sync()
            push(state_obj())
            start_next()
            return
        end
        if type(y) == "table" and y.kind == "approval" then
            approval_seq = approval_seq + 1
            pending_approval = { id = approval_seq, name = y.name, args = y.args }
            approval_deadline = os.time() + 60
            push({ type = "approval", id = approval_seq, name = y.name, args = y.args })
        elseif type(y) == "table" and y.kind == "http" then
            active_req = y.req
        elseif type(y) == "table" and y.kind == "proc" then
            active_proc = y.proc
        end
    end

    resume_agent = function(a, e)
        if not co then return end
        local ok, y = coroutine.resume(co, a, e)
        on_resume(ok, y)
    end

    start_next = function()
        if busy or #queue == 0 then return end
        local item = table.remove(queue, 1)
        local text = type(item) == "table" and item.text or item
        if type(item) == "table" and item.seq then inputs:remove(item.seq) end
        busy = true
        co = agent:run_async(text)
        resume_agent()
    end

    local function submit(text, meta)
        if not text or text == "" then return end
        local seq = inputs:add(text)
        if not (meta and meta.quiet) then
            push({ type = "user", text = text })
        end
        queue[#queue + 1] = { seq = seq, text = text }
        start_next()
    end

    if wake > 0 then
        scheduler = Scheduler.new({
            every = wake,
            task = task,
            max_runs = wake_max,
            memory = memory,
            can = function() return not busy and #queue == 0 end,
            submit = function(prompt, run)
                push({ type = "wake", run = run, task = task })
                submit(prompt, { quiet = true })
            end,
        })
        scheduler:load()
        io.write(string.format("wake every %ds (max %s)\n", wake,
            wake_max > 0 and tostring(wake_max) or "unlimited"))
        io.flush()
    end

    local function cancel()
        if pending_approval then
            local p = pending_approval
            pending_approval = nil
            approval_deadline = nil
            push({ type = "approval_reply", id = p.id, decision = "reject" })
            resume_agent("reject")
            return
        end
        if active_proc then
            local out = active_proc:cancel()
            active_proc = nil
            resume_agent(out)
        elseif active_req and multi then
            http.cancel(multi, active_req)
            active_req = nil
            resume_agent(nil, "cancelled")
        elseif busy then
            push({ type = "info", text = "tool 执行中，无法中断" })
        end
    end

    local function handle_line(fd, line)
        local ok, obj = pcall(cjson.decode, line)
        if not ok or type(obj) ~= "table" then
            send_obj(fd, { type = "error", error = "bad json" })
            return
        end
        local t = obj.type
        if t == "submit" then
            submit(tostring(obj.text or ""))
        elseif t == "cancel" then
            cancel()
        elseif t == "approval" then
            if pending_approval and tonumber(obj.id) == pending_approval.id then
                local decision = tostring(obj.decision or "reject")
                if decision ~= "once" and decision ~= "always" then decision = "reject" end
                local p = pending_approval
                pending_approval = nil
                approval_deadline = nil
                push({ type = "approval_reply", id = p.id, decision = decision })
                resume_agent(decision)
            end
        elseif t == "state" then
            send_obj(fd, state_obj())
        elseif t == "ping" then
            send_obj(fd, { type = "pong" })
        elseif t == "diff" then
            send_obj(fd, { type = "diff", patch = git_diff(ctx.session.cwd) })
        else
            send_obj(fd, { type = "error", error = "unknown type: " .. tostring(t) })
        end
    end

    local function attach_client(fd)
        clients[fd] = { buf = "" }
        send_obj(fd, {
            type = "hello", version = VERSION,
            model = ctx.session.model, cwd = ctx.session.cwd,
        })
        send_obj(fd, { type = "replay", events = replay })
        send_obj(fd, state_obj())
    end

    local function restore_history()
        for _, m in ipairs(ctx.session.messages or {}) do
            if m.role == "user" then
                local text = Text.content_text(m.content)
                if text ~= "" then push({ type = "user", text = text }) end
            elseif m.role == "assistant" then
                local text = Text.content_text(m.content)
                if text ~= "" then push({ type = "assistant", content = text }) end
            elseif m.role == "tool" then
                push({
                    type = "tool_result", name = "tool",
                    result = tostring(m.content or ""):sub(1, 8000),
                })
            end
        end
    end

    local function load_inputs()
        local items = inputs:load()
        for _, it in ipairs(items) do
            queue[#queue + 1] = it
            push({ type = "user", text = it.text })
        end
        if #items > 0 then
            push({ type = "info", text = "restored " .. #items .. " queued prompts" })
        end
    end

    local sigfd = Signal.sigfd()
    local running = true

    local function loop()
        while running do
            if pending_approval and approval_deadline and os.time() >= approval_deadline then
                local p = pending_approval
                pending_approval = nil
                approval_deadline = nil
                push({ type = "approval_reply", id = p.id, decision = "reject" })
                resume_agent("reject")
            end

            local fds = { server.fd }
            local conns = {}
            for fd in pairs(clients) do
                fds[#fds + 1] = fd
                conns[#conns + 1] = fd
            end
            local sig_index
            if sigfd then
                fds[#fds + 1] = sigfd
                sig_index = #fds
            end

            local _, revs = net.poll(fds, 20)
            if sig_index and revs[sig_index] and revs[sig_index] ~= 0 then
                Signal.drain(sigfd)
                running = false
                break
            end
            if revs[1] and revs[1] ~= 0 then
                while true do
                    local cfd = net.accept(server)
                    if not cfd then break end
                    attach_client(cfd)
                end
            end

            for i, fd in ipairs(conns) do
                if revs[i + 1] and revs[i + 1] ~= 0 then
                    local c = clients[fd]
                    if c then
                        local data, rerr = net.recv(fd)
                        if data then
                            c.buf = c.buf .. data
                            while true do
                                local line, rest = c.buf:match("^([^\n]*)\n(.*)$")
                                if not line then break end
                                c.buf = rest
                                if line ~= "" then handle_line(fd, line) end
                            end
                            if #c.buf > 1024 * 1024 then
                                clients[fd] = nil
                                net.close(fd)
                            end
                        elseif rerr == "closed" then
                            clients[fd] = nil
                            net.close(fd)
                        end
                    end
                end
            end

            if active_req and multi then
                for _, req in ipairs(http.poll(multi, 0)) do
                    if req == active_req then
                        active_req = nil
                        local a, e = Provider.finish_request(req)
                        resume_agent(a, e)
                        break
                    end
                end
            end

            if active_proc then
                local done, out = active_proc:poll()
                if done then
                    local code = active_proc.exit_code
                    active_proc = nil
                    if code and code ~= 0 then
                        out = out .. "\n[exit " .. tostring(code) .. "]"
                    end
                    resume_agent(out)
                end
            end

            memory:tick()
            if scheduler then scheduler:tick(os.time()) end
        end
    end

    restore_history()
    load_inputs()
    start_next()

    local ok, err = pcall(loop)

    if active_proc then active_proc:cancel() end
    for fd in pairs(clients) do net.close(fd) end
    net.close(server.fd)
    if sigfd then net.close(sigfd) end
    if logger then logger:close() end
    memory:close()
    http.multi_free(multi)

    if not ok then return nil, err end
    return true
end

return M
