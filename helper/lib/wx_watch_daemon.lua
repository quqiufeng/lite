-- wx_watch_daemon.lua — 常驻轮询微信「文件传输助手」，把手机发来的新消息当指令丢给 lite。
--
-- 为什么是截图 + OCR：微信 Linux 版的消息落在加密 xwechat_files/*.db 里，没有稳定读口；
-- 屏幕上就有的东西用眼睛取最省事。原文靠「右键气泡 → 复制」拿剪贴板，**不用 OCR 文本**：
-- PP-OCRv4 吃中文稳、吃空格不稳（"lite 列一下 /tmp" 会变成 "lite列一下/tmp"），
-- 指令里的路径和命令必须逐字精确，所以 OCR 只负责"发现新消息 + 定位气泡"。
--
-- 一轮节奏（互斥，不并发）：
--   1 确保微信在前台、会话是「文件传输助手」（不认标题：直接搜索框粘名字 + 回车，见 open_chat）
--   2 鼠标挪到标题栏（不然悬停浮标「翻译」会混进 OCR）→ 截聊天区 → OCR → 合并成块
--   3 和上一帧做尾部后缀比对，只把新增块当候选
--   4 候选逐个：右键 → 菜单里点「复制」→ 剪贴板 = 精确原文（失败退回 OCR 文本）
--   5 过滤（媒体消息[图片/文件/视频，不处理] / 回执 lite: / 无触发前缀[默认全收，见 C.prefix]）
--     → 只留**最新一条** → 派发给主进程
--
-- 只响应最新一条：这是用户自己的一天用法 —— 没回就当没收到，他会再发一条。所以积压的旧
-- 指令一律丢掉（见 tick 的截尾和 drain 的折叠），不做"补跑队列"：手机那头早就不等了，
-- 补跑只会拿过时的话去改现场，还占着窗口让新一轮指令排队。
--
-- **只做转发**：认出指令 → 交给主进程，本进程不执行、不补发回执、不起任何 agent 实例。
-- 派发走 call_master（helper/call_master.lua）：把提示词粘贴进主 lite 的终端输入框并回车，
-- 由握着 mem.lock 的那个进程自己执行 —— 记忆可写、能回微信。不走 serve HTTP，也不走
-- --once：那两条路都是在后台再起一个 --readonly 实例（不落记忆，和桌面会话是两个人）。
--
-- 派完只让路 settle_min 秒（见 dispatch），之后照常轮询 → 不会和 paste 抢窗口，也不会
-- 因为主进程忙就把整条轮询停掉；回执由主进程自己发（提示词里要求了 lite: 前缀）。
-- 主进程不在（mem.lock 里的 pid 已死 / TUI 关着）时指令**留在 pending 原地等**，不执行。
--
-- 空闲收起：每轮没认出新消息就把微信 minimize（--no-hide 关掉）。注意这必然带来闪烁
-- —— 截图取的是屏幕像素，窗口最小化就读不到气泡，所以每轮得先 activate 再收起来，
-- 窗口可见时长 ≈ 一次截屏 + OCR（1~2s）。
--
-- 用法：tools/lite-lua helper/lib/wx_watch_daemon.lua --interval 10 [--gate-ms 300]
--        [--prefix ""] [--dry-run] [--once] [--no-raise] [--no-hide]
--   --interval 只决定「真的进了微信之后歇多久」；没进门的那一轮按 --gate-ms（默认 300）
--   快轮询托盘像素 —— 闪烁只亮一两秒，用一个 10s 的睡眠去等它必然整段错过。
--   不给 --prefix = 全收：文件传输助手里的新消息一律当指令（微信模式的默认行为）。
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
-- 常驻进程，全程起子进程（xterm/xclip/pgrep）；X socket 不标 CLOEXEC 会被子进程继承，
-- 两个进程抢同一条事件流 → 注入的按键静默失效。见 xdo.lua:protect_fd
xdo:protect_fd()

local SELF = arg and arg[0] or ""
local LIBDIR = SELF:match("^(.*)/[^/]+$") or "."
local Watch = assert(loadfile(LIBDIR .. "/wx_watch.lua"))()

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function sleep(ms) ffi.C.usleep(ms * 1000); pcall(function() xdo:sync() end) end

-- ── 配置 ─────────────────────────────────────────────────────────────
local C = {
    interval = 10, port = 8765, host = "127.0.0.1",
    -- 触发前缀；默认全收（微信模式的语义 = 手机发什么就跑什么）。要收窄就 "--prefix #lite"，
    -- 语义钉在 wx_watch.lua 的 M.PREFIX/has_trigger（单测也在那边）。
    prefix = "", chat = "文件传输助手", tag = "lite:",
    once = false, dry = false, raise = true, hide = true,
    -- 唯一的一条去重：兜底强检进来、最新一条跟上次派过的**一模一样**时多久之内不重跑。
    -- 只防「别的会话在闪 → 我们进去却只看到老指令」这一种误重放；用户重发同一句话过了
    -- 这个窗口就照跑。别做成永久（踩过：派过一次后重发同一条永远静默丢弃）。
    same_after = 60,
    -- 派完只让路 settle_min 秒（防「刚 paste 就被下一轮抢走窗口」），之后照常轮询；
    -- 不再有「等主进程 CPU 闲下来」的超时上限 —— 那个上限本身就意味着最长 30 分钟不看微信。
    settle_min = 15,
    -- 兜底强检间隔（秒）：门有 ~27% 死区（见 wx_watch.lua 的 GATE），偶尔漏一次靠它补。
    -- 它不打扰用户的前提是 surface() 判「窗口本来就被盖住才 raise」；0 = 关掉纯测门。
    force_every = Watch.FORCE_EVERY,
    -- **空闲快门**：没进门（图标没闪）的那一轮只花 ~0.8s 像素采样，睡 0.3s 再来 —— 覆盖
    -- 73% 时间轴，消息到了 1~2s 内就进来。以前的 10s 一轮让闪烁整段漏掉，只能靠 force 强检。
    gate_ms = Watch.GATE.poll_ms,
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
        elseif a == "--gate-ms" then C.gate_ms = tonumber(v); i = i + 2
        elseif a == "--port" then C.port = tonumber(v); i = i + 2   -- 空转，留着不炸旧调用
        elseif a == "--host" then C.host = v; i = i + 2            -- 同上
        elseif a == "--wait" then i = i + 2                       -- 空转：不再等主进程干完活
        elseif a == "--settle" then C.settle_min = tonumber(v); i = i + 2
        elseif a == "--force-every" then C.force_every = tonumber(v); i = i + 2
        elseif a == "--prefix" then C.prefix = v; i = i + 2
        elseif a == "--chat" then C.chat = v; i = i + 2
        elseif a == "--tag" then C.tag = v; i = i + 2
        elseif a == "--same-after" then C.same_after = tonumber(v); i = i + 2
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
-- last/last_t：最近一次派发出去的指令指纹与时刻（见 tick）。没有别的账本了。
local st = { pending = {}, replies = {}, seq = 0, last = "", last_t = 0 }
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

-- 窗口刚 map 出来那几百毫秒里截图是残帧（半画、全黑），拿去 OCR 会得到 0 条气泡 →
-- 白跑一轮。判「重绘完了」看像素：连拍两帧一模一样就算稳定。**不认字**，也就不会因为
-- 标题是灰色小字/截到遮挡窗口而永远等不到。
local function wait_repaint(tries)
    local prev
    for _ = 1, tries or 12 do
        local p = TMP .. "-settle.png"
        W.capture_screen(p)
        local f = io.open(p, "rb")
        local cur = f and f:read("*a")
        if f then f:close() end
        if cur and prev and cur == prev then return true end
        prev = cur
        sleep(250)
    end
    return false
end

-- 前向声明：title_text 只用于日志取证，定义在后面。
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
        -- 从最小化恢复后窗口要过一会儿才重绘：立刻截气泡区会读到 0 条（→ 空转一轮）。
        wait_repaint(12)
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

-- 进「文件传输助手」= 搜索框粘名字 + 回车（helper/wechat.lua:fast_enter 快路径）。这条路
-- **零 OCR**：验的是「候选面板收起 / 标题区像素变了」，落点由微信的搜索默认项保证，是确定的。
-- 所以这里不再截标题去认「现在是哪个会话」—— 那是在验一件已经确定的事，验错的代价却是整轮
-- skip：标题是灰色小字、窗口刚重绘、或截到遮挡窗口都会读出空串，实测 daemon 因此连续 471 次
-- 「标题 OCR=""」空转，一条指令都没派出去。切没切成，让下面真读气泡的结果说话：读到 0 条
-- 就清 chat_ready，下一轮重切（见 note_blocks）。
local chat_ready = false

local function open_chat()
    local wx = wechat_lib()
    if not wx then return false, "找不到 helper/wechat.lua，无法切会话" end
    take_focus()        -- open 要往搜索框打字，这一步必须真焦点（收尾 hide_idle 还回去）
    local ok, err = pcall(wx.run, { action = "open", name = C.chat, background = false })
    if not ok then return false, "切「" .. C.chat .. "」失败：" .. tostring(err) end
    chat_ready = true
    return true
end

-- daemon 自己从不换会话（只读气泡区），hide_idle 收尾只最小化、不动会话，所以切一次就够。
local function ensure_chat()
    local fok, fwhy = focus()
    if not fok then return false, fwhy or "微信窗口找不到" end
    if chat_ready then return true end
    return open_chat()
end

-- 读到 0 条 = 可能被用户切去别的会话了，也可能只是残帧。连续两轮才算会话真的不对：单轮
-- 残帧就重切一次，只会白抢用户焦点，太吵。
local zero_rounds = 0
local function note_blocks(n)
    if n > 0 then zero_rounds = 0; return end
    zero_rounds = zero_rounds + 1
    if zero_rounds >= 2 and chat_ready then
        chat_ready = false
        log("连续 %d 轮读到 0 条，下一轮重新切会话", zero_rounds)
    end
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
-- 剪贴板里是**什么**："text" / "media"（图片、文件）/ nil（认不出）。
-- 媒体判定只能靠它：文本消息「复制」一定出文本，图片/表情/文件气泡出的是
-- image/png、text/uri-list 这类二进制或 uri，压根没有文本目标。
local function clip_kind()
    local h = io.popen("xclip -selection clipboard -o -t TARGETS 2>/dev/null")
    if not h then return nil end
    local s = h:read("*a") or ""
    h:close()
    if s == "" then return nil end
    for _, t in ipairs(TEXT_TARGETS) do
        if s:find(t, 1, true) then return "text" end
    end
    if s:find("\nSTRING", 1, true) or s:sub(1, 6) == "STRING" then return "text" end
    if s:find("image/", 1, true) then return "media" end
    if s:find("uri%-list") or s:find("x%-moz%-file") then return "media" end
    return nil
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
    -- 判「复制出来的是什么」必须在**还原用户剪贴板之前**：还原完就只剩 keep 了。
    local kind = (got and got ~= "") and "text" or clip_kind()
    if keep then clip_write(keep) end   -- 别偷走用户的剪贴板
    if kind == "text" then return got end
    if kind == "media" then
        -- 图片/表情/文件气泡：复制出来是图或 uri，没有文本。用户定的：这类不处理。
        return nil, "复制出来不是文本（图片/文件）", "media"
    end
    return nil, "复制后剪贴板里没有文本"
end

-- ── 派发 ─────────────────────────────────────────────────────────────
-- 派发提示词：**必须单行**。走 call_master 粘贴时多行会被终端切成多次回车 →
-- 一条指令拆成好几轮（bracketed paste 没生效时尤其明显），碎片全进主进程。
-- 只加一句「做完用 wechat 回复」，别再加长：约定越长，拆出来的废轮次越多。
local PROMPT = "微信远程指令（%s）：做完请用 wechat 插件（action=send, name=文件传输助手）回复我，" ..
    "首行以 lite: 开头（回环标记，缺了会被当新指令再跑）；**回复控制在 2 行内、中间不要空行**" ..
    "（长回复会被 OCR 切成两块，下半截丢前缀就变成新指令）；不可逆/花钱/外发敏感内容先问再动。"

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

-- 派完只**短暂让路**，不在这里等主进程干完活。
-- 早先这里是 while + sleep(1000) 轮询「主进程 CPU 连续 3 次不涨」，实测在用户正跟 lite
-- 干活时（CPU 一直在涨）能卡满 C.wait=1800s，这段时间**完全不看微信**：手机发的下一条
-- 指令根本不触发，日志还一片空白（看着像守护进程死了）。远程指令的价值就是「我不在键盘
-- 前」，让路几秒够避开 paste 回显，不值得为此停掉整条轮询主线。
local settle_until = 0

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

-- 派给主进程后本进程拿不到「那一轮的回答」——回答由它自己发到微信，这里只记一个哨兵。
local MASTER_DONE = {}

-- 唯一的执行出口：call_master → 主进程终端。返回 MASTER_DONE 或 nil, 原因。
-- 没有兜底执行：起了主进程之外的 agent 就绕开 mem.lock 的单写者约定，那一路既写不进
-- 记忆也发不出回执（表现是「看起来跑了，什么都没留下」），所以宁可留着等下轮。
local function dispatch(text, raw)
    -- 手机发来的多行也被拍平：粘贴里每多一个 \n，就多一次回车 → 多一轮废指令。
    local body = text:gsub("%s*\n%s*", " ")
    -- raw = 模式开关命令（#退出…）：原样贴，让主进程的 submit() 当命令吃掉，不包外壳
    -- （包了就只是把"退出"这句话交给模型，微信模式关不掉）。
    local prompt = raw and body or string.format(PROMPT, body)
    local cm, pid = master_mod(), master_pid()
    if not cm then return nil, "加载不了 call_master（helper/call_master.lua）" end
    if not pid then return nil, "没有主进程（" .. C.cwd .. "/mem.lock 里没有活着的 pid）" end
    local ok, res = pcall(cm.run, { text = prompt }, { cwd = C.cwd })
    res = tostring(res)
    if ok and res:sub(1, 3) == "ok:" then
        log("%s", res:sub(1, 200))
        -- 只让路 settle_min 秒让 paste 落地，之后照常轮询（不再等它干完活）
        settle_until = os.time() + C.settle_min
        return MASTER_DONE
    end
    return nil, "call_master 没派成：" .. res:sub(1, 200)
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

-- ── 「图标不闪就不点开」的门 ────────────────────────────────────────
-- 判据就是用户说的那句话：**托盘里的微信图标不闪 = 没有新消息**。微信 Linux 版收到新消息
-- 时图标在两组画面之间来回换（周期约 0.9s），看过消息就静止。所以盯住托盘那一小块
-- 像素就够：不用抢焦点、不用截全屏、不用 OCR。
--
-- **不要按「红点」判**：用 SNI IconPixmap 直读（helper/lib/wx_sni.lua）验过，未读时换的是
-- {64x64,22x22} 与 {16x16,16x16} 两组帧，64x64 那张**不带红点**，闪动停止后也是它。
-- 所以 wx_tray 只比「有没有出现第二种画面」，不比某个像素图案；哪天微信改了配色也不至于失效。
--
-- 早先试过读 ICCCM urgency（`xdo:urgent`）当门，不可靠：微信把图标交给 StatusNotifier
-- 画在 nm-tray 窗口里，客户端不一定还置 urgency，于是「有新消息也判没消息」，整轮被静默跳过。
-- 像素判据不看客户端配合，只要画出来了就认得出。
--
-- 采样窗口 15 帧 × 160ms ≈ 2.4s，见到第二种画面立刻返回（有消息时快）。
-- 托盘图标定位/缓存/失效重定位都在 helper/lib/wx_tray.lua，本轮只持有一份 cache。
local gate_quiet = false          -- 上一轮已判「没闪」，用来把日志压成状态边沿
local tray_cache = {}
local tray, tray_err, tray_env

-- 一次性备好 X 句柄：和主 xdo 共用同一个 Display，别另开连接（多一份往返 + 退出漏关）。
local function tray_ready()
    if tray_env then return tray_env end
    local ok, X11 = pcall(ffi.load, "X11")
    if not ok then return nil, "load libX11 失败" end
    local sw, sh = screen_wh()
    tray_env = { X11 = X11, dpy = xdo.dpy, root = X11.XDefaultRootWindow(xdo.dpy),
                 sw = sw, sh = sh }
    return tray_env
end

local function news_pending()
    if not win_refresh() then return false, "认不出微信窗口" end
    -- 门就是门，没有「窗口可见就放行」的旁路：那条旁路一旦打开，微信被留在桌面上
    -- （最小化失败、或被用户自己摊开）就会每轮都冲进去抢焦点。宁可漏一轮，也别打扰。
    if tray_err then return false, tray_err end       -- 上次就起不来，别每轮重试
    if not tray then
        local ok, mod = pcall(require, "helper.lib.wx_tray")
        if not ok then tray_err = "载不到 wx_tray: " .. tostring(mod); return false, tray_err end
        tray = mod
    end
    local env, eerr = tray_ready()
    if not env then return false, eerr end
    -- 门用**短窗**（Watch.GATE）：一轮只花 0.8s，才养得起「每 0.3s 看一次」的快轮询。
    -- 15 帧 2.4s 的长窗只在 relocate 判「哪个绿块是真图标」时还值得用，那条路很少走。
    local blink, why, rect = tray.check(env.X11, env.dpy, env.root, env.sw, env.sh, tray_cache,
        { tries = Watch.GATE.tries, gap_ms = Watch.GATE.gap_ms })
    if blink then return true, why end
    if not rect and why then tray_err = why end
    return false, why
end

-- 鼠标落点一律用**窗口相对坐标**（libxdo 的 xdo_move_mouse_relative_to_window），
-- 不要写屏幕绝对像素：绝对坐标绑死 2560x1408 这套几何，换显示器/改分辨率后可能落在
-- 窗口外，浮标挪不走、滚轮也滚不到会话上，而症状只是「OCR 多几行杂字」或「一直没新消息」。
local function grab()
    -- 挪到窗口左上角（标题/侧栏空白处）：悬停浮标会污染 OCR
    pcall(function() if win then xdo:move(win.id, 8, 8) end end)
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
        if not win then return end
        -- 指针必须在聊天区里，滚轮才作用在会话上；位置取气泡区中心再减窗口原点
        -- （geom_ok 要求原点 0,0，但仍然按几何算，别假设）。
        local g = xdo:geometry(win.id)
        if not g then return end
        local cx = math.floor((B.x0 + B.x1) / 2) - (g.x or 0)
        local cy = math.floor((B.y0 + B.y1) / 2) - (g.y or 0)
        if not xdo:move(win.id, cx, cy) then return end
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

-- 回执的指纹只有一种：lite: 前缀（主进程自己发的，见 PROMPT 里那句回环标记）。
-- 以前还有一路「本进程补发过的回执哈希」，补发删掉后它就是恒空的死状态。
local function is_own(text)
    if Watch.is_reply(text, C.tag) then return "回执标记" end
    return nil
end

-- 回执只由主进程发（PROMPT 里那句 wechat 回复）：本进程只转发，验帧/补发整段删掉了。
-- 补发看着贴心，实则两个进程抢同一个输入框 + 用户会收到「GG 没做却有条回执」的假消息；
-- 沉默的代价更小，而且更像真的——主进程不吭声就是它没跑完。

-- 模型一句话（用户定的）：**图标闪 = 有新消息 → 进去把最新那条 #lite 抄下来派发**。
-- 没有基线、没有两帧比对、没有去重表：
--   * 闪动本身就说明「刚来了新的」，所以同一条文字重发也照跑；
--   * 点开会话 = 已读，闪动自己停，不会连着点第二回。
-- 唯一剩下的状态是 st.last/st.last_t，挡的是另一种情况：别的会话在闪、我们进去却只看到
-- 老指令 —— 文字跟 C.same_after 秒内刚派过的一模一样就不再跑第二遍（副作用不能重来）。
local function tick()
    local blocks, err = snapshot()
    if not blocks then log("skip: %s", err); return 0 end
    if #blocks == 0 then
        note_blocks(0)
        log("skip: 这一帧读到 0 条（窗口动画/被遮挡？）"); return 0
    end
    note_blocks(#blocks)
    local b = blocks[#blocks]                       -- 永远只认最新那一条
    -- 长回复会被 OCR 切成两块，第二块丢 lite: 前缀就成了「新指令」回声（踩过：一遍天气被重跑）。
    -- 放在复制/OCR 之前判：几何三条就够，别为一块回声再右键点一次菜单。
    if Watch.is_reply_tail(blocks[#blocks - 1], b, { tag = C.tag }) then
        log("忽略最新条（回执续块，无前缀也认）：%s", Watch.norm(b.text):sub(1, 60))
        return 0
    end
    -- 媒体消息（图片/文件/视频）不处理：用户定的。判据两层，都便宜的先跑：
    --   ① 这块 OCR 文本自己就长成文件气泡/占位符（wx_watch.lua:is_media）；
    --   ② 右键「复制」出来不是文本（截图里有字的图片只能靠这条兜住）。
    -- 同一条媒体消息只判一次：否则每轮 tick 都要右键单击 + 菜单 OCR 一遍（白烧 ~1.2s）。
    local fp = "#" .. #blocks .. "@" .. tostring(math.floor((b.cy or 0) / 8))
    local media_age = os.time() - (tonumber(st.media_t) or 0)
    if st.media == fp and media_age < 3600 then return 0 end
    if Watch.is_media(b.text) then
        st.media, st.media_t = fp, os.time()
        log("忽略最新条（媒体消息，图片/文件不处理）：%s", Watch.norm(b.text):sub(1, 60))
        save()
        return 0
    end
    local text, why = b.text, "OCR"
    local exact, cerr, kind = copy_at(b.cx, b.cy)
    if exact then text, why = exact, "复制"
    elseif kind == "media" then
        st.media, st.media_t = fp, os.time()
        log("忽略最新条（图片/文件：复制出来不是文本），不处理")
        save()
        return 0
    else log("warn: 复制失败(%s)，退回 OCR 文本", tostring(cerr)) end
    local key, own = Watch.key(text), is_own(text)
    local age = os.time() - (tonumber(st.last_t) or 0)
    local body = Watch.strip_trigger(text, C.prefix)
    if own then
        log("忽略最新条（%s）：%s", own, Watch.norm(text):sub(1, 60))
    elseif Watch.mode_cmd_norm(body) then
        -- 全收模式下这条也会进来。模式开关只能由主进程的 submit() 处理（tui/modecmd.lua），
        -- 所以原样透传、不套 PROMPT 外壳；去重也跳过（用户连点两下退出不该被 60s 窗口吃掉）。
        -- 透传的是**规范写法**：手机发「微信模式」（没有 #）也补成 #微信模式，否则 submit() 不认。
        local mcmd = Watch.mode_cmd_norm(body)
        st.seq = (st.seq or 0) + 1
        st.pending = { { id = st.seq, text = mcmd, raw = text, via = why, modecmd = true } }
        st.last, st.last_t = "", 0
        log("收到模式命令 #%d（%s）：%s → %s", st.seq, why, body, mcmd)
        save()
        return 1
    elseif not Watch.has_trigger(text, C.prefix) then
        log("忽略最新条（无触发前缀 %q）：%s", C.prefix, Watch.norm(text):sub(1, 60))
    elseif key ~= "" and key == st.last and age < C.same_after then
        log("最新条与 %ds 前派发的相同，跳过（想重跑：改几个字，或等 %ds）", age, C.same_after)
    else
        if Watch.trigger_form(text, C.prefix) == "loose" then
            log("warn: 触发前缀 %q 的 # 被 OCR 吞了，按指令处理", C.prefix)
        end
        st.seq = (st.seq or 0) + 1
        -- 只留最新一条：上一轮没派出去的（主进程忙、没起来）直接让位——用户没等到回复
        -- 会再发一句，过时的指令派出去只会拿旧话改现场。
        st.pending = { { id = st.seq, text = body, raw = text, via = why } }
        st.last, st.last_t = key, os.time()
        log("收到指令 #%d（%s）：%s", st.seq, why, Watch.norm(body):sub(1, 120))
        save()
        return 1
    end
    save()
    return 0
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
            local reply, err = dispatch(item.text, item.modecmd)
            if reply == MASTER_DONE then
                -- 主进程自己回微信（提示词里要求 lite: 前缀），本进程不补发、不抢窗口
                log("完成 #%d（%ds，已交给主进程）", item.id, os.time() - t0)
                table.remove(st.pending, 1); save()
                goto continue
            end
            log("error: #%d 失败：%s", item.id, tostring(err))
            if err and err:find("没有主进程", 1, true) then
                -- 主进程不在（TUI 关着）：指令留着原地等，别自己起实例执行
                log("指令留着，下一轮再派（待办 %d 条）", #st.pending)
                return
            end
            if (item.tries or 0) >= 1 then
                log("放弃 #%d（已重试一次）", item.id)
            else
                item.tries = (item.tries or 0) + 1
                save(); sleep(5000)
                goto continue
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
    log("启动 pid=%s interval=%ds gate=%dms window=%dms force=%ds prefix=%q chat=%s dry=%s settle=%ds",
        pid, C.interval, C.gate_ms, Watch.gate_window_ms(), C.force_every, C.prefix, C.chat,
        tostring(C.dry), C.settle_min)
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
-- 没有 force 开关是有意的：需要「不管 touched 都收」的场合只有调试，而调试时直接在
-- 调完 hide_idle 后手写 xdo:minimize 就行，留一个恒不传的参数只会让人以为有旁路。
local function hide_idle()
    if C.hide and win and touched then
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
local last_real = os.time()          -- 上次真正进去检查的时刻（兜底强检用它计时）
while true do
    rounds = rounds + 1
    local added = 0
    -- 本轮是不是「只过门、没进门」的浅轮：浅轮不碰窗口，睡 shutter(0.3s) 就再来；
    -- 深轮（真的进了微信）才睡 C.interval。两个间隔分开是这次改动的**全部要点** ——
    -- 一个数同时管「多久看一次托盘」和「进去之后歇多久」时，只能折中成 10s，
    -- 而托盘闪烁只亮一两秒：那次 10s 的睡眠就是消息漏掉的地方。
    local shallow = false
    touched = false                       -- 上一轮没收尾（ok=false）也要清零，别把旧状态带进来
    local ok, err = pcall(function()
        -- 先过廉价门：图标没闪就整轮不做 —— 不抢焦点、不截图、不 OCR。这一步放在
        -- fix_geom 之前，因为救几何本身就要抢焦点开微信，那正是用户抱怨的打扰。
        -- 刚派完的让路窗口：这轮不进去（保住 paste 落地），但轮询照常跑 —— 早先这段在
        -- dispatch 里阻塞等主进程闲，主进程一忙就整条轮询停摆（消息到了不触发、日志空）。
        local wait_s = settle_until - os.time()
        if wait_s > 0 then
            shallow = true
            if not gate_quiet then log("让路中：%ds 后恢复检查", wait_s); gate_quiet = true end
            return
        end
        local pend, gwhy0 = news_pending()
        -- 门有死区（采样窗只覆盖时间轴的 ~73%），隔 force_every 秒兜底进去看一眼。
        -- 注意这不再是主要通路：门自己够快，正常消息不会等到这里。0 = 关（专测门时用）。
        if not pend and C.force_every > 0 and os.time() - last_real >= C.force_every then
            pend, gwhy0 = true, string.format("兜底强检（%ds 没进去过）", os.time() - last_real)
        end
        if not pend then
            shallow = true
            -- 日志要写**真实原因**：以前这里固定成「图标没闪」，把 tray_err（定位失败）
            -- 也一起吞成这句，于是「一直在 skip」和「门本身就坏了」分不开。
            if not gate_quiet then log("skip: %s（没点开检查）", tostring(gwhy0)); gate_quiet = true end
            return
        end
        if gate_quiet then log("恢复检查：%s", tostring(gwhy0)); gate_quiet = false end
        -- 几何先量一遍：坐标失准时截图裁到的不是聊天区，继续跑只会「一直 skip」或把
        -- 别处的字当指令 diff 出来。救不回来就跳过本轮，等下一轮（用户可能正在拖窗口）。
        local gok, gwhy = fix_geom()
        if not gok then log("skip: %s", tostring(gwhy)); return end
        local ready, why = ensure_chat()
        if not ready then log("skip: %s", tostring(why)); return end
        last_real = os.time()
        added = tick() or 0
        drain()
    end)
    if not ok then log("error: %s", tostring(err)) end
    -- 每一轮检查完都收起 —— 只收「本轮自己弄出来」的那份（hide_idle 里看 touched）。
    -- ok=false（认不出窗口/几何不对）不动它，免得搅用户自己的操作。
    if ok then hide_idle() end
    if C.once then break end
    -- 浅轮睡快门（0.3s），深轮睡整间隔：见循环开头 shallow 的注释。
    sleep(shallow and C.gate_ms or C.interval * 1000)
end
log("退出 rounds=%d", rounds)
