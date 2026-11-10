-- 非阻塞后台命令：后台 bash 写临时文件，主循环 poll 增量读取。
local ffi = require("ffi")

pcall(ffi.cdef, "int kill(int pid, int sig);")

local M = {}
M.__index = M

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.new(command, opts)
    opts = opts or {}
    local out = os.tmpname()
    local status_file = os.tmpname()

    local script = "{\n" .. command .. "\n} > " .. shq(out)
        .. " 2>&1\necho $? > " .. shq(status_file)
    -- setsid：让这条命令自成一个进程组，cancel 时 killpg 才能连它的孙子
    -- （`sleep 40` 这类）一起收掉；stdin 接 /dev/null，否则常驻的后台命令
    -- 会和 TUI 抢同一份 stdin，按键被它吃掉，输入框看起来就是死的。
    local launcher = "setsid bash -c " .. shq(script) .. " </dev/null & echo $!"

    local p = io.popen(launcher, "r")
    if not p then
        os.remove(out)
        os.remove(status_file)
        return nil, "cannot start background process"
    end
    local pid = tonumber(p:read("*l") or "")
    p:close()
    if not pid then
        os.remove(out)
        os.remove(status_file)
        return nil, "cannot read background pid"
    end

    return setmetatable({
        pid = pid,
        out = out,
        status_file = status_file,
        f = io.open(out, "rb"),
        pos = 0,
        buf = {},
        start = os.time(),
        timeout = tonumber(opts.timeout) or 120,
        done = false,
        exit_code = nil,
    }, M)
end

-- 命令本身是 setsid 起来的进程组长，负 pid 才能连孙子进程一起收掉。
local function kill_tree(pid, sig)
    if not pid then return end
    ffi.C.kill(-pid, sig)
    ffi.C.kill(pid, sig)
end

function M:output()
    return table.concat(self.buf)
end

function M:_read_new()
    local f = self.f
    if not f then return "" end
    f:seek("set", self.pos)
    local s = f:read("*a") or ""
    if #s > 0 then
        self.pos = self.pos + #s
        self.buf[#self.buf + 1] = s
    end
    return s
end

function M:_close()
    if self.f then self.f:close(); self.f = nil end
    os.remove(self.out)
    os.remove(self.status_file)
end

function M:poll()
    if self.done then return true, self:output(), "" end
    local delta = self:_read_new()

    local sf = io.open(self.status_file, "rb")
    if sf then
        local code = tonumber((sf:read("*l") or ""):match("^%s*(%-?%d+)"))
        sf:close()
        if code then
            self:_read_new()
            self.done = true
            self.exit_code = code
            self:_close()
            return true, self:output(), delta
        end
    end

    if os.time() - self.start > self.timeout then
        kill_tree(self.pid, 9)
        self:_read_new()
        self.done = true
        self.exit_code = 124
        self:_close()
        return true, self:output() .. "\n[timeout]", ""
    end

    -- 进程被信号杀死时不会写 status 文件；给 status 一点落盘时间。
    if ffi.C.kill(self.pid, 0) ~= 0 then
        self.dead_ticks = (self.dead_ticks or 0) + 1
        if self.dead_ticks >= 2 then
            self:_read_new()
            self.done = true
            self.exit_code = -1
            self:_close()
            return true, self:output() .. "\n[terminated]", ""
        end
    else
        self.dead_ticks = 0
    end

    return false, self:output(), delta
end

function M:cancel()
    if self.done then return self:output() end
    kill_tree(self.pid, 9)
    self:_read_new()
    self.done = true
    self.exit_code = 130
    self:_close()
    return self:output() .. "\n[cancelled]"
end

return M
