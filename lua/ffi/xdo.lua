local ffi = require("ffi")

ffi.cdef[[
typedef unsigned long Window;
typedef unsigned long Atom;
typedef unsigned char Bool;
typedef struct _XDisplay Display;
typedef struct xdo xdo_t;
typedef struct {
    char *res_name;
    char *res_class;
} XClassHint;
void free(void *ptr);

Display *XOpenDisplay(const char *name);
int XCloseDisplay(Display *display);
Window XDefaultRootWindow(Display *display);
Atom XInternAtom(Display *display, const char *name, Bool only_if_exists);
int XGetWindowProperty(Display *display, Window w, Atom property,
    long offset, long length, Bool delete, Atom req_type,
    Atom *actual_type, int *actual_format, unsigned long *nitems,
    unsigned long *bytes_after, unsigned char **prop);
int XFree(void *data);
int XFetchName(Display *display, Window w, char **name);
int XGetGeometry(Display *display, unsigned long drawable, Window *root,
    int *x, int *y, unsigned int *width, unsigned int *height,
    unsigned int *border_width, unsigned int *depth);
int XTranslateCoordinates(Display *display, Window src, Window dst,
    int src_x, int src_y, int *dest_x, int *dest_y, Window *child);
int XMapWindow(Display *display, Window w);
int XUnmapWindow(Display *display, Window w);
int XIconifyWindow(Display *display, Window w, int screen);
int XGetClassHint(Display *display, Window w, XClassHint *class_hints);

/* 只用到 map_state（0=IsUnmapped 1=IsUnviewable 2=IsViewable）与 override_redirect。
   其余字段按 XWindowAttributes 的真实布局声明，保证偏移正确。 */
typedef struct {
    int x, y;
    int width, height;
    int border_width;
    int depth;
    void *visual;
    unsigned long root;
    int class;
    int bit_gravity;
    int win_gravity;
    int backing_store;
    unsigned long backing_planes;
    unsigned long backing_pixel;
    int save_under;
    unsigned long colormap;
    int map_installed;
    int map_state;
    long all_event_masks;
    long your_event_mask;
    long do_not_propagate_mask;
    int override_redirect;
    void *screen;
} XWinAttr;
int XGetWindowAttributes(Display *display, Window w, XWinAttr *attrs);

/* _NET_ACTIVE_WINDOW：自己发 ClientMessage，绕开 libxdo。
   libxdo 的 xdo_activate_window 会顺带读 _NET_WM_DESKTOP 切工作区，
   桌面/面板类窗口没有该属性，于是往 stderr 打
   "XGetWindowProperty[_NET_WM_DESKTOP] failed (code=1)"。 */
typedef struct {
    int type;
    unsigned long serial;
    int send_event;
    Display *display;
    Window window;
    Atom message_type;
    int format;
    union {
        char b[20];
        short s[10];
        long l[5];
    } data;
} XClientMessageEvent;

typedef union {
    int type;
    XClientMessageEvent xclient;
    long pad[24];
} XAnyEvent;

int XSendEvent(Display *display, Window w, int propagate, long event_mask, XAnyEvent *event);
int XRaiseWindow(Display *display, Window w);
int XSync(Display *display, Bool discard);
int XFlush(Display *display);
int XMoveWindow(Display *display, Window w, int x, int y);
int XDisplayWidth(Display *display, int screen);
int XDisplayHeight(Display *display, int screen);
int XTestFakeButtonEvent(Display *display, unsigned int button, Bool is_press, unsigned long delay);
int usleep(unsigned int usec);

xdo_t *xdo_new(const char *display);
void xdo_free(xdo_t *xdo);
int xdo_get_window_name(const xdo_t *xdo, Window window,
    unsigned char **name_ret, int *name_len_ret, int *name_type);
int xdo_get_active_window(const xdo_t *xdo, Window *window_ret);
int xdo_activate_window(const xdo_t *xdo, Window wid);
int xdo_focus_window(const xdo_t *xdo, Window wid);
int xdo_raise_window(const xdo_t *xdo, Window wid);
int xdo_minimize_window(const xdo_t *xdo, Window wid);
int xdo_map_window(const xdo_t *xdo, Window wid, int x, int y);
int xdo_wait_for_window_map_state(const xdo_t *xdo, Window wid, int map_state);
int xdo_wait_for_window_active(const xdo_t *xdo, Window wid, int activate);
int xdo_move_mouse(const xdo_t *xdo, int x, int y, int screen);
int xdo_get_mouse_location(const xdo_t *xdo, int *x, int *y, int *screen_num);
int xdo_get_window_at_mouse(const xdo_t *xdo, Window *window_ret);
int xdo_move_mouse_relative_to_window(const xdo_t *xdo, Window window, int x, int y);
int xdo_move_window(const xdo_t *xdo, Window wid, int x, int y);
int xdo_click_window(const xdo_t *xdo, Window window, int button);
int xdo_send_keysequence_window(const xdo_t *xdo, Window window,
    const char *keysequence, unsigned int delay);
int xdo_enter_text_window(const xdo_t *xdo, Window window,
    const char *string, unsigned int delay);
]]

