-- helper/lib/sdb.lua — 电视（Sony BRAVIA / Android TV）控制层，走 adb wifi
--
-- sdb = sony debug bridge 的意思：本质还是 adb，但只认电视机这一台，
-- 并把「开电视 / 能不能操作 / 信号在哪个 HDMI」这三件事压成一次 ensure()。
--
-- 实测口径（2026-11-24，KD-55X7000D）：
--   唤醒 KEYCODE_WAKEUP(224)、休眠 KEYCODE_SLEEP(223)；不要用 POWER(26)，它是切换键
--   切输入源 = keyevent (242 + 端口号)：243=HDMI1 244=HDMI2 …（本机实测 243/244 双向可逆）
--   查当前输入 = dumpsys tv_input：
--       sessionStateMap 里 mainSessionToken 那条的 inputId 是 .../HW<n>
--       TvInputHardwareManager 的 mConnections 里 deviceId=<n> 的 hdmi_port 才是真的口
--       （HW 编号与端口号不是一回事：HDMI2 = HW3，别直接拿 HW 号当端口）
local M = {}

local ADB = os.getenv("ADB") or "adb"
M.host = os.getenv("LITE_TV_HOST") or "192.168.1.110:5555"
M.want_port = tonumber(os.getenv("LITE_TV_HDMI") or 2)

local function q(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- 跑一条本机命令，返回 output, ok（尾部哨兵拿退出码：io.popen 不返回 code）
local function sh(cmd, timeout)
    local t = timeout or 20
    local p = io.popen("timeout " .. t .. " sh -c " .. q(cmd) .. " 2>&1; printf '\\n__rc=%d\\n' $?")
    if not p then return "", false end
    local out = p:read("*a") or ""
    p:close()
    local code = tonumber(out:match("__rc=(%-?%d+)%s*$")) or -1
    out = out:gsub("%s*__rc=%-?%d+%s*$", "")
    return out, code == 0
end

local function adb(cmd, timeout)
    return sh(q(ADB) .. " -s " .. q(M.host) .. " shell " .. q(cmd), timeout)
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------- 连接 ----------
-- 电视的 adb wifi 会掉（休眠后尤其），且第一次 connect 常回 no route to host、
-- 紧接着就通了：所以判活看 getprop，不看 connect 的返回。
-- 超时给足：电视刚醒时 `adb connect` 会对着一台半死的 TCP 连接干等几十秒，
-- 10s 硬杀会让「其实再等一下就通」误判成「连不上」（2026-11-24 实测踩到）。
function M.connect(tries)
    tries = tries or 3
    local last = ""
    for i = 1, tries do
        local out = trim((select(1, sh(q(ADB) .. " connect " .. q(M.host), 30))))
        local model = trim((select(1, adb("getprop ro.product.model", 15))))
        if model ~= "" and not model:find("device not found", 1, true)
            and not model:find("error", 1, true) then
            M.model = model
            return true
        end
        last = (model ~= "" and model or out):gsub("%s+", " ")
        if last == "" then last = "无应答" end
        if i < tries then os.execute("sleep 3") end
    end
    return false, "adb 连不上 " .. M.host .. "（" .. last
        .. "）；电视休眠会断网，手动开一下电视或查 IP"
end

-- ---------- 屏态 ----------
function M.wakefulness()
    local out = adb("dumpsys power | grep mWakefulness=", 15)
    return trim(out:match("mWakefulness=(%a+)") or "unknown")
end

function M.focus()
    -- grep -m1 会提前关管道，dumpsys 把 "Failed to write … Broken pipe" 写到 stderr，先在设备侧丢掉
    local out = adb('dumpsys window 2>/dev/null | grep -m1 mCurrentFocus', 15)
    out = out:gsub("[^\n]*Failed to write[^\n]*\n?", "")
    return trim(out:gsub("^%s*mCurrentFocus=", ""))
end

-- ---------- 输入源 ----------
-- 返回 port(数字，HDMI 口) 或 nil, 说明
-- 当前台不是 HDMI（比如在 Android 桌面/应用里）时 port = nil
function M.current_port()
    local raw = adb("dumpsys tv_input", 25)
    if trim(raw) == "" then return nil, "dumpsys tv_input 空（电视没醒或 adb 掉线）" end

    -- 1) HW 编号 → 端口号（键统一用数字：gmatch 给的是字符串，"3" ≠ 3）
    local hw2port = {}
    for id, port in raw:gmatch("(%d+): Connection%{ mHardwareInfo:[^\n]-hdmi_port=(%d+)") do
        hw2port[tonumber(id)] = tonumber(port)
    end
    -- 2) 当前会话的 inputId（优先 mainSessionToken 对应的那条）
    local session_hw
    local main_tok = raw:match("mainSessionToken:%s*(%S+)")
    for blk_tok, hw in raw:gmatch("(android%.os%.Binder@%x+):[^\n]*\n%s*inputId: [^\n]-/(HW%d+)") do
        if main_tok and blk_tok == main_tok then session_hw = hw; break end
        session_hw = session_hw or hw
    end
    if session_hw then
        local id = tonumber(session_hw:match("%d+"))
        local port = hw2port[id]
        if port then return port, session_hw end
        return nil, session_hw .. " 不是 HDMI（" .. tostring(id) .. " 号硬件无 hdmi_port）"
    end
    if not main_tok then return nil, "没有活动会话（电视停在 Android 应用/桌面，没有选输入源）" end
    return nil, "会话里没解析出 inputId"
