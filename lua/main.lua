-- lite 入口：--check / --once / --recall；支持 --json 供 agent 驱动。
local VERSION = "0.1.1"

local function usage()
    io.write([[
lite — DeepSeek 终端 coding agent

用法:
  lite --check                 检查运行依赖
  lite --once "<prompt>"       无 UI 单轮/工具循环（流式输出）
  lite --recall "<query>"      查询当前目录的本地记忆
  lite --version               版本
  lite --help                  帮助

选项:
  --json                       机器可读 JSONL 输出（AI agent 友好）

环境:
  DEEPSEEK_API_KEY             必需
  DEEPSEEK_BASE_URL            默认 https://api.deepseek.com
  DEEPSEEK_MODEL               默认 deepseek-chat
  LITE_CWD                     默认当前目录
  LITE_MAX_TURNS               默认 16
  LITE_JSON=1                  等价于 --json

状态: TUI 尚未实现；--once 是当前唯一执行入口。
]])
end

local args = {}
for i = 1, #arg do args[#args + 1] = arg[i] end

local json = os.getenv("LITE_JSON") == "1"
local rest = {}
for i = 2, #args do
    if args[i] == "--json" then
        json = true
    else
        rest[#rest + 1] = args[i]
    end
end

local function emit(obj)
    local cjson = require("cjson")
    io.write(cjson.encode(obj), "\n")
    io.flush()
end

local cmd = args[1]

if cmd == "--version" then
    if json then emit({ type = "version", version = VERSION })
    else print("lite " .. VERSION) end
    os.exit(0)
elseif cmd == "--help" or cmd == "-h" or cmd == nil then
    usage()
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
elseif cmd == "--once" then
    local prompt = rest[1]
    if not prompt or prompt == "" then
        if json then emit({ type = "error", error = "missing prompt" })
        else io.stderr:write("lite: --once requires a prompt\n") end
        os.exit(2)
    end

    local config = require("core.config").load()
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
    })
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

    local tools = Tools.new({ cwd = config.cwd, memory = memory })
    local session = Session.new(ctx)
    local agent = Agent.new(ctx, Provider, tools, session, memory)

    if json then
        ctx:on("delta", function(text) emit({ type = "delta", text = text }) end)
        ctx:on("tool_start", function(name, a) emit({ type = "tool_start", name = name, args = a }) end)
        ctx:on("tool_result", function(name, result) emit({ type = "tool_result", name = name, result = result }) end)
        ctx:on("assistant", function(m) emit({ type = "assistant", content = m.content or "" }) end)
        ctx:on("error", function(err) emit({ type = "error", error = tostring(err) }) end)
    else
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
