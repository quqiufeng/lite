-- helper/adb.lua — adb 插件（Android 设备操作，迁自 /opt/my-agent 的 phone 能力）
-- 坐标是「设备像素」(adb input 坐标系)，不是桌面像素；先 screenshot 再按比例换算。
local function lib(env)
    local dir = (env and env.helper_dir) and (env.helper_dir .. "/lib") or "helper/lib"
    local path = dir .. "/adb.lua"
    local f, e = loadfile(path)
    if not f then error("adb: cannot load " .. path .. ": " .. tostring(e)) end
    return f()
end

local function tmp_png()
    local dir = os.getenv("TMPDIR") or "/tmp"
    if dir:sub(-1) == "/" then dir = dir:sub(1, -2) end
    return string.format("%s/lite-adb-%d-%d.png", dir, os.time(), math.random(1000, 9999))
end

local function tail(s, n)
    s = tostring(s or ""):gsub("%s+$", "")
    n = n or 1200
    if #s > n then return "..." .. s:sub(-n) end
    return s
end

local ACTIONS = {}

ACTIONS.devices = function(A)
    local list, err = A.devices()
    local out = {}
    for _, d in ipairs(list) do
        out[#out + 1] = string.format("%s  %s  (%s)", d.serial, d.state,
            d.serial:find(":", 1, true) and "wifi" or "usb")
    end
    if #out == 0 then
        local why = (err and err ~= "") and (": " .. tail(err)) or ""
        return "no adb device" .. why
            .. " — 插 USB 并开 USB 调试，或 adb connect <ip>:5555（先 connect 再看 devices）"
    end
    return table.concat(out, "\n")
end

ACTIONS.status = function(A, args)
    local st, err = A.status(args.serial)
    if not st then return "adb status failed: " .. err end
    return string.format("%s  %s %s  android %s (sdk %s)  %s  ime=%s  adbkeyboard=%s",
        st.serial, st.brand, st.model, st.android, st.sdk, st.size, st.ime,
        tostring(st.adbkeyboard))
end

ACTIONS.screenshot = function(A, args)
    local out = args.out
    if not out or out == "" then out = tmp_png() end
    local ok, err = A.screencap(args.serial, out)
    if not ok then return "adb screenshot failed: " .. tostring(err) end
    return "screenshot -> " .. out .. " (设备像素；tap/swipe 同坐标系)"
end

ACTIONS.tap = function(A, args)
    local ok, msg = A.tap(args.serial, args.x, args.y)
    if not ok then return "adb tap failed: " .. tail(msg) end
    return string.format("tap %s %s", tostring(args.x), tostring(args.y))
end

ACTIONS.swipe = function(A, args)
    local ok, msg = A.swipe(args.serial, args.x1, args.y1, args.x2, args.y2, args.ms)
    if not ok then return "adb swipe failed: " .. tail(msg) end
    return string.format("swipe %s,%s -> %s,%s in %sms", tostring(args.x1), tostring(args.y1),
        tostring(args.x2), tostring(args.y2), tostring(args.ms or 300))
end

ACTIONS.text = function(A, args)
    local ok, msg = A.text(args.serial, args.text, { plain = args.plain })
    if not ok then return "adb text failed: " .. tail(msg) end
    return "typed " .. #tostring(args.text) .. " chars: " .. tail(msg, 200)
end

ACTIONS.key = function(A, args)
    local ok, msg = A.key(args.serial, args.key)
    if not ok then return "adb key failed: " .. tail(msg) end
    return "key " .. tostring(args.key)
end

ACTIONS.open = function(A, args)
    local ok, msg = A.open(args.serial, args.package)
    if not ok then return "adb open failed: " .. tail(msg) end
    return "open " .. tostring(args.package) .. " -> " .. tail(msg, 300)
end

