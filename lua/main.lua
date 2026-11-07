-- lite 入口：--check / --once / --recall；支持 --json 供 agent 驱动。
local VERSION = "0.1.1"

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function usage()
    io.write([[
lite — DeepSeek 终端 coding agent

用法:
  lite                         交互式终端 UI（默认，等价于 --tui）
  lite --tui                   同上，显式写法
  lite serve --port 8765       启动 headless 服务端（TCP JSONL）
  lite serve --port 8765 --wake 300 --task "检查 CI"   定时唤醒
  lite attach --port 8765      连接服务端并显示 TUI
  lite attach --port 8765 --tmux  在新 tmux 窗口 attach
  lite --tui --snapshot out.txt   输出整屏快照（AI 验收）
  lite state [--json]          输出会话/记忆/todo 状态
  lite sessions [--json]       列出同 cwd 会话
  lite --check                 检查运行依赖
  lite --once "<prompt>"       无 UI 单轮/工具循环（流式输出）
  lite --recall "<query>"      查询当前目录的本地记忆
  lite --version               版本
  lite --help                  帮助

选项:
  --json                       机器可读 JSONL 输出（AI agent 友好）
  --thinking                   启用 DeepSeek thinking（reasoning_content）
  --reasoning-effort LEVEL     high | medium | low
  --sandbox                    bash 使用 bwrap 沙箱（需安装 bubblewrap）
  --approval auto|ask|deny     工具审批策略（默认 auto）
  --max-turns N                单次任务工具循环上限（默认 256）
  --debug-log PATH             写 JSONL 调试日志（provider/HTTP）

环境:
  DEEPSEEK_API_KEY             必需
  DEEPSEEK_BASE_URL            默认 https://api.deepseek.com
  DEEPSEEK_MODEL               默认 deepseek-flash
  LITE_CWD                     默认当前目录
  LITE_MAX_TURNS               默认 256
  LITE_JSON=1                  等价于 --json

状态: 无参数启动即交互入口（与 --tui 等价）；--once 用于脚本/CI。
]])
end

local args = {}
for i = 1, #arg do args[#args + 1] = arg[i] end

