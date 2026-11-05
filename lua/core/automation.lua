-- lua/core/automation.lua — 进程内 Unix socket 自动化桥
--
-- JSON Lines 协议：
--   {"cmd":"ping"}
--   {"cmd":"list"}
--   {"cmd":"state"}
--   {"cmd":"click","id":"reader.next"}
--   {"cmd":"call","fn":"reader.open","args":{"path":"..."}}
--
-- 非阻塞 accept/recv，由 UI 主循环每帧调用 poll()。

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef [[
typedef struct {
    unsigned short sun_family;
    char sun_path[108];
} sockaddr_un;

int socket(int domain, int type, int protocol);
int bind(int fd, const sockaddr_un *addr, unsigned int len);
int listen(int fd, int backlog);
int accept(int fd, sockaddr_un *addr, unsigned int *len);
long recv(int fd, void *buf, size_t len, int flags);
long send(int fd, const void *buf, size_t len, int flags);
int close(int fd);
int unlink(const char *path);
int fcntl(int fd, int cmd, int arg);
int chmod(const char *path, unsigned int mode);
]]

local C = ffi.C

local AF_UNIX = 1
local SOCK_STREAM = 1
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 0x800
local EAGAIN = 11
local EWOULDBLOCK = 35
local MSG_NOSIGNAL = 0x4000

local function jesc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
         :gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return s
end

local function jser(v)
    local t = type(v)
    if t == "string" then return '"' .. jesc(v) .. '"' end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "table" then
        if #v > 0 then
            local a = {}
            for i = 1, #v do a[#a + 1] = jser(v[i]) end
            return "[" .. table.concat(a, ",") .. "]"
        end
        local a = {}
        for k, x in pairs(v) do
            a[#a + 1] = jser(k) .. ":" .. jser(x)
        end
        return "{" .. table.concat(a, ",") .. "}"
    end
    return "null"
end

local function jget(s, key)
    local v = s:match('"' .. key .. '"%s*:%s*"([^"]*)"')
    if not v then return nil end
    return v:gsub("\\\\", "\\"):gsub('\\"', '"')
            :gsub("\\n", "\n"):gsub("\\r", "\r"):gsub("\\t", "\t")
            :gsub("\\/", "/")
end

local function jgetnum(s, key)
    local v = s:match('"' .. key .. '"%s*:%s*(%-?%d+)')
    return v and tonumber(v) or nil
end

local function jgetfloat(s, key)
    local v = s:match('"' .. key .. '"%s*:%s*(%-?%d+%.?%d*)')
    return v and tonumber(v) or nil
end

local M = {}
M.__index = M

function M.start(path, handlers)
    local self = setmetatable({
        path = path,
        handlers = handlers or {},
        clients = {},
    }, M)

    C.unlink(path)
    local fd = C.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 then error("automation: socket failed") end

    local sun = ffi.new("sockaddr_un")
    sun.sun_family = AF_UNIX
    ffi.fill(sun.sun_path, 108, 0)
    ffi.copy(sun.sun_path, path)

    if C.bind(fd, sun, ffi.sizeof(sun)) ~= 0 then
        C.close(fd)
        error("automation: bind failed: " .. path)
    end
    C.chmod(path, 0x1C0) -- 0700

    if C.listen(fd, 8) ~= 0 then
        C.close(fd)
        error("automation: listen failed")
    end
    local flags = C.fcntl(fd, F_GETFL, 0)
    C.fcntl(fd, F_SETFL, bit.bor(flags, O_NONBLOCK))
    self.fd = fd
    return self
end

function M:handle(line)
    local cmd = jget(line, "cmd") or ""
    local H = self.handlers

    if cmd == "ping" then
        return jser({ ok = true, pong = true })
    end
    if cmd == "list" then
        local actions = H.actions and H.actions() or {}
        return jser({ ok = true, actions = actions })
    end
    if cmd == "state" then
        local state = H.state and H.state() or {}
        return jser({ ok = true, state = state })
    end
    if cmd == "click" then
        local id = jget(line, "id")
        if not id then return jser({ ok = false, error = "missing id" }) end
        if not H.click then return jser({ ok = false, error = "no click handler" }) end
        return jser(H.click(id))
    end
    if cmd == "call" then
        local fn = jget(line, "fn")
        if not fn then return jser({ ok = false, error = "missing fn" }) end
        local args = {
            path = jget(line, "path"),
            q = jget(line, "q"),
            note = jget(line, "note"),
            theme = jget(line, "theme"),
            page = jgetnum(line, "page"),
            chapter = jgetnum(line, "chapter"),
            index = jgetnum(line, "index"),
            selected = jgetnum(line, "selected"),
            row = jgetnum(line, "row"),
            delta = jgetnum(line, "delta"),
            dy = jgetnum(line, "dy"),
            dx = jgetfloat(line, "dx"),
            zoom = jgetfloat(line, "zoom"),
            z = jgetfloat(line, "z"),
            count = jgetnum(line, "count"),
            font_size = jgetnum(line, "font_size"),
            line_factor = jgetfloat(line, "line_factor"),
            margin = jgetnum(line, "margin"),
        }
        if not H.call then return jser({ ok = false, error = "no call handler" }) end
        return jser(H.call(fn, args))
    end
    return jser({ ok = false, error = "unknown cmd: " .. tostring(cmd) })
end

function M:poll()
    while true do
        local cfd = C.accept(self.fd, nil, nil)
        if cfd < 0 then break end
        local flags = C.fcntl(cfd, F_GETFL, 0)
        C.fcntl(cfd, F_SETFL, bit.bor(flags, O_NONBLOCK))
        self.clients[cfd] = ""
    end

    local buf = ffi.new("char[8192]")
    for cfd, pending in pairs(self.clients) do
        local n = C.recv(cfd, buf, 8192, 0)
        if n > 0 then
            pending = pending .. ffi.string(buf, n)
            while true do
                local line, rest = pending:match("^([^\n]*)\n(.*)$")
                if not line then break end
                pending = rest
                local resp = self:handle(line) or '{"ok":false,"error":"no handler"}'
                local data = resp .. "\n"
                C.send(cfd, data, #data, MSG_NOSIGNAL)
            end
            self.clients[cfd] = pending
        elseif n == 0 then
            C.close(cfd)
            self.clients[cfd] = nil
        else
            local e = ffi.errno()
            if e ~= EAGAIN and e ~= EWOULDBLOCK then
                C.close(cfd)
                self.clients[cfd] = nil
            end
        end
    end
end

function M:stop()
    for cfd in pairs(self.clients) do
        C.close(cfd)
    end
    self.clients = {}
    if self.fd then
        C.close(self.fd)
        self.fd = nil
    end
    if self.path then
        C.unlink(self.path)
    end
end

return M
