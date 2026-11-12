-- Linux bubblewrap 沙箱：只读根 + workspace 可写；失败即拒绝（fail closed）。
local M = {}

local cached
local cached_reason

local function ok(rc) return rc == 0 or rc == true end

-- bwrap 装了不等于能用：Ubuntu 23.10+/24.04、容器、以及禁了非特权 user namespace
-- 的机器上，bwrap 二进制在、但一启动就 "Creating new namespace failed"。
-- 只看 `command -v` 会让 --sandbox 变成「可用却在每条命令上炸」，测试也会误判。
-- 所以真实探一次（结果缓存），失败时把原因留给 wrap() 报给用户。
function M.available()
    if cached ~= nil then return cached end
    if not ok(os.execute("command -v bwrap >/dev/null 2>&1")) then
        cached, cached_reason = false, "bwrap is not installed (apt install bubblewrap)"
        return cached
    end
    local probe = os.execute("bwrap --ro-bind / / --dev /dev --proc /proc -- true >/dev/null 2>&1")
    cached = ok(probe)
    if cached then
        cached_reason = nil
    else
        cached_reason = "bwrap cannot create user namespaces on this host "
            .. "(unprivileged_userns_clone=0 or container restriction)"
    end
    return cached
end

-- 不可用时的原因（可用时为 nil）；给 user/model 一句能动手的话，别只说 false。
function M.reason()
    M.available()
    return cached_reason
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
        return nil, "sandbox requested but unavailable: " .. tostring(M.reason())
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
