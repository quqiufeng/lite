-- 微信模式：把「手机发消息 → 文件传输助手 → 本机 lite 执行」的常驻轮询挂到 TUI 上。
-- 真正的轮询在进程外（helper/lib/wx_watch_daemon.lua），这里只是开关 + 状态显示，
-- 免得用户在 TUI 里还要记得敲 `wechat_watch action=start`。
--
-- 与监工模式（lua/tui/watchdog.lua）同一套纪律：命令识别是纯逻辑、不碰 io，
-- 所以能在 tools/wx_watch_check.lua 里直接单测；插件调用走注入的 exec，
-- 拿不到 tools 时降级成一句错误提示，不抛异常。
local ModeCmd = require("tui.modecmd")

local M = {}

-- 开启写法（关闭写法走共用的 modecmd：#退出微信模式 / #退出微信）。
M.ON_WORDS = { "#微信模式", "#wx", "#微信" }

-- 返回 "on" / "off" / nil。
function M.command(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    for _, w in ipairs(M.ON_WORDS) do
        if s == w then return "on" end
    end
    if ModeCmd.is(s, { "微信" }) then return "off" end
    return nil
end

-- 插件输出 → 一行摘要（transcript 里贴整段太长：status 会带十几行日志）。
-- 出错原样透出：插件报错时截断等于把唯一线索砍了。
function M.head(res)
    local s = tostring(res or "")
    if s:match("^error") or s:match("^error:") then
        return s:gsub("%s+$", "")
    end
    local first = s:match("^[^\n]*") or ""
    return (first:gsub("%s+$", ""))
end

-- exec(name, args) -> 字符串（一般是 agent.tools:execute）。返回 { on, start, stop, status }。
function M.new(exec)
    local self = { on = false, res = nil, interval = nil }
    self.exec = exec

    local function call(args)
        if type(self.exec) ~= "function" then return "error: 没有可用的插件执行入口" end
        local ok, res = pcall(self.exec, "wechat_watch", args)
        if not ok then return "error: " .. tostring(res) end
        return tostring(res or "")
    end

    -- 返回 ok, 摘要。ok=false 只表示「没起来」，不影响已跑着的实例状态。
    function self:start(args)
        local a = { action = "start" }
        for k, v in pairs(args or {}) do a[k] = v end
        local res = call(a)
        self.res = res
        local ok = not res:match("^error")
        if ok then
            self.on = true
            if a.interval then self.interval = a.interval end
        end
        return ok, M.head(res)
    end

    function self:stop()
        local res = call({ action = "stop" })
        self.res = res
        self.on = false
        return M.head(res)
    end

    function self:status()
        return call({ action = "status" })
    end

    return self
end

return M
