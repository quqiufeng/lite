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
--   5 过滤（回执 lite: / 已知回复哈希 / 无触发前缀）→ 入 pending → 派发给 serve
--
-- 派发是同步的：POST /prompt 一直阻塞到那一轮 agent 跑完，所以 agent 在会话里发回执时，
-- 本进程正好停在等回复上，不会和它抢微信窗口。跑完继续采，回执会被识别成回执。
--
-- 用法：tools/lite-lua helper/lib/wx_watch_daemon.lua --interval 6 [--port 8765]
--        [--prefix lite] [--dry-run] [--once] [--no-spawn] [--no-raise]
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
    interval = 6, port = 8765, host = "127.0.0.1",
    prefix = "lite", chat = "文件传输助手", tag = "lite:",
    once = false, dry = false, spawn = true, raise = true, max_new = 3,
    http_timeout = 1500, cwd = os.getenv("LITE_CWD") or os.getenv("PWD") or ".",
    state = os.getenv("LITE_WX_STATE") or
        ((os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") or "/tmp") .. "/.local/share")
            .. "/lite/wx-watch"),
}
do
    local i = 1
    while arg and arg[i] do
        local a, v = arg[i], arg[i + 1]
        if a == "--interval" then C.interval = tonumber(v); i = i + 2
        elseif a == "--port" then C.port = tonumber(v); i = i + 2
        elseif a == "--host" then C.host = v; i = i + 2
        elseif a == "--prefix" then C.prefix = v; i = i + 2
        elseif a == "--chat" then C.chat = v; i = i + 2
        elseif a == "--tag" then C.tag = v; i = i + 2
        elseif a == "--max-new" then C.max_new = tonumber(v); i = i + 2
        elseif a == "--cwd" then C.cwd = v; i = i + 2
        elseif a == "--state" then C.state = v; i = i + 2
        elseif a == "--once" then C.once = true; i = i + 1
        elseif a == "--dry-run" then C.dry = true; i = i + 1
        elseif a == "--no-spawn" then C.spawn = false; i = i + 1
        elseif a == "--no-raise" then C.raise = false; i = i + 1
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
local function focus()
    if not win_refresh() then return nil end
    if C.raise then
        -- xdo 的方法吃的是裸 Window id，传 W.resolve 的表会 "cannot convert 'table'"，
        -- 被 pcall 吞掉后表现成「微信永远抬不起来、标题一直是别人窗口的」。
        pcall(function() xdo:raise(win.id) end)
        if xdo:active() ~= win.id then
            pcall(function() xdo:activate(win.id) end)
        end
        sleep(250)
    end
    return win
end

