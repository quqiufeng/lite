-- wx_sni.lua — 从 StatusNotifierItem（D-Bus）直接读微信托盘图，判「有没有新消息」。
--
-- 为什么要有这条通道：微信 Linux 版是 Qt SNI 应用，托盘图标由**它自己**通过 D-Bus 交给
-- 面板（本机 = lxqt-panel，没有 XEmbed 老托盘可退）。有未读时图标在「绿气泡」和
-- 「绿气泡 + 红点」之间闪，也就是 **IconPixmap 属性被换着给**。
-- 于是判「要不要去点开微信」可以不碰窗口：不抢焦点、不截屏、不 OCR、不看屏幕几何。
--
-- 与 wx_tray.lua（面板像素闪动）的分工 —— **当前线上只有 wx_tray 在跑**：
--   * wx_tray：从**屏幕**上承认结果，能兜住「面板不是 SNI host」这类环境；
--     代价是要面板可见、要算图标包围盒、要采样 15 帧。daemon 的门就是它。
--   * 本模块：从**源头**读属性，一次 D-Bus 往返就是全部开销，跟窗口在不在前台无关。
--     **目前没有生产调用方**，只当「门失灵时的外部真值源」用：daemon 判没消息却没消息、
--     或判有消息其实没有时，跑本文件对一遍就知道是微信改版还是像素判据坏了。
--   不走 FFI 是因为它每次要起 busctl 子进程，比 XGetImage 贵；验真值不值得上快路，
--   等门真出问题再说。
--
-- 实测事实（2026-11-23 本机，微信 1887 / lxqt-panel 1926）：
--   Status 恒 "Active"（从不给 NeedsAttention）、AttentionIconPixmap 空、
--   ToolTip 里没有未读数 —— SNI 的「未读语义」字段全被微信留空，
--   **唯一活的通道就是 IconPixmap 内容本身**。所以判据只能是「图变了」，
--   不是「图变成了某个特定样子」。
--   也因此不能只看有没有红点：红点是半个周期，单帧采样有一半概率读到没有。
--
-- 实现取舍：先用 `busctl --json=short get-property` 子进程读（一次 ~64KB JSON，
-- cjson 解析毫秒级），先把判据验实，再决定要不要下沉成 libdbus FFI。
-- 急着上 FFI 会在「微信到底发不发 NewIcon」还没验的情况下白写一套绑定。
local cjson = require("cjson")

local M = {}

local ITEM_IFACE = "org.kde.StatusNotifierItem"
local ITEM_PATH = "/StatusNotifierItem"

