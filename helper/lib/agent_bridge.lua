-- helper/lib/agent_bridge.lua — 把外部「插件仓」(my-agent) 接到 lite 的桥
--
-- 目标：一套实现，两种调用面
--   my-agent 侧：argv 进、stdout 出（lib/plugin/entry.lua，现状不变）
--   lite   侧：结构化 args 进、返回字符串（helper/agent_run.lua）
--
-- 两种执行模式：
--   inline  同进程 require + 捕获 stdout（快，0 fork；要求模块不 os.exit）
--   exec    子进程 luajit 跑 helper/lib/agent_run_module.lua（安全，os.exit 不影响 lite）
--
-- 插件仓位置：$AGENT_ROOT（默认 /opt/my-agent），约定
--   <root>/plugins/<group>/<name>/entry/<name>.sh   ← PLUGIN_MODULE=lib.<g>.<n>
--   <root>/lite/spec/<name>.lua                     ← 可选，args -> argv 映射
local M = {}

local function root()
    return os.getenv("AGENT_ROOT") or "/opt/my-agent"
end
M.root = root

local function read_all(p)
    local f = io.open(p)
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- ── 插件索引：name -> {dir, module, group}  来源 = plugins/<g>/<n>/ 实目录 ──
local idx
function M.index()
    if idx then return idx end
    idx = {}
    local p = io.popen("ls -d " .. shq(root() .. "/plugins") .. "/*/*/ 2>/dev/null")
    if not p then return idx end
    for dir in p:lines() do
        dir = dir:gsub("/+$", "")
        local g, n = dir:match("/([^/]+)/([^/]+)$")
        local sh = read_all(dir .. "/entry/" .. (n or "") .. ".sh")
        local mod = sh and sh:match("PLUGIN_MODULE=([%w%._%-]+)")
        if g and n then
            idx[n] = { dir = dir, group = g, name = n, module = mod }
        end
    end
    p:close()
    return idx
end

function M.resolve(name)
    local e = M.index()[name]
    if not e then
        local names = {}
        for k in pairs(M.index()) do names[#names + 1] = k end
        table.sort(names)
        return nil, "unknown plugin: " .. tostring(name) .. "; known: " .. table.concat(names, " ")
    end
    return e
end

-- 模块源码里 os.exit → 不能 inline（Lua 抓不住 os.exit，会直接干掉 lite）
function M.inline_ok(entry)
    local src = read_all(root() .. "/" .. (entry.module:gsub("%.", "/")) .. ".lua")
    if not src then return false, "module source not found" end
    if src:find("os%.exit") then return false, "module calls os.exit" end
    return true
end

-- 结构化 args -> argv：优先用 spec/<name>.lua 的 map()，否则只认 args.argv
function M.argv_for(name, args)
    if type(args.argv) == "table" then
        local out = {}
        for i, v in ipairs(args.argv) do out[i] = tostring(v) end
        return out
    end
    if type(args.argv) == "string" and args.argv ~= "" then
        local out = {}
        for tok in args.argv:gmatch("%S+") do out[#out + 1] = tok end
        return out
    end
    local spec = read_all(root() .. "/lite/spec/" .. name .. ".lua")
    if spec then
        local chunk = loadstring(spec, "@spec/" .. name)
        local ok, mod = pcall(chunk)
        if ok and type(mod) == "table" and type(mod.map) == "function" then
            local built = mod.map(args)
            if type(built) == "table" then
                local out = {}
                for i, v in ipairs(built) do out[i] = tostring(v) end
                return out
            end
        end
    end
    return nil, "plugin " .. name .. " 需要 argv（或补 " .. root() .. "/lite/spec/" .. name .. ".lua）"
end

-- 捕获块里执行的 stdout：print / io.write / io.stdout:write 三路都收
local function capture(fn)
    local buf = {}
    local function sink(_, ...)
        for i = 1, select("#", ...) do buf[#buf + 1] = tostring((select(i, ...))) end
        return sink
    end
    local old_print, old_write, old_stdout = print, io.write, io.stdout
    local fake = setmetatable({}, { __index = function() return sink end })
    print = function(...)
        for i = 1, select("#", ...) do buf[#buf + 1] = tostring((select(i, ...))) end
        buf[#buf + 1] = "\n"
    end
    io.write = sink
    io.stdout = fake
    local ok, err = pcall(fn)
    print, io.write, io.stdout = old_print, old_write, old_stdout
    local text = table.concat(buf)
    if not ok then
        return nil, tostring(err) .. (text ~= "" and ("\n" .. text) or "")
    end
    return text
end

-- inline：同进程 require + main(argv)
function M.inline(entry, argv)
    local r = root()
    -- 插件模块默认以仓根为 cwd（find_file / 相对路径都靠它）
    local ffi = require("ffi")
    pcall(ffi.cdef, "int chdir(const char *path); char *getcwd(char *buf, size_t size);")
    local cwd = ffi.new("char[4096]")
    local restored = false
    if ffi.C.getcwd(cwd, 4096) ~= nil then
        local here = ffi.string(cwd)
        pcall(ffi.C.chdir, r)
        restored = here
    end
    local paths = { r .. "/?.lua", r .. "/lib/?.lua" }
    for _, p in ipairs(paths) do
        if not package.path:find(p, 1, true) then
            package.path = p .. ";" .. package.path
        end
    end
    local out, err = capture(function()
        local mod = require(entry.module)
        local ok, res = pcall(mod.main, argv)
        if not ok then error(res, 0) end
        if type(res) == "string" then io.write(res) end
        return res
    end)
    if restored then pcall(ffi.C.chdir, restored) end
    return out, err
end

-- exec：子进程跑，os.exit / fd / cwd 全隔离
function M.exec(entry, argv, opts)
    opts = opts or {}
    local own = ((opts.helper_dir) or "helper") .. "/lib/agent_run_module.lua"
    if not read_all(own) then
        own = (os.getenv("LITE_ROOT") or (os.getenv("HOME") .. "/.local/share/lite"))
            .. "/helper/lib/agent_run_module.lua"
    end
    local parts = { "cd", shq(root()), "&&", "luajit", shq(own), shq(entry.module) }
    for _, a in ipairs(argv) do parts[#parts + 1] = shq(a) end
    local cmd = table.concat(parts, " ")
    if opts.timeout and opts.timeout > 0 then
        cmd = "timeout " .. math.floor(opts.timeout / 1000) .. " bash -c " .. shq(cmd)
    end
    local p = io.popen(cmd .. " 2>&1")
    if not p then return nil, "spawn failed" end
    local out = p:read("*a")
    local ok = p:close()
    if not ok then return nil, "exit non-zero\n" .. out end
    return out
end

-- 统一入口
function M.call(name, args, opts)
    args = args or {}
    opts = opts or {}
    local entry, err = M.resolve(name)
    if not entry then return nil, err end
    if not entry.module then return nil, "plugin " .. name .. " 的入口里没有 PLUGIN_MODULE" end
    local argv, aerr = M.argv_for(name, args)
    if not argv then return nil, aerr end
    local mode = opts.mode or args.mode or "exec"
    if mode == "inline" then
        local ok, why = M.inline_ok(entry)
        if not ok then return nil, "cannot inline " .. name .. ": " .. why end
        return M.inline(entry, argv)
    end
    return M.exec(entry, argv, opts)
end

return M
