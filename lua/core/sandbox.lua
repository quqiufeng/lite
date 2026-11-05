-- Linux bubblewrap 沙箱：只读根 + workspace 可写；失败即拒绝（fail closed）。
local M = {}

local cached

function M.available()
    if cached ~= nil then return cached end
    local rc = os.execute("command -v bwrap >/dev/null 2>&1")
    cached = (rc == 0 or rc == true)
    return cached
end

local function mode_on(v)
    if v == nil then return false end
    if type(v) == "boolean" then return v end
    v = tostring(v):lower()
    return v == "1" or v == "true" or v == "on" or v == "enforce" or v == "auto"
end

function M.enabled(v)
    return mode_on(v)
end

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- 返回需要执行的完整 shell 命令；不可用时返回 nil, error。
function M.wrap(command, opts)
    opts = opts or {}
    if not M.available() then
        return nil, "sandbox requested but bwrap is not installed"
    end
    local cwd = tostring(opts.cwd or ".")
    local parts = {
        "bwrap",
        "--die-with-parent",
        "--ro-bind", shq("/"), shq("/"),
        "--dev", shq("/dev"),
        "--proc", shq("/proc"),
        "--tmpfs", shq("/tmp"),
        "--bind", shq(cwd), shq(cwd),
        "--chdir", shq(cwd),
        "--setenv", shq("TMPDIR"), shq("/tmp"),
    }
    if opts.network == false then
        parts[#parts + 1] = "--unshare-net"
    end
    parts[#parts + 1] = "--"
    parts[#parts + 1] = "bash"
    parts[#parts + 1] = "-lc"
    parts[#parts + 1] = shq(command)
    return table.concat(parts, " ")
end

return M
