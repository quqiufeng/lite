-- Linux signalfd：serve 优雅处理 SIGINT/SIGTERM（无 Lua FFI 回调）。
local ffi = require("ffi")

ffi.cdef[[
typedef struct { unsigned long __val[16]; } sigset_t;
int sigemptyset(sigset_t *set);
int sigaddset(sigset_t *set, int signum);
int sigprocmask(int how, const sigset_t *set, sigset_t *oldset);
int signalfd(int fd, const sigset_t *mask, int flags);
long read(int fd, void *buf, unsigned long count);
]]

local M = {}

local SIG_BLOCK = 0
local SIGINT = 2
local SIGTERM = 15
local SFD_NONBLOCK = 0x800

function M.sigfd()
    local set = ffi.new("sigset_t")
    ffi.C.sigemptyset(set)
    ffi.C.sigaddset(set, SIGINT)
    ffi.C.sigaddset(set, SIGTERM)
    ffi.C.sigprocmask(SIG_BLOCK, set, nil)
    local fd = ffi.C.signalfd(-1, set, SFD_NONBLOCK)
    if fd < 0 then return nil end
    return fd
end

function M.drain(fd)
    if not fd then return end
    local buf = ffi.new("char[128]")
    ffi.C.read(fd, buf, 128)
end

return M
