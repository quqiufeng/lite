-- lite serve：headless agent + TCP JSONL 事件广播；attach 客户端消费。
-- 同一个端口还挂着一个 HTTP 前端（core/serve_http.lua）：任何智能应用都能用
-- OpenAI/Anthropic 的 `/v1/chat/completions` 直接把它当大脑使。
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
local Http = require("core.serve_http")

-- 进程内追踪账本（trace.prof）：serve 每请求时延（含排队等待）。
local ok_prof, prof = pcall(require, "trace.prof")
if not ok_prof then prof = nil end

local M = {}

-- reboot/shutdown 工具只往 ctx.settings 里置标记，TUI 由 lua/tui/loop.lua 在空闲处收尾；
-- serve 没有 UI 回收点，收工时靠这个判「为什么停」：nil=继续，"exit"/"reboot"=交回 main。
function M.stop_reason(settings)
    local s = settings or {}
    if s.exit then return "exit" end
    if s.reboot then return "reboot" end
    return nil
end

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

    -- HTTP 前端共享这个端口；不做鉴权（本机/局域网自用），只靠 host 控制暴露面。
    local http_timeout = tonumber(opts.http_timeout)
        or tonumber(os.getenv("LITE_SERVE_HTTP_TIMEOUT")) or 900

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
        context_window = config.context_window,
        reserve_tokens = config.reserve_tokens,
        compact = config.compact,
        max_output_tokens = config.max_output_tokens,
        token_budget = config.token_budget,
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
    -- serve 是长命的写实例：抢不到锁就跑，等于整轮唤醒/对话不落盘，
    -- 客户端还看得见流式回复，谁也发现不了记忆没写。这里直接拒绝启动。
    if memory.lock_busy and not opts.allow_readonly then
        local msg = Memory.lock_message(memory.dir, memory:owner())
        memory:close()
        return nil, "memory is locked by " .. msg
            .. "; refusing to serve without write access (use --readonly to override)"
    end
    if memory.lock_busy then
        io.stderr:write("lite serve: memory read-only by request ("
            .. Memory.lock_message(memory.dir, memory:owner()) .. ")\n")
    end

    local multi, mlerr = http.multi_new()
    if not multi then
        memory:close()
        return nil, mlerr
    end
    ctx.settings.multi = multi
    local logger = require("core.debug").new(config.debug_log)
    if logger then ctx.settings.debug = logger end

    local restored_turn = 0
    -- 恢复走和 TUI/once 同一条路径（含 mem.bin 损坏时从 JSONL 备份兜底）。
    local prev = Session.from_memory(memory, config.cwd, 1)
    if prev then
        ctx.session.id = prev.id
        ctx.session.messages = prev.messages
        restored_turn = prev.turn or 0
        if prev.from_jsonl then
            io.stderr:write("lite: mem.bin has no session, recovered from JSONL backup "
                .. tostring(prev.id) .. " (" .. tostring(prev.path) .. ")\n")
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
        plugins = config.plugins,
    })
    if tools.todos then tools.todos:load() end
    local msg_count = memory:session_message_count(ctx.session.id)
    local session = Session.new(ctx, {
        memory = memory,
        seq = math.max(#ctx.session.messages, msg_count),
    })
    local agent = Agent.new(ctx, Provider, tools, session, memory)
    agent:restore_usage()

    local server, serr = net.listen(host, port)
    if not server then
        memory:close()
        http.multi_free(multi)
        return nil, serr
    end

    io.write(string.format("lite serve listening on %s:%d\n", server.host, server.port))
    io.write(string.format("PORT=%d\n", server.port))
    io.write("http  GET /health | POST /prompt {\"prompt\":\"...\"}\n")
    io.write(string.format("http  timeout %ds | jsonl attach 同端口\n", http_timeout))
    io.flush()

    local clients = {}
    local replay = {}
    local queue = {}
    -- HTTP 前端的状态：每个连接一条，busy_http 是「正在为哪条连接跑这一轮」。
    local http_conns = {}
    local busy_http
    local finish_http
    local http_close
    local accept_conn
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

    -- HTTP 只有一问一答：delta/reasoning 只喂 JSONL 客户端，答案走 finish_http。
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
    ctx:on("error", function(err)
        push({ type = "error", error = tostring(err) })
        -- 这一轮如果是 HTTP 请求要的，把错误留给 finish_http 报给客户端。
        if busy_http then busy_http.error = tostring(err) end
    end)
    ctx:on("status", function(status) push({ type = "status", status = status }) end)
    ctx:on("turn_start", function(turn) push({ type = "turn_start", turn = turn }) end)
    ctx:on("turn_end", function(turn) push({ type = "turn_end", turn = turn }) end)
    ctx:on("memory", function(items)
        items = items or {}
        last_hits = #items
        -- 带 key 出去：客户端（attach）默认静音，开 LITE_TUI_MEM_NOTICE=1 才显示
        -- 命中了什么；只发计数的话客户端连开关都撑不起来。
        local keys = {}
        for i, it in ipairs(items) do
            if i > 6 then break end
            keys[#keys + 1] = tostring(it.key or "?")
        end
        push({ type = "memory", hits = last_hits, keys = keys })
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
    -- reboot/shutdown 工具只往 ctx.settings 里置标记，TUI 由 lua/tui/loop.lua 在
    -- 空闲处收尾。serve 没有 UI 回收点，得自己判：一轮（含排队消息）收完就停下，
    -- 交回 main 去换代进程 / 退出。`running` 提前声明，on_resume 才抓得到它。
    local running = true
    local stop_mode

    local function stop_requested()
        return M.stop_reason(ctx.settings)
    end

    local function on_resume(ok, y)
        if not ok then
            busy = false
            co = nil
            active_req = nil
            if scheduler then scheduler:set_answer("error: " .. tostring(y)) end
            push({ type = "error", error = tostring(y) })
            finish_http(nil, tostring(y))
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
            -- 先把结果交回 HTTP 客户端（它在等这一轮的答案），再发状态/起下一条。
            finish_http(answer)
            memory:sync()
            push(state_obj())
            local stop = stop_requested()
            if stop and #queue == 0 then
                -- 收工：先把「为什么停」告诉客户端，再跳出 poll 循环（下面 loop 会看 running）。
                stop_mode = stop
                running = false
                push({
                    type = "info",
                    text = stop == "exit" and "shutdown requested; exiting"
                        or "reboot requested; restarting as a fresh process",
                })
                return
            end
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
        -- 排队是一条队列：谁被 pop 出来，这一轮就为谁答（HTTP 请求按 FIFO 轮到）。
        if type(item) == "table" and item.http then
            busy_http = { fd = item.fd }
        end
        co = agent:run_async(text)
        resume_agent()
    end

    local function submit(text, meta)
        if not text or text == "" then return end
        local seq = inputs:add(text)
        if not (meta and meta.quiet) then
            push({ type = "user", text = text })
        end
        -- meta.http + meta.fd：这条消息同时是某个 HTTP 请求的答案，跑完要回写那一条连接。
        queue[#queue + 1] = { seq = seq, text = text, http = meta and meta.http,
            fd = meta and meta.fd }
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
            finish_http(nil, "cancelled by client")
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

    -- ── HTTP 前端 ─────────────────────────────────────────────────────
    -- 与 JSONL 共用一条队列：HTTP 请求也是一条「用户消息」，跑完再把答案回写给
    -- 那条连接（流式边跑边推 SSE）。这样 HTTP 客户端和 TUI/attach 看到的是同一
    -- 个 agent、同一份记忆，谁先来谁先答。
    local function http_drop(fd)
        http_conns[fd] = nil
        if busy_http and busy_http.fd == fd then
            -- 客户端先走了：这一轮照样跑完（记忆/日志仍完整），只是不再回写。
            busy_http = nil
        end
        net.close(fd)
    end

    http_close = function(fd, payload)
        if payload then net.send(fd, payload) end
        http_drop(fd)
    end

    local function http_route(fd, req)
        local c = http_conns[fd]
        if not c then return end
        if req.method == "OPTIONS" then
            return http_close(fd, Http.response(204, {}, ""))
        end
        -- /health 不鉴权：探活用，不回工作区信息，也不排队。
        if req.path == "/health" or req.path == "/healthz" then
            -- shell = 当前这条 bash 后台进程还活着（含 setsid 出来的子孙）。
            -- 探活只看「还在不在跑」，不看时间阈值：长命令跑一小时也是活着，
            -- 主循环卡在同步 C 调用时这个请求根本答不上（对方超时即判卡）。
            local shell, shell_sec, pid
            if active_proc and active_proc:alive() then
                shell = true
                pid = active_proc.pid
                shell_sec = os.time() - (active_proc.start or os.time())
            end
            return http_close(fd, Http.json(200,
                { ok = true, live = true, busy = busy, queued = #queue,
                  shell = shell, pid = pid, shell_sec = shell_sec }))
        end
        if req.path ~= "/prompt" then
            return http_close(fd, Http.not_found(req.path))
        end
        if req.method ~= "POST" then
            return http_close(fd, Http.error(405, "only POST /prompt", "method_not_allowed"))
        end
        local prompt, perr = Http.prompt_of(req.body)
        if not prompt then
            return http_close(fd, Http.error(400, perr or "bad request", "bad_request"))
        end
        if prof then c.p_t0 = prof.now_ms() end
        c.prompt_len = #prompt
        -- 进同一条队列，轮到自己跑一轮，跑完 finish_http 回 {"ok":true,"text":...}。
        c.waiting = true
        submit(prompt, { http = true, fd = fd })
    end

    local function http_read(fd)
        local c = http_conns[fd]
        if not c then return end
        local data, rerr = net.recv(fd)
        if data then
            c.buf = (c.buf or "") .. data
            if #c.buf > 9 * 1024 * 1024 then
                return http_close(fd, Http.error(413, "request body too large"))
            end
            local req, perr = Http.parse(c.buf)
            if req then
                c.buf = ""
                http_route(fd, req)
            elseif perr ~= "more" then
                http_close(fd, Http.error(400, tostring(perr):gsub("^bad:%s*", "")))
            end
        elseif rerr == "closed" then
            http_drop(fd)
        end
    end

    -- 一轮跑完：把这一轮的最终答案回写给那条 HTTP 连接，然后关掉它。
    finish_http = function(answer, err)
        local b = busy_http
        busy_http = nil
        if not b then return end
        local c = http_conns[b.fd]
        if not c then return end
        c.waiting = nil
        local text = type(answer) == "string" and answer or ""
        local aerr = type(err) == "string" and err or b.error
        if prof and c.p_t0 then
            prof.record("serve.request", prof.now_ms() - c.p_t0, aerr == nil or aerr == "", c.prompt_len)
        end
        if aerr and aerr ~= "" and text == "" then
            return http_close(b.fd, Http.error(500, aerr, "agent_error"))
        end
        http_close(b.fd, Http.json(200, { ok = true, text = text }))
    end

    -- 首包嗅探：HTTP 客户端连上就发请求行；attach 客户端啥也不发、等 hello。
    -- 所以最多等 50ms 看有没有字节，没有就按 JSONL 处理（不会误伤 attach）。
    accept_conn = function(fd)
        local data = net.peek(fd)
        if not data then
            net.poll({ fd }, 50)
            data = net.peek(fd)
        end
        if Http.looks_like_http(data) then
            http_conns[fd] = { buf = "", created = os.time() }
            return
        end
        attach_client(fd)
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

    local function loop()
        while running do
            if pending_approval and approval_deadline and os.time() >= approval_deadline then
                local p = pending_approval
                pending_approval = nil
                approval_deadline = nil
                push({ type = "approval_reply", id = p.id, decision = "reject" })
                resume_agent("reject")
            end

            -- HTTP 请求有超时线：等太久就回 504 收掉连接（那一轮仍会跑完，只是没人收）。
            if http_timeout > 0 then
                local now = os.time()
                for fd, c in pairs(http_conns) do
                    if c.waiting and c.created and now - c.created > http_timeout then
                        c.waiting = nil
                        if busy_http and busy_http.fd == fd then busy_http = nil end
                        http_close(fd, Http.error(504,
                            "agent timed out after " .. http_timeout .. "s",
                            "server_error", "timeout"))
                    end
                end
            end

            local fds = { server.fd }
            local conns = {}
            for fd in pairs(clients) do
                fds[#fds + 1] = fd
                conns[#conns + 1] = fd
            end
            -- HTTP 连接排在 JSONL 之后、sigfd 之前：索引好算（+2 起）。
            local hconns = {}
            for fd in pairs(http_conns) do
                fds[#fds + 1] = fd
                hconns[#hconns + 1] = fd
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
                    accept_conn(cfd)
                end
            end

            for i, fd in ipairs(hconns) do
                if revs[#conns + i + 1] and revs[#conns + i + 1] ~= 0 then
                    http_read(fd)
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
    -- reboot 后那句「继续」（main 从 core.reboot 取回）：当普通用户消息排队，
    -- attach 客户端在 replay 里能看到它，和 TUI 里自动发那句话等价。
    if opts.resume_text and opts.resume_text ~= "" then
        submit(opts.resume_text)
    end
    start_next()

    local ok, err = pcall(loop)

    if active_proc then active_proc:cancel() end
    for fd in pairs(clients) do net.close(fd) end
    for fd in pairs(http_conns) do net.close(fd) end
    net.close(server.fd)
    if sigfd then net.close(sigfd) end
    if logger then logger:close() end
    memory:close()
    http.multi_free(multi)

    if not ok then return nil, err end
    -- 第三返回值 = 为什么要停：main 据此换代进程（reboot，exit 75 / execv）或直接退出。
    if stop_mode then
        return true, nil, {
            mode = stop_mode,
            prompt = ctx.settings and ctx.settings.reboot_prompt or nil,
        }
    end
    return true
end

return M