end

-- 切到某个 HDMI 口：keyevent 242+port，然后回读确认（不信「发完就算成功」）
function M.switch_port(port, wait_s)
    port = tonumber(port)
    if not port or port < 1 or port > 4 then return false, "端口号要在 1..4：" .. tostring(port) end
    local _, ok = adb("input keyevent " .. (242 + port), 15)
    if not ok then return false, "发键失败（权限？电视没醒？）" end
    wait_s = wait_s or 12
    local deadline = os.time() + wait_s
    local last
    repeat
        os.execute("sleep 1")
        local p, why = M.current_port()
        if p == port then return true, "HDMI" .. port end
        last = p and ("HDMI" .. p) or tostring(why)
    until os.time() >= deadline
    return false, "切不到 HDMI" .. port .. "（现在：" .. tostring(last) .. "）"
end

function M.wake(wait_s)
    if M.wakefulness() == "Awake" then return true, "本来就醒着" end
    adb("input keyevent 224", 15)                       -- KEYCODE_WAKEUP
    wait_s = wait_s or 15
    local deadline = os.time() + wait_s
    repeat
        os.execute("sleep 1")
        if M.wakefulness() == "Awake" then return true, "已唤醒" end
    until os.time() >= deadline
    return false, "唤不醒（" .. M.wakefulness() .. "）"
end

function M.sleep()
    adb("input keyevent 223", 15)                       -- KEYCODE_SLEEP
    return true, "已休眠"
end

-- ---------- 一次到位 ----------
-- 开电视 + 确认能操作 + 信号在指定 HDMI。
-- 返回 ok, report(给人看的一行行), changed(有没有动过电视)
function M.ensure(opts)
    opts = opts or {}
    local want = tonumber(opts.port) or M.want_port
    local changed = {}

    local cok, cerr = M.connect(opts.tries)
    if not cok then return false, "电视没就绪：" .. tostring(cerr), changed end

    local wok, wmsg = M.wake()
    if not wok then return false, "电视没就绪：" .. tostring(wmsg), changed end
    if wmsg == "已唤醒" then changed[#changed + 1] = "唤醒" end

    local port, why = M.current_port()
    if port ~= want then
        local sok, smsg = M.switch_port(want)
        if not sok then
            return false, "电视信号不在 HDMI" .. want .. "：" .. tostring(smsg) .. "（" .. tostring(why) .. "）", changed
        end
        changed[#changed + 1] = "切到 HDMI" .. want
        port = want
    end

    -- 「能操作」= adb 有应答 + 屏亮 + 前台窗口真有东西
    local focus = M.focus()
    if focus == "" or focus:find("Focus=null", 1, true) then
        return false, "电视醒着但没有前台窗口（黑屏？）", changed
    end

    return true, {
        model = M.model or "?",
        host = M.host,
        wakefulness = M.wakefulness(),
        port = port,
        focus = focus:match("([%w%.]+/[%w%.$]+)") or focus,
    }, changed
end

return M
