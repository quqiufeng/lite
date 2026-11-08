-- helper/lib/music.lua — 后台放歌：常驻 VLC，控制走 MPRIS(dbus-send)
-- 没有 socat/nc/playerctl，MPRIS 是唯一稳定的无守护依赖通道；
-- dbus-send 一次进程 ~10ms，够用。队列用 m3u 文件喂 VLC（OpenUri 会自动展开）。
local cjson = require("cjson")

local M = {}

local DEST = "org.mpris.MediaPlayer2.vlc"
local OBJ = "/org/mpris/MediaPlayer2"
local PL = "org.mpris.MediaPlayer2.Player"
local PR = "org.freedesktop.DBus.Properties"
local TL = "org.mpris.MediaPlayer2.TrackList"
local NO_TRACK = "/org/mpris/MediaPlayer2/TrackList/NoTrack"

local EXT = {
    mp3 = 1, flac = 1, wav = 1, ogg = 1, oga = 1, opus = 1, m4a = 1, aac = 1,
    wma = 1, ape = 1, wv = 1, aiff = 1, mka = 1, webm = 1, m4v = 1,
}

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
M.q = q

function M.sh(cmd, timeout)
    local f = io.popen(cmd .. " 2>&1", "r")
    if not f then return { ok = false, output = "popen failed: " .. cmd } end
    local out = f:read("*a") or ""
    local ok, how = f:close()
    return { ok = (ok and how == "exit") and true or false, output = out }
end

local function base()
    return "dbus-send --session --print-reply --dest=" .. DEST .. " " .. OBJ
end

-- MPRIS 方法调用；返回文本输出，失败返回 nil+错误
local function call(iface, method, args)
    local out = M.sh(base() .. " " .. iface .. "." .. method .. (args and (" " .. args) or ""), 5).output
    if out:find("Error ") then return nil, out:match("Error [^\n]+") end
    return out
end

local function get(prop)
    local out, err = call(PR, "Get", "string:" .. PL .. " string:" .. prop)
    if not out then return nil, err end
    local v = out:match("variant%s+string%s+\"(.-)\"%s*\n")
    if v then return v end
    local n = out:match("variant%s+int64%s+(-?%d+)") or out:match("variant%s+double%s+([-%d.e]+)")
    return n and tonumber(n) or nil
end

local function set(prop, sig, val)
    return call(PR, "Set", string.format("string:%s string:%s variant:%s", PL, prop, sig))
end
-- dbus-send 的 variant 值要跟在类型后面："variant:double:0.7"
local function setnum(prop, sig, val)
    return call(PR, "Set", string.format("string:%s string:%s variant:%s:%s", PL, prop, sig, tostring(val)))
end

local function status_of()
    return get("PlaybackStatus")
end

function M.running()
    return status_of() ~= nil
end

function M.sock() return string.format("/tmp/lite-music-%d.m3u", tonumber(M.sh("id -u").output) or 0) end

local SPAWN_LOG = "/tmp/lite-music-vlc.log"

local function spawn()
    local log = SPAWN_LOG
    local bin = (os.getenv("DISPLAY") and os.getenv("DISPLAY") ~= "") and "vlc" or "cvlc"
    local cmd = string.format(
        "setsid %s --no-video --no-video-title-show --no-one-instance "
        .. "--no-metadata-network-access --playlist-autostart "
        .. "--input-title-format='$t' >%s 2>&1 </dev/null &", bin, q(log))
    M.sh(cmd, 5)
    for _ = 1, 60 do
        if M.running() then
            local vol = tonumber(os.getenv("LITE_MUSIC_VOLUME")) or 70
            setnum("Volume", "double", vol / 100)
            return true
        end
        M.sh("sleep 0.2")
    end
    local tail = ""
    local f = io.open(log, "r")
    if f then tail = (f:read("*a") or ""):sub(-300); f:close() end
    return nil, "vlc 起不来（或 MPRIS 没注册）：" .. (tail ~= "" and tail or "无输出")
end

function M.ensure() return M.running() and true or spawn() end

