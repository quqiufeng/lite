-- helper/music.lua — 放歌：后台常驻 VLC（play/pause/next/volume/seek/playlist）
-- 逻辑在 helper/lib/music.lua（VLC + MPRIS over dbus-send，无外部守护依赖）
local function lib(env)
    local dir = (env and env.helper_dir) or "helper"
    local ok, mod = pcall(loadfile(dir .. "/lib/music.lua"))
    if not ok or type(mod) ~= "table" then
        error("cannot load music lib from " .. dir .. "/lib/music.lua: " .. tostring(mod))
    end
    return mod
end

-- WebDAV 无损曲库（PROPFIND + 按需下载，凭据只在内存）
local function wdlib(env)
    local dir = (env and env.helper_dir) or "helper"
    local ok, mod = pcall(loadfile(dir .. "/lib/webdav.lua"))
    if not ok or type(mod) ~= "table" then
        error("cannot load webdav lib from " .. dir .. "/lib/webdav.lua: " .. tostring(mod))
    end
    return mod
end

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function expand(p)
    if p:sub(1, 1) == "~" then
        local home = os.getenv("HOME") or "/root"
        p = home .. p:sub(2)
    end
    return p
end

local function is_dir(p)
    local r = io.popen("test -d " .. q(p) .. " && echo dir")
    local out = r:read("*a") or ""
    r:close()
    return out:find("dir", 1, true) ~= nil
end

local function exists(p)
    local f = io.open(p, "rb")
    if not f then return false end
    f:close()
    return true
end

