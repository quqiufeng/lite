-- helper/lib/adb.lua — adb 传输层 + 设备操作
-- 迁自 /opt/my-agent：lib/ffi/adbhost.lua（CLI 后端）、lib/transport/adb.lua（串号/设备）、
-- lib/act/input.lua（tap/swipe/text/key/open/install）、lib/phone/control.lua（status/screenshot）。
-- 与 agent 同进程，走 io.popen；设备没插时所有操作 fail-fast 并给出 adb devices 原文。
local M = {}

local ADB = os.getenv("ADB") or "adb"
local DEFAULT_TIMEOUT = tonumber(os.getenv("LITE_ADB_TIMEOUT") or 20)

function M.q(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function join(argv)
    local out = {}
    for i, a in ipairs(argv) do out[i] = M.q(a) end
    return table.concat(out, " ")
end

-- 跑一条 shell 命令；返回 {code, output, ok}。用尾部哨兵拿退出码（io.popen 不返回 code）。
function M.sh(cmd, opts)
    opts = opts or {}
    local t = opts.timeout or DEFAULT_TIMEOUT
    local wrapped = "timeout " .. t .. " sh -c " .. M.q(cmd)
        .. " 2>&1; printf '\\n__rc=%d\\n' $?"
    local p = io.popen(wrapped, "r")
    if not p then return nil, "cannot spawn shell" end
    local out = p:read("*a") or ""
    p:close()
    local code = tonumber(out:match("__rc=(%-?%d+)%s*$")) or -1
    out = out:gsub("%s*__rc=%-?%d+%s*$", "")
    return { code = code, output = out, ok = code == 0 }
end

function M.adb(serial, argv, opts)
    local t = { ADB }
    if serial and serial ~= "" then t[#t + 1] = "-s"; t[#t + 1] = serial end
    for _, a in ipairs(argv) do t[#t + 1] = tostring(a) end
    return M.sh(join(t), opts)
end

function M.shell(serial, cmd, opts)
    return M.adb(serial, { "shell", cmd }, opts)
end

-- 二进制安全：exec-out 直接重定向进文件，不过 Lua 字符串
function M.exec_out(serial, cmd, out_path)
    local t = { ADB }
    if serial and serial ~= "" then t[#t + 1] = "-s"; t[#t + 1] = serial end
    t[#t + 1] = "exec-out"; t[#t + 1] = cmd
    local rc = M.sh(join(t) .. " > " .. M.q(out_path) .. " 2>/dev/null", { timeout = 25 })
    if not rc then return false, "cannot spawn shell" end
    if rc.code ~= 0 then return false, "exec-out exit " .. rc.code end
    local f = io.open(out_path, "rb")
    if not f then return false, "no output file" end
    local size = f:seek("end")
    f:close()
    if not size or size == 0 then return false, "empty output" end
    return true
end

local function lines(s)
    local out = {}
    for line in (s or ""):gmatch("[^\n]+") do
        line = line:gsub("%s+$", "")
        if line ~= "" then out[#out + 1] = line end
    end
    return out
end
M.lines = lines

function M.devices()
    local r = M.adb(nil, { "devices" }, { timeout = 10 })
    if not r or r.code ~= 0 then
        return {}, (r and r.output or "adb not runnable"), r and r.code
    end
    local list = {}
    for _, line in ipairs(lines(r.output)) do
        local serial, state = line:match("^(%S+)%s+(%S+)")
        if serial and state and serial ~= "List" and serial ~= "*" then
            list[#list + 1] = { serial = serial, state = state }
        end
    end
    return list, nil, r.code
end

-- 串号解析：显式参数 → ADB_SERIAL/LITE_ADB_SERIAL → 唯一在线设备（USB 优先）
function M.resolve(explicit)
    if explicit and explicit ~= "" then return explicit end
    local env = os.getenv("LITE_ADB_SERIAL") or os.getenv("ADB_SERIAL")
    if env and env ~= "" then return env end
    local list = M.devices()
    local usb, wifi
    for _, d in ipairs(list) do
        if d.state == "device" then
            if d.serial:find(":", 1, true) then wifi = wifi or d.serial else usb = usb or d.serial end
        end
    end
    return usb or wifi
end

function M.need(explicit)
    local s = M.resolve(explicit)
    if s then return s end
    local list, err, code = M.devices()
    local seen = {}
    for _, d in ipairs(list) do seen[#seen + 1] = d.serial .. " " .. d.state end
    local detail = #seen > 0 and table.concat(seen, ", ") or ((err or "no device") .. " (exit " .. tostring(code) .. ")")
    return nil, "no adb device online: " .. detail
        .. " — 插 USB 并开 USB 调试，或 `adb connect <ip>:5555`；"
        .. "多设备时传 serial（或设 LITE_ADB_SERIAL）。required: device"
end

function M.prop(serial, name)
    local r = M.shell(serial, "getprop " .. name, { timeout = 10 })
    return r and (r.output:gsub("%s+$", "")) or ""
end

function M.size(serial)
    local r = M.shell(serial, "wm size", { timeout = 10 })
    local phys = r and r.output:match("Physical size:%s*(%d+x%d+)")
    local over = r and r.output:match("Override size:%s*(%d+x%d+)")
    return over or phys or ""
end

function M.status(serial)
    local s, err = M.need(serial)
    if not s then return nil, err end
    return {
        serial = s,
        model = M.prop(s, "ro.product.model"),
        brand = M.prop(s, "ro.product.brand"),
        android = M.prop(s, "ro.build.version.release"),
        sdk = M.prop(s, "ro.build.version.sdk"),
        size = M.size(s),
        ime = M.current_ime(s),
        adbkeyboard = M.has_adbkeyboard(s),
    }
end

function M.screencap(serial, out)
    local s, err = M.need(serial)
    if not s then return nil, err end
    local ok, why = M.exec_out(s, "screencap -p", out)
    if not ok then return nil, "screencap failed: " .. tostring(why) end
    return out
end

-- ---- 输入 ----

function M.current_ime(serial)
    local r = M.shell(serial, "settings get secure default_input_method", { timeout = 10 })
    return r and (r.output:gsub("%s+$", "")) or ""
end

function M.has_adbkeyboard(serial)
    local r = M.shell(serial, "pm list packages com.android.adbkeyboard", { timeout = 15 })
    return (r and r.output:find("com.android.adbkeyboard", 1, true)) ~= nil
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function M.b64(s)
    local out, src = {}, s
    local n = #src
    local i = 1
    while i <= n do
        local a, b, c = src:byte(i), src:byte(i + 1), src:byte(i + 2)
        local v = (a or 0) * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(v / 262144) % 64
        local c2 = math.floor(v / 4096) % 64
        local c3 = math.floor(v / 64) % 64
        local c4 = v % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=")
            .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
        i = i + 3
    end
    return table.concat(out)
end

function M.tap(serial, x, y)
    local s, err = M.need(serial)
    if not s then return nil, err end
    local mx = tonumber(x); local my = tonumber(y)
    if not mx or not my then return nil, "tap needs numeric x/y, got " .. tostring(x) .. "," .. tostring(y) end
    local r = M.shell(s, "input tap " .. math.floor(mx) .. " " .. math.floor(my), { timeout = 12 })
    return r and r.code == 0, r and r.output
end

function M.swipe(serial, x1, y1, x2, y2, ms)
    local s, err = M.need(serial)
    if not s then return nil, err end
    local n = { tonumber(x1), tonumber(y1), tonumber(x2), tonumber(y2) }
    for i = 1, 4 do
        if not n[i] then return nil, "swipe needs numeric x1,y1,x2,y2" end
    end
    local dur = tonumber(ms) or 300
    local cmd = string.format("input swipe %d %d %d %d %d",
        math.floor(n[1]), math.floor(n[2]), math.floor(n[3]), math.floor(n[4]), math.floor(dur))
    local r = M.shell(s, cmd, { timeout = 15 })
    return r and r.code == 0, r and r.output
end

local KEY_ALIAS = {
    home = "KEYCODE_HOME", back = "KEYCODE_BACK", wake = "KEYCODE_WAKEUP",
    sleep = "KEYCODE_SLEEP", enter = "KEYCODE_ENTER", power = "KEYCODE_POWER",
    menu = "KEYCODE_MENU", appswitch = "KEYCODE_APP_SWITCH", recents = "KEYCODE_APP_SWITCH",
}

function M.key(serial, name)
    local s, err = M.need(serial)
    if not s then return nil, err end
    if not name or name == "" then return nil, "key needs a name (home/back/enter/KEYCODE_xxx)" end
    local code = KEY_ALIAS[name:lower()] or (name:upper():find("^KEYCODE_") and name:upper() or "KEYCODE_" .. name:upper())
    local r = M.shell(s, "input keyevent " .. code, { timeout = 12 })
    return r and r.code == 0, r and r.output
end

-- 文本输入：装了 AdbKeyboard 走 base64 广播（支持中文），否则退回 input text（%s 转义空格）
function M.text(serial, text, opts)
    local s, err = M.need(serial)
    if not s then return nil, err end
    if not text or text == "" then return nil, "text 为空" end
    local plain = opts and opts.plain
    if not plain and M.has_adbkeyboard(s) then
        local prev = M.current_ime(s)
        M.shell(s, "ime enable com.android.adbkeyboard/.AdbIME", { timeout = 10 })
        M.shell(s, "ime set com.android.adbkeyboard/.AdbIME", { timeout = 10 })
        local r = M.shell(s, "am broadcast -a ADB_INPUT_B64 --es msg " .. M.q(M.b64(text)), { timeout = 15 })
        if prev ~= "" and prev ~= "com.android.adbkeyboard/.AdbIME" then
            M.shell(s, "ime set " .. M.q(prev), { timeout = 10 })
        end
        return r and r.code == 0 and r.output:find("Broadcast completed", 1, true) ~= nil, r and r.output
    end
    local esc = text:gsub("%s", "%%s"):gsub("([\"'()&|;<>$`\\%*%?%[%]%{%}~!#])", "\\%1")
    local r = M.shell(s, "input text " .. M.q(esc), { timeout = 20 })
    if r and r.code ~= 0 and r.output:find("Error", 1, true) then
        return nil, "input text 失败（非 ASCII 需要装 AdbKeyboard）: " .. r.output
    end
    return r and r.code == 0, r and r.output
end

function M.open(serial, pkg)
    local s, err = M.need(serial)
    if not s then return nil, err end
    if not pkg or pkg == "" then return nil, "open needs a package name" end
    local r = M.shell(s, "cmd package resolve-activity --brief " .. M.q(pkg) .. " 2>/dev/null", { timeout = 15 })
    local comp = r and r.output:match("([%w%.]+/[%w%.$]+)")
    if comp then
        local ok = M.shell(s, "am start -n " .. M.q(comp), { timeout = 15 })
        return ok and ok.code == 0, comp
    end
    local ok = M.shell(s, "monkey -p " .. M.q(pkg) .. " -c android.intent.category.LAUNCHER 1", { timeout = 20 })
    return ok and ok.code == 0, ok and ok.output
end

function M.apps(serial, filter)
    local s, err = M.need(serial)
    if not s then return nil, err end
    local r = M.shell(s, "pm list packages -3", { timeout = 25 })
    local out = {}
    for _, line in ipairs(lines(r and r.output)) do
        local pkg = line:match("package:(.*)")
        if pkg and (not filter or filter == "" or pkg:lower():find(filter:lower(), 1, true)) then
            out[#out + 1] = pkg
        end
    end
    return out
end

function M.install(serial, apk)
    local s, err = M.need(serial)
    if not s then return nil, err end
    if not apk or apk == "" then return nil, "install needs an apk path" end
    local r = M.adb(s, { "install", "-r", apk }, { timeout = 180 })
    return r and r.ok, r and r.output
end

return M
