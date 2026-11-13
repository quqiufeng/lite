-- example.lua — 插件骨架（helper/ 下按名即调，参数 schema 由 .json 描述）。
--
-- 约定：return { run = function(args, env) ... end }
--   args：已解析的表；env.cwd / env.helper_dir / env.load(name) / env.call(name, input)
-- 失败返回 string（带原参数 + required），成功返回 string（人读或 JSON）。
return {
    description = "示例插件：调用 @NAME@_core 做整数加法（证明 Lua→FFI→C 通路）",
    parameters = {
        type = "object",
        properties = {
            a = { type = "integer", description = "加数 a" },
            b = { type = "integer", description = "加数 b" },
        },
        required = { "a", "b" },
    },
    run = function(args, env)
        local ffi = require("ffi")
        local a, b = tonumber(args and args.a), tonumber(args and args.b)
        if not a or not b then
            return string.format("参数不足：需要 a, b（收到 a=%s b=%s）",
                tostring(args and args.a), tostring(args and args.b))
        end
        local lib = env and env.load and env.load("@NAME@_core") or nil
        if not lib then
            local ok, l = pcall(require, "ffi.lib")
            if not ok then return "找不到 ffi/lib.lua" end
            local err
            lib, err = l.load("@NAME@_core")
            if not lib then return err end
        end
        pcall(ffi.cdef, [[
            int @NAME@_add(int a, int b);
            const char *@NAME@_error(void);
        ]])
        local r = lib.@NAME@_add(a, b)
        if r < 0 then return "add 失败：" .. tostring(ffi.string(lib.@NAME@_error())) end
        return string.format("%d + %d = %d", a, b, r)
    end,
}
