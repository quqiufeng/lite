-- wx_watch_daemon.lua — 常驻轮询微信「文件传输助手」，把手机发来的新消息当指令丢给 lite。
--
-- 为什么是截图 + OCR：微信 Linux 版的消息落在加密 xwechat_files/*.db 里，没有稳定读口；
-- 屏幕上就有的东西用眼睛取最省事。原文靠「右键气泡 → 复制」拿剪贴板，**不用 OCR 文本**：
-- PP-OCRv4 吃中文稳、吃空格不稳（"lite 列一下 /tmp" 会变成 "lite列一下/tmp"），
-- 指令里的路径和命令必须逐字精确，所以 OCR 只负责"发现新消息 + 定位气泡"。
--
-- 一轮节奏（互斥，不并发）：
--   1 确保微信在前台、会话是「文件传输助手」（标题 OCR 不对就调 wechat 插件的 open）
--   2 鼠标挪到标题栏（不然悬停浮标「翻译」会混进 OCR）→ 截聊天区 → OCR → 合并成块
--   3 和上一帧做尾部后缀比对，只把新增块当候选
--   4 候选逐个：右键 → 菜单里点「复制」→ 剪贴板 = 精确原文（失败退回 OCR 文本）
--   5 过滤（回执 lite: / 已知回复哈希 / 无触发前缀）→ 入 pending → 派发给**主进程**
--
-- 派发走 call_master（helper/call_master.lua）：把提示词粘贴进主 lite 的终端输入框并回车，
-- 由握着 mem.lock 的那个进程自己执行 —— 记忆可写、能回微信。不再走 serve HTTP：HTTP 那条
-- 路只能在后台再起一个 --readonly 实例（不落记忆，和桌面会话是两个人）。
--
-- 派完本进程**等主进程闲下来**（撒 CPU 采样，见 wait_master_idle）再继续采，所以不会和它
-- 抢微信窗口；回执由主进程自己发（提示词里要求了 lite: 前缀），本进程不再补发。
-- 主进程不可用（没有活着的 mem.lock / 没有窗口）才退回一次性执行 --once --readonly。
--
-- 空闲收起：每轮没认出新消息就把微信 minimize（--no-hide 关掉）。注意这必然带来闪烁
-- —— 截图取的是屏幕像素，窗口最小化就读不到气泡，所以每轮得先 activate 再收起来，
-- 窗口可见时长 ≈ 一次截屏 + OCR（1~2s）。
--
-- 用法：tools/lite-lua helper/lib/wx_watch_daemon.lua --interval 10 [--wait 1800]
--        [--prefix "#lite"] [--dry-run] [--once] [--no-raise] [--no-hide]
-- 兼容旧调用：--port/--host/--no-spawn 还认，但已经是空转（派发不走 serve HTTP 了）。
-- 由 helper/wechat_watch.lua 拉起/收掉，别手写 nohup（pidfile/日志在对面的状态目录里）。
local ROOT = os.getenv("LITE_ROOT") or "."
package.path = ROOT .. "/lua/?.lua;" .. ROOT .. "/?.lua;" .. package.path

local ffi = require("ffi")
pcall(ffi.cdef, "void usleep(unsigned int);")
pcall(ffi.cdef, "int getpid(void);")
local cjson = require("cjson")
local W = require("ffi.x11")
local OCR = require("ffi.ocr")
local xdo = require("ffi.xdo").new()

local SELF = arg and arg[0] or ""
local LIBDIR = SELF:match("^(.*)/[^/]+$") or "."
local Watch = assert(loadfile(LIBDIR .. "/wx_watch.lua"))()

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function sleep(ms) ffi.C.usleep(ms * 1000); pcall(function() xdo:sync() end) end

-- ── 配置 ─────────────────────────────────────────────────────────────
local C = {
    interval = 10, port = 8765, host = "127.0.0.1",
    -- 触发前缀；改这里就得同步 wx_watch.lua 的 M.PREFIX（单测钉的是那边的语义）
    prefix = "#lite", chat = "文件传输助手", tag = "lite:",
    once = false, dry = false, raise = true, hide = true, max_new = 3,
    -- 连续多少帧读到 0 条才认「会话被清空」（见 tick 里的空帧分支）
    empty_frames = 4,
    -- 派完等主进程闲下来：最少等 settle_min 秒（防「刚 paste 还没动起来就判闲」），
    -- 最多等 wait 秒（主进程在跑长任务时不至于把守护进程饿死，超时就照常继续采）
    settle_min = 15, wait = 1800,
    cwd = os.getenv("LITE_CWD") or os.getenv("PWD") or ".",
    state = os.getenv("LITE_WX_STATE") or
        ((os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") or "/tmp") .. "/.local/share")
            .. "/lite/wx-watch"),
}
do
    local i = 1
    while arg and arg[i] do
        local a, v = arg[i], arg[i + 1]
        if a == "--interval" then C.interval = tonumber(v); i = i + 2
        elseif a == "--port" then C.port = tonumber(v); i = i + 2   -- 空转，留着不炸旧调用
        elseif a == "--host" then C.host = v; i = i + 2            -- 同上
        elseif a == "--wait" then C.wait = tonumber(v); i = i + 2
        elseif a == "--settle" then C.settle_min = tonumber(v); i = i + 2
        elseif a == "--prefix" then C.prefix = v; i = i + 2
        elseif a == "--chat" then C.chat = v; i = i + 2
        elseif a == "--tag" then C.tag = v; i = i + 2
        elseif a == "--max-new" then C.max_new = tonumber(v); i = i + 2
        elseif a == "--cwd" then C.cwd = v; i = i + 2
        elseif a == "--state" then C.state = v; i = i + 2
        elseif a == "--once" then C.once = true; i = i + 1
        elseif a == "--dry-run" then C.dry = true; i = i + 1
        elseif a == "--no-spawn" then i = i + 1                   -- 空转（不再拉 serve）
        elseif a == "--no-raise" then C.raise = false; i = i + 1
        elseif a == "--no-hide" then C.hide = false; i = i + 1
        elseif a == "--dump" then C.dump = true; C.once = true; C.dry = true; i = i + 1
        else
            io.stderr:write("unknown arg: " .. tostring(a) .. "\n")
            os.exit(2)
        end
    end
end
os.execute("mkdir -p " .. q(C.state))
local STATE = C.state .. "/state.json"
local PIDFILE = C.state .. "/daemon.pid"
local TMP = C.state .. "/tmp"

-- ── 日志 ─────────────────────────────────────────────────────────────
local function now() return os.date("%m-%d %H:%M:%S") end
local function log(fmt, ...)
    local s = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    io.write(now(), " ", s, "\n"); io.flush()
end

-- ── 状态 ─────────────────────────────────────────────────────────────
local st = { prev = {}, pending = {}, replies = {}, done = {}, seq = 0 }
do
    local f = io.open(STATE, "rb")
    if f then
        local ok, t = pcall(cjson.decode, f:read("*a") or "")
        f:close()
        if ok and type(t) == "table" then
            for k, v in pairs(t) do if st[k] ~= nil then st[k] = v end end
        end
    end
end
local function save()
    local f = io.open(STATE .. ".tmp", "wb")
    if not f then return end
    f:write(cjson.encode(st)); f:close()
    os.rename(STATE .. ".tmp", STATE)
end

-- ── 微信窗口 ─────────────────────────────────────────────────────────
local win, wechat
local function wechat_lib()
    if wechat then return wechat end
    local ok, mod = pcall(loadfile(LIBDIR .. "/../wechat.lua"))
    wechat = ok and type(mod) == "table" and mod or false
    return wechat
end

local function win_refresh()
    local ok, w = pcall(W.resolve, { class = "wechat", pick = 1 })
    if ok and w then win = w; return w end
    win = nil
    return nil
end

local function ocr_region(r, tag)
    local shot = TMP .. "-" .. tag .. ".png"
    local cut = TMP .. "-" .. tag .. "-c.png"
    W.capture_screen(shot)
    os.execute(string.format("convert %s -crop %dx%d+%d+%d +repage %s", q(shot),
        r[3] - r[1], r[4] - r[2], r[1], r[2], q(cut)))
    local boxes = OCR.run(cut) or {}
    for _, b in ipairs(boxes) do
        b.x = (b.x or 0) + r[1]; b.y = (b.y or 0) + r[2]
    end
    return boxes
end

-- 会话标题 OCR：不是目标会话就调 wechat 插件的 open（它自己会 ensure_geom/搜索/回车）
-- 抢焦点之前谁在前台：每轮跑完要还回去，不能把用户正干活的窗口顶掉（用户明确要求
-- 「检查完就最小化、别占焦点」）。只在真的要 raise 时才记，避免白白多一次 X 查询。
local prev_active
-- 这一轮「动过窗口」吗：只有动过（show/raise/activate）收尾才 hide，否则别去碰用户正用着的
-- 微信 —— 每轮无条件 minimize 会把「微信本来就是开着的、用户正在里面翻记录」也一起收掉。
local touched = false
local function remember_prev()
    local a = xdo:active()
    if a and a ~= 0 and (not win or a ~= win.id) then prev_active = a end
end

-- 只把窗口摆到最前面（map + raise），**不抢键盘焦点**：用户可能正在别的窗口打字，
-- XSetInputFocus 一挪，下一次按键就进了微信。xdo:activate 内部会 take_focus，所以这里
-- 只走 show/raise；唯一需要真焦点的是「往搜索框打字切会话」那条路（见 take_focus）。
local function surface()
    if xdo:_is_viewable(win.id) then
        -- 已经没被盖住（或者用户正在里面）→ 用户可能正用着它，什么都别动：
        -- 不 raise、也不记 touched，收尾就不会 minimize。判据用 visible() 而不是 is_top()：
        -- 这台机器 top_window() 返回的不是 client window（44040200，查不到 WM_CLASS，
        -- 多半是 WM 框/override 窗口），is_top 恒 false，那判据等于没写。
        if xdo:active() == win.id or (xdo:visible(win.id)) then return true end
        touched = true
        pcall(function() xdo:raise(win.id) end)
        return true
    end
    touched = true
    pcall(function() xdo:show(win.id) end)
    for _ = 1, 20 do
        if xdo:_is_viewable(win.id) then
            pcall(function() xdo:raise(win.id) end)
            return true
        end
        sleep(120)
    end
    return false
end

-- 真要发键盘事件（搜索框打字）才取焦点，且记下原来是谁，收尾 hide_idle 还回去。
local function take_focus()
    touched = true
    remember_prev()
    for _ = 1, 15 do
        pcall(function() xdo:activate(win.id) end)
        if xdo:active() == win.id and xdo:_is_viewable(win.id) then return true end
        sleep(120)
    end
    return xdo:_is_viewable(win.id)
end

-- 把键盘焦点还给用户原来的窗口。窗口管理器（openbox/…）在 map/raise 时会按自己的
-- 「新窗口获得焦点」策略把焦点塞给微信，surface() 管不住这件事，所以摆完立刻抢回来：
-- 微信仍然可见（我们只改焦点不改堆叠），但用户下一次按键不会掉进微信。
local function restore_focus()
    if not prev_active or prev_active == win.id then return end
    if xdo:active() == prev_active then return end
    pcall(function() xdo:activate(prev_active) end)
end

-- 前向声明：focus() 要等标题认出来，而 title_text 定义在后面。
-- 注意 local 必须写在这里 —— 写在 title_text 定义处的话 focus 里看到的是全局 nil。
local title_text

local function focus()
    if not win_refresh() then return nil end
    if C.raise or C.hide then
        remember_prev()
        surface()
        -- 这里**不能**调 restore_focus()：它把 prev 窗口 activate 回来，而 activate 带 raise，
        -- 被最大化的终端立刻又盖满屏幕 —— 随后截全屏读到的全是终端内容（实测标题 OCR 空、
        -- 把 7 条基线读成 2 条）。用户的焦点等这一轮干完，由 hide_idle() 收尾时还。
        --
        -- 「看得见」要按层叠算，不是按 map_state：两个窗口都最大化时下面那个照样
        -- viewable=true。xdo:visible() 用 windows() 的 z + 几何算遮挡比例，面板（只压
        -- 底部 32px）不算遮挡，最大化终端（压满）算。
        for _ = 1, 24 do
            local vis, ratio = xdo:visible(win.id)
            if vis then break end
            touched = true
            pcall(function() xdo:raise(win.id) end)
            sleep(250)
            if _ == 1 then
                log("等微信到最前（被盖住 %.0f%%）", (ratio or 0) * 100)
            end
        end
        local vis = xdo:visible(win.id)
        if not vis then
            log("warn: 微信仍被盖住（无法截图取证），本轮跳过")
            return nil, "微信被其他窗口盖住"
        end
        -- 从最小化恢复后窗口要过一会儿才重绘：立刻 OCR 会读到空标题（→被误判成
        -- 「会话不对」而去打字切会话，反而抢焦点）和 0 条气泡。等到认出标题为止。
        for _ = 1, 20 do
            sleep(250)
            if title_text() ~= "" then break end
        end
    end
    return win
end

local TITLE_R          -- 前向声明：title_text 在它赋值之前定义，直接写 TITLE_R 会是 nil 的全局
function title_text()
    local boxes = ocr_region(TITLE_R, "title")
    local txt = {}
    for _, b in ipairs(boxes) do txt[#txt + 1] = tostring(b.text or "") end
    return Watch.key(table.concat(txt, ""))
end

local last_ok_title            -- 上一次确认过的标题（OCR 读空时的兜底）

local function ensure_chat_via(region_title)
    local fok, fwhy = focus()
    if not fok then return false, fwhy or "微信窗口找不到" end
    local want = Watch.key(C.chat)
    local joined = title_text()
    if joined:find(want, 1, true) then
        last_ok_title = joined
        return true
    end
    -- 标题 OCR 偶尔读空/读残（窄的灰字），这时上一条已知标题才可信：会话不会自己变，
    -- 认成「不对」只会白抢一次焦点去打字重开。
    if joined == "" and last_ok_title and last_ok_title:find(want, 1, true) then
        return true
    end
    if joined == "" then
        sleep(300)
        joined = title_text()
        if joined ~= "" and joined:find(want, 1, true) then return true end
        -- 标题空有两种：窗口还没抬起来（遮挡），或抬起来了但停在通讯录/设置等页面。
        -- 前者截图是别人的画面，拿它更新 prev 会污染基线 → 跳一轮；后者必须切回会话。
        -- 用「窗口是否真的可见」区分，不能一律跳过，否则一旦微信停在通讯录就永久空转。
        if joined == "" and not xdo:_is_viewable(win.id) then
            return false, "窗口不可见且标题识别为空（微信被遮挡？）"
        end
    end
    local wx = wechat_lib()
    if not wx then return false, "找不到 helper/wechat.lua，无法自动切会话" end
    log("当前会话不是「%s」（标题 OCR=%q），调 wechat open", C.chat, joined:sub(1, 40))
    take_focus()        -- open 要往搜索框打字，这一步必须真焦点（收尾会还回去）
    pcall(wx.run, { action = "open", name = C.chat, background = false })
    sleep(400)
    joined = title_text()
    if joined ~= "" and not joined:find(want, 1, true) then
        return false, "切成「" .. C.chat .. "」失败（标题 OCR=" .. joined:sub(1, 30) .. "）"
    end
    return true
end

-- ── 精确原文：右键气泡 → 菜单点「复制」 → 读剪贴板 ───────────────────
-- 剪贴板里可能不是文本（用户刚截了图 / 拷了文件）。`xclip -o` 对那种内容会吐一大坨
-- 二进制，更糟的是**拿空串回写会直接把图弄没**。所以先看 TARGETS 里有没有文本类型，
-- 只有本来就是文本的剪贴板才允许我们抹掉再还原。
local TEXT_TARGETS = { "UTF8_STRING", "text/plain", "COMPOUND_TEXT" }
local function clip_has_text()
    local h = io.popen("xclip -selection clipboard -o -t TARGETS 2>/dev/null")
    if not h then return false end
    local s = h:read("*a") or ""
    h:close()
    for _, t in ipairs(TEXT_TARGETS) do
        if s:find(t, 1, true) then return true end
    end
    return s:find("\nSTRING", 1, true) ~= nil    -- 只认独立一行，别被 UTF8_STRING 蹭中
end
-- 返回剪贴板里的**文本**；没有文本内容时返回 nil（和「空文本」区分开）
local function clip_read()
    if not clip_has_text() then return nil end
    local h = io.popen("xclip -selection clipboard -o 2>/dev/null")
    if not h then return nil end
    local s = h:read("*a") or ""
    h:close()
    return s
end
local function clip_write(s)
    local p = TMP .. "-clip.txt"
    local f = io.open(p, "wb"); if not f then return end
    f:write(s); f:close()
    os.execute("xclip -selection clipboard -i " .. q(p) .. " >/dev/null 2>&1")
end

-- 菜单裁剪框贴到屏幕边上会越界（convert -crop 越界只是变黑，不会报错，但 OCR 白算）。
-- 屏幕多大问 X 要，别写死 2560x1408：换显示器/换机器这套代码就静默错位。
local function screen_wh()
    local ok, w, h = pcall(function() return xdo:display_size() end)
    if ok and w and h and w > 0 and h > 0 then return w, h end
    return 2560, 1408
end

local function copy_at(x, y)
    local keep = clip_read()             -- nil = 剪贴板里本来没文本（图/文件），一律别动它
    if keep ~= nil then clip_write("") end  -- 抹成空：读到空就知道「复制」没发生
    pcall(function() xdo:click_abs(math.floor(x), math.floor(y), 3) end)
    sleep(450)
    local sw, sh = screen_wh()
    local mx0, my0 = math.max(0, x - 500), math.max(0, y - 60)
    local boxes = ocr_region({ mx0, my0, math.min(x + 700, sw), math.min(y + 620, sh) }, "menu")
    local hit
    for _, b in ipairs(boxes) do
        if Watch.key(b.text) == Watch.key("复制") then
            hit = b; break
        end
    end
    if not hit then
        -- win 传具体 id：libxdo 走 XSendEvent 直投微信，不依赖焦点（key(0,…) 是
        -- XTEST 打到当前焦点窗口，会把 Escape 漏进用户正在打字的窗口）
        pcall(function() xdo:key(win.id, "Escape") end)
        if keep then clip_write(keep) end
        return nil, "菜单里没找到「复制」"
    end
    pcall(function() xdo:click_abs(math.floor(hit.x + hit.w / 2), math.floor(hit.y + hit.h / 2), 1) end)
    sleep(350)
    local got = clip_read()
    if keep then clip_write(keep) end   -- 别偷走用户的剪贴板
    if not got or got == "" then return nil, "复制后剪贴板里没有文本" end
    return got
end

-- ── 派发 ─────────────────────────────────────────────────────────────
local PROMPT = [[
【微信远程指令】主人在手机上发给微信「文件传输助手」的消息，原文如下：

%s

执行约定（每条都算数）：
1. 先自己判风险：不可逆、改系统、删数据、花钱、往外发敏感内容 —— 先只回一句确认，别动手。
2. 干完用 wechat 工具（action=send, name=文件传输助手）把结论发回去，正文第一行以 `lite:` 开头，这是回环标记，必须保留（不带标记会被当成新指令再跑一遍）。
3. 手机屏幕小：结论 ≤800 字；长内容发文件或给本机路径。
4. 只做这一件事，别顺手扩活。
]]

-- 主进程 = 攥着 <cwd>/mem.lock 的那个（单写者，见 AGENTS §4）。
local function master_pid()
    local f = io.open(C.cwd .. "/mem.lock", "rb")
    if not f then return tonumber(os.getenv("LITE_MASTER_PID") or "") end
    local s = f:read("*a") or ""; f:close()
    local pid = tonumber(s:match("^%s*(%d+)"))
    if pid and os.execute("kill -0 " .. pid .. " 2>/dev/null") == 0 then return pid end
    return tonumber(os.getenv("LITE_MASTER_PID") or "")
end

-- ── 进程树 CPU ───────────────────────────────────────────────────────
-- 主进程的活几乎都在子进程里（bash/编译），只看自己那一行会一直在「闲」，所以要算整棵树。
-- 老写法每次采样 `cat /proc/[0-9]*/stat`：fork 一个 shell、扫上万行，而这条循环存在的意义
-- 就是「等它闲下来」——等到 30 分钟就是 1800 次白烧。现在零子进程：opendir/readdir 走
-- libc，stat 当成小文件逐个读。tick 是 USER_HZ 的 1/100 秒。
pcall(ffi.cdef, [[
typedef struct __dirstream LITE_DIR;
struct lite_dirent { uint64_t d_ino; int64_t d_off; unsigned short d_reclen;
                     unsigned char d_type; char d_name[256]; };
LITE_DIR *opendir(const char *);
struct lite_dirent *readdir(LITE_DIR *);
int closedir(LITE_DIR *);
]])

local function listdir(path)
    local d = ffi.C.opendir(path)
    if d == nil then return nil end
    local out = {}
    while true do
        local e = ffi.C.readdir(d)
        if e == nil then break end
        local n = ffi.string(e.d_name)
        if n ~= "." and n ~= ".." then out[#out + 1] = n end
    end
    ffi.C.closedir(d)
    return out
end

local function proc_stat(pid)
    local f = io.open("/proc/" .. pid .. "/stat", "rb")
    if not f then return nil end
    local line = f:read("*l") or ""
    f:close()
    local _, rest = line:match("^(%d+)%s+%b()%s*(.*)$")
    if not rest then return nil end
    local s = {}
    for tok in rest:gmatch("%S+") do s[#s + 1] = tok end
    -- 右括号后第 1 字段是 state(3)，所以 ppid 在 2、utime(14)/stime(15) 在 12/13
    return { ppid = tonumber(s[2]), cpu = (tonumber(s[12]) or 0) + (tonumber(s[13]) or 0) }
end

-- 直接子进程。**本机内核（7.2.12-hwreal）没有 /proc/<pid>/children，children 挂在每个
-- 线程下面（/proc/<pid>/task/<tid>/children）**，两条路都试；都没有才返回 nil 退全表扫。
-- 少算子孙 → 把「还在干活」误判成「闲了」→ 抢微信窗口，比多花点 CPU 贵得多。
local function proc_children(pid)
    local kids, found = {}, false
    local function slurp(p)
        local f = io.open(p, "rb")
        if not f then return false end
        local s = f:read("*a") or ""
        f:close()
        for tok in s:gmatch("%d+") do kids[#kids + 1] = tonumber(tok) end
        return true
    end
    if slurp("/proc/" .. pid .. "/children") then return kids end
    for _, tid in ipairs(listdir("/proc/" .. pid .. "/task") or {}) do
        if slurp("/proc/" .. pid .. "/task/" .. tid .. "/children") then found = true end
    end
    return found and kids or nil
end

local function tree_cpu(pid)
    local total, seen, stack, walked = 0, {}, { pid }, 0
    while #stack > 0 do
        local p = table.remove(stack)
        if p and not seen[p] and walked < 4096 then
            seen[p] = true; walked = walked + 1
            local s = proc_stat(p)
            if s then total = total + s.cpu end
            local kids = proc_children(p)
            if kids then
                for _, k in ipairs(kids) do stack[#stack + 1] = k end
            elseif p == pid then
                -- children 文件都没有（老内核/容器）：退回全表按 ppid 收子孙
                local all = {}
                for _, name in ipairs(listdir("/proc") or {}) do
                    local n = tonumber(name)
                    if n then
                        local st = proc_stat(n)
                        if st then all[n] = st end
                    end
                end
                local sum, in_tree = 0, { [pid] = true }
                local changed = true
                while changed do
                    changed = false
                    for id, st in pairs(all) do
                        if not in_tree[id] and st.ppid and in_tree[st.ppid] then
                            in_tree[id] = true; changed = true
                        end
                    end
                end
                for id in pairs(in_tree) do sum = sum + ((all[id] and all[id].cpu) or 0) end
                return sum
            end
        end
    end
    return total
end

-- 派完等主进程把这活干完：CPU 连续 3 次采样不涨 + 至少 settle_min 秒才算闲。
-- 建模等 API 时 CPU 也接近 0，所以这不是「精确在跑」的判据，只是「别在它动键盘时抢微信」；
-- 提前判闲最多是多截一帧，主线（回执）由它自己发，不会错。
local function wait_master_idle(pid)
    local base = tree_cpu(pid)
    local t0, last, quiet = os.time(), base, 0
    while true do
        sleep(1000)
        local now_cpu = tree_cpu(pid)
        local spent = os.time() - t0
        if base and now_cpu then
            if now_cpu ~= last then quiet = 0 else quiet = quiet + 1 end
            last = now_cpu
        end
        if spent >= C.settle_min and quiet >= 3 then
            if spent > C.settle_min + 3 then log("主进程闲了（等了 %ds，CPU 涨 %d tick）", spent, now_cpu and base and (now_cpu - base) or -1) end
            return true
        end
        if spent >= C.wait then
            log("warn: 等了 %ds 主进程还在动，先继续采（它的回执会被 lite: 前缀认出来）", spent)
            return false
        end
    end
end

local CM_MOD
local function master_mod()
    if CM_MOD ~= nil then return CM_MOD or nil end
    local p = LIBDIR .. "/../call_master.lua"
    local ok, mod = pcall(loadfile(p))
    if not ok or type(mod) ~= "table" or type(mod.run) ~= "function" then
        log("warn: 加载不了 %s（%s），只能退回一次性执行", p, tostring(mod))
        CM_MOD = false
        return nil
    end
    CM_MOD = mod
    return mod
end

local function oneshot(prompt)
    local run = ROOT .. "/tools/run.sh"
    local payload = TMP .. "-one.txt"
    local f = io.open(payload, "wb"); f:write(prompt); f:close()
    local h = io.popen(string.format(
        "cd %s && LITE_ALLOW_READONLY=1 %s --once --readonly --json \"$(cat %s)\" 2>&1",
        q(C.cwd), q(run), q(payload)))
    if not h then return nil, "run.sh 起不来" end
    local out = h:read("*a") or ""
    h:close()
    local ok, t = pcall(cjson.decode, out)
    if ok and type(t) == "table" then return t.text or t.answer or "" end
    return nil, "一次性执行失败: " .. out:sub(0, 400)
end

-- 派给主进程后本进程拿不到「那一轮的回答」——回答由它自己发到微信，这里只记一个哨兵。
local MASTER_DONE = {}

local function dispatch(text)
    local prompt = string.format(PROMPT, text)
    local cm, pid = master_mod(), master_pid()
    if cm and pid then
        local ok, res = pcall(cm.run, { text = prompt }, { cwd = C.cwd })
        res = tostring(res)
        if ok and res:sub(1, 3) == "ok:" then
            log("%s", res:sub(1, 200))
            wait_master_idle(pid)
            return MASTER_DONE
        end
        log("warn: call_master 没派成：%s", res:sub(1, 200))
    else
        log("warn: 没有主进程（%s/mem.lock 里没有活着的 pid），退回一次性执行", C.cwd)
    end
    -- 兜底：主进程不在（关着 TUI）时起一个 --once --readonly 实例。这条不会进主会话，
    -- 所以回执得本进程自己发（见 drain 的 send_fallback）。
    return oneshot(prompt)
end

-- ── 主循环 ───────────────────────────────────────────────────────────
local MAP_PATH = LIBDIR .. "/../lib/app_wechat_map.lua"
local map = assert(loadfile(MAP_PATH))()
local B = map.regions.bubble
-- 聊天区到底：region 底部含输入框工具条（会被 OCR 认成杂行），留 70px 白；
-- 气泡的最后一行永远在这条线之上（实测 817 vs 工具条 896）。
local REGION = { B.x0 + 12, B.y0 + 12, B.x1 - 12, B.y1 - 55 }   -- 底 = 985，正好切在工具条杂行(~999)之上
local TITLE = map.regions.title
TITLE_R = { TITLE.x0, TITLE.y0, TITLE.x1, TITLE.y1 }

-- ── 几何自检 ─────────────────────────────────────────────────────────
-- map 里那些坐标（裁剪框、右键点、滚轮位置）是在「微信最大化、原点 0,0、2560x1408」
-- 下标定的。窗口被 restore、换了显示器或面板高度变了，坐标就整体失准：截图裁到的不是
-- 聊天区，OCR 读到的是别的东西 —— 表现不是报错，而是悄悄「一直 skip」或「认错会话」。
-- 所以每轮先量一次；不符就借 wechat 插件的 ensure_geom 去救（它会 maximize 并复核），
-- 救了还不对就跳过这一轮，别拿错位的像素去 diff（会把噪音当新指令派给主进程）。
local GEOM_TOL = 2
local function geom_ok()
    if not win_refresh() then return false, "找不到微信窗口" end
    local g = xdo:geometry(win.id)
    if not g then return false, "读不到微信窗口几何" end
    local want = map.window or {}
    local bad = {}
    if want.w and math.abs(g.w - want.w) > GEOM_TOL then bad[#bad + 1] = "宽" end
    if want.h and math.abs(g.h - want.h) > GEOM_TOL then bad[#bad + 1] = "高" end
    -- 原点不在 0,0 时所有裁剪/点击都得平移，本模块没做（wechat.lua 自己会算 OFF）→ 也算不符
    if g.x ~= 0 or g.y ~= 0 then bad[#bad + 1] = "位置" end
    if #bad == 0 then return true end
    local st = xdo:wm_state(win.id) or {}
    return false, string.format("窗口几何 %dx%d+%d+%d 与标定 %sx%s+0+0 不符（%s；maximized=%s）",
        g.w, g.h, g.x, g.y, tostring(want.w), tostring(want.h),
        table.concat(bad, "/"), tostring(st.maximized))
end

local function fix_geom()
    local ok, why = geom_ok()
    if ok then return true end
    log("warn: %s → 调 wechat open 触发 ensure_geom", tostring(why))
    local wx = wechat_lib()
    if not wx then return false, "找不到 helper/wechat.lua，几何救不回来" end
    take_focus()
    pcall(wx.run, { action = "open", name = C.chat, background = false })
    sleep(600)
    return geom_ok()
end

local function grab()
    pcall(function() xdo:move_abs(1280, 12) end)   -- 挪开鼠标：悬停浮标会污染 OCR
    sleep(120)
    local boxes = ocr_region(REGION, "bubble")
    -- boxes 的坐标在 ocr_region 里已经换成屏幕坐标了：既不能再加偏移（右键会点偏），
    -- maxy 也必须写屏幕坐标——写成裁剪相对高度的话，最下面那条消息会被当噪音切掉，
    -- 表现就是「手机发了新指令，daemon 一直没反应」。
    return Watch.blocks(boxes, { maxy = REGION[4] - 4 })
end

-- 微信的会话列表不保证停在底部：被别的窗口抢过焦点、或新消息在你看不见时到达，
-- 滚动位置就停在当时那条上，最新几条压根不在可视区里（于是「新消息」永远等不到）。
-- 每轮先滚到底（已经到底时滚轮是空操作），再截图，就不用去猜「到底了没有」。
local function scroll_bottom()
    pcall(function()
        xdo:move_abs(1500, 700)                  -- 指针必须在聊天区里，滚轮才作用在会话上
        for _ = 1, 5 do xdo:mouse_down(5); xdo:mouse_up(5) end
    end)
    sleep(400)
end

local function snapshot()
    local fok, fwhy = focus()
    if not fok then return nil, fwhy or "微信窗口找不到" end
    local blocks = grab()
    local last = blocks[#blocks]
    if (not last) or (last.y + last.h > REGION[4] - 8) then
        scroll_bottom()
        local again = grab()
        if #again >= #blocks then blocks = again end
    else
        -- 画面里看得到旧消息说明可能还没到最新，滚一下确认（到底则画面不变）
        local before = #blocks
        scroll_bottom()
        local again = grab()
        if #again > before or (again[#again] and again[#again].y > (last.y or 0)) then
            blocks = again
        end
    end
    return blocks
end

-- 已派发过的指令指纹：滚动抖动/几何跳变会让 diff 退化，同一条消息可能被认成新的，
-- 没有这张表就会把同一条指令跑第二遍（跑测试、发消息这种副作用不能重来）。
local function dup_of(text)
    local k = Watch.key(text)
    for _, d in ipairs(st.done or {}) do if d == k then return true end end
    return false
end

local function mark_done(text)
    local k = Watch.key(text)
    if k == "" then return end
    st.done = st.done or {}
    st.done[#st.done + 1] = k
    while #st.done > 60 do table.remove(st.done, 1) end
end

local function is_own(text)
    if Watch.is_reply(text, C.tag) then return "回执标记" end
    -- replies 里存的是回执前 200 字的 key，气泡原文可能更长：只能按前缀认，
    -- 整串相等等于永远不命中。
    local k = Watch.key(text)
    for _, r in ipairs(st.replies or {}) do
        if r ~= "" and #r >= 16 and k:sub(1, #r) == r then return "回执哈希" end
    end
    return nil
end

-- ── 回执兜底 ─────────────────────────────────────────────────────────
-- PROMPT 第 2 条要求 agent 自己调 wechat send 回执，但模型完全可以不听：实测一句
-- 「只回一行「收到」，不要开工具」就把它顶掉了，agent 乖乖只回文本、没调工具。
-- 手机那头只看到沉默，分不清「跑完了没」和「压根没收到」。所以派发完本进程自己
-- 验一遍这一帧：可见气泡里没有 lite: 回执，就补发（宁可重复一条，不能沉默）。
local function reply_in_frame()
    local blocks = snapshot()
    if not blocks then return false end
    for _, b in ipairs(blocks) do
        if is_own(b.text) then return true end
    end
    return false
end

local function send_fallback(text)
    local wx = wechat_lib()
    if not wx then return false, "找不到 helper/wechat.lua" end
    local body = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if body == "" then return false, "agent 没吐出任何文字" end
    if #body > 800 then body = body:sub(1, 800) .. "…（截断，全文在本机）" end
    local ok, res = pcall(wx.run, { action = "send", name = C.chat, text = C.tag .. " " .. body }, { cwd = C.cwd })
    if not ok then return false, tostring(res) end
    if type(res) == "string" and res:match("^error") then return false, res end
    return true, res
end

local function tick()
    local blocks, err = snapshot()
    if not blocks then log("skip: %s", err); return 0 end
    local keys = Watch.keys(blocks)
    -- 空帧不能覆盖基线：窗口刚被拉起/正在滚动时 OCR 会读到 0 条，若拿它刷新
    -- prev，下一帧就从头重建基线，这中间发来的消息会被当历史吞掉（实测丢过 #3）。
    -- 会话真的清空是极小概率，宁可留旧基线多看一轮，也不悄悄漏指令。
    if #keys == 0 and #(st.prev or {}) > 0 then
        -- 连续空帧才认「会话真的被清空了」：单帧空是窗口动画/被遮挡/滚动中，拿它
        -- 覆盖基线会让下一条消息变成「整屏重放」。但会话真的清空时（实测清空过），
        -- 老判据会永远 skip —— 基线里那 9 条旧消息再也对不上，指令全部静默丢失。
        st.empty = (st.empty or 0) + 1
        if st.empty <= C.empty_frames then
            log("skip: 这一帧读到 0 条（窗口在动画/被遮挡？），保留上一帧基线（%d/%d）",
                st.empty, C.empty_frames)
            save()
            return 0
        end
        log("会话读到连续 %d 帧 0 条：认为被清空，丢掉旧基线重新开始", st.empty)
        st.prev = {}
        st.empty = 0
    end
    st.empty = 0
    -- 首次启动只建基线，绝不回放历史消息。判据是 st.inited 而不是「prev 为空」：
    -- 会话被清空/换了空会话时 prev 天然是空的，老判据会把清空后的第一条指令当成
    -- 基线吞掉（实测：清空会话后发的 #lite 全静默）。inited 落了盘，重启也不会重放。
    local baseline = not st.inited
    st.inited = true
    -- diff 对「没有基线」返回 m+1（= 别执行，只建基线），会话本来就是空的时候走的
    -- 正是那条 n==0 分支。所以「已初始化 + prev 为空」要单独放行：清空后第一条就是指令。
    local from
    if not baseline and #(st.prev or {}) == 0 then
        from = #keys > 0 and 1 or (#keys + 1)
    else
        from = Watch.diff(st.prev, keys)
    end
    local added = 0
    local fresh = {}
    for i = from, #blocks do fresh[#fresh + 1] = blocks[i] end
    if not baseline and #keys ~= #(st.prev or {}) then
        log("帧：可见 %d 条（上一帧 %d 条），新增 %d", #keys, #(st.prev or {}), #fresh)
    end
    st.prev = keys
    if baseline then
        log("基线：%d 条可见消息（不执行历史）", #blocks)
        save(); return 0
    end
    if #fresh == 0 then save(); return 0 end
    if #fresh > C.max_new then
        log("warn: 一次认出 %d 条新增，只取最后 %d 条", #fresh, C.max_new)
        local cut = {}
        for i = #fresh - C.max_new + 1, #fresh do cut[#cut + 1] = fresh[i] end
        fresh = cut
    end
    for _, b in ipairs(fresh) do
        local text, why = b.text, "OCR"
        local exact, cerr = copy_at(b.cx, b.cy)
        if exact then text, why = exact, "复制" else log("warn: 复制失败(%s)，退回 OCR 文本", tostring(cerr)) end
        local own = is_own(text)
        if own then
            log("忽略新块（%s）：%s", own, Watch.norm(text):sub(1, 60))
        elseif not Watch.has_trigger(text, C.prefix) then
            log("忽略新块（无触发前缀 %q）：%s", C.prefix, Watch.norm(text):sub(1, 60))
        elseif Watch.trigger_form(text, C.prefix) == "loose" then
            -- 宽容命中的那条路：OCR 把 "#" 吞了。照跑，但日志留痕，方便区分误触。
            log("warn: 触发前缀 %q 的 # 被 OCR 吞了，按指令处理", C.prefix)
        elseif dup_of(text) then
            log("跳过重复（滚动/重排导致的旧消息回流）：%s", Watch.norm(text):sub(1, 60))
        else
            st.seq = (st.seq or 0) + 1
            local body = Watch.strip_trigger(text, C.prefix)
            st.pending[#st.pending + 1] = { id = st.seq, text = body, raw = text, via = why }
            mark_done(text)
            log("收到指令 #%d（%s）：%s", st.seq, why, Watch.norm(body):sub(1, 120))
            added = added + 1
        end
    end
    save()
    return added
end

local function drain()
    while #st.pending > 0 do
        local item = st.pending[1]
        if C.dry then
            log("[dry-run] 不派发 #%d：%s", item.id, Watch.norm(item.text):sub(1, 120))
            table.remove(st.pending, 1); save()
        else
            log("派发 #%d …", item.id)
            local t0 = os.time()
            local reply, err = dispatch(item.text)
            if reply == MASTER_DONE then
                -- 主进程自己回微信（提示词里要求 lite: 前缀），别补发、别抢窗口
                log("完成 #%d（%ds，已交给主进程，回执由它自己发）", item.id, os.time() - t0)
                table.remove(st.pending, 1); save()
                goto continue
            elseif reply then
                log("完成 #%d（%ds，%d 字）", item.id, os.time() - t0, #tostring(reply))
                st.replies[#st.replies + 1] = Watch.key(tostring(reply):sub(1, 200))
                while #st.replies > 12 do table.remove(st.replies, 1) end
                -- 回执兜底：agent 没自己发就本进程补一条，别让手机那头等到沉默
                local seen = reply_in_frame()
                if not seen then
                    sleep(1500)
                    seen = reply_in_frame()
                end
                if seen then
                    log("回执已在微信里（agent 自己发的）")
                else
                    log("warn: 这一帧没看到 %s 回执，改由守护进程补发", C.tag)
                    local sok, sres = send_fallback(reply)
                    if sok then log("补发回执成功") else log("error: 补发回执失败：%s", tostring(sres)) end
                end
            else
                log("error: #%d 失败：%s", item.id, tostring(err))
                if (item.tries or 0) >= 1 then
                    log("放弃 #%d（已重试一次）", item.id)
                else
                    item.tries = (item.tries or 0) + 1
                    save(); sleep(5000)
                    goto continue
                end
            end
            table.remove(st.pending, 1); save()
        end
        ::continue::
    end
end

do
    local pid = tostring(ffi.C.getpid())
    if not C.once then                       -- 一次性模式不留 pidfile，免得插件以为还活着
        local f = io.open(PIDFILE, "wb"); if f then f:write(pid); f:close() end
    end
    log("启动 pid=%s interval=%ds prefix=%q chat=%s dry=%s wait=%ds 派发=call_master",
        pid, C.interval, C.prefix, C.chat, tostring(C.dry), C.wait)
end

if C.dump then
    -- 排错口：只列出当前这一帧认出来的块（坐标已换回屏幕），不动 state
    local blocks = snapshot() or {}
    for i, b in ipairs(blocks) do
        log("%d y=%.0f x=%.0f w=%.0f h=%.0f key=%s | %s", i, b.y, b.x, b.w, b.h,
            tostring(b.key):sub(1, 40), tostring(b.text):gsub("\n", " ⏎ "))
    end
    local last = blocks[#blocks]
    log("共 %d 块；标题 OCR=%q；末块底=%s（裁剪底=%d）", #blocks, title_text(),
        last and string.format("%.0f", last.y + last.h) or "nil", REGION[4])
    os.exit(0)
end

-- 空闲就收起微信：hide 用的是 minimize（任务栏还在，点一下回来），不是 unmap 到
-- 无影无踪；下一轮 focus() 的 activate 会把它拉回来（raise 对最小化的窗口无效）。
-- touched=false 时**不动窗口**：微信本来就是摊着的（用户在用），我们只是看了几眼，
-- 收尾再 minimize 就成了「守护进程每 10 秒把用户的窗口收走一次」。
local function hide_idle(force)
    if C.hide and win and (touched or force) then
        pcall(function() xdo:minimize(win.id) end)
    end
    -- 还焦点这件事**不受 --no-hide 影响**：抢焦点发生在 take_focus()（切会话要往搜索框
    -- 打字）。只要抢过就必须还，否则 --no-hide 时微信一直摊着、焦点也一直留在微信上，
    -- 用户下一次按键就掉进微信输入框（比"窗口摊着"更难受的坑）。
    -- 最小化不一定会把焦点交出去（有的 WM 把焦点留在隐藏窗口上），所以显式 activate
    -- 之前那个窗口；activate 带 raise，用户的窗口重新盖回来。
    restore_focus()
    prev_active = nil
    touched = false
    pcall(function() xdo:sync() end)
end

local rounds = 0
while true do
    rounds = rounds + 1
    local added = 0
    touched = false                       -- 上一轮没收尾（ok=false）也要清零，别把旧状态带进来
    local ok, err = pcall(function()
        -- 几何先量一遍：坐标失准时截图裁到的不是聊天区，继续跑只会「一直 skip」或把
        -- 别处的字当指令 diff 出来。救不回来就跳过本轮，等下一轮（用户可能正在拖窗口）。
        local gok, gwhy = fix_geom()
        if not gok then log("skip: %s", tostring(gwhy)); return end
        local ready, why = ensure_chat_via(TITLE_R)
        if not ready then log("skip: %s", tostring(why)); return end
        added = tick() or 0
        drain()
    end)
    if not ok then log("error: %s", tostring(err)) end
    -- 每一轮检查完都收起 —— 只收「本轮自己弄出来」的那份（hide_idle 里看 touched）。
    -- ok=false（认不出窗口/几何不对）不动它，免得搅用户自己的操作。
    if ok then hide_idle() end
    if C.once then break end
    sleep(C.interval * 1000)
end
log("退出 rounds=%d", rounds)