local X11 = ffi.load("X11")
local Xtst = ffi.load("Xtst")
local lib
for _, name in ipairs({ "xdo", "libxdo.so.3", "libxdo.so" }) do
    local ok, handle = pcall(ffi.load, name)
    if ok then lib = handle; break end
end
assert(lib, "无法加载 libxdo（安装 libxdo3）")

local Xdo = {}
Xdo.__index = Xdo

local function x11_string(ptr, len)
    if ptr == nil then return nil end
    local s = ffi.string(ptr, tonumber(len))
    return s
end

function Xdo.new(display)
    local xdpy = X11.XOpenDisplay(display and ffi.cast("const char *", display) or nil)
    if xdpy == nil then return nil, "XOpenDisplay 失败（DISPLAY?）" end
    local handle = lib.xdo_new(display and ffi.cast("const char *", display) or nil)
    if handle == nil then X11.XCloseDisplay(xdpy); return nil, "xdo_new 失败" end
    return setmetatable({ handle = handle, dpy = xdpy }, Xdo)
end

function Xdo:close()
    if self.handle ~= nil then lib.xdo_free(self.handle); self.handle = nil end
    if self.dpy ~= nil then X11.XCloseDisplay(self.dpy); self.dpy = nil end
end

function Xdo:_name(win)
    local atom = X11.XInternAtom(self.dpy, "_NET_WM_NAME", 0)
    local actual, fmt = ffi.new("Atom[1]"), ffi.new("int[1]")
    local n, after = ffi.new("unsigned long[1]"), ffi.new("unsigned long[1]")
    local prop = ffi.new("unsigned char *[1]")
    local rc = X11.XGetWindowProperty(self.dpy, win, atom, 0, 1024, 0, 0,
        actual, fmt, n, after, prop)
    if rc == 0 and prop[0] ~= nil and n[0] > 0 then
        local s = x11_string(prop[0], n[0])
        X11.XFree(prop[0])
        if s and #s > 0 then return s end
    end
    local name = ffi.new("char *[1]")
    if X11.XFetchName(self.dpy, win, name) ~= 0 and name[0] ~= nil then
        local s = ffi.string(name[0])
        X11.XFree(name[0])
        if #s > 0 then return s end
    end
    return nil
end

function Xdo:_geom(win)
    local root = ffi.new("Window[1]")
    local x, y = ffi.new("int[1]"), ffi.new("int[1]")
    local w, h = ffi.new("unsigned int[1]"), ffi.new("unsigned int[1]")
    local bw, depth = ffi.new("unsigned int[1]"), ffi.new("unsigned int[1]")
    if X11.XGetGeometry(self.dpy, win, root, x, y, w, h, bw, depth) == 0 then
        return nil
    end
    local rx, ry = ffi.new("int[1]"), ffi.new("int[1]")
    local child = ffi.new("Window[1]")
    X11.XTranslateCoordinates(self.dpy, win, root[0], 0, 0, rx, ry, child)
    return { x = tonumber(rx[0]), y = tonumber(ry[0]),
             w = tonumber(w[0]), h = tonumber(h[0]) }
end

