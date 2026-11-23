-- call_master 插件：把一句话**贴进主 lite 进程的终端输入框并回车**，让主进程去执行。
--
-- 为什么需要它：`wechat_watch` 常驻守护进程（helper/lib/wx_watch_daemon.lua）跑在进程外，
-- 早先是靠 serve 的 HTTP /prompt 派发；但只要主 TUI 开着，它就握着 `mem.lock`，任何别的实例都
-- 是 readonly（remember 直接报 "readonly memory"）。所以「让主进程干活」的正路不是再开一个
-- agent，而是把指令敲进主进程的 stdin —— 主进程自己会读写记忆、跑工具、回微信。
--
-- 定位主进程：`<cwd>/mem.lock` 首列是持锁 pid（单写者，见 AGENTS §4）；主 lite 是 luajit
-- 子进程，X 窗口的 _NET_WM_PID 属于它的父终端（qterminal/konsole…），所以从持锁 pid 沿
-- /proc/<pid>/stat 的 ppid 往上走几层，逐层找哪个 pid 拥有窗口。
-- 兜底：mem.lock 缺失/不活时按 LITE_MASTER_PID，再不行按常见终端 class 找可见窗口。
--
-- 注入方式：不经 IME 也不逐字符打（中文会被输入法吞），一律 xclip 写剪贴板 +
-- ctrl+shift+v 粘贴 + Return（终端粘贴键是 ctrl+shift+v，不是 ctrl+v）。
--
-- ⚠ 只发自然语言，别发斜杠命令（/reboot、/clear 贴进去一样会执行）。
-- ⚠ 主进程正在跑工具时贴字会留在输入缓冲，等它空闲再执行 —— 这是预期，不是失败。
-- ⚠ 别在主进程自己里调用（会往自己键盘里打自己），已用 getpid 挡住。
-- ⚠ enter=false 时文本**留在输入框里**（TUI 不清缓冲），验证完要自己按退格清掉，
--   否则下一句话会被拼到它后面。
local ffi = require("ffi")
pcall(ffi.cdef, "int getpid(void);")

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function readfile(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end

local function alive(pid)
    if not pid then return false end
    return os.execute("kill -0 " .. math.floor(tonumber(pid)) .. " 2>/dev/null") == 0
end

-- /proc/<pid>/stat 的 ppid：comm 可能带空格/括号，从右括号之后再切
local function ppid_of(pid)
    local s = readfile("/proc/" .. math.floor(tonumber(pid)) .. "/stat")
    if not s then return nil end
    local rest = s:match("%)%s*(.*)$")
    if not rest then return nil end
    local pp = rest:match("^%S+%s+(%d+)")
    return pp and tonumber(pp) or nil
end

-- mem.lock：`<pid> <mtime>`，首列 pid
local function lock_pid(cwd)
    local s = readfile(cwd .. "/mem.lock")
    if not s then return nil end
    return tonumber(s:match("^%s*(%d+)"))
end

local function self_pid()
    local ok, v = pcall(function() return ffi.C.getpid() end)
    return ok and tonumber(v) or nil
end

-- 主进程可能不在 cwd 持锁（cwd 换了目录、mem.lock 在别处），顺路兜两个常见位置
local function find_lock(cwd)
    local cands = { cwd, os.getenv("PWD") or cwd, (os.getenv("HOME") or "") .. "/Desktop/lite" }
    for _, d in ipairs(cands) do
        if d ~= "" then
            local p = lock_pid(d)
            if p and alive(p) then return p, d end
        end
    end
    return nil
end

local M = {}

M.schema = {
    name = "call_master",
    description = "把指令贴进主 lite 进程的终端并回车（主进程持 mem.lock，只读实例/微信守护进程靠它派活）",
    parameters = {
        type = "object",
        properties = {
            text = { type = "string", description = "要交给主进程执行的话（自然语言，别带前导斜杠命令）" },
            enter = { type = "boolean", description = "true(默认)=贴完回车；false=只贴不回车（文本会留在输入框，需自己清）" },
            pid = { type = "integer", description = "指定主进程 pid，默认读 mem.lock" },
            settle = { type = "integer", description = "贴完等几毫秒再回车，默认 900（贴没交接完就回车会发半句）" },
            window = { type = "integer", description = "直接指定 X 窗口 id，跳过 pid 定位（排错用）" },
        },
        required = { "text" },
    },
}

function M.run(args, env)
    args = args or {}
    local text = args.text
    if not text or text == "" then return "error: required: text" end
    local cwd = (env and env.cwd) or os.getenv("PWD") or "."
    local me = self_pid()

    local root = tonumber(args.pid) or tonumber(os.getenv("LITE_MASTER_PID") or "") or (find_lock(cwd))
    if not root then
        return "error: 找不到主进程（" .. cwd .. "/mem.lock 没有活着的 pid，也没给 pid / LITE_MASTER_PID）"
    end
    if me and root == me then
        return "error: 主进程就是我自己（pid " .. me .. "），不能往自己的输入框里贴指令"
    end
    if not alive(root) then
        return "error: 持锁 pid " .. root .. " 已不在（僵尸 mem.lock？），没敢动键盘"
    end

    local Xdo = require("ffi.xdo")
    local x = Xdo.new()
    -- 本插件要粘贴，也会起子进程（cp/读 mem.lock），X socket 必须 CLOEXEC，
    -- 否则子进程抢事件流 → 贴进输入框的指令丢半句。见 xdo.lua:protect_fd
    x:protect_fd()

    local win, chain = nil, {}
    if tonumber(args.window) then
        local id = tonumber(args.window)
        win = { id = id, name = x:name(id), class = select(2, (x:_class(id))) }
    else
        -- 沿父进程链找「拥有窗口的那一层」：lite 是终端的子进程，窗口记在终端 pid 上
        local p = root
        for _ = 1, 8 do
            chain[#chain + 1] = p
            local w = x:resolve({ pid = p })
            if w then win = w; break end
            p = ppid_of(p)
            if not p or p <= 1 then break end
        end
        if not win then
            for _, cls in ipairs({ "qterminal", "konsole", "xterm", "alacritty", "kitty", "gnome-terminal" }) do
                for _, w in ipairs(x:find_class(cls) or {}) do
                    if w.viewable then win = w; break end
                end
                if win then break end
            end
        end
    end
    if not win then
        return string.format("error: 主进程 pid %d 往上找了 %d 层都没找到窗口（链：%s）",
            root, #chain, table.concat(chain, " → "))
    end

    local g = x:geometry(win.id)
    if not g then return "error: 拿到窗口 " .. win.id .. " 但读不到几何" end

    local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/call_master-" .. (me or 0) .. ".txt"
    local f = assert(io.open(tmp, "wb")); f:write(text); f:close()

    -- 激活 + 置顶：窗口被微信盖住时盲贴会贴到别的应用上
    local activated = false
    pcall(function() activated = x:activate(win.id) end)
    pcall(function() x:raise(win.id) end)
    pcall(function() x:focus(win.id) end)
    x:sync()
    os.execute("sleep 0.7")

    x:click(win.id, math.floor(g.w * 0.35), g.h - 40, 1)   -- 点输入框
    -- 等焦点真到位（库自带 1s 超时），别拿固定 sleep 赌终端重绘完：焦点没交接好时
    -- v 的 press/release 会跨窗口，release 丢掉就开始无限刷 vvvvvv。
    pcall(function() x:wait_active(win.id, true) end)
    os.execute("sleep 0.35")

    os.execute("xclip -selection clipboard -i " .. q(tmp) .. " >/dev/null 2>&1")
    os.execute("sleep 0.35")
    x:key(win.id, "ctrl+shift+v")
    -- 无条件补一次抬键：粘成没粘成都清掉按下的键（幂等）。少了这句，一次 keyup 丢失
    -- 就会满屏 vvvvvvvv —— 实测踩过。
    pcall(function() x:key_up(win.id, "ctrl+shift+v") end)
    -- 粘贴是**键盘事件流**，不是一次原子写入：字数越多、TUI 越忙，吃进 composer 越慢。
    -- 以前固定 900ms，735 字的指令在忙时吃不完 —— 回车落在「composer 还是空的」那一刻，
    -- submit() 见 text=="" 直接 return，整段指令留在输入框没人提交。现象就是投递报 ok、
    -- 会话里却什么都没有（用户看到的是「微信派了活但主进程不响应」）。
    local settle = tonumber(args.settle) or math.min(4000, 600 + #text * 3)
    os.execute(string.format("sleep %.2f", settle / 1000))
    local sent_enter = false
    if args.enter ~= false then
        -- 回车发两次：第一次被上面那种时序吞掉时第二次补上；第一次真成功的话 composer
        -- 已经空了，第二次 submit() 的 text=="" 还是 return —— 幂等，不会派两遍。
        x:key(win.id, "Return")
        pcall(function() x:key_up(win.id, "Return") end)   -- 同理：Return 卡住就是满屏空行
        os.execute("sleep 0.35")
        x:key(win.id, "Return")
        pcall(function() x:key_up(win.id, "Return") end)
        sent_enter = true
    end
    os.remove(tmp)

    return string.format("ok: 已%s进主进程 pid %d（窗口 %d %s %q，%dx%d）文本 %d 字%s",
        sent_enter and "投递并回车" or "投递（未回车，文本仍留在输入框）",
        root, win.id, win.class or "?", win.name or "", g.w, g.h, #text,
        activated and "" or "（警告：activate 返回 false，可能没拿到焦点）")
end

return M