-- 扫目录里的音频（递归 3 层）
function M.scan(dir)
    local r = M.sh(string.format("find %s -maxdepth 3 -type f 2>/dev/null | sort", q(dir)), 20)
    local out = {}
    for line in (r.output or ""):gmatch("[^\r\n]+") do
        local ext = line:lower():match("%.([%w]+)$")
        if ext and EXT[ext] then out[#out + 1] = line end
    end
    return out
end

function M.playlist_files(dir)
    if type(dir) ~= "string" or dir == "" then return nil, "playlist_files 需要目录参数" end
    local files = M.scan(dir)
    if #files == 0 then return nil, "目录里没找到音频文件: " .. dir end
    return files
end

-- 队列日志：VLC 的 TrackList 不暴露标题，自己记 loadfile 顺序（追加/替换）
function M.queuelog()
    return M.sock():gsub("%.m3u$", ".queue")
end

function M.tracks()
    local list = {}
    local f = io.open(M.queuelog(), "r")
    if not f then return list end
    for line in f:lines() do
        if line ~= "" then list[#list + 1] = line:match("([^/]+)$") or line end
    end
    f:close()
    return list
end

-- 一批 loadfile 攒成一个 m3u 再交给 VLC
local pending, pending_append = {}, false

local function flush()
    if #pending == 0 then return true end
    local list, append = pending, pending_append
    pending = {}
    local qlog = M.queuelog()
    local qf = io.open(qlog, append and "a" or "w")
    if qf then
        for _, p in ipairs(list) do qf:write(p, "\n") end
        qf:close()
    end
    if append then
        -- TrackList.AddTrack + NoTrack = 追加到队尾，不打断当前播放
        for _, p in ipairs(list) do
            local out, err = call(TL, "AddTrack",
                string.format('string:"file://%s" objpath:%s boolean:false', p, NO_TRACK))
            if not out then return nil, err end
        end
        return true
    end
    local path = M.sock()
    local f = io.open(path, "w")
    if not f then return nil, "写不了播放列表: " .. path end
    f:write("#EXTM3U\n")
    for _, p in ipairs(list) do f:write(p, "\n") end
    f:close()
    call(PL, "Stop")
    local out, err = call(PL, "OpenUri", "string:file://" .. path)
    return out and true or nil, err
end

-- 把 mpv 风格的命令翻译成 VLC 动作；无法映射的静默忽略。
-- 返回 { [i] = {error="success", data=...} } 保持调用方格式不变。
function M.cmd(cmds)
    local replies = {}
    for i, c in ipairs(cmds) do
        local name, a, b = c[1], c[2], c[3]
        local ok, err = true, nil
        if name == "loadfile" then
            if i == 1 then
                flush() -- 上一批（可能是 append 残留）先落地
                pending_append = (b == "append")
            end
            pending[#pending + 1] = a
        elseif name == "get_property" then
            local map = { ["pause"] = "PlaybackStatus", ["media-title"] = "Metadata", ["volume"] = "Volume" }
            local p = map[a]
            if p then
                local v = get(p)
                if a == "pause" then v = (v == "Paused") end
                replies[i] = { error = "success", data = v }
            end
        else
            local fok, ferr = flush()
            if not fok then ok, err = nil, ferr end
            if ok and name == "set_property" then
                if a == "pause" then
                    local st = status_of()
                    if st == "Playing" and b == true then ok, err = call(PL, "PlayPause")
                    elseif st == "Paused" and b == false then ok, err = call(PL, "PlayPause") end
                elseif a == "volume" then
                    ok, err = setnum("Volume", "double", (tonumber(b) or 70) / 100)
                end
                -- playlist-pos 等：VLC 从第一首开始，无需处理
            elseif name == "playlist-next" then ok, err = call(PL, "Next")
            elseif name == "playlist-prev" then ok, err = call(PL, "Previous")
            elseif name == "stop" then ok, err = call(PL, "Stop")
            elseif name == "quit" then M.sh("pkill -x vlc; pkill -x cvlc")
            elseif name == "seek" then
                ok, err = call(PL, "Seek", string.format("variant:int64:%d", math.floor((tonumber(a) or 0) * 1e6)))
            end
        end
        if ok then replies[i] = replies[i] or { error = "success" } end
    end
    local fok, ferr = flush()
    if not fok then return nil, ferr end
    return replies
end

function M.ipc(cmds) return M.cmd(cmds) end

function M.time(s)
    s = tonumber(s)
    if not s or s < 0 then return "--:--" end
    s = math.floor(s)
    if s >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60)
    end
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

function M.status()
    local st = status_of()
    if not st then return nil, "VLC (MPRIS) 未运行" end
    local meta = M.sh(base() .. " " .. PR .. ".Get string:" .. PL .. " string:Metadata", 5).output or ""
    local title = meta:match("xesam:title\"%s*\n%s*variant%s*string%s*\"(.-)\"")
    local len = meta:match("mpris:length\"%s*\n%s*variant%s*int64%s*(%d+)")
    local pos = get("Position")
    local vol = get("Volume")
    local v = {
        ["media-title"] = title,
        ["time-pos"] = pos and (pos / 1e6) or nil,
        duration = len and (tonumber(len) / 1e6) or nil,
        pause = (st == "Paused"),
        volume = vol and (vol * 100) or nil,
        ["idle-active"] = (st == "Stopped"),
    }
    return v
end

function M.describe(v)
    if not v then return "播放器未运行" end
    if v["idle-active"] then return "空闲（队列已空，VLC 在跑）" end
    local parts = { string.format("♪ %s", tostring(v["media-title"] or "?")) }
    parts[#parts + 1] = string.format("%s / %s", M.time(v["time-pos"]), M.time(v.duration))
    if v.pause then parts[#parts + 1] = "已暂停" end
    if v.volume then parts[#parts + 1] = string.format("音量 %d%%", math.floor(v.volume + 0.5)) end
    return table.concat(parts, " · ")
end

return M