local function run(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return nil, "popen 失败" end
    local out = p:read("*a")
    local ok = p:close()
    if not out or out == "" then return nil, "命令无输出" end
    if ok == nil or ok == false then return nil, "命令失败" end
    return out
end

-- 微信进程的 comm：SNI 服务名是 org.kde.StatusNotifierItem-<pid>-<n>，pid 直接写在名字里，
-- 靠它认「哪个 item 是微信」，别去猜注册顺序（面板重启/多实例都会变）。
local function comm_of(pid)
    local f = io.open("/proc/" .. pid .. "/comm", "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    return s
end

-- 找微信的 SNI 目的名。返回 dest, pid；找不到返回 nil, 原因。
function M.locate(proc)
    proc = proc or "wechat"
    local out, err = run("busctl --user list --no-legend")
    if not out then return nil, "busctl list: " .. tostring(err) end
    local seen = {}
    for line in out:gmatch("[^\n]+") do
        local name = line:match("^(%S+)")
        if name and not seen[name] then
            seen[name] = true
            -- 新旧两种前缀都认：org.kde.* 是老 spec，org.freedesktop.* 是 0.9 之后的写法
            local pid = name:match("^org%.kde%.StatusNotifierItem%-(%d+)%-")
                or name:match("^org%.freedesktop%.StatusNotifierItem%-(%d+)%-")
            if pid and comm_of(pid) == proc then
                return name, tonumber(pid)
            end
        end
    end
    return nil, "没找到 " .. proc .. " 的 StatusNotifierItem（托盘没起来？）"
end

-- 读单个属性；返回原始 JSON 解出来的 .data（属性值），失败 nil, 原因。
local function get_prop(dest, prop)
    local out, err = run(string.format(
        "busctl --user --json=short get-property %s %s %s %s",
        dest, ITEM_PATH, ITEM_IFACE, prop))
    if not out then return nil, prop .. ": " .. tostring(err) end
    local ok, v = pcall(cjson.decode, out)
    if not ok or type(v) ~= "table" then return nil, prop .. ": JSON 解析失败" end
    return v.data
end

function M.status(dest)
    local d = get_prop(dest, "Status")
    if type(d) ~= "string" then return nil end
    return d
end

-- FNV-1a 32 位：只要「两张图不同就大概率不同」，不需要密码学强度。
local function fnv(arr, n)
    local h = 2166136261
    for i = 1, n do
        h = h - math.floor(h / 4294967296) * 4294967296
        h = (h * 16777619 + arr[i]) % 4294967296
        h = h % 4294967296
    end
    return h
end

-- 红点像素数。微信未读红 #FA5151 附近；判「偏红」而不是精确等值，
-- 换主题/缩放/抗锯齿后还能认。
local function count_red(arr, n)
    local c = 0
    for i = 1, n - 3, 4 do
        local b, g, r, a = arr[i], arr[i + 1], arr[i + 2], arr[i + 3]
        if (a == nil or a > 128) and r > 190 and g < 130 and b < 130 then c = c + 1 end
    end
    return c
end

-- 采样一次 IconPixmap。
-- SNI 允许一个属性里带多张不同尺寸（本机微信实测恒为 64x64 + 22x22 两帧），
-- 所以**判据是整个帧集合**，不是某一张：只盯最大帧会在「集合变了但最大帧碰巧没变」
-- 和「最大帧换成了另一张」两种情况之间反复误判（后者表现为恒 100%，量不出幅度）。
-- 返回 info{frames, key, w, h, n, arr, hash, red}，后者是面积最大那帧（给人看的、算红点用）；
-- 失败 nil, 原因。key = 各帧 "宽x高:h=哈希" 按宽降序拼接，是这一轮的身份。
function M.sample(dest)
    local d, err = get_prop(dest, "IconPixmap")
    if not d then return nil, err end
    if type(d) ~= "table" or #d == 0 then return nil, "IconPixmap 为空（面板/微信还没画）" end
    local frames = {}
    for _, e in ipairs(d) do
        local w, h, arr = e[1], e[2], e[3]
        if type(w) == "number" and type(h) == "number" and type(arr) == "table"
            and w > 0 and h > 0 and #arr >= w * h * 4 then
            local n = w * h * 4
            frames[#frames + 1] = {
                w = w, h = h, n = n, arr = arr,
                hash = fnv(arr, n), red = count_red(arr, n),
            }
        end
    end
    if #frames == 0 then return nil, "IconPixmap 里没有可用帧" end
    table.sort(frames, function(a, b) return a.w * a.h > b.w * b.h end)
    local parts = {}
    for i, f in ipairs(frames) do
        parts[i] = string.format("%dx%d:h=%d", f.w, f.h, f.hash)
    end
    local info = frames[1]
    info.frames = frames
    info.key = table.concat(parts, ",")
    return info
end

-- 判一轮：cache 是调用方长期持有的表（跨轮保存上一帧）。
-- 返回 changed, why。
-- 首次只建基线（changed=false）：刚起进程时图是什么样不代表来了新消息，
-- 照「变了就冲进去」处理的话，启动瞬间必然误判一次。
function M.check(cache, dest)
    cache = cache or {}
    if not dest then
        local err
        dest, err = M.locate()
        if not dest then return false, err end
        cache.dest = dest
    end
    local info, err = M.sample(dest)
    if not info then return false, err end
    local prev = cache.info
    cache.info = info
    if not prev then
        return false, string.format("基线 %dx%d 帧数 %d 红点 %d",
            info.w, info.h, #info.frames, info.red)
    end
    if prev.key == info.key then
        return false, string.format("未变（%d 帧，红点 %d）", #info.frames, info.red)
    end
    -- 帧集合变了。分两种：
    --   a) 帧数/尺寸不同 → 幅度没法按像素算，直接报「结构变了」并列出前后帧形状；
    --   b) 尺寸相同、内容不同 → 逐像素统计，给出百分比（这才是「图标闪了」的正经度量）。
    local pf, cf = prev.frames or { prev }, info.frames
    local same_shape = #pf == #cf
    if same_shape then
        for i = 1, #pf do
            if pf[i].w ~= cf[i].w or pf[i].h ~= cf[i].h then same_shape = false break end
        end
    end
    if not same_shape then
        local function shape(list)
            local t = {}
            for i, f in ipairs(list) do t[i] = string.format("%dx%d", f.w, f.h) end
            return table.concat(t, "+")
        end
        return true, string.format("帧集合变了 %s → %s", shape(pf), shape(cf)), 100
    end
    local diff, total = 0, 0
    for i = 1, #pf do
        local a, b = pf[i].arr, cf[i].arr
        for p = 1, cf[i].n do
            if a[p] ~= b[p] then diff = diff + 1 end
        end
        total = total + cf[i].n
    end
    local pct = total > 0 and (diff * 100 / total) or 100
    return true, string.format("图标变了 %.2f%%（红点 %s→%d）",
        pct, tostring(prev.red or "?"), info.red), pct
end

-- 「有未读」的唯一可靠信号 = 图标在闪，不是红点。
-- 实测（2026-11-23，微信 4.x + KDE StatusNotifier）：64x64 那张图标**不带红点**，
-- 未读时 StatusNotifier 把 IconPixmap 在两组之间来回换（周期约 0.9s，各占 ~0.45s）：
--   A = 64x64 + 22x22（真图标，无未读时恒为它）
--   B = 16x16 + 16x16（占位图，只出现在闪动期间）
-- 所以判据是「最近 window 秒内见过最小帧 < 32px 的 B 态」，而不是「变了就算新消息」：
-- 后者的一个未读会连发几十次告警，且闪动停止后永远等不到「已读」的边沿。
-- cache.last_alert 由本函数维护，调用方长期持有同一张 cache 即可。
function M.blinking(cache, dest, window)
    window = window or 15
    local _, why = M.check(cache, dest)
    local info = cache.info
    if info and info.frames[1] and info.frames[1].w < 32 then
        cache.last_alert = os.time()
    end
    local age = cache.last_alert and (os.time() - cache.last_alert) or nil
    local on = age ~= nil and age <= window
    return on, age, why
end

-- 命令行自检：直接跑本文件。
if arg and arg[0] and arg[0]:find("wx_sni%.lua$") then
    local dest, pid = M.locate()
    if not dest then
        io.stderr:write("error: " .. tostring(pid) .. "\n")
        os.exit(1)
    end
    print(string.format("item   %s (pid %s)", dest, tostring(pid)))
    print(string.format("status %s", tostring(M.status(dest))))
    local info, err = M.sample(dest)
    if not info then
        io.stderr:write("error: " .. tostring(err) .. "\n")
        os.exit(1)
    end
    print(string.format("icon   %dx%d n=%d hash=%d red=%d", info.w, info.h, info.n,
        info.hash, info.red))
    if arg[1] == "--watch" then
        local cache = { info = info }
        local n = tonumber(arg[2]) or 10
        for i = 1, n do
            os.execute("sleep 1")
            local ch, why = M.check(cache, dest)
            print(string.format("  %2ds %s %s", i, ch and "CHANGED" or "same   ", tostring(why)))
        end
    end
    os.exit(0)
end

return M
