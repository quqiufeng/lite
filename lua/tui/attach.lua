-- lite attach：连接 serve 端口，用 TUI 实时显示/交互。
local cjson = require("cjson")
local Terminal = require("tui.terminal")
local Screen = require("tui.screen")
local Input = require("tui.input")
local Composer = require("tui.composer")
local Transcript = require("tui.transcript")
local Status = require("tui.status")
local Diff = require("tui.diff")
local DiffView = require("tui.diff_view")
local TodoView = require("tui.todo_view")
local HelpView = require("tui.help_view")
local ApprovalView = require("tui.approval_view")
local net = require("core.net")

local M = {}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function layout(h, composer)
    local max_composer = math.max(1, math.min(6, h - 2))
    local composer_h = composer:height(max_composer)
    local composer_y = h - composer_h
    local transcript_h = math.max(1, composer_y - 1)
    return composer_y, transcript_h
end

function M.run(opts)
    opts = opts or {}
    if not Terminal.is_tty() then
        return nil, "attach requires a TTY"
    end

    local host = opts.host or "127.0.0.1"
    local port = tonumber(opts.port)
    if not port then return nil, "missing --port" end

    local fd, cerr = net.connect(host, port)
    if not fd then return nil, cerr end

    local w, h = Terminal.size()
    local screen = Screen.new(w, h)
    local input = Input.new()
    local composer = Composer.new()
    local transcript = Transcript.new()

    local ctx = {
        session = { model = "?", cwd = ".", turn = 0, messages = {} },
        view = { status = "idle" },
    }
    local busy = false
    local running = true
    local diff_view
    local todo_view
    local help_view
    local approval_view
    local approval_id
    local todo_items = {}
    local current_tool
    local hits = 0
    local mem = 0
    local spinner_i = 0
    local buf = ""

    transcript:add("info", string.format("connected to %s:%d", host, port))

    local function send_obj(obj)
        local ok, s = pcall(cjson.encode, obj)
        if not ok then return false end
        return net.send(fd, s .. "\n")
    end

    local function open_diff(patch)
        if not patch or patch == "" then
            transcript:add("info", "没有可显示的 diff")
            return
        end
        local files = Diff.parse(patch)
        if #files == 0 then
            transcript:add("info", "没有可显示的 diff")
            return
        end
        diff_view = DiffView.new(files, {
            width = w,
            height = h,
            mode = w >= 100 and "split" or "unified",
        })
    end

    local function apply(ev)
        local t = ev.type
        if t == "hello" then
            ctx.session.model = ev.model or ctx.session.model
            ctx.session.cwd = ev.cwd or ctx.session.cwd
        elseif t == "state" then
            ctx.session.turn = ev.turn or ctx.session.turn
            ctx.session.model = ev.model or ctx.session.model
            ctx.session.cwd = ev.cwd or ctx.session.cwd
            ctx.view.status = ev.status or ctx.view.status
            busy = ev.busy == true
            mem = ev.mem or mem
            hits = ev.hits or 0
            todo_items = ev.todos or todo_items
            if todo_view then todo_view:set_items(todo_items) end
        elseif t == "replay" then
            for _, e in ipairs(ev.events or {}) do apply(e) end
        elseif t == "user" then
            transcript:add("user", ev.text or "")
            transcript:reset_scroll()
        elseif t == "reasoning" then
            transcript:reasoning_append(ev.text or "")
        elseif t == "delta" then
            transcript:end_reasoning()
            transcript:stream_append(ev.text or "")
        elseif t == "assistant" then
            transcript:end_reasoning()
            local content = ev.content or ""
            if transcript.stream_block == nil and content ~= "" then
                transcript:add("assistant", content)
            else
                transcript:end_stream()
            end
        elseif t == "tool_start" then
            current_tool = ev.name
            transcript:tool_start(ev.name, ev.args)
        elseif t == "tool_result" then
            transcript:tool_result(ev.name, ev.result)
            current_tool = nil
        elseif t == "error" then
            transcript:add("error", tostring(ev.error))
            busy = false
        elseif t == "info" then
            transcript:add("info", tostring(ev.text))
        elseif t == "status" then
            ctx.view.status = ev.status or ctx.view.status
            busy = ctx.view.status ~= "idle"
        elseif t == "turn_start" then
            ctx.session.turn = ev.turn or ctx.session.turn
            busy = true
        elseif t == "turn_end" then
            ctx.session.turn = ev.turn or ctx.session.turn
            busy = false
        elseif t == "memory" then
            hits = ev.hits or 0
        elseif t == "todos" then
            todo_items = ev.items or {}
            if todo_view then todo_view:set_items(todo_items) end
        elseif t == "wake" then
            transcript:add("info", string.format("scheduled wake #%d%s",
                ev.run or 0, ev.task and (" · " .. tostring(ev.task)) or ""))
        elseif t == "image" then
            transcript:add("info", "image: " .. tostring(ev.path or ""))
        elseif t == "approval" then
            approval_id = ev.id
            approval_view = ApprovalView.new(ev, { width = w, height = h })
        elseif t == "approval_reply" then
            if approval_id == ev.id then
                approval_view = nil
                approval_id = nil
            end
        elseif t == "diff" then
            open_diff(ev.patch)
        end
    end

    local function feed(data)
        buf = buf .. data
        while true do
            local line, rest = buf:match("^([^\n]*)\n(.*)$")
            if not line then break end
            buf = rest
            if line ~= "" then
                local ok, obj = pcall(cjson.decode, line)
                if ok and type(obj) == "table" then apply(obj) end
            end
        end
    end

    local function handle(ev)
        if approval_view then
            local decision = approval_view:handle(ev)
            if decision then
                send_obj({ type = "approval", id = approval_id, decision = decision })
                approval_view = nil
                approval_id = nil
            end
            return
        end
        if help_view then
            if help_view:handle(ev) == "close" then help_view = nil end
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
        if k == "ctrl" then
            if ev.char == "c" then
                if not composer:is_empty() then
                    composer:clear()
                elseif busy then
                    send_obj({ type = "cancel" })
                else
                    running = false
                end
            elseif ev.char == "d" then
                if composer:is_empty() then running = false else composer:delete() end
            elseif ev.char == "l" then
                screen:invalidate()
            elseif ev.char == "o" then
                transcript:toggle_last_tool()
            elseif ev.char == "g" then
                send_obj({ type = "diff" })
            elseif ev.char == "t" then
                diff_view = nil
                todo_view = TodoView.new(todo_items, { width = w, height = h })
            end
            return
        end

        if k == "enter" then
            local text = composer:get_text()
            if text ~= "" then
                local word = text:lower()
                if word == "quit" or word == "exit" or word == ":q" then
                    composer:clear()
                    running = false
                else
                    composer:push_history(text)
                    composer:clear()
                    transcript:reset_scroll()
                    send_obj({ type = "submit", text = text })
                end
            end
        elseif k == "newline" then
            composer:insert("\n")
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
            local _, th = layout(h, composer)
            transcript:scroll_up(math.max(1, th - 1))
        elseif k == "pgdown" then
            local _, th = layout(h, composer)
            transcript:scroll_down(math.max(1, th - 1))
        elseif k == "char" and ev.text == "?" then
            help_view = HelpView.new({ width = w, height = h })
        elseif k == "paste" or k == "char" then
            composer:insert(ev.text)
        end
    end

    local term = Terminal.enter()
    local ok, err = pcall(function()
        while running do
            local nw, nh = Terminal.size()
            if nw ~= w or nh ~= h then
                w, h = nw, nh
                screen:resize(w, h)
                if diff_view then diff_view:set_size(w, h) end
                if todo_view then todo_view:set_size(w, h) end
                if help_view then help_view:set_size(w, h) end
                if approval_view then approval_view:set_size(w, h) end
            end

            local _, revs = net.poll({ 0, fd }, 15)
            if revs[1] and revs[1] ~= 0 then
                local s = Terminal.read_available(4096)
                if s then
                    for _, e in ipairs(input:feed(s)) do handle(e) end
                end
            end
            if revs[2] and revs[2] ~= 0 then
                local data, rerr = net.recv(fd)
                if data then
                    feed(data)
                elseif rerr == "closed" then
                    transcript:add("error", "server disconnected")
                    running = false
                end
            end

            if busy then spinner_i = (spinner_i + 1) % #SPINNER end

            screen:clear()
            if approval_view then
                approval_view:render(screen, w, h)
                screen.cursor.visible = false
            elseif help_view then
                help_view:render(screen, w, h)
                screen.cursor.visible = false
            elseif todo_view then
                todo_view:render(screen, w, h)
                screen.cursor.visible = false
            elseif diff_view then
                diff_view:render(screen, w, h)
                screen.cursor.visible = false
            else
                local composer_y, transcript_h = layout(h, composer)
                local composer_h = h - composer_y
                transcript:render(screen, 1, 1, w, transcript_h)
                local cur_x, cur_y = composer:render(screen, 1, composer_y, w, "default", composer_h)
                Status.render(screen, h, w, ctx, {
                    busy = busy,
                    mem = mem,
                    hits = hits,
                    todos = todo_items,
                    spinner = busy and SPINNER[spinner_i + 1] or nil,
                    status = current_tool and ("tool:" .. current_tool) or nil,
                })
                screen.cursor.x = cur_x
                screen.cursor.y = cur_y
                screen.cursor.visible = not busy
            end
            Terminal.write(screen:render())
        end
    end)

    Terminal.leave(term)
    net.close(fd)
    if not ok then return nil, err end
    return true
end

return M