local json = os.getenv("LITE_JSON") == "1"
local clean = {}
for i = 1, #args do
    if args[i] == "--json" then
        json = true
    else
        clean[#clean + 1] = args[i]
    end
end

local function emit(obj)
    local cjson = require("cjson")
    io.write(cjson.encode(obj), "\n")
    io.flush()
end

-- 子命令识别：`lite` 不带参数就是交互 TUI；`lite --snapshot out.txt` 这种只给
-- TUI 选项、没写子命令的写法也当 TUI 处理（选项原样转发）。`--help/-h` 仍打用法。
local SUBCOMMANDS = {
    ["--version"] = true, ["--help"] = true, ["-h"] = true,
    serve = true, ["--serve"] = true, attach = true, ["--attach"] = true,
    state = true, ["--state"] = true, sessions = true, ["--sessions"] = true,
    ["--check"] = true, ["--recall"] = true, ["--tui"] = true, ["--once"] = true,
}

local cmd = clean[1]
local rest = {}
if cmd == nil then
    cmd = "--tui"
elseif cmd:sub(1, 1) == "-" and not SUBCOMMANDS[cmd] then
    rest[1] = cmd
    cmd = "--tui"
end
for i = 2, #clean do rest[#rest + 1] = clean[i] end

local function parse_flags(list)
    local flags, pos = {}, {}
    local i = 1
    while i <= #list do
        local a = list[i]
        if a == "--port" then
            flags.port = tonumber(list[i + 1])
            i = i + 2
        elseif a == "--host" then
            flags.host = list[i + 1]
            i = i + 2
        elseif a == "--tmux" then
            flags.tmux = true
            i = i + 1
        elseif a == "--wake" then
            flags.wake = tonumber(list[i + 1])
            i = i + 2
        elseif a == "--wake-max" then
            flags.wake_max = tonumber(list[i + 1])
            i = i + 2
        elseif a == "--task" then
            flags.task = list[i + 1]
            i = i + 2
        elseif a == "--task-file" then
            flags.task_file = list[i + 1]
            i = i + 2
        elseif a == "--snapshot" then
            flags.snapshot = list[i + 1]
            i = i + 2
        elseif a == "--snapshot-text" then
            flags.snapshot_text = list[i + 1]
            i = i + 2
        elseif a == "--snapshot-todo" then
            flags.snapshot_todo = true
            i = i + 1
        elseif a == "--snapshot-diff" then
            flags.snapshot_diff = true
            i = i + 1
        elseif a == "--width" then
            flags.width = tonumber(list[i + 1])
            i = i + 2
        elseif a == "--height" then
            flags.height = tonumber(list[i + 1])
            i = i + 2
        elseif a == "--session" then
            flags.session = list[i + 1]
            i = i + 2
        elseif a == "--thinking" then
            flags.thinking = true
            i = i + 1
        elseif a == "--reasoning-effort" then
            flags.reasoning_effort = list[i + 1]
            i = i + 2
        elseif a == "--sandbox" then
            flags.sandbox = true
            i = i + 1
        elseif a == "--approval" then
            flags.approval = list[i + 1]
            i = i + 2
        elseif a == "--max-turns" then
            flags.max_turns = tonumber(list[i + 1])
            i = i + 2
        elseif a == "--debug-log" then
            flags.debug_log = list[i + 1]
            i = i + 2
        else
            pos[#pos + 1] = a
            i = i + 1
        end
    end
    return flags, pos
end

if cmd == "--version" then
    if json then emit({ type = "version", version = VERSION })
    else print("lite " .. VERSION) end
    os.exit(0)
elseif cmd == "--help" or cmd == "-h" then
    usage()
    os.exit(0)
elseif cmd == "serve" or cmd == "--serve" then
    local flags = parse_flags(rest)
    local config = require("core.config").load()
    if flags.thinking then config.thinking = true end
    if flags.reasoning_effort then config.reasoning_effort = flags.reasoning_effort end
    if flags.sandbox then config.sandbox = "enforce" end
    if flags.approval then config.approval = flags.approval end
    if flags.max_turns then config.max_turns = flags.max_turns end
    if flags.debug_log then config.debug_log = flags.debug_log end
    if not config.api_key or config.api_key == "" then
        io.stderr:write("lite: missing DEEPSEEK_API_KEY\n")
        os.exit(2)
    end
    local port = flags.port or tonumber(os.getenv("LITE_SERVE_PORT")) or 8765
    local ok, err = require("core.serve").run({
        host = flags.host,
        port = port,
        config = config,
        wake = flags.wake,
        max_runs = flags.wake_max,
        task = flags.task,
        task_file = flags.task_file,
    })
    if not ok then
        io.stderr:write("lite serve: " .. tostring(err) .. "\n")
        os.exit(1)
    end
    os.exit(0)
elseif cmd == "attach" or cmd == "--attach" then
    local flags = parse_flags(rest)
    local host = flags.host or "127.0.0.1"
    local port = flags.port or tonumber(os.getenv("LITE_SERVE_PORT")) or 8765
    if flags.tmux then
        local root = os.getenv("LITE_ROOT") or "."
        local cmdline = string.format(
            "tmux new-window -n lite-attach '%s/tools/lite attach --port %d --host %s'",
            root, port, host)
        local rc = os.execute(cmdline)
        os.exit(rc and 0 or 1)
    end
    local ok, err = require("tui.attach").run({ host = host, port = port })
    if not ok then
        io.stderr:write("lite attach: " .. tostring(err) .. "\n")
        os.exit(1)
    end
    os.exit(0)
elseif cmd == "state" or cmd == "--state" or cmd == "sessions" or cmd == "--sessions" then
    local flags = parse_flags(rest)
    local config = require("core.config").load()
    local Memory = require("core.memory")
    local memory, merr = Memory.new({
        dir = config.memory_dir or config.cwd,
        max_mb = config.memory_mb,
        flush_sec = config.memory_flush,
        readonly = true,
    })
    if not memory then
        io.stderr:write("lite: " .. tostring(merr) .. "\n")
        os.exit(2)
    end

    local sessions = memory:list_sessions(config.cwd, 20)
    local sid = flags.session or (sessions[1] and sessions[1].id)
    local saved = sid and memory:get("/agent/session", sid .. "/todos") or nil
    local todos = type(saved) == "table" and (saved.items or saved) or {}
    local is_sessions = (cmd == "sessions" or cmd == "--sessions")

    local out = {
        type = is_sessions and "sessions" or "state",
        cwd = config.cwd,
        model = config.model,
        sessions = sessions,
    }
    if not is_sessions then
        out.session = sid
        out.todos = todos
        out.memory = memory:stats()
        out.wake = memory:get("/agent/working", "wake")
    end

    if json then
        emit(out)
    else
        print("cwd   " .. config.cwd)
        print("model " .. config.model)
        for _, s in ipairs(sessions) do
            print(string.format("%s  turns=%s  %s", s.id,
                tostring(s.turns or 0), tostring(s.title or "")))
        end
        if not is_sessions then
            local st = out.memory or {}
            print(string.format("memory count=%d used=%d max=%d",
                st.count or 0, st.used or 0, st.max or 0))
            for _, t in ipairs(todos) do
                print(string.format("[%s] %s", tostring(t.status), tostring(t.content)))
            end
        end
    end
    memory:close()
    os.exit(0)
elseif cmd == "--check" then
    local deps = require("core.deps")
    local ok, rows = deps.check()
    if json then
        emit({ type = "check", ok = ok, deps = rows })
    else
        for _, r in ipairs(rows) do
            print(string.format("[%s] %-8s %s", r.ok and "OK" or "FAIL", r.name, r.detail))
        end
    end
    os.exit(ok and 0 or 1)
elseif cmd == "--recall" then
    local query = rest[1] or ""
    local config = require("core.config").load()
    local Memory = require("core.memory")
    local memory, merr = Memory.new({
        dir = config.memory_dir or config.cwd,
        max_mb = config.memory_mb,
        flush_sec = config.memory_flush,
        readonly = true,
    })
    if not memory then
        if json then emit({ type = "error", error = tostring(merr) })
        else io.stderr:write("lite: " .. tostring(merr) .. "\n") end
        os.exit(2)
    end
    local items = memory:search(query, { limit = 10 })
    if json then
        emit({ type = "memory", dir = memory.dir, items = items })
    elseif #items == 0 then
        print("no memory in " .. memory.dir)
    else
        for _, it in ipairs(items) do
            print(string.format("[%.2f] %s\n  %s", it.score or 0, it.key, it.text or ""))
        end
    end
    memory:close()
    os.exit(0)
elseif cmd == "--tui" then
    local flags, pos = parse_flags(rest)
    -- 无子命令时未知选项会落到这里（见上面 SUBCOMMANDS 那段），别静默吞掉
    if #pos > 0 then
        io.stderr:write("lite: ignoring unexpected argument: " .. tostring(pos[1]) .. "\n")
    end
    local config = require("core.config").load()
    if flags.thinking then config.thinking = true end
    if flags.reasoning_effort then config.reasoning_effort = flags.reasoning_effort end
    if flags.sandbox then config.sandbox = "enforce" end
    if flags.approval then config.approval = flags.approval end
    if flags.max_turns then config.max_turns = flags.max_turns end
    if flags.debug_log then config.debug_log = flags.debug_log end
    if not flags.snapshot and (not config.api_key or config.api_key == "") then
        io.stderr:write("lite: missing DEEPSEEK_API_KEY\n")
        os.exit(2)
    end

    local Context = require("context")
    local Tools = require("core.tools")
    local Session = require("core.session")
    local Provider = require("core.provider")
    local Agent = require("core.agent")
    local Memory = require("core.memory")
    local http = require("core.http")

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
        debug_log = config.debug_log,
    })
    local Debug = require("core.debug")
    local logger = Debug.new(config.debug_log)
    if logger then ctx.settings.debug = logger end
    local memory, merr = Memory.new({
        dir = config.memory_dir or config.cwd,
        max_mb = config.memory_mb,
        flush_sec = config.memory_flush,
    })
    if not memory then
        io.stderr:write("lite: " .. tostring(merr) .. "\n")
        os.exit(2)
    end

    local multi, mlerr = http.multi_new()
    if not multi then
        memory:close()
        io.stderr:write("lite: " .. tostring(mlerr) .. "\n")
        os.exit(2)
    end
    ctx.settings.multi = multi

    local tools = Tools.new({
        cwd = config.cwd,
        memory = memory,
        ctx = ctx,
        sandbox = config.sandbox,
        sandbox_net = config.sandbox_net,
    })

    -- 只从当前目录的 mem.bin 恢复；全局 JSONL 不参与（见 Session.from_memory）。
    local prev = Session.from_memory(memory, config.cwd, 5)
    local restored, restored_id, restored_turn = {}, nil, 0
    if prev then
        restored = prev.messages
        restored_id = prev.id
        restored_turn = prev.turn
    end
    if restored_id then ctx.session.id = restored_id end
    ctx.session.turn = restored_turn or 0
    ctx.session.messages = restored
    memory:ensure_session(ctx.session.id, config.cwd, config.model)
    if tools.todos then tools.todos:load() end

    local msg_count = memory:session_message_count(ctx.session.id)
    local session = Session.new(ctx, { memory = memory, seq = math.max(#ctx.session.messages, msg_count) })
    local agent = Agent.new(ctx, Provider, tools, session, memory)
    -- 恢复会话时把落盘的 usage 接回来，否则状态栏/命中率从 0 开始。
    agent:restore_usage()

    if flags.snapshot then
        local patch = ""
        if flags.snapshot_diff then
            local p = io.popen("cd " .. shq(config.cwd)
                .. " && git --no-pager diff --no-color --no-ext-diff -U3 2>/dev/null", "r")
            if p then patch = p:read("*a") or ""; p:close() end
        end
        local ok, err = require("tui.snapshot").write(flags.snapshot, ctx, {
            messages = restored,
            text = flags.snapshot_text,
            todo = flags.snapshot_todo,
            diff = flags.snapshot_diff,
            diff_patch = patch,
            width = flags.width,
            height = flags.height,
            mem = memory:stats().count or 0,
        })
        memory:close()
        http.multi_free(multi)
        if logger then logger:close() end
        if not ok then
            io.stderr:write("lite snapshot: " .. tostring(err) .. "\n")
            os.exit(1)
        end
        os.exit(0)
    end

    local ok, err = require("tui").run(ctx, agent, memory, {
        multi = multi,
        messages = restored,
    })
    memory:close()
    http.multi_free(multi)
    if logger then logger:close() end
    if not ok then
        io.stderr:write("lite: " .. tostring(err) .. "\n")
        os.exit(1)
    end
    os.exit(0)
elseif cmd == "--once" then
    local flags, pos = parse_flags(rest)
    local prompt = pos[1]
    if not prompt or prompt == "" then
        if json then emit({ type = "error", error = "missing prompt" })
        else io.stderr:write("lite: --once requires a prompt\n") end
        os.exit(2)
    end

    local config = require("core.config").load()
    if flags.max_turns then config.max_turns = flags.max_turns end
    if not config.api_key or config.api_key == "" then
        if json then emit({ type = "error", error = "missing DEEPSEEK_API_KEY" })
        else io.stderr:write("lite: missing DEEPSEEK_API_KEY\n") end
        os.exit(2)
    end

    local Context = require("context")
    local Tools = require("core.tools")
    local Session = require("core.session")
    local Provider = require("core.provider")
    local Agent = require("core.agent")
    local Memory = require("core.memory")

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
        debug_log = config.debug_log,
    })
    local Debug = require("core.debug")
    local logger = Debug.new(config.debug_log)
    if logger then ctx.settings.debug = logger end
    local memory, merr = Memory.new({
        dir = config.memory_dir or config.cwd,
        max_mb = config.memory_mb,
        flush_sec = config.memory_flush,
    })
    if not memory then
        if json then emit({ type = "error", error = tostring(merr) })
        else io.stderr:write("lite: " .. tostring(merr) .. "\n") end
        os.exit(2)
    end

    local tools = Tools.new({
        cwd = config.cwd,
        memory = memory,
        ctx = ctx,
        sandbox = config.sandbox,
        sandbox_net = config.sandbox_net,
    })
    -- 与 TUI 路径一致：先登记会话 meta，否则 --once 写进 KV 的 msg/*
    -- 没有 /meta 索引，list_sessions 找不到，下次打开就等于没记录。
    memory:ensure_session(ctx.session.id, config.cwd, config.model)
    local session = Session.new(ctx, { memory = memory })
    local agent = Agent.new(ctx, Provider, tools, session, memory)
    agent:restore_usage()

    if json then
        ctx:on("reasoning", function(text) emit({ type = "reasoning", text = text }) end)
        ctx:on("delta", function(text) emit({ type = "delta", text = text }) end)
        ctx:on("tool_start", function(name, a) emit({ type = "tool_start", name = name, args = a }) end)
        ctx:on("tool_result", function(name, result) emit({ type = "tool_result", name = name, result = result }) end)
        ctx:on("assistant", function(m) emit({ type = "assistant", content = m.content or "" }) end)
        ctx:on("error", function(err) emit({ type = "error", error = tostring(err) }) end)
        ctx:on("compact", function(info)
            emit({
                type = "compact", ok = info.ok, reason = info.reason,
                baseline = info.baseline, stats = info.stats,
                used = info.used, line = info.line,
                dropped = info.dropped, est_tokens = info.est_tokens,
            })
        end)
        ctx:on("turn_limit", function(info)
            emit({
                type = "turn_limit",
                reason = info.reason,
                turns = info.turns,
            })
        end)
        ctx:on("prefix_drop", function(d)
            emit({
                type = "prefix_drop",
                ratio = d.ratio,
                hit = d.hit,
                denom = d.denom,
                prompt = d.prompt,
                prev_prompt = d.prev_prompt,
            })
        end)
        ctx:on("usage", function(u, total)
            emit({
                type = "usage",
                prompt = u.prompt,
                completion = u.completion,
                cache_hit = u.cache_hit,
                cache_miss = u.cache_miss,
                requests = total and total.requests,
                cache_ratio = total and ((total.cache_hit + total.cache_miss) > 0
                    and (total.cache_hit / (total.cache_hit + total.cache_miss)) or nil),
                -- 第二种口径：hit / min(上一轮 prompt, 本轮 prompt)。
                -- cache_ratio 会被每轮新增的工具输出稀释，这个不会。
                reuse = u.reuse,
                prefix_ratio = total and total.prefix_denom and total.prefix_denom > 0
                    and (total.prefix_hit / total.prefix_denom) or nil,
            })
        end)
    else
        ctx:on("reasoning", function(text)
            io.write("\27[90m", text, "\27[0m")
            io.flush()
        end)
        ctx:on("delta", function(text)
            io.write(text)
            io.flush()
        end)
        ctx:on("tool_start", function(name, a)
            io.write(string.format("\n\n● %s %s\n", name, tostring(a.command or a.path or "")))
            io.flush()
        end)
        ctx:on("tool_result", function(name, result)
            local s = tostring(result or "")
            if #s > 800 then s = s:sub(1, 800) .. "\n..." end
            io.write(s, "\n")
            io.flush()
        end)
        ctx:on("error", function(err)
            io.stderr:write("lite: " .. tostring(err) .. "\n")
        end)
    end

    local text, err = agent:run(prompt)
    if json then
        emit({ type = "done", ok = err == nil, error = err })
    else
        io.write("\n")
        io.flush()
    end
    memory:close()
    if logger then logger:close() end
    if err then os.exit(1) end
    os.exit(0)
else
    if json then emit({ type = "error", error = "unknown argument: " .. tostring(cmd) })
    else
        io.stderr:write("lite: unknown argument: " .. tostring(cmd) .. "\n")
        usage()
    end
    os.exit(1)
end
