-- 终端适配：termios raw / winsize / poll / ANSI 生命周期。
local ffi = require("ffi")
local bit = require("bit")
local Net = require("core.net")

ffi.cdef[[
typedef unsigned int tcflag_t;
typedef unsigned char cc_t;
typedef unsigned int speed_t;

struct termios {
    tcflag_t c_iflag, c_oflag, c_cflag, c_lflag;
    cc_t c_line;
    cc_t c_cc[32];
    speed_t c_ispeed, c_ospeed;
};

struct winsize {
    unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel;
};

int tcgetattr(int fd, struct termios *t);
int tcsetattr(int fd, int action, const struct termios *t);
int ioctl(int fd, unsigned long request, ...);
long read(int fd, void *buf, unsigned long count);
]]

local M = {}

local TCSANOW = 0
local TIOCGWINSZ = 0x5413
local POLLIN = 0x001

-- termios flags
local BRKINT = 0x0002
local ICRNL = 0x0100
local INPCK = 0x0010
local ISTRIP = 0x0020
local IXON = 0x0400
local OPOST = 0x0001
local CS8 = 0x0030
local ECHO = 0x0008
local ICANON = 0x0002
local IEXTEN = 0x8000
local ISIG = 0x0001
local VTIME = 5
local VMIN = 6

function M.is_tty()
    local ws = ffi.new("struct winsize")
    return ffi.C.ioctl(0, TIOCGWINSZ, ws) == 0
end

function M.size()
    local ws = ffi.new("struct winsize")
    if ffi.C.ioctl(0, TIOCGWINSZ, ws) ~= 0 then return 80, 24 end
    local w, h = tonumber(ws.ws_col), tonumber(ws.ws_row)
    if w == 0 then w = 80 end
    if h == 0 then h = 24 end
    return w, h
end

function M.enter()
    local orig = ffi.new("struct termios")
    ffi.C.tcgetattr(0, orig)

    local raw = ffi.new("struct termios")
    ffi.copy(raw, orig, ffi.sizeof(orig))
    raw.c_iflag = bit.band(raw.c_iflag,
        bit.bnot(bit.bor(BRKINT, ICRNL, INPCK, ISTRIP, IXON)))
    raw.c_oflag = bit.band(raw.c_oflag, bit.bnot(OPOST))
    raw.c_cflag = bit.bor(bit.band(raw.c_cflag, bit.bnot(CS8)), CS8)
    raw.c_lflag = bit.band(raw.c_lflag,
        bit.bnot(bit.bor(ECHO, ICANON, IEXTEN, ISIG)))
    raw.c_cc[VMIN] = 1
    raw.c_cc[VTIME] = 0
    ffi.C.tcsetattr(0, TCSANOW, raw)

    M.write("\27[?1049h\27[?25l\27[2J\27[H")
    return { orig = orig, active = true }
end

function M.leave(t)
    if not t or not t.active then return end
    t.active = false
    M.write("\27[0m\27[?25h\27[?1049l")
    ffi.C.tcsetattr(0, TCSANOW, t.orig)
end

function M.poll(timeout_ms)
    local _, revs = Net.poll({ 0 }, timeout_ms or 20)
    local r = revs[1] or 0
    return r, r
end

function M.read_available(max)
    max = max or 4096
    local buf = ffi.new("char[?]", max)
    local n = ffi.C.read(0, buf, max)
    if n <= 0 then return nil end
    return ffi.string(buf, n)
end

function M.write(s)
    io.write(s)
    io.flush()
end

return M
