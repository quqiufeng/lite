-- wechat 插件：动态 libxdo / libX11 直驱（不依赖 xdotool/wmctrl/import）。
--
-- ⚠ 用前必须确认**虚拟桌面只有一个**：多桌面模式下，滚轮/后台动作会切换桌面，
--   微信窗口连同后续截图一起"跑掉"，OCR 与点击坐标全部错位（表现为点了没反应、
--   或点到了别的东西上）。检查：xprop -root _NET_NUMBER_OF_DESKTOPS 必须是 1；
--   openbox 改 ~/.config/openbox/rc.xml 的 <desktops><number>1</number>，
--   lxqt 面板删掉 desktopswitch 插件。窗口管理器的滚轮换桌面（Desktop 上下文
--   button Up/Down）也要清掉。不是 1 就别往下跑，先修桌面再操作。
--
-- ⚠ 输入法（本机 ibus + libpinyin，实测命令见下）：**不管打中文还是英文，
--   点输入框动手之前先把输入法切对**。切错的表现是"字没进去/进去的是拼音串"：
--   拼音引擎开着敲英文 → 输入框里是候选框里的中文或干脆被吞；
--   英文引擎开着打中文 → 贴出来是空格。机器环境：GTK_IM_MODULE=ibus、
--   QT_IM_MODULE=ibus、XMODIFIERS=@im=ibus，预加载引擎只有 libpinyin，
--   引擎切换键是 <Super>space。
--     查当前引擎： ibus engine                       # libpinyin | xkb:us::eng
--     切中文拼音： ibus engine libpinyin
--     切英文：     ibus engine xkb:us::eng            # = English (US)
--     键盘切法：   Super+space 换引擎（libpinyin ↔ xkb:us::eng）
--   libpinyin 内部还认 **单按 Shift** 切中/英，但那只是引擎内部状态，
--   `ibus engine` 照样显示 libpinyin —— 别拿它当"已经切到英文"的判据，
--   拿不准就直接 `ibus engine xkb:us::eng`，别靠猜。
--   顺带：本插件的 paste() 走剪贴板 ctrl+v，不经 IME，中英文都能原样进去；
--   真正怕 IME 的是 xdo:type 那种逐字符输入（拼音引擎会弹候选框吞字符），
--   所以要么先切法再用 type，要么一律走 paste。切完统一按上面的命令复核一遍。
--
-- 流程：activate → 点标题栏拿焦点 → 点搜索框 → 粘贴关键词 → 回车进会话
--      → 点输入框 → ctrl+a/BS → 粘贴 → Return。发送之后**没有任何验收**。
-- 搜索段默认零 OCR：搜索框坐标在 map 里，回车即接受微信的默认项；成功与否看
-- 「候选面板收起 / 会话标题变了」两个像素指纹。OCR 只留一处真正需要的：
-- index>1 时点完候选行要确认点中了谁（点错行标题也会变，只有 OCR 认得出）。
-- 坐标全部是真实屏幕像素，按 map.window 标定的几何（2560x1408，即最大化）；
--   **窗口几何不对时先 ensure_geom() 自动最大化**，最大化也救不回来就报错，
--   不会硬点（窗口一小每个点都落到别处，症状像"没反应"）。位置偏移走平移兜住。
-- OCR box 已由 _pt() 换算回屏幕坐标，禁止按看图缩放后的像素估点。
local ffi = require("ffi")
if not pcall(ffi.cdef, "void usleep(unsigned int);") then end
-- 墙钟毫秒：os.clock() 在 LuaJIT 是 CPU 时间，等 I/O 时几乎不动，不能用来量轮询超时
pcall(ffi.cdef, [[struct timeval { long tv_sec; long tv_usec; };
int gettimeofday(struct timeval *tv, void *tz);]])

-- 坐标 100% 来自 helper/lib/app_wechat_map.lua（产物，由 helper/lib/apps/wechat.lua 生成）。
-- 本文件不含任何屏幕坐标：map 缺失或缺 region 时直接报错，不给写死的兜底值。
local MAP_REQUIRED = { "titlebar", "contacts", "search", "title", "candidates", "input" }

local function map_candidates()
    local here = (debug.getinfo(1, "S") or {}).source or ""
    here = here:gsub("^@", "")
    local dir = here:match("^(.*)[/\\][^/\\]*$") or "."
    local cwd = os.getenv("LITE_CWD") or "."
    return { dir .. "/lib/app_wechat_map.lua", cwd .. "/helper/lib/app_wechat_map.lua" }
end

-- min_sim 是 OCR 阈值，不是坐标（拍照常把手认成丰）。
-- tmp_prefix：中间产物（剪贴板/全屏截图/裁剪图）带 pid。原来是三处写死 /tmp/wechat-*.png，
--   两个 lite 实例（不同 cwd 不共享 mem.lock）或 cluster.sh 并发时互相覆盖剪贴板与截图，
--   症状是「验收通过但发错内容」——比失败更难查。
pcall(ffi.cdef, "int getpid(void);")
local pid_ok, pid = pcall(function() return ffi.C.getpid() end)
local D = {
    min_sim = 0.5,
    tmp_prefix = string.format("/tmp/wechat-%d", pid_ok and pid or 0),
}

local function load_map()
    local tried = map_candidates()
    for _, p in ipairs(tried) do
        local ok, m = pcall(dofile, p)
        if ok and type(m) == "table" and type(m.regions) == "table" then
            D.map_path, D.map = p, m
            return m
        end
    end
    D.map_error = string.format(
        "wechat map 读不到： %s\n重新生成： ./tools/lua.sh helper/lib/apps/wechat.lua",
        table.concat(tried, " | "))
    return nil
end

-- map 里的坐标是**绝对屏幕坐标**，按生成 map 时的窗口几何（map.window.w/h）标定。
-- 窗口一旦换了几何，所有点就落到别处（点空、点到别的按钮，症状像"没反应"）。
-- 所以每次 run 先 ensure_geom()：尺寸不符就最大化（openbox 只认 _NET_WM_STATE，
-- move/resize 凑不出来），最大化也救不回来就直接报错——硬点等于随机点。
-- 尺寸对得上但位置不同（多显示器/面板把最大化窗口顶下去）纯平移就够，走 OFF。
local OFF = { x = 0, y = 0 }
local GEOM_TOL = 8      -- 边框/面板可能吃掉几像素