local TITLE_R          -- 前向声明：title_text 在它赋值之前定义，直接写 TITLE_R 会是 nil 的全局
local function title_text()
    local boxes = ocr_region(TITLE_R, "title")
    local txt = {}
    for _, b in ipairs(boxes) do txt[#txt + 1] = tostring(b.text or "") end
    return Watch.key(table.concat(txt, ""))
end

local function ensure_chat_via(region_title)
    if not focus() then return false, "微信窗口找不到" end
    local want = Watch.key(C.chat)
    local joined = title_text()
    if joined:find(want, 1, true) then return true end
    if joined == "" then
        -- 标题认不出来 = 窗口还没抬起来/被别的东西挡着。这时气泡区大概率也是别人的画面，
        -- 拿它更新 prev 会污染基线，所以宁可跳一轮。
        sleep(300)
        joined = title_text()
        if joined == "" then return false, "标题识别为空（微信被遮挡？）" end
        if joined:find(want, 1, true) then return true end
    end
    local wx = wechat_lib()
    if not wx then return false, "找不到 helper/wechat.lua，无法自动切会话" end
    log("当前会话不是「%s」（标题 OCR=%q），调 wechat open", C.chat, joined:sub(1, 40))
    pcall(wx.run, { action = "open", name = C.chat, background = false })
    sleep(400)
    joined = title_text()
    if joined ~= "" and not joined:find(want, 1, true) then
        return false, "切成「" .. C.chat .. "」失败（标题 OCR=" .. joined:sub(1, 30) .. "）"
    end
    return true
end

-- ── 精确原文：右键气泡 → 菜单点「复制」 → 读剪贴板 ───────────────────
local function clip_read()
    local h = io.popen("xclip -selection clipboard -o 2>/dev/null")
    if not h then return "" end
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

local function copy_at(x, y)
    local keep = clip_read()
    clip_write("")                       -- 先抹掉，读到空就知道复制没发生
    pcall(function() xdo:click_abs(math.floor(x), math.floor(y), 3) end)
    sleep(450)
    local mx0, my0 = math.max(0, x - 500), math.max(0, y - 60)
    local boxes = ocr_region({ mx0, my0, math.min(x + 700, 2560), math.min(y + 620, 1408) }, "menu")
    local hit
    for _, b in ipairs(boxes) do
        if Watch.key(b.text) == Watch.key("复制") then
            hit = b; break
        end
    end
    if not hit then
        pcall(function() xdo:key(0, "Escape") end)
        if keep ~= "" then clip_write(keep) end
        return nil, "菜单里没找到「复制」"
    end
    pcall(function() xdo:click_abs(math.floor(hit.x + hit.w / 2), math.floor(hit.y + hit.h / 2), 1) end)
    sleep(350)
    local got = clip_read()
    if keep ~= "" then clip_write(keep) end   -- 别偷走用户的剪贴板
    if got == "" then return nil, "复制后剪贴板是空的" end
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

local function health()
    local ok = os.execute(string.format("curl -s -m 2 %s >/dev/null 2>&1",
        q(string.format("http://%s:%d/health", C.host, C.port))))
    return ok == 0 or ok == true
end

local function spawn_serve()
    if not C.spawn then return false end
    local run = ROOT .. "/tools/run.sh"
    local f = io.open(run, "r")
    if not f then log("warn: 没有 %s，无法自动拉起 serve", run); return false end
    f:close()
    log("serve 没在跑，拉一个（cwd=%s port=%d）", C.cwd, C.port)
    os.execute(string.format(
        "cd %s && setsid nohup %s serve --host %s --port %d >> %s 2>&1 &",
        q(C.cwd), q(run), q(C.host), C.port, q(C.state .. "/serve.log")))
    for _ = 1, 30 do
        sleep(1000)
        if health() then log("serve 起来了"); return true end
    end
    log("warn: serve 30s 没起来（见 %s/serve.log），退回一次性执行", C.state)
    return false
end

local function post(prompt)
    local payload = TMP .. "-payload.json"
    local f = io.open(payload, "wb")
    if not f then return nil, "写不了 payload" end
    f:write(cjson.encode({ prompt = prompt })); f:close()
    local cmd = string.format(
        "curl -sS -m %d -H 'Content-Type: application/json' --data-binary @%s %s/prompt",
        C.http_timeout, q(payload), q(string.format("http://%s:%d", C.host, C.port)))
    local h = io.popen(cmd .. " 2>&1")
    if not h then return nil, "curl 起不来" end
    local out = h:read("*a") or ""
    h:close()
    local ok, t = pcall(cjson.decode, out)
    if ok and type(t) == "table" then
        if t.ok then return t.text or "" end
        return nil, tostring(t.error or out:sub(1, 300))
    end
    return nil, "响应不是 JSON: " .. out:sub(1, 300)
end

local function oneshot(prompt)
    local run = ROOT .. "/tools/run.sh"
    local payload = TMP .. "-one.txt"
    local f = io.open(payload, "wb"); f:write(prompt); f:close()
    local h = io.popen(string.format(
        "cd %s && %s --once --json \"$(cat %s)\" 2>&1", q(C.cwd), q(run), q(payload)))
    if not h then return nil, "run.sh 起不来" end
    local out = h:read("*a") or ""
    h:close()
    local ok, t = pcall(cjson.decode, out)
    if ok and type(t) == "table" then return t.text or t.answer or "" end
    return nil, "一次性执行失败: " .. out:sub(0, 400)
end

local function dispatch(text)
    local prompt = string.format(PROMPT, text)
    if health() then
        local reply, err = post(prompt)
        if reply then return reply end
        log("error: serve 派发失败：%s", tostring(err))
        return nil, err
    end
    if spawn_serve() then
        local reply, err = post(prompt)
        if reply then return reply end
        log("error: serve 派发失败：%s", tostring(err))
        return nil, err
    end
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
    if not focus() then return nil, "微信窗口找不到" end
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

local function tick()
    local blocks, err = snapshot()
    if not blocks then log("skip: %s", err); return 0 end
    local keys = Watch.keys(blocks)
    local from = Watch.diff(st.prev, keys)
    local added = 0
    local fresh = {}
    for i = from, #blocks do fresh[#fresh + 1] = blocks[i] end
    -- 首次启动（prev 为空）只建基线，绝不回放历史消息
    local baseline = #(st.prev or {}) == 0
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
            if reply then
                log("完成 #%d（%ds，%d 字）", item.id, os.time() - t0, #tostring(reply))
                st.replies[#st.replies + 1] = Watch.key(tostring(reply):sub(1, 200))
                while #st.replies > 12 do table.remove(st.replies, 1) end
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
    log("启动 pid=%s interval=%ds port=%d prefix=%q chat=%s dry=%s",
        pid, C.interval, C.port, C.prefix, C.chat, tostring(C.dry))
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

local rounds = 0
while true do
    rounds = rounds + 1
    local ok, err = pcall(function()
        local ready, why = ensure_chat_via(TITLE_R)
        if not ready then log("skip: %s", tostring(why)); return end
        tick()
        drain()
    end)
    if not ok then log("error: %s", tostring(err)) end
    if C.once then break end
    sleep(C.interval * 1000)
end
log("退出 rounds=%d", rounds)
