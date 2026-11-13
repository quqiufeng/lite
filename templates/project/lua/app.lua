-- app.lua — 主程序骨架：参数解析 → 调内核 → 输出（--json 机器可读，默认人读）。
--
--   ./tools/run.sh ping
--   ./tools/run.sh --json add --a 1 --b 2     → {"ok":true,"result":3}
--
-- 纪律：stdout 只出结果，日志/进度走 stderr；失败回带原参数 + required（调用方要能自修）。
local ffi = require("ffi")
local libfind = require("ffi.lib")

local ROOT = os.getenv("ROOT") or (arg and arg[0] or ""):match("^(.*)/lua/[^/]+$") or "."
arg[0] = nil

local opt, cmd, errs = { pos = {} }, nil, {}
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--json" then opt.json = true
    elseif a:sub(1, 2) == "--" then
        local k = a:sub(3)
        local v = arg[i + 1]
        if v and v:sub(1, 2) ~= "--" then opt[k] = v; i = i + 1
        else opt[k] = true end
    elseif not cmd then cmd = a
    else opt.pos[#opt.pos + 1] = a end
    i = i + 1
end

local function emit(t)
    if opt.json then
        local parts = {}
        for k, v in pairs(t) do
            local s
            if type(v) == "string" then s = '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
            elseif type(v) == "table" then
                local it = {}; for _, x in ipairs(v) do it[#it + 1] = '"' .. tostring(x) .. '"' end
                s = "[" .. table.concat(it, ",") .. "]"
            elseif v == nil then s = "null"
            else s = tostring(v) end
            parts[#parts + 1] = '"' .. k .. '":' .. s
        end
        print("{" .. table.concat(parts, ",") .. "}")
    elseif t.ok then
        for k, v in pairs(t) do if k ~= "ok" then print(k .. ": " .. tostring(v)) end end
    else
        io.stderr:write("error: " .. tostring(t.error) .. "\n")
    end
end

local function fail(msg, required, args)
    local t = { ok = false, error = msg }
    if required then t.required = required end
    if args then t.args = args end
    emit(t)
    os.exit(1)
end

if cmd == "ping" then
    emit({ ok = true, pong = true, lua = _VERSION })
    os.exit(0)
end

if cmd == "add" then
    local a, b = tonumber(opt.a), tonumber(opt.b)
    if not a or not b then
        -- 失败要可自修：原参数 + required 一起回
        fail("add 需要两个整数", { "a", "b" }, { a = tostring(opt.a), b = tostring(opt.b) })
    end
    local lib, err = libfind.load("@NAME@_core")
    if not lib then fail(err) end
    pcall(ffi.cdef, [[
        int @NAME@_add(int a, int b);
        const char *@NAME@_error(void);
    ]])
    local r = lib.@NAME@_add(a, b)
    if r < 0 then fail(ffi.string(lib.@NAME@_error())) end
    emit({ ok = true, result = r })
    os.exit(0)
end

emit({ ok = false, error = "用法: run.sh [--json] {ping|add --a N --b N}", cmd = tostring(cmd) })
os.exit(2)
