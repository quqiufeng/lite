-- x11.lua — native_reader 的 LuaJIT 原生窗口控制（FFI libxdo / X11）
--
-- 原生自动化：不启动 xdotool / wmctrl 进程，
-- 直接调 libxdo，因此在 luajit -e 里做动态测试非常快。
--
--   local x11 = require("ffi.x11")
--   local w = assert(x11.window("native-reader"))
--   w:center(); w:capture("/tmp/opencode/native_reader.png")
--   w:click(120, 240); w:key("ctrl+l"); w:type("hello")
--
-- 截屏用 lite 自带 liblite_capture.so（FFI，无外部命令）。
-- 注意：native_reader 优先使用应用自截图（SDL_RenderReadPixels），X11 截图仅作兜底。

local ffi = require("ffi")
local Xdo = require("ffi.xdo")

local M = {}

-- pcall：避免重复 cdef。
pcall(ffi.cdef, [[
int setenv(const char* name, const char* value, int overwrite);
]])
pcall(ffi.cdef, [[
int lite_capture(int x, int y, int w, int h, const char* out_png);
const char *lite_capture_error(void);
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
        ffi.C.setenv("DISPLAY", os.getenv("LITE_DISPLAY") or os.getenv("READER_DISPLAY") or ":0", 1)
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

local function capture_lib()
    if M._capture_lib ~= nil then return M._capture_lib or nil end
    -- 顺序与 ffi/libfind.lua 一致（$LITE_ROOT/build → lib → 老布局绝对路径 → 裸名），
    -- 但本文件要能整对拷给别的项目，所以候选表内联，不 require lite 的模块。
    local root = os.getenv("LITE_ROOT")
    local candidates = {
        root and (root:gsub("/+$", "") .. "/build/liblite_capture.so"),
        root and (root:gsub("/+$", "") .. "/lib/liblite_capture.so"),
        "/usr/local/share/lite/build/liblite_capture.so",
        "/usr/local/share/lite/lib/liblite_capture.so",
        "liblite_capture.so",
    }
    for _, path in ipairs(candidates) do
        if path then
            local f = io.open(path, "rb")
            if f then
                f:close()
                local ok, lib = pcall(ffi.load, path)
                if ok then
                    M._capture_lib = lib
                    return lib
                end
            end
        end
    end
    M._capture_lib = false
    return nil, "liblite_capture.so not found"
end
M.capture_lib = capture_lib

-- 全部窗口（id/name/geom）
function M.windows()
    return display():windows()
end

-- 精确解析窗口。query = { id, name, class, instance, pid, active, viewable, exact }
-- 唯一命中返回 Win；否则返回 nil, 候选列表（调用方自己决定，不静默选一个）。
function M.resolve(query)
    M.ensure_display()
    local w, cand = display():resolve(query or {})
    if not w then
        -- 候选也补上 Win 方法，方便调用方直接 :activate()/:capture()
        local out = {}
        for _, c in ipairs(cand or {}) do
            out[#out + 1] = M.wrap(c.id, c.name, c):refresh()
        end
        return nil, out
    end
    return M.wrap(w.id, w.name, w):refresh(), nil
end

-- 按标题查找；opts = { class=, exact=, pick= }
-- 多个匹配时默认**报错**（返回 nil + 候选），要显式 pick 才取第 N 个。
function M.window(title, opts)
    opts = opts or {}
    if opts.class then
        return M.resolve({ class = opts.class, exact = opts.exact, pick = opts.pick })
    end
    local w, cand = M.resolve({ name = title, exact = opts.exact })
    if w then return w end
    if #cand == 0 then return nil, cand end
    if opts.pick then
        local hit = cand[opts.pick] or cand[#cand]
        return M.wrap(hit.id, hit.name):refresh(), #cand
    end
    return nil, cand
end

-- 按 WM_CLASS 查找（如 "com.quqiufeng.nativereader"）。
function M.window_class(class, opts)
    opts = opts or {}
    opts.class = class
    return M.window(nil, opts)
end

-- 截图默认落到临时目录，不写进 workspace：
-- 截图是过程产物，不该污染仓库（artifacts/ 里留着上一轮的图很容易误读）。
-- read/resize 都对 $TMPDIR:/tmp:/var/tmp 放行图片，所以闭环不受影响。
-- 可用 LITE_SHOT_DIR 覆盖（测试和 CI 用得上）。
local function default_shot_path()
    local dir = os.getenv("LITE_SHOT_DIR")
    if not dir or dir == "" then
        dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/lite-shot"
    end
    return dir .. "/screen.png"
end

local function ensure_parent(path)
    local dir = path:match("^(.*)/[^/]+$")
    if not dir or dir == "" then return end
    os.execute("mkdir -p " .. "'" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
end

local Win = {}
Win.__index = Win
M.Win = Win

function M.wrap(id, name, raw)
    local self = setmetatable({ id = tonumber(id), name = name }, Win)
    if type(raw) == "table" then
        self.class = raw.class
        self.instance = raw.instance
        self.pid = raw.pid
        self.viewable = raw.viewable
        self.z = raw.z
    end
    return self
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

-- 截图窗口区域（lite 自带 X11 + PNG）
-- 注意：lite_capture 抓的是**屏幕像素**，窗口被遮挡会截到别的应用。
-- 因此先激活并确认它真的拿到焦点；拿不到就明确报错，不产出错图。
function Win:capture(path)
    self:activate()
    ffi.C.usleep(120000)
    self:refresh()
    local active = display():active()
    if active ~= nil and active ~= self.id then
        return false, string.format(
            "window %s did not become active (active=%s); refusing to capture an occluded area",
            tostring(self.id), tostring(active))
    end
    path = path or (default_shot_path():gsub("%.png$", "-window.png"))
    ensure_parent(path)
    local lib, err = capture_lib()
    if not lib then return false, err end
    local rc = lib.lite_capture(self.x, self.y, self.w, self.h, path)
    if rc ~= 0 then
        local msg = lib.lite_capture_error()
        return false, msg ~= nil and ffi.string(msg) or "capture failed"
    end
    return true, path
end

-- 全屏截图（lite 自带 X11 + PNG）
function M.capture_screen(path)
    M.ensure_display()
    path = path or default_shot_path()
    ensure_parent(path)
    local lib, err = capture_lib()
    if not lib then return false, err end
    local sw, sh = display():display_size()
    local rc = lib.lite_capture(0, 0, sw, sh, path)
    if rc ~= 0 then
        local msg = lib.lite_capture_error()
        return false, msg ~= nil and ffi.string(msg) or "capture failed"
    end
    return true, path
end

-- 便于 luajit -e 的一行式：
--   luajit -e 'package.path=".../lua/?.lua;"..package.path;
--     require("ffi.x11").window("native-reader"):center():capture("/tmp/native_reader.png")'
function M.once(title, path)
    local w = assert(M.window(title or "reader"))
    if path then w:capture(path) end
    return w
end

return M
