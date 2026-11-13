-- lib.lua — 原生库的**唯一**解析点（对应 lite 的 ffi/libfind.lua）。
-- 顺序：$ROOT/build → $ROOT/lib → ./build|lib → 裸名。
-- 命中后比一下所有候选的大小，不一致就往 stderr 打一行警告（每次进程每个库一次）：
-- 静默新旧混编是最贵的 bug——"改了没生效"多半跑的是几天前的 .so。
local ffi = require("ffi")

local M = {}
local warned, cache = {}, {}

local function root()
    local src = (debug.getinfo(1, "S") or {}).source or ""
    local p = src:match("^@(.+)$")
    if p then
        local r = p:match("^(.*)/lua/ffi/[^/]+$")
        if r then return r end
    end
    return os.getenv("ROOT") or "."
end

local function exists(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

local function size(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:seek("end"); f:close(); return s
end

local function candidates(name)
    local r = (os.getenv("ROOT") or root()):gsub("/+$", "")
    local soname = "lib" .. name .. ".so"
    return { r .. "/build/" .. soname, r .. "/lib/" .. soname,
             "./build/" .. soname, "./lib/" .. soname, soname }
end

-- load(name) → lib, err     name 不带 lib/so：load("demo_core")
function M.load(name)
    if cache[name] ~= nil then return cache[name] or nil, cache[name] and nil or "not found: " .. name end
    local hit, hit_path
    for _, p in ipairs(candidates(name)) do
        if exists(p) then
            local ok, lib = pcall(ffi.load, p)
            if ok then hit, hit_path = lib, p; break end
        end
    end
    if not hit then
        cache[name] = false
        return nil, "无法加载 lib" .. name .. ".so（先跑 ./tools/build.sh）"
    end
    -- 新旧混编自检
    local sz = size(hit_path)
    for _, p in ipairs(candidates(name)) do
        local s2 = size(p)
        if p ~= hit_path and s2 and sz and s2 ~= sz and not warned[name] then
            warned[name] = true
            io.stderr:write(string.format(
                "warn: %s 有多个副本且大小不同（在用 %s）。跑过的构建可能没同步到安装目录。\n",
                "lib" .. name .. ".so", hit_path))
        end
    end
    cache[name] = hit
    return hit
end

return M
