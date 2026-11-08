-- helper/usb.lua — 本机 USB 外设插件：麦克风录音 / 音箱播放 / 摄像头拍照录像 / 音量
-- 依赖：arecord aplay ffmpeg v4l2-ctl pactl（缺哪个对应 action 才报错）
-- 设备可用名字子串（"jieli" / "LC2100" / "e523"）或 "<card>,<dev>"，留空=第一个 USB 设备
local function lib(env)
    local dir = (env and env.helper_dir) or "helper"
    local ok, mod = pcall(loadfile(dir .. "/lib/usb.lua"))
    if not ok or type(mod) ~= "table" then
        error("cannot load usb lib from " .. dir .. "/lib/usb.lua: " .. tostring(mod))
    end
    return mod
end

local function need_missing(name, args)
    local miss = {}
    for _, k in ipairs(args._required or {}) do
        if args[k] == nil or args[k] == "" then miss[#miss + 1] = k end
    end
    if #miss > 0 then
        error(string.format("usb %s 缺少参数 %s — required: %s", name, table.concat(miss, ","), table.concat(args._required, ",")))
    end
end

local function devs(list, what)
    local o = {}
    for _, d in ipairs(list) do
        o[#o + 1] = { id = d.id or d.dev, name = d.card_name or d.name, label = d.label or d.name }
    end
    if #o == 0 then return "（无 " .. what .. "）" end
    local parts = {}
    for _, d in ipairs(o) do parts[#parts + 1] = d.label end
    return table.concat(parts, "; ")
end

local actions = {}

actions.list = function(U, args)
    local lines = { "mic:    " .. devs(U.mics(), "capture device") }
    lines[#lines + 1] = "speaker: " .. devs(U.speakers(), "playback device")
    local cams = {}
    for _, c in ipairs(U.cams()) do cams[#cams + 1] = c.name .. "=" .. tostring(c.dev) end
    lines[#lines + 1] = "camera: " .. (#cams > 0 and table.concat(cams, "; ") or "（无 camera）")
    local vol = U.volume({})
    if vol then lines[#lines + 1] = string.format("default sink: %s (%d%%)", vol.device, vol.percent) end
    return table.concat(lines, "\n")
end

actions.record = function(U, args)
    local ok, path, stats, dev = U.record(args)
    if not ok then error(path) end
    return string.format("recorded %ss -> %s  [%s]  max=%.1fdB mean=%.1fdB%s",
        tostring(args.seconds or 3), path, dev.id, stats.max, stats.mean,
        stats.max < -50 and "  ⚠ 近乎静音（查设备是否选对/是否静音）" or "")
end

actions.play = function(U, args)
    local ok, path, dev = U.play(args)
    if not ok then error(path) end
    return string.format("played %s -> %s [%s]", path, dev.id, dev.card_name)
end

actions.photo = function(U, args)
    local ok, path, sz, c, warn = U.photo(args)
    if not ok then error(path) end
    return string.format("photo %s (%s bytes) <- %s%s", path, tostring(sz), c.dev, warn and ("  ⚠ " .. warn) or "")
end

actions.video = function(U, args)
    local ok, path, sz, c = U.video(args)
    if not ok then error(path) end
    return string.format("video %ss -> %s (%s bytes) <- %s", tostring(args.seconds or 5), path, tostring(sz), c.dev)
end

actions.volume = function(U, args)
    local v, err = U.volume(args)
    if not v then error(err) end
    return string.format("%s %s = %d%% mute=%s", args.kind or "sink", v.device, v.percent, tostring(v.mute))
end

actions.default = function(U, args)
    local ok, name = U.set_default(args)
    if not ok then error(name) end
    return "default " .. (args.kind or "sink") .. " = " .. name
end

actions.info = function(U, args)
    local c, err = U.cam(args.cam)
    if not c then error(err) end
    local i = U.cam_info(c)
    local fmts = {}
    for _, f in ipairs(i.fmts) do fmts[#fmts + 1] = f[1] .. ":" .. f[2] end
    local sizes = {}
    for n, s in ipairs(i.sizes) do
        if n > 12 then sizes[#sizes + 1] = "..."; break end
        sizes[#sizes + 1] = s
    end
    local vol = U.volume({})
    return string.format("%s %s\nformats: %s\nsizes: %s\nsink: %s (%s%%)",
        c.name, c.dev, table.concat(fmts, ", "), table.concat(sizes, ", "),
        vol and vol.device or "?", vol and tostring(vol.percent) or "?")
end

return {
    schema = {
        name = "usb",
        description = "本机 USB 外设：麦克风录音 / 音箱播放 / 摄像头拍照录像 / 音量与默认设备。action=list 列设备。",
        parameters = {
            type = "object",
            properties = {
                action = {
                    type = "string",
                    enum = { "list", "record", "play", "photo", "video", "volume", "default", "info" },
                    description = "list=列设备; record=麦克风录音; play=音箱播放(不给 path 则 440Hz 测试音); photo=摄像头拍照; video=录像; volume=音量/静音; default=设默认设备; info=摄像头能力",
                },
                mic = { type = "string", description = "麦克风：名字子串或 <card>,<dev>，留空=第一个 USB 麦" },
                spk = { type = "string", description = "音箱：名字子串或 <card>,<dev>，留空=第一个 USB 声卡" },
                cam = { type = "string", description = "摄像头：/dev/videoN 或名字子串，留空=第一个 USB 摄像头" },
                kind = { type = "string", enum = { "sink", "source" }, description = "volume/default 作用于 sink(输出) 还是 source(输入)，默认 sink" },
                device = { type = "string", description = "pactl 设备名子串（volume/default 用，可选）" },
                level = { type = "integer", description = "volume: 设为百分比 0..150" },
                mute = { type = "boolean", description = "volume: true=静音 false=取消静音" },
                path = { type = "string", description = "play: 要播放的音频文件；photo/video: 输出路径" },
                out = { type = "string", description = "record/photo/video 输出路径（默认 /tmp/lite-usb-*.wav|jpg|mp4）" },
                seconds = { type = "integer", description = "record/video 时长秒；play 未给 path 时作为测试音时长" },
                size = { type = "string", description = "photo/video 分辨率，默认 1280x720" },
                rate = { type = "integer", description = "record 采样率，默认 48000" },
                channels = { type = "integer", description = "record 声道数，默认 1" },
                freq = { type = "integer", description = "play 测试音频率，默认 440" },
            },
        },
    },
    run = function(args, env)
        args = args or {}
        local U = lib(env)
        local name = args.action or "list"
        local fn = actions[name]
        if not fn then
            local names = {}
            for k in pairs(actions) do names[#names + 1] = k end
            table.sort(names)
            error("unknown usb action: " .. tostring(name) .. " — required: action ∈ {" .. table.concat(names, ",") .. "}")
        end
        args._required = ({ record = {}, play = {}, photo = {}, video = {} })[name] or {}
        local ok, res = pcall(fn, U, args)
        if not ok then error("usb " .. name .. ": " .. tostring(res)) end
        return res
    end,
}