-- _NET_WM_PID（CARDINAL）：多应用并跑时按 pid 定位比按标题可靠
function Xdo:_pid(win)
    local atom = X11.XInternAtom(self.dpy, "_NET_WM_PID", 0)
    local actual, fmt = ffi.new("Atom[1]"), ffi.new("int[1]")
    local n, after = ffi.new("unsigned long[1]"), ffi.new("unsigned long[1]")
    local prop = ffi.new("unsigned char *[1]")
    if X11.XGetWindowProperty(self.dpy, win, atom, 0, 1, 0, 0,
        actual, fmt, n, after, prop) ~= 0 or prop[0] == nil then
        return nil
    end
    local pid = nil
    if fmt[0] == 32 and n[0] > 0 then
        pid = tonumber(ffi.cast("unsigned long *", prop[0])[0])
    end
    X11.XFree(prop[0])
    return pid
end

function Xdo:_class(win)
    local hint = ffi.new("XClassHint")
    if X11.XGetClassHint(self.dpy, win, hint) == 0 then return nil, nil end
    local res_name = hint.res_name ~= nil and ffi.string(hint.res_name) or nil
    local res_class = hint.res_class ~= nil and ffi.string(hint.res_class) or nil
    if hint.res_name ~= nil then X11.XFree(hint.res_name) end
    if hint.res_class ~= nil then X11.XFree(hint.res_class) end
    return res_name, res_class
end

-- 可见性：map_state==2 才是 IsViewable；最小化/隐藏的窗口不该被截
function Xdo:_attrs(win)
    local a = ffi.new("XWinAttr")
    if X11.XGetWindowAttributes(self.dpy, win, a) == 0 then return nil end
    return {
        viewable = tonumber(a.map_state) == 2,
        map_state = tonumber(a.map_state),
        override_redirect = tonumber(a.override_redirect) ~= 0,
    }
end

function Xdo:windows()
    local root = X11.XDefaultRootWindow(self.dpy)
    local atom = X11.XInternAtom(self.dpy, "_NET_CLIENT_LIST", 0)
    local actual, fmt = ffi.new("Atom[1]"), ffi.new("int[1]")
    local n, after = ffi.new("unsigned long[1]"), ffi.new("unsigned long[1]")
    local prop = ffi.new("unsigned char *[1]")
    local rc = X11.XGetWindowProperty(self.dpy, root, atom, 0, 4096, 0, 33,
        actual, fmt, n, after, prop)
    if rc ~= 0 or prop[0] == nil then return {} end
    local list = ffi.cast("Window *", prop[0])
    local out = {}
    for i = 0, tonumber(n[0]) - 1 do
        local win = list[i]
        local res_name, res_class = self:_class(win)
        local at = self:_attrs(win) or {}
        out[#out + 1] = {
            id = win,
            name = self:_name(win),
            geom = self:_geom(win),
            class = res_class,
            instance = res_name,
            pid = self:_pid(win),
            viewable = at.viewable,
            override_redirect = at.override_redirect,
            -- 堆叠顺序：_NET_CLIENT_LIST 是自下而上，末尾最靠前
            z = i + 1,
        }
    end
    X11.XFree(prop[0])
    return out
end

