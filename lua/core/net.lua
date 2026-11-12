-- 极简 TCP + poll（LuaJIT FFI），用于 serve/attach。
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
typedef unsigned int socklen_t;

struct sockaddr_in {
    unsigned short sin_family;
    unsigned short sin_port;
    unsigned int sin_addr;
    unsigned char sin_zero[8];
};

struct pollfd {
    int fd;
    short events;
    short revents;
};

int socket(int domain, int type, int protocol);
int setsockopt(int fd, int level, int optname, const void *optval, unsigned int optlen);
int bind(int fd, const struct sockaddr_in *addr, unsigned int len);
int listen(int fd, int backlog);
int accept(int fd, struct sockaddr_in *addr, unsigned int *len);
int connect(int fd, const struct sockaddr_in *addr, unsigned int len);
int getsockname(int fd, struct sockaddr_in *addr, unsigned int *len);
long recv(int fd, void *buf, unsigned long len, int flags);
long send(int fd, const void *buf, unsigned long len, int flags);
int close(int fd);
int fcntl(int fd, int cmd, int arg);
int poll(struct pollfd *fds, unsigned long nfds, int timeout);
unsigned short htons(unsigned short v);
unsigned short ntohs(unsigned short v);
unsigned int inet_addr(const char *cp);
]]

local M = {}

local AF_INET = 2
local SOCK_STREAM = 1
local SOL_SOCKET = 1
local SO_REUSEADDR = 2
local IPPROTO_TCP = 6
local TCP_NODELAY = 1
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 0x800
local POLLIN = 1
local MSG_NOSIGNAL = 0x4000
local MSG_PEEK = 0x2

local function addr(host, port)
    local a = ffi.new("struct sockaddr_in")
    ffi.fill(a, ffi.sizeof(a), 0)
    a.sin_family = AF_INET
    a.sin_port = ffi.C.htons(port)
    a.sin_addr = ffi.C.inet_addr(host)
    return a
end

function M.listen(host, port)
    host = host or "127.0.0.1"
    local fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 then return nil, "socket: " .. tostring(ffi.errno()) end

    local one = ffi.new("int[1]", 1)
    ffi.C.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, one, ffi.sizeof(one))

    local a = addr(host, port)
    if ffi.C.bind(fd, a, ffi.sizeof(a)) ~= 0 then
        local e = ffi.errno()
        ffi.C.close(fd)
        return nil, "bind " .. host .. ":" .. tostring(port) .. ": " .. tostring(e)
    end
    if ffi.C.listen(fd, 16) ~= 0 then
        local e = ffi.errno()
        ffi.C.close(fd)
        return nil, "listen: " .. tostring(e)
    end

    local flags = ffi.C.fcntl(fd, F_GETFL, 0)
    ffi.C.fcntl(fd, F_SETFL, bit.bor(flags, O_NONBLOCK))

    local out = ffi.new("struct sockaddr_in")
    local len = ffi.new("socklen_t[1]", ffi.sizeof(out))
    local actual = port
    if ffi.C.getsockname(fd, out, len) == 0 then
        actual = tonumber(ffi.C.ntohs(out.sin_port))
    end

    return { fd = fd, host = host, port = actual }
end

function M.connect(host, port)
    host = host or "127.0.0.1"
    local fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 then return nil, "socket: " .. tostring(ffi.errno()) end

    local a = addr(host, port)
    if ffi.C.connect(fd, a, ffi.sizeof(a)) ~= 0 then
        local e = ffi.errno()
        ffi.C.close(fd)
        return nil, "connect " .. host .. ":" .. tostring(port) .. ": " .. tostring(e)
    end

    local one = ffi.new("int[1]", 1)
    ffi.C.setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, one, ffi.sizeof(one))
    return fd
end

function M.poll(fds, timeout_ms)
    local n = #fds
    if n == 0 then
        if timeout_ms and timeout_ms > 0 then ffi.C.poll(nil, 0, timeout_ms) end
        return 0, {}
    end
    local arr = ffi.new("struct pollfd[?]", n)
    for i, fd in ipairs(fds) do
        arr[i - 1].fd = fd
        arr[i - 1].events = POLLIN
        arr[i - 1].revents = 0
    end
    local rc = ffi.C.poll(arr, n, timeout_ms or 20)
    local out = {}
    for i = 1, n do out[i] = arr[i - 1].revents end
    return tonumber(rc), out
end

function M.set_nonblock(fd)
    local flags = ffi.C.fcntl(fd, F_GETFL, 0)
    if flags >= 0 then ffi.C.fcntl(fd, F_SETFL, bit.bor(flags, O_NONBLOCK)) end
end

function M.accept(server)
    local fd = ffi.C.accept(server.fd, nil, nil)
    if fd < 0 then return nil end
    local one = ffi.new("int[1]", 1)
    ffi.C.setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, one, ffi.sizeof(one))
    -- 非阻塞：serve 在首包嗅探时会不带 poll 直接 peek，阻塞 fd 会卡住整个循环。
    M.set_nonblock(fd)
    return fd
end

function M.recv(fd)
    local buf = ffi.new("char[8192]")
    local n = ffi.C.recv(fd, buf, 8192, 0)
    if n > 0 then return ffi.string(buf, tonumber(n)) end
    if n == 0 then return nil, "closed" end
    local e = ffi.errno()
    if e == 11 or e == 4 then return nil, "again" end
    return nil, "recv: " .. tostring(e)
end

-- 看一眼还没读的字节（不消费），serve 用它区分 HTTP 与 JSONL 客户端。
function M.peek(fd, len)
    len = len or 8192
    local buf = ffi.new("char[?]", len)
    local n = ffi.C.recv(fd, buf, len, MSG_PEEK)
    if n > 0 then return ffi.string(buf, tonumber(n)) end
    return nil
end

function M.send(fd, data)
    local sent = 0
    local len = #data
    while sent < len do
        local n = ffi.C.send(fd, ffi.cast("const char *", data) + sent,
            len - sent, MSG_NOSIGNAL)
        if n <= 0 then return false, ffi.errno() end
        sent = sent + tonumber(n)
    end
    return true
end

function M.close(fd)
    if fd and fd >= 0 then ffi.C.close(fd) end
end

return M
