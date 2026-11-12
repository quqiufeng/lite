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
  lite --reboot                重启后自动继续：起来就把上一轮 /reboot 留下的提示词发出去
                               （没留就用默认的「重启成功，继续工作。」）
  lite state [--json]          输出会话/记忆/todo 状态
  lite sessions [--json]       列出同 cwd 会话
  lite plugins [--json]        列出 helper/ 插件与加载错误
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
  --no-plugins                 禁用 helper/ 插件与 hook（默认启用）
  --reboot                     重启后自动继续（见用法里那条）
  --max-turns N                单次任务工具循环上限（默认 256）
  --debug                      开启调试日志（默认 $TMPDIR/lite-debug.jsonl）
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
    plugins = true, ["--plugins"] = true,
    ["--check"] = true, ["--recall"] = true, ["--tui"] = true, ["--once"] = true,
    ["--gui"] = true,
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

local function default_debug_log()
    return (os.getenv("TMPDIR") or "/tmp") .. "/lite-debug.jsonl"
end

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
        elseif a == "--reboot" then
            flags.reboot = true
            i = i + 1
        elseif a == "--no-plugins" then
            flags.no_plugins = true
            i = i + 1
        elseif a == "--sandbox" then
            flags.sandbox = true
            i = i + 1
        elseif a == "--approval" then
            flags.approval = list[i + 1]
            i = i + 2
        elseif a == "--max-turns" then
            flags.max_turns = tonumber(list[i + 1])
            i = i + 2
        elseif a == "--debug" then
            flags.debug = true
            i = i + 1
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