-- 精确解析窗口。query 支持 id / name / class / instance / pid / active / viewable 组合。
-- 返回: win, nil（唯一命中） | nil, {candidates}（0 或多命中） —— 绝不静默挑一个。
function Xdo:resolve(query)
    query = query or {}
    local active = self:active()
    local ws = self:windows()
    local hits = {}
    for _, w in ipairs(ws) do
        local ok = true
        if query.id ~= nil and w.id ~= tonumber(query.id) then ok = false end
        if ok and query.pid ~= nil and w.pid ~= tonumber(query.pid) then ok = false end
        if ok and query.class ~= nil then
            local c = (w.class or ""):lower()
            ok = query.exact and c == query.class:lower()
                or (not query.exact and c:find(query.class:lower(), 1, true) ~= nil)
        end
        if ok and query.instance ~= nil then
            local c = (w.instance or ""):lower()
            ok = query.exact and c == query.instance:lower()
                or (not query.exact and c:find(query.instance:lower(), 1, true) ~= nil)
        end
        if ok and query.name ~= nil then
            local n = w.name or ""
            ok = query.exact and n == query.name
                or (not query.exact and n:find(query.name, 1, true) ~= nil)
        end
        if ok and query.active and w.id ~= active then ok = false end
        if ok and query.viewable and not w.viewable then ok = false end
        if ok then hits[#hits + 1] = w end
    end
    if #hits == 1 then return hits[1] end
    -- 多命中时只有调用方显式 pick 才取第 N 个（不静默选，但要让 pick 生效）
    if query.pick and hits[query.pick] then return hits[query.pick] end
    return nil, hits
end

function Xdo:find(pattern)
    local out = {}
    for _, w in ipairs(self:windows()) do
        if pattern == nil or (w.name and w.name:find(pattern)) then
            out[#out + 1] = w
        end
    end
    return out
end

function Xdo:find_class(pattern)
    local out = {}
    for _, w in ipairs(self:windows()) do
        local hint = ffi.new("XClassHint")
        if X11.XGetClassHint(self.dpy, w.id, hint) ~= 0 then
            local cls = hint.res_class ~= nil and ffi.string(hint.res_class) or ""
            if hint.res_name ~= nil then X11.XFree(hint.res_name) end
            if hint.res_class ~= nil then X11.XFree(hint.res_class) end
            if pattern == nil or cls:lower():find(pattern:lower(), 1, true) then
                out[#out + 1] = w
            end
        end
    end
    return out
end

function Xdo:name(win) return self:_name(win) end
function Xdo:geometry(win) return self:_geom(win) end

function Xdo:active()
    local win = ffi.new("Window[1]")
    if lib.xdo_get_active_window(self.handle, win) ~= 0 then return nil end
    return tonumber(win[0])
end

-- IsViewable=2 / IsUnmapped=0（X11 map_state 常量）
local IS_VIEWABLE, IS_UNMAPPED = 2, 0

-- 给 root 发 ICCCM WM_CHANGE_STATE：1 = Normal（deiconify），3 = Iconic（最小化）
-- 这条路径只改 WM_STATE，不碰输入焦点 —— openbox 不会把它当"抢焦点"再打回 Iconic
function Xdo:_change_state(win, state)
    local root = X11.XDefaultRootWindow(self.dpy)
    local ev = ffi.new("XAnyEvent")
    ev.xclient.type = 33
    ev.xclient.send_event = 1
    ev.xclient.display = self.dpy
    ev.xclient.window = win
    ev.xclient.message_type = X11.XInternAtom(self.dpy, "WM_CHANGE_STATE", 0)
    ev.xclient.format = 32
    ev.xclient.data.l[0] = state
    -- SubstructureRedirectMask(0x100000) | SubstructureNotifyMask(0x80000)
    X11.XSendEvent(self.dpy, root, 0, 0x180000, ev)
    X11.XSync(self.dpy, 0)
end

-- 显示 = xdo_map_window（等价 `xdotool windowmap --sync`）+ 抬栈序。
-- 实测 openbox 下对 Iconic 窗口调用即可 deiconify 并稳定可见（300ms×30 采样全 IsViewable）[verified p68]
function Xdo:map(win, w, h)
    return lib.xdo_map_window(self.handle, win, w or 0, h or 0) == 0
end

-- 窗口可见 ≠ 窗口有焦点：只 map+raise 时 openbox 把焦点留给原窗口，
-- 之后 key(0,...)（XTEST 真键盘）和整屏截图都打到别的窗口上。
-- xdo_activate_window ≡ `xdotool windowactivate`，是真正发出 _NET_ACTIVE_WINDOW 的那一步；
-- 它在没有 _NET_WM_DESKTOP 的窗口上会返回非 0，所以用 pcall 兜住，map+raise 仍是基底。
local function take_focus(self, win)
    pcall(function() lib.xdo_wait_for_window_map_state(self.handle, win, IS_VIEWABLE) end)
    lib.xdo_raise_window(self.handle, win)
    pcall(function() lib.xdo_activate_window(self.handle, win) end)
    pcall(function() lib.xdo_wait_for_window_active(self.handle, win, 1) end)
end

function Xdo:activate(win)
    if self:map(win) then
        take_focus(self, win)
        if self:_is_viewable(win) then return true end
    end
    self:_change_state(win, 1)
    local ok = pcall(function()
        lib.xdo_wait_for_window_map_state(self.handle, win, IS_VIEWABLE)
    end)
    if not ok then return false end
    take_focus(self, win)
    return self:_is_viewable(win)
end

function Xdo:_is_viewable(win)
    local a = self:_attrs(win)
    return (a and a.viewable) and true or false
end
function Xdo:focus(win) return lib.xdo_focus_window(self.handle, win) == 0 end
function Xdo:raise(win) return lib.xdo_raise_window(self.handle, win) == 0 end
function Xdo:minimize(win)
    -- libxdo 的 xdo_minimize_window 在 openbox 上静默失效（返回 0 但窗口不 unmapped），
    -- 走 XIconifyWindow（WM_CHANGE_STATE → IconicState）才真进后台
    local ok = X11.XIconifyWindow(self.dpy, win, 0) ~= 0
    X11.XSync(self.dpy, 0)
    if ok then
        lib.xdo_wait_for_window_map_state(self.handle, win, IS_UNMAPPED)
        return true
    end
    if lib.xdo_minimize_window(self.handle, win) ~= 0 then return false end
    lib.xdo_wait_for_window_map_state(self.handle, win, IS_UNMAPPED)
    return true
end
function Xdo:hide(win)
    local ok = X11.XUnmapWindow(self.dpy, win) ~= 0
    X11.XSync(self.dpy, 0)
    return ok
end
function Xdo:show(win)
    local ok = X11.XMapWindow(self.dpy, win) ~= 0
    X11.XSync(self.dpy, 0)
    return ok
end
function Xdo:move(win, x, y)
    return lib.xdo_move_mouse_relative_to_window(self.handle, win, x, y) == 0
end
function Xdo:move_window(win, x, y)
    -- 直接 XMoveWindow 比 libxdo 的封装更可控（后者在部分 WM 上不生效）
    X11.XMoveWindow(self.dpy, win, x, y)
    X11.XSync(self.dpy, 0)
    return true
end
function Xdo:move_abs(x, y) return lib.xdo_move_mouse(self.handle, x, y, 0) == 0 end
function Xdo:mouse_down(button)
    Xtst.XTestFakeButtonEvent(self.dpy, button or 1, 1, 0)
    X11.XFlush(self.dpy)
    return true
end
function Xdo:mouse_up(button)
    Xtst.XTestFakeButtonEvent(self.dpy, button or 1, 0, 0)
    X11.XFlush(self.dpy)
    return true
end
function Xdo:click_current(button, repeat_count, delay_ms)
    repeat_count = repeat_count or 1
    for i = 1, repeat_count do
        self:mouse_down(button)
        self:mouse_up(button)
        if i < repeat_count and delay_ms and delay_ms > 0 then
            ffi.C.usleep(math.floor(delay_ms * 1000))
        end
    end
    return true
end
function Xdo:click_abs(x, y, button, repeat_count, delay_ms)
    if not self:move_abs(x, y) then return false end
    return self:click_current(button, repeat_count, delay_ms)
end
function Xdo:click(win, x, y, button)
    if not self:move(win, x, y) then return false end
    return self:click_current(button)
end
function Xdo:sync()
    X11.XSync(self.dpy, 0)
end
function Xdo:window_at_mouse()
    local w = ffi.new("Window[1]")
    if lib.xdo_get_window_at_mouse(self.handle, w) ~= 0 then return nil end
    return tonumber(w[0])
end
function Xdo:mouse_location()
    local x, y, s = ffi.new("int[1]"), ffi.new("int[1]"), ffi.new("int[1]")
    if lib.xdo_get_mouse_location(self.handle, x, y, s) ~= 0 then return nil end
    return tonumber(x[0]), tonumber(y[0]), tonumber(s[0])
end
function Xdo:display_size()
    return tonumber(X11.XDisplayWidth(self.dpy, 0)), tonumber(X11.XDisplayHeight(self.dpy, 0))
end
function Xdo:key(win, seq, delay)
    return lib.xdo_send_keysequence_window(self.handle, win, seq, delay or 12000) == 0
end
function Xdo:type(win, text, delay)
    return lib.xdo_enter_text_window(self.handle, win, text, delay or 12000) == 0
end

return Xdo