-- 曲库检索 → 编号列表（最多 20 条）
local function search_list(env, kw, limit)
    local wd = env and wdlib(env)
    local hits, err = wd.search(kw)
    if not hits then error(err) end
    local lines = {}
    for i = 1, math.min(#hits, limit or 20) do
        lines[#lines + 1] = string.format("%d. %s", i, (hits[i].name:gsub("%.[%w]+$", "")))
    end
    return hits, lines
end

-- 把 VLC 窗口提到前台（无 DISPLAY / 找不到窗口就静默跳过，不影响播放）
local function front()
    local ok, x11 = pcall(require, "ffi.x11")
    if not ok or type(x11) ~= "table" then return false end
    for _ = 1, 40 do
        local ok2, w = pcall(x11.window_class, "vlc")
        if ok2 and w then
            pcall(function() w:activate() end)
            return true
        end
        os.execute("sleep 0.15")
    end
    return false
end

-- 播放前自动退出语音模式（否则麦克风会把歌声当人声转成文字）
local function mute_voice()
    local ok, vm = pcall(require, "core.voice")
    if not ok or type(vm) ~= "table" or not vm.running or not vm.running() then return false end
    pcall(vm.stop)
    return true
end

local actions = {}

actions.front = function(M)
    if not front() then return "找不到播放器窗口（无 DISPLAY 或窗口未创建）" end
    return "已把播放器窗口切到前台"
end

actions.play = function(M, args, env)
    local src = args.source or args.path
    if not src or src == "" then error("music play 需要 source（文件/目录/URL/曲名关键词） — required: source") end
    src = expand(src)
    local files, label
    local is_url = src:match("^%a[%w+.-]*://") ~= nil
    if not is_url and is_dir(src) then
        local res, derr = M.playlist_files(src)
        if not res then error(derr) end
        files = res
    elseif not is_url and not exists(src) then
        -- 不是本地路径 → 当曲库关键词：WebDAV 检索 + 按需下载到 /tmp/lite-music-cache
        local wd = wdlib(env)
        local hits, lines = search_list(env, src)
        if #hits == 0 then
            error("曲库里没有匹配「" .. src .. "」的歌 — 换更短的关键词，或用 action=search 看看有什么")
        end
        local idx = args.index
        if not idx and #hits == 1 then idx = 1 end
        if not idx then
            return string.format("「%s」匹配 %d 首，选一首再放（play 加 index=N）：\n%s",
                src, #hits, table.concat(lines, "\n"))
        end
        local hit = hits[idx]
        if not hit then error("index 超出范围（1.." .. #hits .. "）") end
        local p, derr = wd.fetch(hit.href)
        if not p then error("下载「" .. hit.name .. "」失败: " .. tostring(derr)) end
        files = { p }
        label = hit.name
    elseif is_url and src:match("^davs?://") then
        -- dav://host:port/路径 → 列目录 → 直接流播（不下载；默认整库随机）
        local wd = wdlib(env)
        local entries, lerr = wd.list_at(src)
        if not entries then error(tostring(lerr)) end
        local dirname = src:gsub("/+$", ""):match("([^/]+)$") or src
        if args.index then
            local hit = entries[args.index]
            if not hit then error("index 超出范围（1.." .. #entries .. "）") end
            files = { wd.auth_url(hit.url) }
            label = hit.name
        else
            files = {}
            for i, e in ipairs(entries) do
                if args.limit and i > args.limit then break end
                files[#files + 1] = wd.auth_url(e.url)
            end
            if args.shuffle == nil then args.shuffle = true end
            label = dirname .. "（流播）"
        end
    else
        files = { src }
    end
    if args.shuffle then
        math.randomseed(os.time())
        for i = #files, 2, -1 do
            local j = math.random(i)
            files[i], files[j] = files[j], files[i]
        end
    end
    mute_voice()
    local ok, err = M.ensure()
    if not ok then error(err) end
    local mode = args.append and "append" or "replace"
    local cmds = {}
    for i, f in ipairs(files) do
        cmds[#cmds + 1] = { "loadfile", f, i == 1 and mode or "append" }
    end
    if not args.append then cmds[#cmds + 1] = { "set_property", "playlist-pos", 0 } end
    cmds[#cmds + 1] = { "set_property", "pause", false }
    local r, cerr = M.cmd(cmds, 5)
    if not r then error(cerr) end
    -- 等 time-pos 就绪再回状态，避免刚起播显示 --:--
    -- VLC 冷启动 + 解码起播可能要几秒，等 MPRIS 真的不进 idle 再回状态
    for _ = 1, 80 do
        local v = M.status()
        if v and v["time-pos"] and v["idle-active"] == false then break end
        os.execute("sleep 0.1")
    end
    local st = M.status() or {}
    front()
    return string.format("开始播放 %s（%d 首%s）\n%s",
        label or files[1]:match("[^/]+$") or files[1], #files,
        args.append and "，追加到队列" or "", M.describe(st))
end

actions.pause = function(M)
    local r, err = M.cmd({ { "set_property", "pause", true } })
    if not r then error(err) end
    return "已暂停 · " .. M.describe(M.status())
end

actions.resume = function(M)
    local r, err = M.cmd({ { "set_property", "pause", false } })
    if not r then error(err) end
    return "继续播放 · " .. M.describe(M.status())
end

actions.toggle = function(M)
    local v, err = M.status()
    if not v then error(err) end
    local want = not v.pause
    local r, e2 = M.cmd({ { "set_property", "pause", want } })
    if not r then error(e2) end
    return (want and "已暂停" or "继续播放") .. " · " .. M.describe(M.status())
end

actions.next = function(M)
    local r, err = M.cmd({ { "playlist-next", "weak" } })
    if not r then error(err) end
    os.execute("sleep 0.4")
    return "下一首 · " .. M.describe(M.status())
end

actions.prev = function(M)
    local r, err = M.cmd({ { "playlist-prev", "weak" } })
    if not r then error(err) end
    os.execute("sleep 0.4")
    return "上一首 · " .. M.describe(M.status())
end

actions.stop = function(M)
    local r, err = M.cmd({ { "stop" } })
    if not r then error(err) end
    return "已停止（守护进程仍在，下次 play 秒开）"
end

actions.quit = function(M)
    if not M.running() then return "播放器本来就没在跑" end
    pcall(M.cmd, { { "quit" } })
    return "已关闭播放器守护进程"
end

actions.status = function(M)
    local v, err = M.status()
    if not v then
        return "播放器未运行（用 music action=play 启动）"
    end
    return M.describe(v)
end

actions.volume = function(M, args)
    local v, err = M.status()
    if not v then error(err) end
    local cur = tonumber(v.volume) or 70
    local level
    if args.level then
        level = math.max(0, math.min(150, args.level))
    elseif args.delta then
        level = math.max(0, math.min(150, cur + args.delta))
    else
        return string.format("当前音量 %d%%（给 level=0..150 或 delta=±10 改）", math.floor(cur + 0.5))
    end
    local r, e2 = M.cmd({ { "set_property", "volume", level } })
    if not r then error(e2) end
    return string.format("音量 %d%% → %d%%", math.floor(cur + 0.5), level)
end

actions.seek = function(M, args)
    local d = args.delta or args.seconds
    if not d then error("music seek 需要 delta（秒，可负） — required: delta") end
    local r, err = M.cmd({ { "seek", d, "relative" } })
    if not r then error(err) end
    os.execute("sleep 0.3")
    return string.format("跳 %+ds · %s", d, M.describe(M.status()))
end

actions.playlist = function(M)
    local v = M.status()
    if not v then return "播放器未运行" end
    if v["idle-active"] then return "队列是空的" end
    local cur = tostring(v["media-title"] or "?")
    local lines = { string.format("▶ %s · %s / %s", cur, M.time(v["time-pos"]), M.time(v.duration)) }
    local q = M.tracks and M.tracks() or {}
    if #q > 0 then
        lines[#lines + 1] = string.format("队列 %d 首：", #q)
        for i, name in ipairs(q) do
            local stem = name:gsub("%.[%w]+$", "")
            local is_cur = stem:find(cur, 1, true) or cur:find(stem, 1, true)
            lines[#lines + 1] = string.format("%s %d. %s", is_cur and "▶" or " ", i, stem)
        end
    end
    return table.concat(lines, "\n")
end

actions.search = function(_, args, env)
    local kw = args.source or args.path or args.keyword
    if not kw or kw == "" then error("music search 需要 source（关键词） — required: source") end
    local wd = wdlib(env)
    local hits, err = wd.search(kw)
    if not hits then error(err) end
    if #hits == 0 then return "曲库里没有匹配「" .. kw .. "」的歌" end
    local lines = { string.format("曲库「%s」匹配 %d 首：", kw, #hits) }
    for i = 1, math.min(#hits, 20) do
        lines[#lines + 1] = string.format("%d. %s", i, (hits[i].name:gsub("%.[%w]+$", "")))
    end
    if #hits > 20 then lines[#lines + 1] = string.format("…另有 %d 首未列出", #hits - 20) end
    lines[#lines + 1] = "放其中一首：action=play source=\"关键词\" index=N"
    return table.concat(lines, "\n")
end

actions.devices = function(M)
    local r = M.sh("pactl list short sinks 2>/dev/null", 10)
    local out = { "系统输出设备（VLC 跟随系统默认 sink）：" }
    for line in (r.output or ""):gmatch("[^\r\n]+") do out[#out + 1] = "  " .. line end
    out[#out + 1] = "切换输出：pactl set-default-sink <sink名>（VLC 跟随系统默认）"
    return table.concat(out, "\n")
end

return {
    schema = {
        name = "music",
        description = "放歌：后台常驻 VLC，支持播放文件/目录/网络流、暂停继续、上一首下一首、音量、跳转、队列、状态。action 默认 status。",
        parameters = {
            type = "object",
            properties = {
                action = {
                    type = "string",
                    enum = { "play", "pause", "resume", "toggle", "next", "prev", "stop", "status", "volume", "seek", "playlist", "quit", "devices", "search" },
                    description = "play=播放(本地路径/URL或曲库关键词); pause/resume/toggle; next/prev=切歌; stop=停止; status=状态; volume=音量; seek=跳转; playlist=队列; search=搜曲库; quit=关播放器; devices=列输出设备",
                },
                source = { type = "string", description = "play: 文件路径 / 目录（递归找音频）/ http(s) URL 或广播流 / 曲库关键词（如「九月九」）；search: 关键词" },
                index = { type = "integer", description = "play: 关键词命中多首时选第几首（先不带 index 看列表）" },
                append = { type = "boolean", description = "play: true=追加到现有队列（默认替换）" },
                shuffle = { type = "boolean", description = "play: 目录/多文件时是否打乱（dav:// 目录默认 true）" },
                limit = { type = "integer", description = "play: dav:// 目录最多取几首（默认整个目录，边播边取不下载）" },
                level = { type = "integer", description = "volume: 直接设为 0..150" },
                delta = { type = "integer", description = "volume: 相对调整（如 +10 / -10）；seek: 相对秒数（如 30 / -15）" },
                seconds = { type = "integer", description = "seek: 同 delta" },
            },
        },
    },
    run = function(args, env)
        args = args or {}
        local M = lib(env)
        local name = args.action or "status"
        local fn = actions[name]
        if not fn then
            local names = {}
            for k in pairs(actions) do names[#names + 1] = k end
            table.sort(names)
            error("unknown music action: " .. tostring(name) .. " — required: action ∈ {" .. table.concat(names, ",") .. "}")
        end
        local ok, res = pcall(fn, M, args, env)
        if not ok then error("music " .. name .. ": " .. tostring(res)) end
        return res
    end,
}
