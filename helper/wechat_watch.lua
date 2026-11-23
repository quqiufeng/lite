-- wechat_watch 插件 — 在手机微信给「文件传输助手」发消息，本机 lite 轮询收到就执行。
-- 逻辑全在 helper/lib/wx_watch_daemon.lua（常驻）+ helper/lib/wx_watch.lua（纯逻辑），
-- 本文件只做进程账（拉起/收掉/看状态/单次试跑），不进 agent 自己的线程。
--
-- 为什么要常驻在**进程外**：轮询要反复截屏 + OCR（每轮 1~2s 阻塞）+ 用鼠标右键气泡，
-- 放在 agent 线程里会把每一轮对话都卡住；派发走 serve 的 HTTP /prompt，agent 在自己的
-- 进程里跑，互不干扰（同一时刻只有一边在动微信窗口）。
--
-- 触发前缀（默认 "#lite"）：文件传输助手平时还是发笔记/文件的中转站，全收会把随手记
-- 也当指令执行。加 # 是因为裸 "lite" 太容易误触（任何以 lite 开头的单词都算）。
-- 只认 "#lite 帮我看看磁盘" / "#lite：跑一下测试"，其余只记日志不执行；
-- 想全收就 prefix=""（注意：那一刻起，凡是你自己发到箱子的东西都会被当指令跑）。
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function root_of(env)
    local hd = (env and env.helper_dir) or "helper"
    local root = hd:gsub("/helper$", "")
    if root == hd then root = "." end
    return root, hd
end

local function state_dir()
    if os.getenv("LITE_WX_STATE") then return os.getenv("LITE_WX_STATE") end
    local data = os.getenv("XDG_DATA_HOME")
        or ((os.getenv("HOME") or "/tmp") .. "/.local/share")
    return data .. "/lite/wx-watch"
end

