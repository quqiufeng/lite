-- helper/sdb.lua — 电视（Sony BRAVIA）遥控：开/关/切输入源/自检
-- 传输与判定都在 helper/lib/sdb.lua；本文件只做工具面。
local function lib(env)
    local dir = (env and env.helper_dir) and (env.helper_dir .. "/lib") or "helper/lib"
    local path = dir .. "/sdb.lua"
    local f, e = loadfile(path)
    if not f then error("sdb: cannot load " .. path .. ": " .. tostring(e)) end
    return f()
end

local function report(t)
    -- port 可能是数字（HDMI 口号），也可能是 status 塞进来的说明串，别无条件套 "HDMI" 前缀
    local src = tostring(t.port)
    if src:match("^%d+$") then src = "HDMI" .. src end
    return ("电视 %s @ %s\n屏态：%s\n输入源：%s\n前台：%s"):format(
        t.model or "?", t.host or "?", t.wakefulness or "?", src, t.focus or "?")
end

local ACTIONS = {}

-- 默认动作：开电视 + 确认能操作 + 信号在 HDMI2
ACTIONS.ensure = function(S, args)
    local want = args.port or S.want_port
    local ok, rep, changed = S.ensure{ port = want, tries = args.tries }
    if not ok then
        return "没就绪：" .. tostring(rep) .. "\n（查：adb connect " .. S.host
            .. "；手动开一下电视再看）"
    end
    local moved = (changed and #changed > 0) and ("（本次动作：" .. table.concat(changed, "、") .. "）") or "（本来就好，没动它）"
    return "就绪 " .. moved .. "\n" .. report(rep)
end

-- 只看不动：不给任何写操作
ACTIONS.status = function(S)
    local ok, err = S.connect(1)
    if not ok then return "连不上：" .. tostring(err) end
    local port, why = S.current_port()
    local t = {
        model = S.model, host = S.host,
        wakefulness = S.wakefulness(),
        port = port and tostring(port) or ("非HDMI/" .. tostring(why)),
        focus = S.focus(),
    }
    return report(t) .. "\n（status 不改电视；要开/切源用 action=ensure 或 wake/input）"
end

ACTIONS.wake = function(S)
    local ok, err = S.connect(1)
    if not ok then return "连不上：" .. tostring(err) end
    local wok, msg = S.wake()
    if not wok then return "没开起来：" .. tostring(msg) end
    return msg .. "；屏态 " .. S.wakefulness()
end

ACTIONS.sleep = function(S)
    local ok, err = S.connect(1)
    if not ok then return "连不上：" .. tostring(err) end
    local _, msg = S.sleep()
    return msg .. "（休眠，可用 action=wake 再唤）"
end

ACTIONS.input = function(S, args)
    local port = tonumber(args.port)
    if not port then return "input 需要 port（1..4，对应 HDMI1..HDMI4）" end
    local ok, err = S.connect(1)
    if not ok then return "连不上：" .. tostring(err) end
    if S.wakefulness() ~= "Awake" then
        local wok, wm = S.wake()
        if not wok then return "电视没醒，切不了：" .. tostring(wm) end
    end
    local sok, smsg = S.switch_port(port)
    if not sok then return "切不过去：" .. tostring(smsg) end
    local p, why = S.current_port()
    return ("已切到 HDMI%d（回读确认：%s）"):format(port, p and ("HDMI" .. p) or tostring(why))
end

local SCHEMA = {
    name = "sdb",
    description = "电视（Sony BRAVIA / Android TV，adb wifi）遥控：ensure=开电视+确认可操作+信号在 HDMI2（box 执行前的前置检查就是它）/ status 只看不动 / wake / sleep / input 切 HDMI 口",
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                enum = { "ensure", "status", "wake", "sleep", "input" },
                description = "默认 ensure（开电视 + 确认能操作 + 切到 HDMI2 并回读验证）",
            },
            port = { type = "number", description = "ensure/input: HDMI 口号 1..4，默认 2" },
            tries = { type = "number", description = "ensure: adb 连接重试次数，默认 2" },
        },
        required = { "action" },
    },
}

return {
    schema = SCHEMA,
    run = function(args, env)
        args = args or {}
        local action = args.action or "ensure"
        local fn = ACTIONS[action]
        if not fn then
            local names = {}
            for k in pairs(ACTIONS) do names[#names + 1] = k end
            table.sort(names)
            return "sdb: unknown action " .. tostring(action) .. "; 可用: " .. table.concat(names, "|")
        end
        local ok, S = pcall(lib, env)
        if not ok then return "error: sdb 载入 lib 失败: " .. tostring(S) end
        local ok2, res = pcall(fn, S, args, env)
        if not ok2 then return "error: sdb " .. action .. ": " .. tostring(res) end
        return res
    end,
}
