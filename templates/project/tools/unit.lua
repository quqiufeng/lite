-- unit.lua — 纯逻辑单测（无网、无显示）。FAIL 先行：修 bug 前先让它红。
-- 只断言契约，不断言措辞。加一条测试 = 加一行 check("名字", 条件)。
local ok_all, checks = true, 0

local function check(name, cond, detail)
    checks = checks + 1
    if cond then
        io.write("ok   ", name, "\n")
    else
        ok_all = false
        io.write("FAIL ", name, detail and ("  (" .. tostring(detail) .. ")") or "", "\n")
    end
end

-- 1. JSON 判空/往返（换成你项目的核心纯函数）
local ffi = require("ffi")
check("ffi 可用", ffi ~= nil)

-- 2. 单一解析点的路径推导（不依赖 cd）
local libfind = require("ffi.lib")
check("libfind.load 返回二值", select("#", libfind.load("nonexistent_xyz")) >= 1)

-- 3. 内核符号（有 build 才断言）
local lib = libfind.load("@NAME@_core")
if lib then
    pcall(ffi.cdef, [[int @NAME@_add(int a, int b); const char *@NAME@_error(void);]])
    check("add(2,3)==5", lib.@NAME@_add(2, 3) == 5)
    check("add 溢出返回负", lib.@NAME@_add(2147483647, 1) < 0)
    check("错误串非空", ffi.string(lib.@NAME@_error()) ~= "")
else
    io.write("skip  内核符号（无 build/lib@NAME@_core.so）\n")
end

io.write(string.format("\n%d checks, %s\n", checks, ok_all and "ALL OK" or "FAILED"))
os.exit(ok_all and 0 or 1)
