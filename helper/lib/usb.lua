-- helper/lib/usb.lua — 本机 USB 外设：麦克风（ALSA capture）、音箱（ALSA playback）、摄像头（V4L2）
-- 走 arecord/aplay/ffmpeg/v4l2-ctl/pactl，与 agent 同进程（io.popen）。
-- 设备用 "<card>,<device>" 标识（如 "3,0"），也可传名字子串（如 "jieli"），大小写不敏感。
local M = {}

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function join(t)
    local o = {}
    for i, v in ipairs(t) do o[i] = q(v) end
    return table.concat(o, " ")
end

function M.sh(cmd, timeout)
    local t = math.max(1, tonumber(timeout) or 60)
    local out_path, rc_path, to_path = os.tmpname(), os.tmpname(), os.tmpname()
    -- 子进程可能 fork（ffmpeg 尤其常见）。直接 io.popen 读管道时，
    -- timeout 只杀掉 sh，ffmpeg 仍持有 stdout，父进程会永远等不到 EOF。
    -- 用 setsid 建独立进程组、输出落文件、watchdog 杀整组，宿主不会再被拖死。
    local wrapped = string.format(
        "setsid sh -c %s > %s 2>&1 & pid=$!; "
            .. "( sleep %d; echo timeout > %s; kill -TERM -$pid 2>/dev/null; sleep 1; "
            .. "kill -KILL -$pid 2>/dev/null ) >/dev/null 2>&1 & watcher=$!; "
            .. "wait $pid; rc=$?; kill $watcher 2>/dev/null; echo $rc > %s",
        q(cmd), q(out_path), t, q(to_path), q(rc_path))
    local p = io.popen(wrapped, "r")
    if not p then
        os.remove(out_path); os.remove(rc_path); os.remove(to_path)
        return { code = -1, output = "cannot spawn shell" }
    end
    p:read("*a")
    p:close()
    local f = io.open(out_path, "rb")
    local out = f and (f:read("*a") or "") or ""
    if f then f:close() end
    local rf = io.open(rc_path, "rb")
    local code = rf and tonumber((rf:read("*l") or ""):match("^%s*(%-?%d+)")) or -1
    if rf then rf:close() end
    local tf = io.open(to_path, "rb")
    local timed_out = tf and tf:read("*a") ~= "" or false
    if tf then tf:close() end
    os.remove(out_path); os.remove(rc_path); os.remove(to_path)
    if timed_out then
        code = 124
        if out ~= "" and out:sub(-1) ~= "\n" then out = out .. "\n" end
        out = out .. "[timeout]"
    end
    return { code = code, output = out:gsub("%s+$", ""), ok = code == 0 }
end

local function tmp(ext)
    local d = os.getenv("TMPDIR") or "/tmp"
    if d:sub(-1) == "/" then d = d:sub(1, -2) end
    return string.format("%s/lite-usb-%d-%d.%s", d, os.time(), math.random(1000, 9999), ext)
end
M.tmp = tmp

-- ---------- 枚举 ----------
-- arecord -l / aplay -l 行长这样：
--   card 3: UACDemoV10 [UACDemoV1.0], device 0: USB Audio [USB Audio]
local function parse_alsa(text)
    local out = {}
    for line in (text or ""):gmatch("[^\n]+") do
        local card, cid, cname, dev, dname, dsub =
            line:match("^card%s+(%d+):%s+(%S+)%s+%[([^%]]*)%],%s+device%s+(%d+):%s+([^%[]*)%[([^%]]*)%]")
        if card then
            out[#out + 1] = {
                card = tonumber(card), dev = tonumber(dev),
                card_id = cid, card_name = cname,
                dev_name = (dname or ""):gsub("%s+$", ""),
                id = card .. "," .. dev,
                usb = (line:lower():find("usb") ~= nil),
                label = string.format("%s,%s  %s / %s", card, dev, cname, dsub or ""),
            }
        end
    end
    return out
end

