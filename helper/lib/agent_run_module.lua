-- helper/lib/agent_run_module.lua — 子进程跑外部插件模块（= my-agent lib/plugin/entry.lua 的等价物）
-- 用法: cd <AGENT_ROOT> && luajit agent_run_module.lua <PLUGIN_MODULE> [argv...]
local ffi = require("ffi")
pcall(ffi.cdef, "int close(int fd);")
for fd = 3, 63 do pcall(ffi.C.close, fd) end

local root = os.getenv("AGENT_ROOT") or "/opt/my-agent"
package.path = root .. "/?.lua;" .. root .. "/lib/?.lua;" .. package.path

local mod = arg[1]
if not mod or mod == "" then io.stderr:write("PLUGIN_MODULE missing\n"); os.exit(2) end

local argv = {}
for i = 2, #arg do argv[#argv + 1] = arg[i] end

local ok, m = pcall(require, mod)
if not ok or type(m) ~= "table" or type(m.main) ~= "function" then
    io.stderr:write("plugin module invalid: " .. tostring(m) .. "\n"); os.exit(2)
end
local rc = m.main(argv)
io.stdout:flush(); io.stderr:flush()
os.exit(rc or 0)
