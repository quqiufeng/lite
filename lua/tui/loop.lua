-- TUI 事件循环：stdin + curl_multi + 定时器 + 重绘。
local Terminal = require("tui.terminal")
local Screen = require("tui.screen")
local Input = require("tui.input")
local Mouse = require("tui.mouse")
local Composer = require("tui.composer")
local Transcript = require("tui.transcript")
local Status = require("tui.status")
local Diff = require("tui.diff")
local DiffView = require("tui.diff_view")
local TodoView = require("tui.todo_view")
local HelpView = require("tui.help_view")
local ApprovalView = require("tui.approval_view")
local Complete = require("tui.complete")
local SessionView = require("tui.session_view")
local Session = require("core.session")
local Reload = require("core.reload")
local CoreText = require("core.text")
local http = require("core.http")

local M = {}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.run(ctx, agent, memory, opts)
    opts = opts or {}
    local multi = opts.multi
    local provider = agent.provider

    local input = Input.new()
    local composer = Composer.new()
    local transcript = Transcript.new()

    local w, h = Terminal.size()
    local screen = Screen.new(w, h)
    local mouse = Mouse.new(screen)

    local busy = false
    local quitting = false
    local co, active_req
    local queue = {}
    local last_escape = 0
    local diff_view
    local todo_view
    local help_view
    local approval_view
    local active_approval
    local active_proc
    local session_view
    local todo_items = ctx.session.todos or {}
    local last_tool_diff
    local current_tool
    local memory_hits = 0
    local draw
    local spinner_i = 0
    local mem_count = 0
    local last_stats = -1

    local HINT = "lite TUI · Enter 发送 · Ctrl+J 换行 · Tab 补全 · 左键拖选=复制 · /session 会话 · Esc×2 终止 · Ctrl+G diff · Ctrl+T todo · ? help · Ctrl+D 退出"

    local function populate(messages, label)
        transcript:clear()
        transcript:add("info", HINT)
        for _, m in ipairs(messages or {}) do
            if m.role == "user" then
                local txt = CoreText.content_text(m.content)
                if txt ~= "" then transcript:add("user", txt) end
            elseif m.role == "assistant" then
                local txt = CoreText.content_text(m.content)
                if txt ~= "" then transcript:add("assistant", txt) end
            elseif m.role == "tool" then
                local s = tostring(m.content or "")
                if #s > 4000 then s = s:sub(1, 4000) .. "\n... [truncated]" end
                local b = transcript:add("tool", "● tool result\n" .. s)
                b.tool = true
            end
        end
        if label then transcript:add("info", label) end
        transcript:reset_scroll()
    end

    populate(opts.messages, opts.messages and #opts.messages > 0
        and ("restored " .. #opts.messages .. " messages") or nil)

    -- 插件坏了以前完全静默（`_helper_errors` 只存不展示）。启动只提示错误，清单用
    -- `lite plugins`；`--no-plugins` 下不打扰。
    do
        local tools = agent.tools
        if tools and tools.plugin_report then
            local rep = tools:plugin_report()
            for _, err in ipairs(rep.errors or {}) do
                transcript:add("info", string.format("plugin %s failed: %s", err.name, err.error))
            end
        end
    end

    local function switch_to(id)
        if busy then
            transcript:add("info", "无法切换：当前正在执行")
            return
        end
        -- 内容只取当前目录 mem.bin 里的 KV；JSONL 仅作镜像，不参与恢复。
        local mem_msgs, max_turn = {}, 0
        if memory then mem_msgs, max_turn = memory:session_messages(id, 50) end

        local s = Session.new(ctx, { id = id, memory = memory })
        local msgs = mem_msgs
        local total = memory and memory:session_message_count(id) or 0
        s.seq = math.max(#mem_msgs, total)
        local turn = max_turn or 0

        ctx.session.id = id
        ctx.session.messages = msgs
        ctx.session.turn = turn
        agent.session = s
        if memory then
            memory:ensure_session(id, ctx.session.cwd, ctx.session.model)
        end
        -- 换会话必须重接 usage，否则状态栏会带着上一个会话的账继续累加。
        agent:restore_usage()
        if agent.tools and agent.tools.todos then
            agent.tools.todos:load()
            ctx:emit("todos", ctx.session.todos)
        end
        populate(msgs, string.format("session %s · memory %d", id, #mem_msgs))
    end

    local function switch_new()
        if busy then
            transcript:add("info", "无法切换：当前正在执行")
            return
        end
        local id = Session.new_id()
        ctx.session.id = id
        ctx.session.messages = {}
        ctx.session.turn = 0
        agent.session = Session.new(ctx, { id = id, memory = memory })
        if memory then
            memory:ensure_session(id, ctx.session.cwd, ctx.session.model)
        end
        agent:restore_usage()
        if agent.tools and agent.tools.todos then
            agent.tools.todos:load()
            ctx:emit("todos", ctx.session.todos)
        end
        populate({}, "new session " .. id)
    end

    local function handle_command(text)
        local name, arg = text:match("^/(%S+)%s*(.*)$")
        if not name then return end
        if name == "session" then
            if arg == "new" then
                switch_new()
            elseif arg ~= "" then
                switch_to(arg)
            else
                local sessions = {}
                if memory then
                    for _, meta in ipairs(memory:list_sessions(ctx.session.cwd, 10)) do
                        sessions[#sessions + 1] = { id = meta.id, preview = meta.title or "" }
                    end
                end
                -- 不列全局 JSONL 里的会话：记忆只跟当前目录的 mem.bin 走。
                session_view = SessionView.new(sessions, {
                    current = ctx.session.id,
                    width = w,
                    height = h,
                })
            end
        elseif name == "new" then
            switch_new()
        elseif name == "help" then
            help_view = HelpView.new({ width = w, height = h })
        elseif name == "reload" then
            if busy then
                transcript:add("info", "无法重载：当前正在执行")
            else
                local ok, err = Reload.lua(agent, ctx)
                if ok then
                    transcript:add("info", "reloaded lua (tools/prompt/ffi); C .so changes need restart")
                else
                    transcript:add("info", "reload failed: " .. tostring(err))
                end
            end
        elseif name == "quit" then
            quitting = true
        else
            transcript:add("info", "unknown command /" .. name)
        end
    end

    ctx:on("reasoning", function(t) transcript:reasoning_append(t) end)
    ctx:on("delta", function(t)
        transcript:end_reasoning()
        transcript:stream_append(t)
    end)
    ctx:on("assistant", function()
        transcript:end_reasoning()
        transcript:end_stream()
    end)
    ctx:on("tool_start", function(name, args)
        current_tool = name
        transcript:tool_start(name, args)
        if draw then draw() end
    end)
    ctx:on("tool_result", function(name, result)
        transcript:tool_result(name, result)
        if type(result) == "string" and result:find("diff --git ", 1, true) then
            last_tool_diff = result
        end
        current_tool = nil
        if draw then draw() end
    end)
    ctx:on("error", function(err) transcript:add("error", tostring(err)) end)
    ctx:on("memory", function(items)
        memory_hits = #(items or {})
        if draw then draw() end
    end)
    -- 压缩是低频但重要的事件：它一次性改变了 prompt 前缀。
    -- 不提示的话，用户只会看到命中率突然掉一段而不知道为什么。
    ctx:on("compact", function(info)
        if not info then return end
        if info.ok and info.stats then
            transcript:add("info", string.format(
                "compact: prompt %d -> %d chars (folded %d into a %d-char digest;"
                    .. " baseline %d, %d user turns kept, %d dropped)",
                info.stats.before_chars or 0, info.stats.after_chars or 0,
                info.stats.region_chars or 0, info.stats.digest_chars or 0,
                info.baseline or 0, info.stats.kept_user or 0, info.stats.dropped_user or 0))
        else
            transcript:add("info", "compact skipped: " .. tostring(info.reason or "?"))
        end
        if draw then draw() end
    end)
    -- 可复用前缀命中率掉到阈值以下才提示。cache% 被新增工具输出稀释是常态，
    -- 真正值得排查的是"上一轮那截里没命中多少" —— 那说明前缀位移了
    -- （system/tools 变了、历史被改、或者压缩把前缀动了）。
    ctx:on("prefix_drop", function(d)
        if not d then return end
        transcript:add("info", string.format(
            "prompt prefix reuse dropped to %d%% (%d of %d tokens from the previous"
                .. " prompt were reused; prev %d -> now %d tokens)."
                .. " Something before the tail changed — check for per-turn"
                .. " system/tool churn or a compaction.",
            math.floor((d.ratio or 0) * 100 + 0.5), d.hit or 0, d.denom or 0,
            d.prev_prompt or 0, d.prompt or 0))
        if draw then draw() end
    end)
    ctx:on("turn_limit", function(info)
        if not info then return end
        transcript:add("info", string.format(
            "tool loop stopped: %s. Asking the model to wrap up with a summary"
                .. " (no tools this time).",
            tostring(info.reason or "")))
        if draw then draw() end
    end)
    ctx:on("todos", function(items)
        todo_items = items or {}
        if todo_view then todo_view:set_items(todo_items) end
        if draw then draw() end
    end)
    ctx:on("image", function(info)
        transcript:add("info", "image: " .. tostring(info.path or ""))
    end)

    local resume_agent
    local start_next

    local function finish_agent()
        busy = false
        co = nil
        active_req = nil
        current_tool = nil
        approval_view = nil
        active_approval = nil
        if active_proc then
            active_proc:cancel()
            active_proc = nil
        end
        transcript:end_stream()
        last_escape = 0
    end

    local function on_resume(ok, y)
        if not ok then
            finish_agent()
            transcript:add("error", tostring(y))
            if start_next then start_next() end
            return
        end
        if coroutine.status(co) == "dead" then
            finish_agent()
            if start_next then start_next() end
            return
        end
        if type(y) == "table" and y.kind == "http" then
            active_req = y.req
        elseif type(y) == "table" and y.kind == "approval" then
            active_approval = y
            approval_view = ApprovalView.new(y, { width = w, height = h })
            if draw then draw() end
        elseif type(y) == "table" and y.kind == "proc" then
            active_proc = y.proc
            if draw then draw() end
        end
    end

    resume_agent = function(a, e)
        if not co then return end
        local ok, y = coroutine.resume(co, a, e)
        on_resume(ok, y)
    end

    local function start_prompt(text, block)
        if block then
            block.kind = "user"
            transcript._cache = nil
        else
            transcript:add("user", text)
        end
        transcript:reset_scroll()
        memory_hits = 0
        last_escape = 0
        busy = true
        co = agent:run_async(text)
        resume_agent()
        if draw then draw() end
    end

    start_next = function()
        if #queue == 0 then return false end
        local item = table.remove(queue, 1)
        start_prompt(item.text, item.block)
        return true
    end

    local voice, voice_on = nil, false
    local function vmod()
        if not voice then voice = require("core.voice") end
        return voice
    end

    local function submit()
        local text = composer:get_text()
        if text == "" then return end
        local vcmd = vmod().command(text)
        if vcmd == "toggle" then
            composer:clear()
            local vm = vmod()
            if voice_on then
                voice_on = false
                vm.stop()
                transcript:add("system", "语音模式已关闭")
            else
                local ok, e = vm.start()
                voice_on = ok and true or false
                transcript:add("system", ok and "语音模式已开启:说话即转文字,再输入 #退出 关闭"
                    or ("语音不可用: " .. tostring(e)))
            end
            if draw then draw() end
            return
        end
        if vcmd == "off" and voice_on then                -- 退出语音模式(不退出 lite)
            composer:clear()
            voice_on = false
            vmod().stop()
            transcript:add("system", "语音模式已关闭")
            if draw then draw() end
            return
        end
        local word = text:lower()
        if word == "quit" or word == "exit" or word == ":q" then
            composer:clear()
            quitting = true
            return
        end
        if text:sub(1, 1) == "/" then
            composer:push_history(text)
            composer:clear()
            handle_command(text)
            return
        end

        composer:push_history(text)
        composer:clear()
        if busy then
            local block = transcript:add("queued", text)
            queue[#queue + 1] = { text = text, block = block }
            transcript:reset_scroll()
            if draw then draw() end
            return
        end
        start_prompt(text)
    end

    local function cancel()
        if not busy then return end
        -- 双 Esc 的语义是终止本轮。不要依赖 coroutine 再走一次错误收尾：
        -- HTTP/工具阶段不同，resume 失败时 busy 会残留，输入框就像死了一样。
        -- 先把所有在途资源取消，再无条件清 TUI 状态。
        if active_req and multi then
            http.cancel(multi, active_req)
            active_req = nil
        end
        if active_proc then
            active_proc:cancel()
            active_proc = nil
        end
        finish_agent()
        if start_next then start_next() end
    end

    local function load_diff()
        local cwd = ctx.session.cwd or "."
        local p = io.popen("cd " .. shq(cwd)
            .. " && git --no-pager diff --no-color --no-ext-diff -U3 2>/dev/null", "r")
        local out = ""
        if p then out = p:read("*a") or ""; p:close() end
        if out == "" then
            p = io.popen("cd " .. shq(cwd)
                .. " && git --no-pager diff --cached --no-color --no-ext-diff -U3 2>/dev/null", "r")
            if p then out = p:read("*a") or ""; p:close() end
        end
        return out
    end

    local function open_diff()
        local text = load_diff()
        if not text or text == "" then text = last_tool_diff end
        if not text or text == "" then
            transcript:add("info", "没有可显示的 git diff")
            return
        end
        local files = Diff.parse(text)
        if #files == 0 then
            transcript:add("info", "没有可显示的 git diff")
            return
        end
        diff_view = DiffView.new(files, {
            width = w,
            height = h,
            mode = w >= 100 and "split" or "unified",
        })
    end

    local function complete_path()
        local line = composer.lines[composer.cy] or ""
        local token, start = Complete.token(line, composer.cx)
        if token == "" or token:sub(1, 1) == "/" or token:find("..", 1, true) then return end

        local dir, base = "", token
        local slash = token:match("^(.*/)([^/]*)$")
        if slash then
            dir = slash
            base = token:match("([^/]*)$")
        end

        local p = io.popen("ls -1ap " .. shq(ctx.session.cwd .. "/" .. dir) .. " 2>/dev/null", "r")
        if not p then return end
        local names = {}
        for n in p:lines() do
            if n ~= "./" and n ~= "../" then names[#names + 1] = n end
        end
        p:close()

        local matches, common = Complete.candidates(names, base)
        if #matches == 0 then return end
        local fill = #matches == 1 and matches[1] or common
        if fill == "" then return end
        composer:replace_token(start, dir .. fill)
    end

    local function handle(ev)
        if ev.key == "mouse" then
            if approval_view or help_view or session_view or todo_view or diff_view then return end
            local _, th = M.layout(h, composer)
            local r = mouse:handle(ev, { top = 1, bottom = th })
            if r then
                local msg = mouse.message
                mouse.message = nil
                if msg and msg ~= "" then transcript:add("info", msg) end
                if draw then draw() end
            end
            return
        end
        if ev.key == "wheel" then
            if not (approval_view or help_view or session_view or todo_view or diff_view) then
                local _, th = M.layout(h, composer)
                mouse:cancel()
                if ev.dy > 0 then
                    transcript:scroll_up(3)
                else
                    transcript:scroll_down(3)
                end
                if draw then draw() end
            end
            return
        end
        if approval_view then
            local decision = approval_view:handle(ev)
            if decision then
                approval_view = nil
                active_approval = nil
                resume_agent(decision)
            end
            return
        end
        if help_view then
            if help_view:handle(ev) == "close" then help_view = nil end
            return
        end
        if session_view then
            local r = session_view:handle(ev)
            if r then
                session_view = nil
                if r.action == "select" then
                    switch_to(r.id)
                elseif r.action == "new" then
                    switch_new()
                end
            end
            return
        end
        if todo_view then
            if todo_view:handle(ev) == "close" then todo_view = nil end
            return
        end
        if diff_view then
            if diff_view:handle(ev) == "close" then diff_view = nil end
            return
        end

        local k = ev.key
        if k ~= "escape" then last_escape = 0 end

        if k == "escape" then
            if busy then
                local now = os.time()
                if last_escape > 0 and now - last_escape <= 2 then
                    last_escape = 0
                    cancel()
                else
                    last_escape = now
                    transcript:add("info", "再按一次 Esc 终止当前回复")
                    if draw then draw() end
                end
            end
            return
        end

        if k == "ctrl" then
            if ev.char == "c" then
                if active_proc then
                    local out = active_proc:cancel()
                    active_proc = nil
                    if agent.tools and agent.tools.limit_output then
                        out = agent.tools.limit_output(out, agent.tools.BASH_MAX_OUT)
                    end
                    resume_agent(out)
                elseif busy then
                    cancel()
                elseif not composer:is_empty() then
                    composer:clear()
                else
                    quitting = true
                end
            elseif ev.char == "d" then
                if not busy then
                    if composer:is_empty() then quitting = true else composer:delete() end
                end
            elseif ev.char == "l" then
                screen:invalidate()
            elseif ev.char == "o" then
                transcript:toggle_last_tool()
            elseif ev.char == "g" then
                open_diff()
            elseif ev.char == "t" then
                diff_view = nil
                todo_view = TodoView.new(todo_items, { width = w, height = h })
            end
            return
        end

        if k == "enter" then
            submit()
        elseif k == "newline" then
            composer:insert("\n")
        elseif k == "tab" then
            complete_path()
        elseif k == "backspace" then
            composer:backspace()
        elseif k == "delete" then
            composer:delete()
        elseif k == "left" then
            composer:left()
        elseif k == "right" then
            composer:right()
        elseif k == "up" then
            if #composer.lines == 1 then composer:history_prev() else composer:up() end
        elseif k == "down" then
            if #composer.lines == 1 then composer:history_next() else composer:down() end
        elseif k == "home" then
            composer:home()
        elseif k == "end" then
            composer:end_()
        elseif k == "pgup" then
            local _, th = M.layout(h, composer)
            transcript:scroll_up(math.max(1, th - 1))
        elseif k == "pgdown" then
            local _, th = M.layout(h, composer)
            transcript:scroll_down(math.max(1, th - 1))
        elseif k == "char" and ev.text == "?" then
            help_view = HelpView.new({ width = w, height = h })
        elseif k == "paste" or k == "char" then
            composer:insert(ev.text)
        end
    end

    draw = function()
        screen:clear()
        if approval_view or help_view or session_view or todo_view or diff_view then
            if screen:has_selection() then mouse:cancel() end
        end
        if approval_view then
            approval_view:render(screen, w, h)
            screen.cursor.visible = false
        elseif help_view then
            help_view:render(screen, w, h)
            screen.cursor.visible = false
        elseif session_view then
            session_view:render(screen, w, h)
            screen.cursor.visible = false
        elseif todo_view then
            todo_view:render(screen, w, h)
            screen.cursor.visible = false
        elseif diff_view then
            diff_view:render(screen, w, h)
            screen.cursor.visible = false
        else
            local composer_y, transcript_h = M.layout(h, composer)
            local composer_h = h - composer_y

            transcript:render(screen, 1, 1, w, transcript_h)
            local cur_x, cur_y = composer:render(screen, 1, composer_y, w, "default", composer_h)
            Status.render(screen, h, w, ctx, {
                busy = busy,
                mem = mem_count,
                hits = memory_hits,
                cache = ctx.cache_ratio and ctx:cache_ratio() or nil,
                reuse = ctx.prefix_ratio and ctx:prefix_ratio() or nil,
                ctxeng = agent and agent._compact_probe or nil,
                todos = todo_items,
                queue = #queue,
                spinner = busy and SPINNER[spinner_i + 1] or nil,
                status = current_tool and ("tool:" .. current_tool) or nil,
            })
            screen.cursor.x = cur_x
            screen.cursor.y = cur_y
            screen.cursor.visible = (not busy) or not composer:is_empty()
        end
        Terminal.write(screen:render())
    end

    while not quitting do
        local nw, nh = Terminal.size()
        if nw ~= w or nh ~= h then
            w, h = nw, nh
            screen:resize(w, h)
            if diff_view then diff_view:set_size(w, h) end
            if todo_view then todo_view:set_size(w, h) end
            if help_view then help_view:set_size(w, h) end
            if approval_view then approval_view:set_size(w, h) end
            if session_view then session_view:set_size(w, h) end
        end

        local _, revents = Terminal.poll(15)
        if revents and revents ~= 0 then
            local s = Terminal.read_available(4096)
            if s then
                for _, ev in ipairs(input:feed(s)) do handle(ev) end
            end
        end

        if active_req and multi then
            local done = http.poll(multi, 5)
            for _, req in ipairs(done) do
                if req == active_req then
                    active_req = nil
                    local a, e = provider.finish_request(req)
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
                -- 异步 bash 的输出原本完全不过限，这里补上 head+tail 双端裁剪。
                if agent.tools and agent.tools.limit_output then
                    out = agent.tools.limit_output(out, agent.tools.BASH_MAX_OUT)
                end
                resume_agent(out)
            end
        end

        if voice_on and voice then
            local got = voice.poll()
            -- 默认转写即执行（等于替你按回车）；LITE_VOICE_AUTO_SEND=0 退回「只填入输入框」。
            local auto = os.getenv("LITE_VOICE_AUTO_SEND") ~= "0"
            for _, t in ipairs(got) do
                if auto then
                    t = (t:gsub("%s+$", ""))
                    if t ~= "" then
                        composer:insert(t)
                        submit()
                    end
                else
                    composer:insert(t .. " ")
                end
            end
            if #got > 0 then draw() end
        end

        if memory then memory:tick() end
        local now = os.time()
        if now ~= last_stats then
            last_stats = now
            mem_count = memory and memory:stats().count or 0
        end
        if busy then spinner_i = (spinner_i + 1) % #SPINNER end

        draw()
    end

    if active_proc then active_proc:cancel() end
end

function M.layout(h, composer)
    local max_composer = math.max(1, math.min(6, h - 2))
    local composer_h = composer:height(max_composer)
    local composer_y = h - composer_h
    local transcript_h = math.max(1, composer_y - 1)
    return composer_y, transcript_h
end

return M