function M.mics() return parse_alsa(M.sh("arecord -l", 15).output) end
function M.speakers() return parse_alsa(M.sh("aplay -l", 15).output) end

function M.cams()
    local out = {}
    local r = M.sh("v4l2-ctl --list-devices", 15)
    local cur = nil
    for line in (r.output or ""):gmatch("[^\n]+") do
        if line:match("^%S") and line:find(":") then
            -- 行尾是 "(bus):" 或 "(bus)"，两种都要吃
            local name, bus = line:match("^(.-)%s*%((.-)%)%s*:?%s*$")
            if not name then name, bus = line, "" end
            cur = { name = name, bus = bus, devs = {} }
            out[#out + 1] = cur
        elseif cur and line:match("/dev/video") then
            cur.devs[#cur.devs + 1] = line:match("(/dev/video%d+)")
        end
    end
    for _, c in ipairs(out) do
        c.dev = c.devs[1]
        c.usb = c.bus:lower():find("usb") ~= nil
        c.virtual = c.bus:lower():find("v4l2loopback") ~= nil
    end
    return out
end

-- 名字子串 / "<card>,<dev>" / nil → 第一个 USB 设备
local function pick(list, want, what)
    if not list or #list == 0 then return nil, "no " .. what .. " found (arecord -l / aplay -l 空)" end
    if not want or want == "" then
        for _, d in ipairs(list) do if d.usb then return d end end
        return list[1]
    end
    local w = tostring(want):lower()
    for _, d in ipairs(list) do
        if d.id == w or d.label:lower():find(w, 1, true) then return d end
    end
    for _, d in ipairs(list) do
        local key = (d.card_id .. " " .. d.card_name .. " " .. d.dev_name):lower()
        if key:find(w, 1, true) then return d end
    end
    local names = {}
    for _, d in ipairs(list) do names[#names + 1] = d.label end
    return nil, "no " .. what .. " matching " .. q(want) .. "; 可选: " .. table.concat(names, " | ")
end
M.pick = pick

function M.mic(want) return pick(M.mics(), want, "capture device (mic)") end
function M.speaker(want) return pick(M.speakers(), want, "playback device (speaker)") end

function M.cam(want)
    local list = M.cams()
    if not want or want == "" then
        for _, c in ipairs(list) do if c.usb and not c.virtual then return c end end
        for _, c in ipairs(list) do if not c.virtual then return c end end
        return nil, "no camera found (v4l2-ctl --list-devices 空)"
    end
    local w = tostring(want):lower()
    for _, c in ipairs(list) do
        if (c.dev or ""):lower() == w then return c end
    end
    for _, c in ipairs(list) do
        if c.name:lower():find(w, 1, true) then return c end
    end
    local names = {}
    for _, c in ipairs(list) do names[#names + 1] = c.name .. "=" .. tostring(c.dev) end
    return nil, "no camera matching " .. q(want) .. "; 可选: " .. table.concat(names, " | ")
end

-- ---------- 录音 ----------
-- 返回 true, path, stats ；stats = {max, mean}（dB，用 ffmpeg volumedetect 复核是否真有声）
function M.record(opts)
    opts = opts or {}
    local dev, err = M.mic(opts.mic)
    if not dev then return nil, err end
    local secs = tonumber(opts.seconds) or 3
    local rate = tonumber(opts.rate) or 48000
    local ch = tonumber(opts.channels) or 1
    if secs <= 0 or secs > 600 then return nil, "seconds 需在 0..600" end
    local out = opts.out
    if not out or out == "" then out = tmp("wav") end
    local cmd = string.format("arecord -D plughw:%s -f S16_LE -r %d -c %d -d %s %s",
        dev.id, rate, ch, tostring(math.floor(secs)), q(out))
    local r = M.sh(cmd, math.floor(secs) + 15)
    if not r.ok then return nil, "arecord failed (" .. dev.id .. "): " .. r.output:sub(-400) end
    local st = M.sh(string.format("ffmpeg -hide_banner -i %s -af volumedetect -f null - 2>&1", q(out)), 30).output
    local stats = {
        max = tonumber(st:match("max_volume:%s*(%-?[%d%.]+)")) or -999,
        mean = tonumber(st:match("mean_volume:%s*(%-?[%d%.]+)")) or -999,
    }
    return true, out, stats, dev
end

-- ---------- 播放 ----------
function M.play(opts)
    opts = opts or {}
    local dev, err = M.speaker(opts.spk)
    if not dev then return nil, err end
    local path = opts.path
    if not path or path == "" then
        -- 没给文件就用 440Hz 测试音
        local secs = tonumber(opts.seconds) or 1
        local freq = tonumber(opts.freq) or 440
        path = tmp("wav")
        local g = M.sh(string.format(
            "ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=%d:duration=%s' -ar 48000 %s",
            freq, tostring(secs), q(path)), 20)
        if not g.ok then return nil, "生成测试音失败: " .. g.output:sub(-300) end
    end
    local probe = M.sh("test -r " .. q(path), 5)
    if not probe.ok then return nil, "文件不可读: " .. path end
    local cmd
    if path:lower():match("%.wav$") then
        cmd = string.format("aplay -D plughw:%s %s", dev.id, q(path))
    else
        cmd = string.format("ffmpeg -hide_banner -loglevel error -i %s -f wav -ar 48000 - 2>/dev/null | aplay -D plughw:%s -",
            q(path), dev.id)
    end
    local r = M.sh(cmd, tonumber(opts.timeout) or 120)
    if not r.ok then return nil, "aplay failed (" .. dev.id .. "): " .. r.output:sub(-400) end
    return true, path, dev
end

-- ---------- 摄像头 ----------
local function ff_capture(c, size, out, extra, secs)
    local in_opt = string.format("-f v4l2 -input_format mjpeg -video_size %s", size)
    if secs then in_opt = in_opt .. string.format(" -t %d", secs) end
    local cmd = string.format("ffmpeg -hide_banner -loglevel error -y %s -i %s %s %s",
        in_opt, c.dev, extra or "-frames:v 1", q(out))
    return M.sh(cmd, (secs or 0) + 40)
end

function M.photo(opts)
    opts = opts or {}
    local c, err = M.cam(opts.cam)
    if not c then return nil, err end
    local out = opts.out
    if not out or out == "" then out = tmp("jpg") end
    local size = opts.size or "1280x720"
    local r = ff_capture(c, size, out, nil, nil)
    local warn = nil
    if not r.ok or not M.sh("test -s " .. q(out), 5).ok then
        -- 回退：让 ffmpeg 自己选格式/分辨率
        r = M.sh(string.format("ffmpeg -hide_banner -loglevel error -y -f v4l2 -i %s -frames:v 1 %s", c.dev, q(out)), 40)
        warn = "mjpeg " .. size .. " 失败，已回退默认格式"
        if not r.ok then return nil, "ffmpeg failed (" .. c.dev .. "): " .. r.output:sub(-400) end
    end
    local sz = M.sh("stat -c %s " .. q(out), 5).output:match("%d+")
    return true, out, sz, c, warn
end

function M.video(opts)
    opts = opts or {}
    local c, err = M.cam(opts.cam)
    if not c then return nil, err end
    local secs = math.floor(tonumber(opts.seconds) or 5)
    if secs <= 0 or secs > 600 then return nil, "seconds 需在 0..600" end
    local out = opts.out
    if not out or out == "" then out = tmp("mp4") end
    local r = ff_capture(c, opts.size or "1280x720", out, "-c:v copy", secs)
    if not r.ok then
        r = M.sh(string.format("ffmpeg -hide_banner -loglevel error -y -f v4l2 -t %d -i %s -c:v mpeg4 %s",
            secs, c.dev, q(out)), secs + 40)
        if not r.ok then return nil, "ffmpeg failed (" .. c.dev .. "): " .. r.output:sub(-400) end
    end
    local sz = M.sh("stat -c %s " .. q(out), 5).output:match("%d+")
    return true, out, sz, c
end

function M.cam_info(c)
    local r = M.sh(string.format("v4l2-ctl -d %s --list-formats-ext", c.dev), 15).output
    local fmts = {}
    for f in r:gmatch("%[(%d+)%]:%s*'([^']+)'") do fmts[#fmts + 1] = f end
    local _, _, res = r:find("%[(%d+)%]:%s*'([^']+)'")
    local sizes = {}
    for s in r:gmatch("Size: Discrete (%d+x%d+)") do sizes[#sizes + 1] = s end
    return { fmts = fmts, sizes = sizes, raw = r }
end

-- ---------- 音量 / 默认设备（PipeWire/PulseAudio） ----------
local function pactl_sink_name(want)
    local r = M.sh("pactl list short sinks", 10).output
    local names = {}
    for line in r:gmatch("[^\n]+") do
        local name = line:match("^%d+%s+(%S+)")
        if name then names[#names + 1] = name end
    end
    if not want or want == "" then
        local d = M.sh("pactl get-default-sink", 10).output
        if d and d ~= "" then return d:gsub("%s+$", "") end
        return names[1]
    end
    local w = want:lower()
    for _, n in ipairs(names) do if n:lower():find(w, 1, true) then return n end end
    return nil, "no sink matching " .. q(want) .. "; 可选: " .. table.concat(names, " | ")
end

local function pactl_source_name(want)
    local r = M.sh("pactl list short sources", 10).output
    local names = {}
    for line in r:gmatch("[^\n]+") do
        local name = line:match("^%d+%s+(%S+)")
        if name and not name:match("%.monitor$") then names[#names + 1] = name end
    end
    if not want or want == "" then
        local d = M.sh("pactl get-default-source", 10).output
        if d and d ~= "" then return d:gsub("%s+$", "") end
        return names[1]
    end
    local w = want:lower()
    for _, n in ipairs(names) do if n:lower():find(w, 1, true) then return n end end
    return nil, "no source matching " .. q(want) .. "; 可选: " .. table.concat(names, " | ")
end

function M.volume(opts)
    opts = opts or {}
    local kind = opts.kind or "sink"
    local name, err
    if kind == "source" then name, err = pactl_source_name(opts.device) else name, err = pactl_sink_name(opts.device) end
    if not name then return nil, err end
    local verb = (kind == "source") and "get-source" or "get-sink"
    local setv = (kind == "source") and "set-source" or "set-sink"
    if opts.mute ~= nil then
        M.sh(string.format("pactl %s-mute %s %s", setv, q(name), opts.mute and "1" or "0"), 10)
    end
    if opts.level ~= nil then
        local lv = tonumber(opts.level)
        if not lv then return nil, "level 需为 0..150 的数字" end
        if lv < 0 then lv = 0 elseif lv > 150 then lv = 150 end
        M.sh(string.format("pactl %s-volume %s %d%%", setv, q(name), math.floor(lv)), 10)
    end
    local vol = M.sh(string.format("pactl %s-volume %s", verb, q(name)), 10).output
    local mute = M.sh(string.format("pactl %s-mute %s", verb, q(name)), 10).output
    local pct = tonumber(vol:match("(%d+)%%")) or -1
    return { device = name, percent = pct, mute = mute:find("是") or mute:lower():find("yes") and true or false, raw = vol }
end

function M.set_default(opts)
    opts = opts or {}
    local kind = opts.kind or "sink"
    local name, err
    if kind == "source" then name, err = pactl_source_name(opts.device) else name, err = pactl_sink_name(opts.device) end
    if not name then return nil, err end
    local r = M.sh(string.format("pactl set-default-%s %s", kind, q(name)), 10)
    if not r.ok then return nil, r.output:sub(-300) end
    return true, name
end

return M