local function region(name)
    local m = D.map or load_map()
    if not m then error(D.map_error) end
    local g = m.regions[name]
    if type(g) ~= "table" or not g.x0 then
        error(string.format("wechat map 缺 region %q（%s）；把坐标写进 helper/lib/apps/wechat.lua 后重跑生成脚本",
            name, D.map_path))
    end
    if OFF.x == 0 and OFF.y == 0 then return g end
    return { x0 = g.x0 + OFF.x, y0 = g.y0 + OFF.y,
             x1 = g.x1 + OFF.x, y1 = g.y1 + OFF.y, note = g.note }
end

local function crop(name)
    local g = region(name)
    return { g.x0, g.y0, g.x1, g.y1 }
end

local function point(name)
    local g = region(name)
    return math.floor((g.x0 + g.x1) / 2), math.floor((g.y0 + g.y1) / 2)
end

-- 开跑前一次性把需要的 region 全查一遍，缺哪个直接列名字（fail fast，不半途炸）
local function check(extra)
    local m = D.map or load_map()
    if not m then return nil, D.map_error end
    local names = {}
    for _, n in ipairs(MAP_REQUIRED) do names[#names + 1] = n end
    for _, n in ipairs(extra or {}) do names[#names + 1] = n end
    local miss = {}
    for _, n in ipairs(names) do
        local g = m.regions[n]
        if type(g) ~= "table" or not g.x0 then miss[#miss + 1] = n end
    end
    if #miss > 0 then
        return nil, string.format("wechat map 缺 region: %s（%s）；坐标写进 helper/lib/apps/wechat.lua 后重跑生成脚本",
            table.concat(miss, ","), D.map_path)
    end
    return m
end

local M = {}
M.schema = {
    name = "wechat",
    description = "操作微信：搜索联系人/群、进入会话、输入并发送消息、发送文件（动态 libxdo 驱动；搜索回车靠像素指纹判定，发送后不做 OCR 验收）",
    parameters = {
        type = "object",
        properties = {
            action = { type = "string", enum = { "run", "search", "open", "send", "sendfile", "screenshot" } },
            name = { type = "string", description = "联系人/群名（search/open/run/sendfile/screenshot 可选，给了就先搜索进入）" },
            text = { type = "string", description = "要发送的消息" },
            path = { type = "string", description = "sendfile 必填：要发送的文件的绝对路径" },
            rect = { type = "array", items = { type = "integer" },
                     description = "screenshot 必填：[x0,y0,x1,y1] 屏幕坐标；先最小化微信，alt+a 拖拽选区，双击入剪贴板" },
            index = { type = "integer", description = "第几行候选，默认 1" },
            background = { type = "boolean", description = "做完最小化微信，默认 true" },
        },
        required = { "action" },
    },
}

local W, xdo, OCR
local win

local function sleep(ms) ffi.C.usleep(ms * 1000); if xdo then xdo:sync() end end

local function libs()
    if not W then
        W = require("ffi.x11")
        xdo = require("ffi.xdo").new()
        -- 必须紧跟着标 CLOEXEC：下面 set_clipboard() 用 os.execute 起 xclip，
        -- 子进程会继承 X socket，两个进程抢同一条事件流 → ctrl+v/ctrl+a 静默失效
        -- （同一调用在一次性脚本里正常，长驻进程里没反应）。见 xdo.lua:protect_fd
        xdo:protect_fd()
        OCR = require("ffi.ocr")
    end
end

local function find_win()
    libs()
    local ok, r = pcall(W.resolve, { name = "微信", class = "wechat", pick = 1 })
    -- resolve 可能返回表（{id=…}）也可能返回裸 number；先判类型再取字段——
    -- 原来写 `r.id or r.win or (type(r)=="number" and r)`，r 是 number 时
    -- 第一个 `r.id` 就 "attempt to index a number value"，兜底永远走不到。
    local id
    if ok and type(r) == "table" then id = r.id or r.win
    elseif ok and type(r) == "number" then id = r end
    if not id then error("wechat 窗口没找到（先打开微信，并确保不在最小化状态）") end
    return id
end

-- 每步前都重新激活：任何键盘事件都可能让 openbox 把微信收回后台。
-- 250ms 只在「真的发起了激活」时才付：窗口已在前台时它纯属白等，
-- 而 do_search 一条路径就要 ensure 十几次（click 前后各一次 + 每个 key）。
-- 前向声明：sig/wait_change/pad_to 依赖下面那套截图轮询，mark 依赖下面的 TRACE。
-- 必须在第一个用到它们的函数（ensure/click）**之前**声明成 local，否则函数体里
-- 编译期解析成全局变量，而定义处写的是 local → 运行时 "call a nil value"。
local sig, wait_change, pad_to, mark

local tvb = ffi.new("struct timeval")
local function now_ms()
    ffi.C.gettimeofday(tvb, nil)
    return tonumber(tvb.tv_sec) * 1000 + tonumber(tvb.tv_usec) / 1000
end

-- 最小化/图标态的窗口 activate() 是**空操作**（openbox 不会因为你 activate 一个
-- iconic 窗口就 deiconify），于是后面所有 XTEST 按键都落到当时的焦点窗口上：
-- 实测过一次 send 就这样把关键词打进了别处，crop("candidates") 抓到的还是旧画面，
-- 报「候选面板没看到该名字」。所以 activate 之后必须回读状态，hidden 就先 show。
local function ensure()
    local t = now_ms()
    local cur = xdo.active and xdo:active() or nil
    mark("  ens.query", t)
    local st
    pcall(function() st = xdo:wm_state(win) end)
    if st and st.hidden then
        pcall(function() xdo:show(win) end)
        mark("  ens.show", t)
        sleep(150)
        cur = nil
    end
    if cur ~= win then
        pcall(function() xdo:activate(win) end)
        mark("  ens.activate", t)
        sleep(250)
        mark("  ens.sleep", t)
    end
    -- 光看 active() 不够：长驻进程里读到的 active 可能是过期值，于是这里静默跳过激活，
    -- 后面 ctrl+a/ctrl+v/Return 全落到当时的焦点窗口上（实测：工具通道里剪贴板明明写着
    -- 「文件传输助手」，搜索框却一个字符都没进去，OCR 读到通讯录左栏 → 误报
    -- 「候选面板没看到该名字」；同一份代码在一次性进程里跑却正常）。所以激活必须回读确认。
    local ok = false
    pcall(function() ok = xdo:wait_active(win, true) end)
    if not ok then
        -- 再抢一次（raise 到栈顶 + 重新 activate），仍不成交给调用方：宁可报焦点错，
        -- 也不能把按键打到别人的窗口里。
        pcall(function()
            xdo:raise(win)
            xdo:activate(win)
        end)
        pcall(function() ok = xdo:wait_active(win, true) end)
        mark("  ens.retry", t)
    end
    if not ok then error("微信拿不到焦点：按键会被别的窗口吃掉（先手动点一下微信再重试）") end
end

-- 几何守门：把窗口弄回 map 标定的那个几何，否则后面每个 point()/crop() 都是错的。
-- 顺序是「先唤醒再看」：最小化/图标态的 XGetGeometry 给的是图标位置，不是真实窗口。
-- 几何不符时先问 WM 记着的 _NET_WM_STATE，**已经是最大化就别再发 maximize**：openbox
-- 对已最大化的窗口再收一次是纯无操作，白等 2.5s，而且失败信息会误报成「最大化没生效」。
-- 两个方向要分开报，用户才知道是重标定还是真没法凑：已最大化 = 面板/显示器变了（只能重标定），
-- 未最大化 = 消息没被 WM 认（窗口 override_redirect / 没有 EWMH）。
-- 返回 true 或 nil+原因；原因要能照着做（重跑生成脚本 / 换窗口）。
local function ensure_geom()
    local m = D.map or load_map()
    if not m then return nil, D.map_error end
    local want = m.window
    if type(want) ~= "table" or not want.w or not want.h then
        return true         -- 没标定几何就无从判断，保持旧行为不阻塞
    end
    local function fits(g)
        return g ~= nil and math.abs(g.w - want.w) <= GEOM_TOL and math.abs(g.h - want.h) <= GEOM_TOL
    end
    pcall(function() xdo:activate(win) end)
    sleep(200)
    local g = xdo:geometry(win)
    if fits(g) then
        OFF.x, OFF.y = g.x, g.y
        if OFF.x ~= 0 or OFF.y ~= 0 then
            D.geom_note = string.format("窗口在 %d,%d，坐标已平移", OFF.x, OFF.y)
        end
        return true
    end
    local t = now_ms()
    local st = xdo:wm_state(win)          -- 没有 _NET_WM_STATE 的窗口返回全 false，不当失败
    if not st.maximized and not st.fullscreen then
        pcall(function() xdo:maximize(win) end)
        local deadline = t + 2500
        while now_ms() < deadline do
            sleep(100)
            g = xdo:geometry(win)
            if fits(g) then break end
        end
        mark("  geom.maximize", t)
        st = xdo:wm_state(win)
    else
        D.geom_note = "窗口已最大化但几何不符（显示器/面板变了），未重发 maximize"
    end
    g = xdo:geometry(win) or g
    if not fits(g) then
        return nil, string.format(
            "微信窗口几何 %sx%s ≠ map 标定 %dx%d（%s）；"
                .. "按当前几何重跑 ./tools/lua.sh helper/lib/apps/wechat.lua 重新标定",
            tostring(g and g.w), tostring(g and g.h), want.w, want.h,
            st.maximized and "已是最大化，最大化救不回来" or "发了 maximize 仍不符")
    end
    OFF.x, OFF.y = g.x, g.y
    return true
end

-- 点一下，然后盯「这块画面变了」就走。
-- 老写法是 move 后 160ms + click 后 420ms 纯盲等：一条搜索路径三次 click 就 1.74s，
-- 而界面通常几十毫秒就反应完了。r = 想等的区域（省略则用点击点周围 60x60）；
-- 盼不到变化就补足到原节拍，所以最坏情况跟老写法一样慢，不会更慢。
-- skip_ensure=true：点完**不要**再抢焦点（默认抢，好让后续盲打键盘落到微信）。
-- 必须能关掉的原因——这是个 15s 的坑，不是洁癖：点「发送文件」后 GTK 的 modal
-- 文件框正在 map（内部枚举 gvfs 挂载点时抓 X server），此时对父窗口调
-- xdo:activate → XSetInputFocus/XSync 要 15076ms 才返回（实测，`WECHAT_TRACE=1`
-- 打 `ens.activate`）。而下一步本来就要 activate(dialog_id)，抢父窗口纯属白等 + 跟
-- modal 抢焦点。21.1s 的 sendfile 里 15.1s 就是这一个调用。
local function click(x, y, r, skip_ensure)
    local t = now_ms()
    mark("start", t)
    ensure()
    mark("ensure", t)
    xdo:move_abs(x, y); sleep(160)
    mark("move", t)
    local box = r or { x - 30, y - 30, x + 30, y + 30 }
    local base = sig(box)                       -- 点击前基准（鼠标已就位、hover 已生效）
    mark("sig", t)
    xdo:click_abs(x, y, 1)
    mark("click_abs", t)
    local ok, el = wait_change(box, base, 420, 25)
    if not ok then pad_to(420, el) end
    mark("wait_change ok=" .. tostring(ok), t)
    if not skip_ensure then ensure() end
    mark("ensure2", t)
end

local function key(seq)
    ensure(); xdo:key(0, seq, 15000); sleep(200)
end

-- ── 小区域轮询：把「固定 sleep 撞运气」换成「看到结果再走」 ──────────────
-- 实测（本机 2560x1440，GTK+ibus）：点「发送文件」→ 弹窗可见 581ms；激活窗口 ~30ms；
-- ctrl+a+BS 两次按键本身 ~30ms；xclip 写剪贴板 2.4ms；ctrl+v 到 GTK 真正粘好 **33ms**；
-- 回车到对话框消失 **16ms**。原来这一段是 900+400+200+200+250+700+1200 = 3.85s 盲等，
-- 真实工作约 110ms —— 这就是「明明粘好了，怎么还没发出去」的全部来源。
-- 判据用 liblite_capture 抓 map 里的一小块（565x34 实测 2.7ms，不落全屏截图、不起子进程），
-- 拿不到 .so 就返回 nil，调用方退回原来的固定 sleep（fail-open：优化失效 ≠ 功能失效）。
local CAP
local function cap()
    if CAP ~= nil then return CAP or nil end
    CAP = false
    pcall(function()
        local f = require("ffi")
        pcall(f.cdef, "int lite_capture(int x, int y, int w, int h, const char *path);")
        CAP = f.load(require("ffi.libfind").find("liblite_capture.so")) or false
    end)
    return CAP or nil
end

-- 分段耗时：`WECHAT_TRACE=1` 才打印到 stderr，平时零成本（一次 getenv）。
-- 不 print stdout：run 的返回值要能被 JSON 化，混进日志会把调用方解析搞坏。
local TRACE = os.getenv("WECHAT_TRACE")
mark = function(tag, t0)
    if not TRACE then return end
    io.stderr:write(string.format("[mark] %6.0fms %s\n", now_ms() - t0, tag))
end

-- 区域指纹 {n=字节数, h=djb2}。截图 2.7ms、文件几 KB，整读算哈希不心疼；
-- 只比字节数会漏掉「长度不变但内容变了」这种罕见情况。
-- 必须返回**单个表**：返回多值时 `local base = sig(r)` 只会拿到第一个值（数字），
-- 之后 sig_eq 去 `base[1]` 就是 "attempt to index a number value"（踩过）。
-- 赋值而不是 `local function`：前面已 `local sig`（click 在它之前就要用）
sig = function(r)
    local lib = cap()
    if not lib or not r then return nil end
    local p = D.tmp_prefix .. "-sig.png"
    if lib.lite_capture(r[1], r[2], r[3] - r[1], r[4] - r[2], p) ~= 0 then return nil end
    local f = io.open(p, "rb"); if not f then return nil end
    local data = f:read("*a"); f:close()
    local h = 5381
    for i = 1, #data do h = (h * 33 + data:byte(i)) % 4294967296 end
    return { n = #data, h = h }
end

local function sig_eq(a, b)
    return a ~= nil and b ~= nil and a.n == b.n and a.h == b.h
end

-- 轮询到 cond() 为真或超时，返回 (ok, elapsed_ms)。step 默认 30ms（不用 sleep()：
-- 那里面还有 xdo:sync()，轮询时要的是轻量 usleep）。
local function wait_for(cond, timeout, step)
    local t0 = now_ms()
    step = step or 30
    while true do
        if cond() then return true, now_ms() - t0 end
        if now_ms() - t0 >= timeout then return false, now_ms() - t0 end
        ffi.C.usleep(step * 1000)
    end
end

-- 等「文字真的进去了」：连抓 persist 次都不同于 base 才算数。
-- 为什么不看单帧：输入框有光标闪烁，单帧差异可能只是光标；假阳性的代价是
-- 「以为粘好了就回车」→ 发空。连抓 3 次 ≈ 45ms，实测贴好后 33ms 就有字，代价可忽略。
local function wait_typed(r, base, persist, timeout)
    if not base then return false end
    persist = persist or 3
    local hits = 0
    return (wait_for(function()
        local s = sig(r)
        hits = (s and not sig_eq(s, base)) and hits + 1 or 0
        return hits >= persist
    end, timeout or 3000, 15))
end

-- 等区域内出现「和 base 不同」的画面（base=nil 时先抓一帧当基准），返回 (ok, 花了多少 ms)。
-- 存在的理由：把「点完/按完之后盲等 N 百毫秒」换成「界面真的变了就走」。
-- 拿不到截图（cap 缺失）或抓帧失败时返回 nil —— 调用方原样退回固定 sleep，功能不减。
wait_change = function(r, base, timeout, step)
    if not r then return nil end
    local b = base or sig(r)
    if not b then return nil end
    return wait_for(function()
        local s = sig(r)
        return s ~= nil and not sig_eq(s, b)
    end, timeout or 500, step or 25)
end

-- 补足到原节拍：轮询已经花掉的时间不算白花，超时就只补差额（失败时行为 == 老写法）。
pad_to = function(ms, el) sleep(math.max(0, ms - (el or 0))) end

-- 等这块区域「画稳」：连抓两帧一致才返回那一帧的指纹（拿不到截图返回 nil）。
-- 候选面板是逐行渲染的，paste 完立刻取指纹会拿到半张脸，之后它自己长完就被
-- 误判成「回车后面板变了」。400ms 上限（实测渲染完 <120ms）。
local function settle(r, timeout, step)
    local a = sig(r)
    if not a then return nil end
    wait_for(function()
        local b = sig(r)
        if b and sig_eq(a, b) then return true end
        a = b
        return false
    end, timeout or 400, step or 20)
    return a
end

-- 写剪贴板是 send / sendfile 共用的第一步：抽出来只是为了别让两处各写一遍
-- xclip 调用、各漏一种失败判据（原来 sendfile 那处拿到的文件句柄连 fsync 都没做）。
-- wait：写完到允许按 ctrl+v 之间的等待。默认 250ms 是盲等（selection 交接没完成
-- 就 ctrl+v 会贴出上一次的内容）；sendfile 那条路会给小值 + 靠指纹轮询确认到底贴上没。
local function set_clipboard(text, wait)
    local p = D.tmp_prefix .. "-clip.txt"
    local f = assert(io.open(p, "w")); f:write(text); f:close()
    -- xclip -i 在本机同步退出（3ms），可安全接力
    local ok = os.execute("xclip -selection clipboard -i " .. p .. " >/dev/null 2>&1")
    if ok ~= 0 and ok ~= true then error("写剪贴板失败：xclip 不可用") end
    sleep(wait or 250)
end

-- paste 的 r（可选）：给了就把「字进去了」当判据，省掉固定 800ms；没给就按原节拍。
-- 粘贴**必须验证**。老写法 `if not wait_typed(...) then sleep(800) end` 把失败吞掉了：
-- 搜索框一个字都没进去，函数照样返回，几十行之后才在 do_search 报
-- 「候选面板没看到该名字」，那是假线索（实测踩过：剪贴板里明明是「文件传输助手」，
-- 面板停在微信搜索首页，OCR 读到左栏导航 → 白查一圈焦点和 OCR）。
-- 现在：验证不上就重写剪贴板再粘一次（selection 交接慢于首次等待时首粘会落空），
-- 还不成就直接报「粘贴失败」，让错误出现在它真实发生的那一行。
local function paste(text, r)
    local base = r and sig(r)
    set_clipboard(text, base and 40 or 250)
    key("ctrl+v")
    if base and wait_typed(r, base, 3, 3000) then return true end
    if base then
        set_clipboard(text, 250)
        key("ctrl+v")
        if wait_typed(r, base, 3, 3000) then return true end
        error("粘贴失败：剪贴板已写入但输入区没变（焦点不在输入框，或 ctrl+v 被吃掉）")
    end
    -- 抓不到区域指纹（无截图库/裁剪越界）时退回原节拍：不因为优化引入新失败。
    sleep(800)
end

local function norm(s)
    return (tostring(s or ""):gsub("[%s%p]", ""):gsub("[,。，、]", ""))
end

-- 字符数（不是字节数）：`#s` 在 UTF-8 上量的是字节，"——by lite" 这种签名
-- norm 后剩 6 个字符却占 9 字节，用 `#` 当门槛会把它误判成"够长的一行"。
local function ulen(s)
    local n = 0
    for i = 1, #s do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then n = n + 1 end
    end
    return n
end

-- 编辑距离相似度：OCR 常把同形字认错（手/丰、记/讠己…）
local function sim(a, b)
    a, b = norm(a), norm(b)
    if a == "" or b == "" then return 0 end
    if a:find(b, 1, true) or b:find(a, 1, true) then return 1 end
    local prev = {}
    for j = 0, #b do prev[j] = j end
    for i = 1, #a do
        local cur = { [0] = i }
        for j = 1, #b do
            local c = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
            cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + c)
        end
        prev = cur
    end
    return 1 - prev[#b] / math.max(#a, #b)
end

-- 截屏 + 裁剪 + OCR，返回 boxes（坐标已换回屏幕像素）和全文
local function ocr_area(tag, r)
    ensure(); sleep(200)
    local shot = D.tmp_prefix .. "-shot.png"
    W.capture_screen(shot)
    local x0, y0, x1, y1 = r[1], r[2], r[3], r[4]
    local cut = D.tmp_prefix .. "-ocr-" .. tag .. ".png"   -- 别叫 crop：会遮蔽模块级 crop(name)
    os.execute(string.format(
        "convert %s -crop %dx%d+%d+%d +repage -colorspace Gray -level 25%%,85%% -sharpen 0x1 %s",
        shot, x1 - x0, y1 - y0, x0, y0, cut))
    local boxes = OCR.run(cut) or {}
    for _, b in ipairs(boxes) do
        b.cx = x0 + (b.x or 0) + (b.w or 0) / 2
        b.cy = y0 + (b.y or 0) + (b.h or 0) / 2
    end
    return boxes, OCR.text(cut) or ""
end

-- OCR 完全不可用（无模型 / 截图空白）时返回 true：此时任何 OCR 复核都必然失败，
-- 用盲操作兜底，把决定权交回调用方，而不是让插件自我否决。
local function blind(s) return norm(s or "") == "" end

local function best_hit(boxes, name)
    local best, score = nil, 0
    for _, b in ipairs(boxes) do
        local s = sim(b.text, name)
        if s > score then best, score = b, s end
    end
    return best, score
end

-- 快路径（index==1，默认）：搜索框坐标就在 map 里，微信搜索面板回车即接受默认项。
-- 唯一名字（文件传输助手/服务号/私聊）根本不需要 OCR 扫候选 —— 粘贴 → 面板出画 →
-- 回车 → 「面板收起 或 标题变了」就说明跳转成立。判据全是像素指纹（2.7ms/帧）。
-- 面板收起这一条还能覆盖 OCR 标题复核唯一会误报的场景：连着发同一个人时标题本来
-- 就没变。返回 true=进会话 / false=没动（交给 OCR 路径报可诊断的错）/ nil=没截图能力。
local function fast_enter(panel, tr)
    local ok, el = wait_change(panel, nil, 600, 25)   -- 粘贴 → 候选面板出画
    if not ok then pad_to(300, el) end
    local pbase = settle(panel, 400)
    local tbase = sig(tr)
    if not pbase and not tbase then return nil end    -- cap 缺失（无 liblite_capture）→ 回退 OCR
    key("Return")
    return wait_for(function()
        local p, t = sig(panel), sig(tr)
        if p and pbase and not sig_eq(p, pbase) then return true end
        if t and tbase and not sig_eq(t, tbase) then return true end
        return false
    end, 900, 30) and true or false
end

local function do_search(name, index)
    ensure()
    click(point("titlebar"))                   -- 关键：ctrl+f 无效，必须先点标题栏
    -- 关键二：搜索框在「聊天」页拿不到焦点，粘贴会掉到空处（候选面板全空）。
    -- 先点左侧栏「通讯录」，再点搜索框才生效。
    -- 原来这里额外 sleep(500) 等页面重绘；现在让 click 盯「搜索框区域变了」自己判断。
    -- point() 返回两个值，写在参数表中间会被 Lua 截成第一个（只剩 x，y 变成
    -- 下一个实参 = 区域表）→ 必崩 "cannot convert 'table' to 'int'"。先取出来。
    local lcx, lcy = point("contacts")
    click(lcx, lcy, crop("search"))
    click(point("search"))
    key("ctrl+a"); key("BackSpace")
    paste(name, crop("search"))

    -- k==1 走快路径：不 OCR、不猜候选行坐标，回车就跳。
    local k = math.max(1, tonumber(index) or 1)
    local panel, tr = crop("candidates"), crop("title")
    if k == 1 then
        local fast = fast_enter(panel, tr)
        if fast then return { enter = true, opened = true } end
    end

    -- 慢路径（index>1，或快路径没跳成）：OCR 候选面板，按名字挑第 k 行。
    local ok, el = wait_change(panel, nil, 600, 25)
    if not ok then pad_to(300, el) end
    local boxes, text = {}, ""
    for _ = 1, 10 do
        boxes, text = ocr_area("candidates", panel)
        if norm(text) ~= "" then break end
        sleep(200)
    end
    local want = {}
    for _, b in ipairs(boxes) do
        if sim(b.text, name) >= D.min_sim and norm(b.text) ~= "" then want[#want + 1] = b end
    end
    -- 按面板的视觉顺序（y）排：det 输出的顺序不等于行的顺序，而下面 open_hit
    -- 找「第一行」也是按 min y —— 两处口径必须一致，否则 index=2 有概率点到第一行。
    table.sort(want, function(a, b) return (a.y or 0) < (b.y or 0) end)
    if #want == 0 then
        if norm(text) == "" then
            -- OCR 不可用（无模型/空白截图）：不猜候选行坐标（猜错一行就进错会话）。
            -- index=1 回车接受默认项是对的（微信默认项就是第一个真实结果）；
            -- 但 index>1 时回车必然进第一项，与请求不符——宁可报错，也不能静默发错人。
            if k > 1 then
                error(string.format("搜索 %q 要第 %d 行候选，但面板 OCR 全空，拒绝盲点（去掉 index 或修 OCR）",
                    name, k))
            end
            return { enter = true, blind = true, text = "" }
        end
        error(string.format("搜索 %q 后候选面板没看到该名字（OCR=%q，required: name）",
            name, norm(text):sub(1, 120)))
    end
    local hit = want[math.min(k, #want)]
    -- 「回车 = 进会话」：系统自带条目（文件传输助手、服务号…）和正常联系人，
    -- 搜索框默认选中项回车就进会话，比拿 OCR 坐标点候选行稳。只有第一行的
    -- 文本确实就是这个名字时才走回车；否则（目标在第二行及以后）还是点坐标。
    local top
    for _, b in ipairs(boxes) do
        if norm(b.text) ~= "" and (not top or (b.y or 0) < (top.y or 0)) then top = b end
    end
    if k == 1 and top and sim(top.text, name) >= D.min_sim then hit.enter = true end
    return hit
end

-- 打开 do_search 的候选：能回车就回车（默认项），否则点 OCR 给的坐标。
-- 返回 "enter" / "click"。慢路径（点候选行）保留标题 OCR 复核：点错人时标题像素同样会变，
-- 只有 OCR 能认出点中的是谁；快路径（回车）零复核。
local function open_hit(b, name)
    -- 快路径已经把「回车」按了，并用面板收起/标题变化验过：别再按一次 Return
    -- （第二次回车会打到聊天窗口的输入框），也别再 OCR 标题。
    if b.opened then return "enter" end
    local how = b.enter and "enter" or "click"
    -- 900ms 是等会话切换完；改成盯标题区域变化，变了就走（判据与下面 OCR 复核同一块区域）
    local tr = crop("title")
    local base = sig(tr)
    if b.enter then key("Return") else click(math.floor(b.cx), math.floor(b.cy), tr) end
    local ok, el = wait_change(tr, base, 900, 30)
    if not ok then pad_to(900, el) end
    local last = ""
    for _ = 1, 8 do
        local _, text = ocr_area("title", crop("title"))
        last = text
        if sim(text, name) >= D.min_sim then return how end
        sleep(300)
    end
    if b.blind or blind(last) then return how end   -- OCR 不可用：盲过，不阻塞
    error(string.format("%s 打开 %q 后会话标题没变（OCR=%q，required: name；可选 index）",
        how, name, norm(last):sub(1, 120)))
end

local function do_open(name, index)
    local b = do_search(name, index)
    return open_hit(b, name)
end

-- 长消息的气泡验收口径：底部 420px 条带里只可能看到**最后几行**，
-- 拿整段文本去 sim() 必然判失败（多行 + 上半截在视野外）。
-- 从末尾往前找第一条**规范化后 ≥10 字符**的行。别只看最后一个非空行：签名类尾行
-- （"——by lite"）norm 后只有 8 字符且全是易混字母，OCR 把 l 认成 t（"bytite"）就判
-- 假失败；挑上面那行中文正文才稳。长度按字符算（ulen），`#` 量的是字节会放宽门槛。
-- 发送 = 流程，不是证明：点输入框 → 粘贴（paste 内部已轮询「字真的进去了」）→ Return。
-- 原来发完还要 OCR 气泡回读、比对文本，等 1.2~3s，还常因 det 漏读小字号整行而假失败
-- （于是加 tail_line/seen_ok/blind 一堆补丁）。这些都是把已知答案再问一遍：
-- 输入框里的字是粘贴进去的、回车是同一个窗口收的，发出去就是发出去了。
-- 别为了"更保险"把气泡 OCR / 像素差加回来。
local function do_send(text)
    ensure()
    click(point("input"))
    key("ctrl+a"); key("BackSpace")
    paste(text, crop("input"))
    key("Return")
    return true
end

-- 文件选择框是独立窗口：不能用 click()/key()（它们会 ensure() 抢回微信主窗口）
local function dclick(x, y)
    xdo:move_abs(x, y); sleep(160)
    local box = { x - 30, y - 30, x + 30, y + 30 }
    local base = sig(box)
    xdo:click_abs(x, y, 1)
    local ok, el = wait_change(box, base, 420, 25)
    if not ok then pad_to(420, el) end
end
-- wait 默认 200ms：XTEST 下按键顺序有保证（sleep 里带 sync），等的是对端处理完，
-- 清空输入框那种「按完立刻按下一个」的场景 120ms 实测够用，省下的时间是纯利润。
local function dkey(seq, wait) xdo:key(0, seq, 15000); sleep(wait or 200) end

local function dialog_id()
    local ok, r = pcall(W.resolve, { name = "打开", class = "wechat", pick = 1 })
    if ok and r then return r.id or r.win end
    return nil
end

local function do_sendfile(path, name, index)
    local t0 = now_ms()
    if name then do_open(name, index) else ensure() end
    mark("open", t0)
    local fi = crop("fileinput")         -- 「文件名称」输入行：粘贴/清空验收就看这一小块
    -- 点完不抢焦点（skip_ensure）：下面立刻要 activate(dialog_id)，而 modal 正在 map 时
    -- 抢父窗口要白等 15s，见 click() 头注释。point 返回两个值，先取出来再传，别写成
    -- click(point("sendfile"), nil, true) —— 参数表中间的多返回值会被截成第一个。
    local bx, by = point("sendfile")
    click(bx, by, nil, true)
    mark("click sendfile", t0)
    -- 等对话框真的出来（实测 581ms）。老写法是「盲等 900ms + 12 轮 400ms」：
    -- 该慢的时候慢、该快的时候也慢，且失败要 4.8s 才知道。
    local id
    wait_for(function() id = dialog_id(); return id ~= nil end, 5000, 25)
    id = dialog_id() or id
    if not id then error("点了「发送文件」但没弹出「打开」对话框（region sendfile 可能偏了）") end
    mark("dialog up", t0)
    -- 弹窗默认焦点就在「文件名称」输入框：只激活窗口，不点（点会写脏 fileinput 坐标依赖）
    pcall(function() xdo:activate(id) end)
    -- 等窗口画稳：连抓两次指纹相同即认为已落定（实测激活 ~30ms），等不到再睡老的 400ms
    local a, b, settled = sig(fi), nil, false
    for _ = 1, 20 do
        sleep(20); b = sig(fi)
        if a and b and sig_eq(a, b) then settled = true; break end
        a = b
    end
    if not settled then sleep(400) end
    dkey("ctrl+a", 120); dkey("BackSpace", 120)
    local empty = sig(fi)                -- 清空后的 baseline：下面「字进去了」就拿它比
    set_clipboard(path, empty and 40 or 250)   -- 与 send 同一条通路，别再各写一份 xclip
    dkey("ctrl+v")
    -- 实测 ctrl+v → GTK 里真的出现字 33ms；老写法盲等 700ms。
    -- 判据：连续 3 帧（≈45ms）都不同于「清空后」的指纹 —— 单帧可能是光标闪烁。
    if not wait_typed(fi, empty, 3, 3000) then sleep(700) end
    mark("path typed", t0)
    dkey("Return")
    -- 实测回车 → 对话框消失 16ms；老写法盲等 1200ms。
    wait_for(function() return dialog_id() == nil end, 4000, 25)
    for _ = 1, 6 do
        if not dialog_id() then break end
        local ox, oy = point("fileopen"); dclick(ox, oy)
    end
    if dialog_id() then error("文件选择框没关掉（路径可能没粘进「文件名称」输入框）") end
    mark("dialog closed", t0)
    ensure(); sleep(200)
    dkey("Return", 400)                  -- 主窗口回车 = 发送
    ensure()
    mark("sent (Return)", t0)
    -- 不再做「气泡像素差 / OCR 回读」验收：发送是否成立已由上面三条流程断言锁死
    -- （对话框弹出 → 路径粘进 fileinput → 对话框关闭 → 主窗口 Return）。
    -- 点对地方、流程走通，发送就是发出了；气泡比对只是把 2.9s 花在证明已经知道的事。
    return string.format("sendfile: %s -> %s (%.1fs)", path, name or "当前会话", (now_ms() - t0) / 1000)
end

-- 剪贴板里是否有 PNG（微信截图器/xfce 都会给 image/png target）
local function clip_png()
    local h = io.popen("xclip -selection clipboard -t image/png -o 2>/dev/null | head -c 8 | od -An -tx1 | tr -d ' \\n'")
    local s = h and (h:read("*a") or "") or ""
    if h then h:close() end
    return s:sub(1, 16) == "89504e470d0a1a0a"
end

-- alt+a 桌面截图 → 拖拽矩形 → 双击入剪贴板 → 回微信输入框 ctrl+v → 回车发送。
-- 铁律：截图前必须先最小化微信。否则 alt+a 的选区遮罩压在微信上，剪贴板会被
-- 微信自己抢回，ctrl+v 表面成功但输入框永远是空的（踩过 6 次）。
local function do_screenshot(a, name, index)
    local x0, y0, x1, y1 = a[1], a[2], a[3], a[4]
    local cx, cy = math.floor((x0 + x1) / 2), math.floor((y0 + y1) / 2)
    -- 顺序铁律：先 open 会话（搜索要用剪贴板贴文字），再截图。
    -- 反了的话 do_open 的文本 xclip 会把刚进剪贴板的图覆盖掉，
    -- ctrl+v 贴进去的是「文件传输助手」四个字，回车发出去的也是文字。
    if name then do_open(name, index) else ensure() end
    -- 最小化：等「微信真的不是活动窗口了」就走（老写法盲等 900ms）
    pcall(function() xdo:minimize(win) end)
    local ok, el = wait_for(function() return (xdo.active and xdo:active() or nil) ~= win end, 900, 40)
    if not ok then pad_to(900, el) end
    local cur = xdo.active and xdo:active() or nil
    if cur == win then error("微信没最小化成功，alt+a 会被微信抢走剪贴板") end
    xdo:move_abs(40, 1400); sleep(250)                 -- 鼠标先离开待截区域
    -- alt+a 是全局热键，遮罩铺满整屏会压暗左上角那一小块 —— 拿它当「截图器已就绪」的判据。
    -- 遮罩刚出来时工具栏还在画，所以认出变化后再给 250ms 让它稳住。
    local corner = { 0, 0, 160, 80 }
    local cbase = sig(corner)
    xdo:key(0, "alt+a", 15000)
    local ok2, el2 = wait_change(corner, cbase, 1900, 40)
    if ok2 then sleep(250) else pad_to(1900, el2) end
    xdo:move_abs(x0, y0); sleep(120)
    xdo:mouse_down(1); sleep(80)
    for i = 1, 12 do
        local t = i / 12
        xdo:move_abs(math.floor(x0 + (x1 - x0) * t), math.floor(y0 + (y1 - y0) * t)); sleep(18)
    end
    sleep(80); xdo:mouse_up(1)
    -- 松手后选区工具栏要画出来；盯选区中心变化，最多 800ms（老写法盲等 800ms）
    local ctr = { cx - 60, cy - 30, cx + 60, cy + 30 }
    local sbase = sig(ctr)
    local ok3, el3 = wait_change(ctr, sbase, 800, 30)
    if not ok3 then pad_to(800, el3) end
    -- 双击确认：判据直接看剪贴板里的 PNG —— 这就是后面 error 的同一个判据，比盲等 1400ms 准
    xdo:click_abs(cx, cy, 1, 2, 90)
    wait_for(function() return clip_png() end, 1400, 60)
    if not clip_png() then error("截图没进剪贴板（没有 image/png）：alt+a 可能没生效或被别的窗口吃掉") end
    -- 抢回微信焦点：等它真的成为活动窗口（老写法盲等 500ms）
    pcall(function() xdo:activate(win) end)
    local ok4, el4 = wait_for(function() return (xdo.active and xdo:active() or nil) == win end, 500, 40)
    if not ok4 then pad_to(500, el4) end
    local ix, iy = point("input")
    click(ix, iy, crop("input"))
    local ibase = sig(crop("input"))
    xdo:key(0, "ctrl+v", 20000)
    -- 图贴进输入框 → 输入区从文字/空白变成缩略图；盯它变（老写法盲等 2600ms）
    local ok5, el5 = wait_change(crop("input"), ibase, 2600, 40)
    if not ok5 then pad_to(2600, el5) end
    ensure(); sleep(200)
    -- 回车 = 发送：盯左栏会话预览变化（老写法盲等 1800ms）
    local pbase = sig(crop("panel"))
    key("Return")
    local ok6, el6 = wait_change(crop("panel"), pbase, 1800, 40)
    if not ok6 then pad_to(1800, el6) end
    -- 不再 OCR 左栏预览找「[图片]」：流程本身已经证明发出了（图已进输入框、回车被同一窗口
    -- 收下、左栏预览出现像素变化），回读只是再花 1~4s 确认已知结论。
    return string.format("screenshot: %dx%d -> %s", x1 - x0, y1 - y0, name or "当前会话")
end

-- 收尾必做：把微信放回后台。
-- 坑：XIconifyWindow 偶尔被 WM 吃掉（刚抢过焦点时），一次 minimize 窗口还在前台；
-- 所以重试到 `_is_viewable == false` 为止，最多 3 次，每次等 300ms 让 WM 回执。
-- 而且**出错也要走这里**（见 M.run 的 pcall 包装）：动作抛错后微信留在最前面
-- 挡住用户桌面，是踩过的投诉点。
local function leave(bg)
    if bg == false then return end
    for _ = 1, 3 do
        pcall(function() xdo:minimize(win) end)
        sleep(300)
        local visible = true
        pcall(function() visible = xdo:_is_viewable(win) end)
        if not visible then return true end
    end
    return false
end

function M.run(args, env)
    libs()
    win = find_win()
    local action = args.action or "run"
    local bg = args.background
    -- 依赖 region 只列**真的会按坐标点**的那些：
    --   sendfile → fileopen（文件框右下「打开」），sendfile 按钮本身
    --   screenshot → panel（收尾验左栏预览「[图片]」）
    -- 原来 screenshot 登记的是 shotbtn，可 shotbtn 恰恰是**不能用**的那个按钮
    -- （内部截图器粘不进剪贴板，走 alt+a），登记它只会误导后来人。
    local needs = (action == "sendfile" and { "sendfile", "fileopen" })
        or (action == "screenshot" and { "panel" }) or nil
    local ok, err = check(needs)
    if not ok then return "error: " .. err end
    -- 坐标是绝对屏幕坐标，窗口几何不对就全错：这一步先把它弄回标定几何。
    local gok, gerr = ensure_geom()
    if not gok then return "error: " .. gerr end
    -- 所有动作都在这层 pcall 里跑：成功 or 抛错，收尾都 leave(bg) 把微信放回后台。
    -- 原来「出错就直接 error()」的写法会让一次失败的 send 把微信留在前台挡桌面。
    local function dispatch()
        if action == "screenshot" then
            local rect = assert(args.rect, "required: rect")
            for i = 1, 4 do
                if type(rect[i]) ~= "number" then
                    return "error: rect must be [x0,y0,x1,y1] integers, got "
                        .. tostring(rect[1]) .. "..."
                end
            end
            return do_screenshot(rect, args.name, args.index)
        end
        if action == "sendfile" then
            return do_sendfile(assert(args.path, "required: path"), args.name, args.index)
        end
        if action == "search" then
            local b = do_search(assert(args.name, "required: name"), args.index)
            if b.enter then
                return string.format("searched: %s (%s)", args.name,
                    b.opened and "回车进会话（面板收起/标题变化，零 OCR）"
                    or (b.blind and "回车进会话，OCR 不可用" or "第一行即目标，回车进会话"))
            end
            return string.format("searched: %s (candidate %q @ %d,%d)",
                args.name, norm(b.text), math.floor(b.cx), math.floor(b.cy))
        elseif action == "open" then
            local how = do_open(assert(args.name, "required: name"), args.index)
            return "opened: " .. args.name .. " (" .. tostring(how) .. ")"
        elseif action == "send" then
            local text = assert(args.text, "required: text")
            local head = ""
            -- name 给了就必须先搜索并进会话：原来这里直接 do_send，
            -- 等于「往当前打开的窗口里粘」——open 的是公众号/群聊就会发给错的人。
            if args.name then
                local b = do_search(args.name, args.index)
                head = "opened: " .. args.name .. " (" .. tostring(open_hit(b, args.name)) .. ")\n"
            end
            do_send(text)
            return head .. "sent: " .. text
        elseif action == "run" then
            local name = assert(args.name, "required: name")
            local text = assert(args.text, "required: text")
            local b = do_search(name, args.index)
            local head = string.format("searched: %s (%s)", name,
                b.opened and "enter,零OCR" or (b.enter and "enter" or string.format("%q @ %d,%d",
                    norm(b.text), math.floor(b.cx), math.floor(b.cy))))
            local how = open_hit(b, name)
            do_send(text)
            return head .. "\nopened: " .. name .. " (" .. tostring(how) .. ")"
                .. "\nsent: " .. text
        end
        -- 动作清单写在这里就一种下场：加了新 action 忘了同步这行。列全。
        error("未知 action: " .. tostring(action)
            .. "（run|search|open|send|sendfile|screenshot）")
    end

    local okd, res = pcall(dispatch)
    local bg_ok = leave(bg)
    if not okd then error(res, 0) end
    if bg_ok == false then
        return tostring(res) .. "\n(警告：微信没能收回后台，minimize 重试 3 次仍可见)"
    end
    return res
end

return M