ACTIONS.apps = function(A, args)
    local list, err = A.apps(args.serial, args.filter)
    if not list then return "adb apps failed: " .. err end
    if #list == 0 then return "no third-party package matched " .. tostring(args.filter) end
    local head = {}
    for i = 1, math.min(#list, 80) do head[i] = list[i] end
    return table.concat(head, "\n") .. (#list > 80 and ("\n... +" .. (#list - 80) .. " more") or "")
end

ACTIONS.install = function(A, args)
    local ok, msg = A.install(args.serial, args.path)
    if not ok then return "adb install failed: " .. tail(msg) end
    return "install ok: " .. tail(msg, 300)
end

ACTIONS.shell = function(A, args)
    local s, err = A.need(args.serial)
    if not s then return "adb shell failed: " .. err end
    if not args.cmd or args.cmd == "" then return "adb shell 需要 cmd" end
    local r = A.shell(s, args.cmd, { timeout = tonumber(args.timeout) or 20 })
    if not r then return "adb shell failed: cannot spawn" end
    return string.format("[exit %d]%s\n%s", r.code, r.code == 124 and " (timeout)" or "", tail(r.output, 4000))
end

ACTIONS.push = function(A, args)
    local s, err = A.need(args.serial)
    if not s then return "adb push failed: " .. err end
    if not args.path or not args.remote then return "adb push 需要 path + remote" end
    local r = A.adb(s, { "push", args.path, args.remote }, { timeout = 120 })
    if not r or not r.ok then return "adb push failed: " .. tail(r and r.output) end
    return "push " .. args.path .. " -> " .. args.remote
end

ACTIONS.pull = function(A, args)
    local s, err = A.need(args.serial)
    if not s then return "adb pull failed: " .. err end
    if not args.remote or not args.path then return "adb pull 需要 remote + path" end
    local r = A.adb(s, { "pull", args.remote, args.path }, { timeout = 120 })
    if not r or not r.ok then return "adb pull failed: " .. tail(r and r.output) end
    return "pull " .. args.remote .. " -> " .. args.path
end

ACTIONS.connect = function(A, args)
    if not args.target or args.target == "" then return "adb connect 需要 target=<ip>:<port>" end
    local r = A.adb(nil, { "connect", args.target }, { timeout = 20 })
    return tail(r and r.output) .. (r and r.ok and "" or " (failed)")
end

ACTIONS.disconnect = function(A, args)
    local r = A.adb(nil, { "disconnect", args.target or "" }, { timeout = 15 })
    return tail(r and r.output)
end

local SCHEMA = {
    name = "adb",
    description = "Android 设备操作（adb）：devices/status/screenshot/tap/swipe/text/key/open/apps/install/shell/push/pull/connect。"
        .. "坐标是设备像素，先 screenshot 看图再点；中文输入自动走 AdbKeyboard base64 广播。",
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                enum = { "devices", "status", "screenshot", "tap", "swipe", "text", "key",
                    "open", "apps", "install", "shell", "push", "pull", "connect", "disconnect" },
                description = "要执行的动作",
            },
            serial = { type = "string", description = "设备串号；省略则 USB 优先/唯一在线设备" },
            x = { type = "number", description = "tap: x（设备像素）" },
            y = { type = "number", description = "tap: y（设备像素）" },
            x1 = { type = "number" }, y1 = { type = "number" },
            x2 = { type = "number" }, y2 = { type = "number" },
            ms = { type = "number", description = "swipe 时长，默认 300" },
            text = { type = "string", description = "text: 要输入的文本（中文需 AdbKeyboard）" },
            plain = { type = "boolean", description = "text: true 强制走 input text（忽略 AdbKeyboard）" },
            key = { type = "string", description = "key: home/back/enter/power/wake 或 KEYCODE_xxx" },
            package = { type = "string", description = "open: 包名" },
            filter = { type = "string", description = "apps: 包名过滤（子串）" },
            path = { type = "string", description = "screenshot/install/push 本地路径、pull 目标路径" },
            out = { type = "string", description = "screenshot: 输出 png 路径（默认 TMPDIR）" },
            cmd = { type = "string", description = "shell: 设备端命令" },
            timeout = { type = "number", description = "shell: 超时秒，默认 20" },
            remote = { type = "string", description = "push/pull: 设备端路径" },
            target = { type = "string", description = "connect/disconnect: <ip>:<port>" },
        },
        required = { "action" },
    },
}

local REQUIRED = {
    tap = { "x", "y" }, swipe = { "x1", "y1", "x2", "y2" }, text = { "text" },
    key = { "key" }, open = { "package" }, install = { "path" },
    shell = { "cmd" }, push = { "path", "remote" }, pull = { "remote", "path" },
    connect = { "target" },
}

return {
    schema = SCHEMA,
    run = function(args, env)
        args = args or {}
        local action = args.action
        local fn = action and ACTIONS[action]
        if not fn then
            local names = {}
            for k in pairs(ACTIONS) do names[#names + 1] = k end
            table.sort(names)
            return "adb: unknown action " .. tostring(action) .. "; required action: " .. table.concat(names, "|")
        end
        for _, k in ipairs(REQUIRED[action] or {}) do
            if args[k] == nil or args[k] == "" then
                return "adb " .. action .. " 缺少参数 " .. k .. " — required: " .. table.concat(REQUIRED[action], ",")
            end
        end
        local A = lib(env)
        local ok, res = pcall(fn, A, args)
        if not ok then return "error: adb " .. action .. ": " .. tostring(res) end
        return res
    end,
}
