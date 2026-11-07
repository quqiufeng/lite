-- 复制到系统剪贴板：先本地命令（xclip/wl-copy/xsel/pbcopy），失败再 OSC 52。
-- OSC 52 走终端自身，ssh/远程容器里也能把文本送进本地剪贴板。
local M = {}

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- 命令是否存在；结果缓存，避免每次拖拽都叉一个 shell。
local found = {}

local function have(cmd)
    local cached = found[cmd]
    if cached ~= nil then return cached end
    local p = io.popen("command -v " .. shq(cmd) .. " 2>/dev/null")
    local ok = false
    if p then
        local out = p:read("*l")
        p:close()
        ok = out ~= nil and out ~= ""
    end
    found[cmd] = ok
    return ok
end

-- 执行命令并把 text 从 stdin 送进去；返回是否成功。
local function pipe(cmd, text)
    local p = io.popen(cmd .. " >/dev/null 2>&1", "w")
    if not p then return false end
    local ok = pcall(function() p:write(text) end)
    local closed = p:close()
    return ok and closed == true
end

-- base64（无换行）；纯 shell 调用，不引第三方库。
local function b64(text)
    local p = io.popen("printf %s " .. shq(text) .. " | base64 -w0", "r")
    if not p then return nil end
    local out = p:read("*a")
    p:close()
    if not out or out == "" then return nil end
    return (out:gsub("%s+$", ""))
end

local function osc52(text)
    local payload = b64(text)
    if not payload then return false end
    io.stdout:write("\27]52;c;" .. payload .. "\7")
    io.stdout:flush()
    return true
end

-- 复制成功返回 true, 方式名；text 为空返回 false, "empty"。
function M.copy(text)
    if not text or text == "" then return false, "empty" end
    if os.getenv("WAYLAND_DISPLAY") and have("wl-copy") then
        if pipe("wl-copy", text) then return true, "wl-copy" end
    end
    if have("xclip") then
        if pipe("xclip -selection clipboard", text) then return true, "xclip" end
    end
    if have("xsel") then
        if pipe("xsel --clipboard --input", text) then return true, "xsel" end
    end
    if have("pbcopy") then
        if pipe("pbcopy", text) then return true, "pbcopy" end
    end
    if osc52(text) then return true, "OSC52" end
    return false, "no clipboard"
end

return M