local function read_file(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end

local function alive(pid)
    if not pid or pid == "" then return false end
    local ok = os.execute("kill -0 " .. tonumber(pid) .. " 2>/dev/null")
    return ok == 0
end

local function pidfile() return state_dir() .. "/daemon.pid" end

local function pid()
    local s = read_file(pidfile())
    return s and (s:gsub("%s", "")) or nil
end

local function opts(a)
    local o = {}
    if a.interval then o[#o + 1] = "--interval " .. tonumber(a.interval) end
    if a.port then o[#o + 1] = "--port " .. tonumber(a.port) end
    if a.prefix ~= nil then o[#o + 1] = "--prefix " .. q(a.prefix) end
    if a.chat then o[#o + 1] = "--chat " .. q(a.chat) end
    if a.max_new then o[#o + 1] = "--max-new " .. tonumber(a.max_new) end
    if a.hide == false then o[#o + 1] = "--no-hide" end
    if a.no_raise then o[#o + 1] = "--no-raise" end
    if a.no_spawn then o[#o + 1] = "--no-spawn" end
    return table.concat(o, " ")
end

local M = {}

M.schema = {
    name = "wechat_watch",
    description = "手机微信→本机执行：常驻轮询「文件传输助手」，带 lite 前缀的消息当指令跑（start/stop/status/once/tail）",
    parameters = {
        type = "object",
        properties = {
            action = { type = "string",
                enum = { "start", "stop", "status", "once", "tail" },
                description = "start=拉起常驻；stop=收掉；status=进程/日志；once=单轮试跑（默认只看不执行）；tail=看日志" },
            interval = { type = "integer", description = "轮询间隔秒，默认 10" },
            port = { type = "integer", description = "serve 端口，默认 8765" },
            prefix = { type = "string", description = "触发前缀，默认 #lite；给空串=全收" },
            chat = { type = "string", description = "目标会话名，默认 文件传输助手" },
            max_new = { type = "integer", description = "单轮最多执行几条，默认 3" },
            dispatch = { type = "boolean", description = "once：true=真的派发执行（默认只看不跑）" },
            dry_run = { type = "boolean", description = "start：true=只记录不执行（排错用）" },
            hide = { type = "boolean", description = "没新消息时是否最小化微信，默认 true；false=让它一直摊着" },
            no_raise = { type = "boolean", description = "true=不抢微信前台（窗口会遮挡，OCR 会读到别的窗口）" },
            no_spawn = { type = "boolean", description = "true=不自动拉起 serve（没 serve 时退回一次性执行）" },
            lines = { type = "integer", description = "tail：日志行数，默认 40" },
        },
    },
}

function M.run(args, env)
    args = args or {}
    local action = args.action or "status"
    local root, hd = root_of(env)
    local lua = root .. "/tools/lite-lua"
    local daemon = hd .. "/lib/wx_watch_daemon.lua"
    local sd = state_dir()
    local logf = sd .. "/daemon.log"
    local cwd = (env and env.cwd) or os.getenv("PWD") or "."

    if not read_file(daemon) then
        return "error: 找不到 " .. daemon .. "（插件没装全？）"
    end

    if action == "start" then
        local p = pid()
        if alive(p) then
            return string.format("已在跑：pid %s（interval 见 %s）\n日志：%s", p, pidfile(), logf)
        end
        os.execute("mkdir -p " .. q(sd))
        local flags = opts(args)
        if args.dry_run then flags = flags .. " --dry-run" end
        local cmd = string.format(
            "cd %s && setsid nohup %s %s --cwd %s --state %s %s >> %s 2>&1 &",
            q(cwd), q(lua), q(daemon), q(cwd), q(sd), flags, q(logf))
        os.execute(cmd)
        for _ = 1, 30 do
            local np = pid()
            if alive(np) then
                return string.format("已启动：pid %s\n间隔 %ds · 前缀 %q · 会话 %s\n日志：%s",
                    np, tonumber(args.interval) or 10,
                    args.prefix ~= nil and args.prefix or "#lite",
                    args.chat or "文件传输助手", logf)
            end
            os.execute("sleep 0.1")
        end
        local tail = read_file(logf) or ""
        return "error: 3s 内没等到 pidfile，日志尾巴：\n" .. tail:sub(-800)
    elseif action == "stop" then
        local p = pid()
        if not alive(p) then
            os.remove(pidfile())
            return "没在跑"
        end
        os.execute("kill -TERM " .. tonumber(p))
        for _ = 1, 50 do
            if not alive(p) then break end
            os.execute("sleep 0.1")
        end
        if alive(p) then os.execute("kill -KILL " .. tonumber(p)) end
        os.remove(pidfile())
        return "已停止（pid " .. tostring(p) .. "）"
    elseif action == "status" then
        local p = pid()
        local up = alive(p)
        local st = read_file(sd .. "/state.json")
        local nprev, npend = 0, 0
        if st then
            local ok, t = pcall(function() return require("cjson").decode(st) end)
            if ok and type(t) == "table" then
                nprev = #(t.prev or {}); npend = #(t.pending or {})
            end
        end
        local tail = read_file(logf) or ""
        local lns = {}
        for line in (tail .. "\n"):gmatch("(.-)\n") do lns[#lns + 1] = line end
        local from = math.max(1, #lns - (tonumber(args.lines) or 12) + 1)
        return table.concat({
            ("状态：%s%s"):format(up and "运行中" or "未运行", up and ("（pid " .. p .. "）") or ""),
            ("状态目录：%s"):format(sd),
            ("上一帧可见消息 %d 条 · 待派发 %d 条"):format(nprev, npend),
            "最近日志：",
            table.concat(lns, "\n", from, #lns),
        }, "\n")
    elseif action == "tail" then
        local tail = read_file(logf) or ""
        local n = tonumber(args.lines) or 40
        local lns = {}
        for line in (tail .. "\n"):gmatch("(.-)\n") do lns[#lns + 1] = line end
        local from = math.max(1, #lns - n + 1)
        return table.concat(lns, "\n", from, #lns)
    elseif action == "once" then
        local flags = opts(args) .. " --once"
        if not args.dispatch then flags = flags .. " --dry-run" end
        local cmd = string.format("cd %s && %s %s --cwd %s --state %s %s 2>&1",
            q(cwd), q(lua), q(daemon), q(cwd), q(sd), flags)
        local h = io.popen(cmd)
        if not h then return "error: 起不来 " .. lua end
        local out = h:read("*a") or ""
        h:close()
        return out:sub(-4000)
    end
    return "error: unknown action " .. tostring(action)
end

return M