-- 自重启的兜底路径：execv 原地换进程（进程还是同一个，只换镜像）。
-- 正常走的是 main.lua 末尾那条「退出码 75 → tools/lite-lua 监督循环拉起新进程」，
-- 只有裸跑（`luajit lua/main.lua`、不经 wrapper 的安装部署）才落到这里。终端、
-- 工作目录、会话 id 全部保留，只有代码/插件清单重新加载（`native build` 出的
-- 新 .so、新建的 helper/*.lua 都能上桌）。
--
-- argv 直接从 `arg` 表还原：`arg[-1]` 是最靠近脚本的那一项，`arg[-2..]` 往前是
-- 它的选项（外层包装脚本 tools/lite-lua 会塞 `-e <prelude>`），`arg[0]` 是脚本，
-- `arg[1..]` 是 lite 自己的参数。所以无论从 run.sh / lite-lua / 裸 luajit 启动
-- 都能原样重启。重启链不设上限（见 tools/lite-lua 里的说明）。
local function exec_self(extra)
    local ffi = require("ffi")
    pcall(ffi.cdef, [[
        int execv(const char *path, char *const argv[]);
    ]])
    local path = arg[-1]
    if not path then return false, "cannot locate interpreter (arg[-1])" end

    local keep, argv = {}, {}
    local function push(s)
        local c = ffi.cast("char *", tostring(s))
        keep[#keep + 1] = c
        argv[#argv + 1] = c
    end
    -- 解释器调用前缀：arg[-1] 是最靠近脚本的那一项（多 -e 时是最后一个 chunk），
    -- 往前依次是它的选项、最右端才是解释器本体 —— 倒序抄回去正好是命令行原序。
    local prefix, i = {}, -1
    while arg[i] do prefix[#prefix + 1] = arg[i]; i = i - 1 end
    for j = #prefix, 1, -1 do push(prefix[j]) end
    push(arg[0] or "lua/main.lua")
    local seen = false
    for j = 1, #arg do
        push(arg[j])
        if arg[j] == "--reboot" then seen = true end
    end
    -- 新进程带 --reboot 起来 → 输入框自动填「重启成功，继续工作。」再提交。
    if not seen then push("--reboot") end

    local arr = ffi.new("char *[?]", #argv + 1)
    for j = 1, #argv do arr[j - 1] = argv[j] end
    io.stdout:flush()
    io.stderr:flush()
    ffi.C.execv(prefix[#prefix] or path, arr)
    return false, "execv failed: " .. tostring(ffi.errno())
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
    if flags.no_plugins then config.plugins = false end
    if flags.max_turns then config.max_turns = flags.max_turns end
    if flags.debug_log then config.debug_log = flags.debug_log end
    if flags.debug and not config.debug_log then config.debug_log = default_debug_log() end
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
elseif cmd == "plugins" or cmd == "--plugins" then
    -- helper/ 是隐式加载的：坏了、被 --no-plugins 关掉、藏在哪个 root，都只能问这里。
    local flags = parse_flags(rest)
    local config = require("core.config").load()
    if flags.no_plugins then config.plugins = false end
    local Tools = require("core.tools")
    local tools = Tools.new({ cwd = config.cwd, plugins = config.plugins })
    local rep = tools:plugin_report()
    if json then
        emit({ type = "plugins", cwd = config.cwd, plugins = rep })
    else
        print("cwd " .. config.cwd)
        print(tools:plugins_report())
    end
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
elseif cmd == "--tui" or cmd == "--gui" then
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
    if flags.no_plugins then config.plugins = false end
    if flags.max_turns then config.max_turns = flags.max_turns end
    if flags.debug_log then config.debug_log = flags.debug_log end
    if flags.debug and not config.debug_log then config.debug_log = default_debug_log() end
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
        context_window = config.context_window,
        reserve_tokens = config.reserve_tokens,
        compact = config.compact,
        max_output_tokens = config.max_output_tokens,
        token_budget = config.token_budget,
        thinking = config.thinking,
        reasoning_effort = config.reasoning_effort,
        max_retries = config.max_retries,
        approval = config.approval,
        debug_log = config.debug_log,
    })
    local Debug = require("core.debug")
    local logger = Debug.new(config.debug_log)
    if logger then ctx.settings.debug = logger end
    -- 快照只读不写记忆，也就没必要抢写锁。
    local snapshot_only = flags.snapshot or flags.snapshot_text or flags.snapshot_todo or flags.snapshot_diff
    local memory, merr = Memory.new({
        dir = config.memory_dir or config.cwd,
        max_mb = config.memory_mb,
        flush_sec = config.memory_flush,
        readonly = snapshot_only and true or false,
    })
    if not memory then
        io.stderr:write("lite: " .. tostring(merr) .. "\n")
        os.exit(2)
    end
    if memory.lock_busy and not snapshot_only then
        io.stderr:write("lite: memory busy, read-only until lock frees (auto-retry): " .. tostring(config.memory_dir or config.cwd) .. "\n")
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
        plugins = config.plugins,
    })

    -- 只从当前目录的 mem.bin 恢复；只有 KV 一条会话都没有时，才由
    -- Session.from_memory 第 3 步从全局 JSONL 备份兜底（mem.bin 损坏/被截断）。
    local prev = Session.from_memory(memory, config.cwd, 5)
    if prev and prev.from_jsonl then
        io.stderr:write("lite: mem.bin has no session, recovered from JSONL backup "
            .. tostring(prev.id) .. " (" .. tostring(prev.path) .. ")\n")
    end
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
            plugin_errors = tools:plugin_report().errors,
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

    if cmd == "--gui" then
        local gok, gerr = require("gui.transcript").run(ctx, { agent = agent })
        memory:close()
        http.multi_free(multi)
        if logger then logger:close() end
        if not gok then
            io.stderr:write("lite gui: " .. tostring(gerr) .. "\n")
            os.exit(1)
        end
        os.exit(0)
    end

    -- 上一轮 `/reboot <提示词>`（或 reboot 工具带 prompt）留下的那句话：新进程带
    -- --reboot 起来时一次性取走，优先于默认的「重启成功，继续工作。」
    local reboot_text
    if flags.reboot then reboot_text = require("core.reboot").take(config.cwd) end

    local ok, err = require("tui").run(ctx, agent, memory, {
        multi = multi,
        messages = restored,
        reboot = flags.reboot,
        reboot_text = reboot_text,
    })
    -- shutdown 工具置的 exit 压过 reboot：说了退出就不再 execv，直接 os.exit(0)。
    local reboot = ctx.settings and ctx.settings.reboot and not ctx.settings.exit
    memory:close()
    http.multi_free(multi)
    if logger then logger:close() end
    if not ok then
        io.stderr:write("lite: " .. tostring(err) .. "\n")
        os.exit(1)
    end
    -- `/reboot` 或 reboot 工具置的标记：换一个全新进程，新进程带 --reboot 起来后
    -- 自动重发这句话（`/reboot <提示词>` 给的那句，没给就是默认的「重启成功，继续
    -- 工作。」），所以对话是连着的。
    --
    -- 默认路径是**退出码 75 + 父进程拉起**（tools/lite-lua 监督循环，它导出了
    -- LITE_SUPERVISED=1）：新进程 = 新 Lua 状态，插件清单一类的东西全部重扫，
    -- 而且出错时 tty 一直在 wrapper 手里。只有裸跑（`luajit lua/main.lua`、装了
    -- 二进制但不经 wrapper）才退回原地 execv。
    if reboot then
        -- 提示词落盘必须在换进程之前：wrapper/execv 都只继承旧环境，argv 又会被
        -- `ps` 看见，只有文件能把它带到新进程（见 lua/core/reboot.lua）。
        require("core.reboot").save(ctx.settings.reboot_prompt, config.cwd)
        if os.getenv("LITE_SUPERVISED") == "1" then
            io.stdout:flush()
            io.stderr:flush()
            os.exit(75)
        end
        local rok, rerr = exec_self()
        if not rok then
            io.stderr:write("lite: reboot failed: " .. tostring(rerr) .. "\n")
            os.exit(1)
        end
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
    if flags.debug_log then config.debug_log = flags.debug_log end
    if flags.debug and not config.debug_log then config.debug_log = default_debug_log() end
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
        context_window = config.context_window,
        reserve_tokens = config.reserve_tokens,
        compact = config.compact,
        max_output_tokens = config.max_output_tokens,
        token_budget = config.token_budget,
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
    if memory.lock_busy then
        io.stderr:write("lite: memory busy, read-only until lock frees (auto-retry): " .. tostring(config.memory_dir or config.cwd) .. "\n")
    end

    local tools = Tools.new({
        cwd = config.cwd,
        memory = memory,
        ctx = ctx,
        sandbox = config.sandbox,
        sandbox_net = config.sandbox_net,
        plugins = config.plugins,
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
