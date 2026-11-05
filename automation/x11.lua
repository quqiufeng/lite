-- x11.lua — native_reader 的 LuaJIT 原生窗口控制（FFI libxdo / X11）
--
-- 复用 /opt/WordCard 的自动化思路：不启动 xdotool / wmctrl 进程，
-- 直接调 libxdo，因此在 luajit -e 里做动态测试非常快。
--
--   package.path = "/home/quqiufeng/Desktop/reader/automation/?.lua;" .. package.path
--   local x11 = require("x11")
--   local w = assert(x11.window("native-reader"))
--   w:center(); w:capture("/tmp/opencode/native_reader.png")
--   w:click(120, 240); w:key("ctrl+l"); w:type("hello")
--
-- 截屏复用 /opt/my-agent/agentkit/lib/libagentkit.so（FFI，无命令）。
-- 注意：native_reader 优先使用应用自截图（SDL_RenderReadPixels），X11 截图仅作兜底。

local ffi = require("ffi")
local Xdo = require("xdo")

local M = {}

-- pcall：避免与 /opt/my-agent/agentkit 的 x11.lua 同时加载时重复 cdef。
pcall(ffi.cdef, [[
int setenv(const char* name, const char* value, int overwrite);
]])
pcall(ffi.cdef, [[
int ak_capture(int x, int y, int w, int h, const char* out_png);
]])

local _xdo
local _display_ready = false

local function sh(cmd)
    local f = io.popen(cmd .. " 2>/dev/null")
    if not f then return "" end
    local out = f:read("*a") or ""
    f:close()
    return out
end

-- 从图形会话进程继承 DISPLAY/XAUTHORITY（luajit 从终端启动时常见缺失）。
function M.ensure_display()
    if _display_ready then return end
    _display_ready = true
    local xa = os.getenv("XAUTHORITY") or ""
    local proc = os.getenv("READER_DESKTOP_PROC") or "pcmanfm-qt"
    local pid = sh(("pgrep -x %s | head -1"):format(proc)):gsub("%s+", "")
    if xa == "" and pid ~= "" then
        local env = sh(("tr '\\0' '\\n' < /proc/%s/environ"):format(pid))
        xa = env:match("XAUTHORITY=([^\n]+)") or ""
    end
    if (os.getenv("DISPLAY") or "") == "" then
        ffi.C.setenv("DISPLAY", os.getenv("READER_DISPLAY") or os.getenv("AGENTKIT_DISPLAY") or ":0", 1)
    end
    if xa ~= "" then ffi.C.setenv("XAUTHORITY", xa, 1) end
end

local function display()
    if _xdo then return _xdo end
    M.ensure_display()
    local d, err = Xdo.new()
    if not d then error("cannot open X display: " .. tostring(err)) end
    _xdo = d
    return d
end
M.display = display

local function agentkit()
    if M._agentkit ~= nil then return M._agentkit or nil end
    local path = os.getenv("AGENTKIT_LIB")
        or "/opt/my-agent/agentkit/lib/libagentkit.so"
    local f = io.open(path, "rb")
    if not f then
        M._agentkit = false
        return nil
    end
    f:close()
    local ok, lib = pcall(ffi.load, path)
    M._agentkit = ok and lib or false
    return ok and lib or nil
end
M.agentkit = agentkit

-- 全部窗口（id/name/geom）
function M.windows()
    return display():windows()
end

-- 按标题子串查找；opts = { class=, pick= }
function M.window(title, opts)
    opts = opts or {}
    local wins = opts.class and display():find_class(opts.class)
        or display():find(title)
    if opts.exact then
        local exact = {}
        for _, w in ipairs(wins) do
            if w.name == title then exact[#exact + 1] = w end
        end
        wins = exact
    end
    if #wins == 0 then return nil end
    local w = wins[opts.pick or #wins]
    return M.wrap(w.id, w.name):refresh()
end

-- 按 WM_CLASS 查找（如 "com.quqiufeng.nativereader"）。
function M.window_class(class, opts)
    opts = opts or {}
    opts.class = class
    return M.window(nil, opts)
end

local Win = {}
Win.__index = Win
M.Win = Win

function M.wrap(id, name)
    return setmetatable({ id = tonumber(id), name = name }, Win)
end

function Win:refresh()
    display():sync()
    local g = display():geometry(self.id)
    if g then
        self.x, self.y, self.w, self.h = g.x, g.y, g.w, g.h
    end
    return self
end

function Win:geometry()
    local g = display():geometry(self.id)
    if not g then return nil end
    return { x = g.x, y = g.y, w = g.w, h = g.h }
end

function Win:activate()
    display():activate(self.id)
    display():raise(self.id)
    self:refresh()
    return self
end

function Win:raise()
    return display():raise(self.id)
end

function Win:focus()
    return display():focus(self.id)
end

function Win:move(x, y)
    display():move_window(self.id, x, y)
    ffi.C.usleep(25000)
    display():sync()
    self:refresh()
    return self
end

function Win:center()
    self:refresh()
    local sw, sh = display():display_size()
    local x = math.max(0, math.floor((sw - (self.w or 0)) / 2))
    local y = math.max(0, math.floor((sh - (self.h or 0)) / 2))
    self:move(x, y)
    return self
end

-- 窗口内相对坐标点击（x/y 以客户区左上角为原点）
function Win:click(x, y, button)
    self:refresh()
    return display():click(self.id, x, y, button or 1)
end

function Win:key(seq, delay)
    return display():key(0, seq, delay)
end

function Win:type(text, delay)
    return display():type(0, text, delay)
end

-- 截图窗口区域（FFI libagentkit）
function Win:capture(path)
    self:activate()
    self:refresh()
    path = path or "/tmp/opencode/native_reader.png"
    local lib = agentkit()
    if not lib then return false, "libagentkit.so not found" end
    local rc = lib.ak_capture(self.x, self.y, self.w, self.h, path)
    return rc == 0, path
end

-- 全屏截图（FFI libagentkit）
function M.capture_screen(path)
    M.ensure_display()
    path = path or "/tmp/opencode/screen.png"
    local lib = agentkit()
    if not lib then return false, "libagentkit.so not found" end
    local sw, sh = display():display_size()
    return lib.ak_capture(0, 0, sw, sh, path) == 0, path
end

-- 便于 luajit -e 的一行式：
--   luajit -e 'package.path=".../automation/?.lua;"..package.path;
--     require("x11").window("native-reader"):center():capture("/tmp/native_reader.png")'
function M.once(title, path)
    local w = assert(M.window(title or "reader"))
    if path then w:capture(path) end
    return w
end

return M
