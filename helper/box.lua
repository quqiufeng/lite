-- helper/box.lua — 盒子（x96src）遥控：看电视 / 看电影 / 看书
--
-- 不需要遥控器、不需要开电视、不需要碰 framebuffer：盒子上的桌面/阅读器/播放器
-- 各自开 Unix socket，本插件 ssh 过去发一行命令收一行 JSON（见 helper/lib/box.lua）。
--
-- 典型用法：
--   box{action="state"}                       # 盒子屏幕上现在是什么
--   box{action="key", name="nav.right"}       # 发键给桌面
--   box{action="select", name="星际穿越"}      # 按名字选中（不用记序号）
--   box{action="shot"}                        # 截图拉回本机，返回路径可直接 read
--   box{action="reader", cmd="open", path="/root/书.epub"}
--   box{action="movie", path="dav:/sata11-…/片.mkv"}
--   box{action="play", cmd="pause"}
--
-- 判据（automation.lua）：外部 app（阅读器/播放器）占屏时 busy=true，此时只有
-- 「返回」还能用，其余会回 busy —— 先收掉它再操作桌面。

local function lib(env)
    local dir = (env and env.helper_dir) and (env.helper_dir .. "/lib") or "helper/lib"
    local path = dir .. "/box.lua"
    local f, e = loadfile(path)
    if not f then error("box: cannot load " .. path .. ": " .. tostring(e)) end
    return f()
end

-- 不需要电视的动作：shot/exec 只是读盒子自己的 framebuffer / 跑远端命令，
-- 电视开不开都不影响结果，硬去开电视纯属多余动作（用户口径：截图又不用开电视）。
local TV_FREE = { shot = true, exec = true }

-- 前置检查：盒子画面走 HDMI2 进电视，所以要看画面/发键之前先把电视开好、确认可操作、
-- 信号切到 HDMI2（helper/lib/sdb.lua）。这一步是硬门槛：没过就不执行动作，
-- 不然「发了键但没人看见」的静默失败最难查。TV_FREE 里的动作不做检查；
-- 排错时 args.no_tv_check=true 一律跳过。
local function tv_gate(args, env)
    if args.no_tv_check then return nil end
    if TV_FREE[args.action or ""] then return nil end
    local dir = (env and env.helper_dir) and (env.helper_dir .. "/lib") or "helper/lib"
    local f, e = loadfile(dir .. "/sdb.lua")
    if not f then return "sdb 库载入失败：" .. tostring(e) end
    local ok, S = pcall(f)
    if not ok then return "sdb 库报错：" .. tostring(S) end
    local gok, rep, changed = S.ensure{ port = tonumber(args.tv_port) or S.want_port }
    if not gok then
        local why = tostring(rep):gsub("^电视没就绪：", "")
        return "电视没就绪，box 不执行：" .. why
            .. "\n（先 sdb{action=\"ensure\"} 或手动开电视；排错可加 no_tv_check=true）"
    end
    if changed and #changed > 0 then
        return nil, "电视：" .. table.concat(changed, "、") .. " → HDMI" .. tostring(rep.port) .. "\n"
    end
    return nil, nil
end

-- 键名两套写法，别混用（白名单在 /opt/desktop/main.lua:CAPS）：
--   key  —— 裸大写名 RIGHT/OK/BACK（caps.keys 查的就是大写，nav.ok 会变成 NAV.OK 被拒）
--   click —— 小写 id  nav.ok / select.<条目> / open.<条目>（caps.click 是正则）
local KEYS = "RIGHT LEFT UP DOWN PAGEUP PAGEDOWN HOME END OK BACK MENU REFRESH ROOTS"
local KEY_ALIAS = { ENTER = "OK", RETURN = "BACK", ESC = "BACK", ESCAPE = "BACK", UP_DIR = "BACK" }
local KEY_OK = {}
for w in KEYS:gmatch("%S+") do KEY_OK[w] = true end
for k in pairs(KEY_ALIAS) do KEY_OK[k] = true end

-- "nav.right" / "right" / "RIGHT" 都收，统一成裸大写名
local function norm_key(name)
    local s = tostring(name or ""):upper():gsub("^NAV[._]", ""):gsub("^KEY[._]", "")
    return KEY_ALIAS[s] or s
end

local function yn(v)
    if v == nil then return "?" end
    return v and "是" or "否"
end

local function fmt_ms(ms)
    if not ms then return nil end
    local s = math.floor(tonumber(ms) / 1000)
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local ACTIONS = {}

-- 一句话说清「屏幕上是什么」，给微信这种窄屏看
ACTIONS.state = function(B)
    local r, err = B.desktop({ cmd = "brief" }, 6)
    if not r then return "桌面没应答：" .. tostring(err) end
    if r.ok == false then return "桌面拒绝：" .. tostring(r.error) end
    local out = {}
    local where = r.dir or "?"
    out[#out + 1] = string.format("前台 app：%s", tostring(r.app or "desktop"))
    out[#out + 1] = string.format("位置：%s（%s 项，光标第 %s）",
        where, tostring(r.count or "?"), tostring(r.pos or r.selected or "?"))
    if r.sel then
        local kind = r.sel_kind == "dir" and "目录" or (r.sel_kind or "?")
        out[#out + 1] = string.format("光标：%s [%s] %s", tostring(r.sel), kind, tostring(r.sel_size or ""))
    end
    if r.file and r.file ~= r.sel then
        out[#out + 1] = "在开：" .. tostring(r.file)
    end
    if r.media_pos or r.media_dur then
        out[#out + 1] = string.format("播放进度：%s / %s",
            fmt_ms(r.media_pos) or "?", fmt_ms(r.media_dur) or "?")
    end
    if r.book_page then
        out[#out + 1] = string.format("书页：%s / %s", tostring(r.book_page), tostring(r.book_pages or "?"))
    end
    out[#out + 1] = string.format("可用：阅读器=%s 播放器=%s 预览=%s",
        yn(r.reader), yn(r.player), yn(r.preview))
    return table.concat(out, "\n")
end

-- 完整 state（嵌套，给排错用）
ACTIONS.full = function(B)
    local r, err = B.desktop({ cmd = "state" }, 6)
    if not r then return "桌面没应答：" .. tostring(err) end
    local ok, enc = pcall(require("cjson").encode, r.state or r)
    return ok and enc or "state 解码失败"
end

-- 可用动作清单（光标落在不同条目上 select.* 会变）
ACTIONS.list = function(B)
    local r, err = B.desktop({ cmd = "list" }, 6)
    if not r then return "桌面没应答：" .. tostring(err) end
    local a = r.actions or {}
    local nav, sel = {}, {}
    for _, v in ipairs(a) do
        if tostring(v):match("^select%.") then sel[#sel + 1] = v
        else nav[#nav + 1] = v end
    end
    return "导航键：\n  " .. table.concat(nav, "  ")
        .. string.format("\nselect.* 共 %d 个（按名字选中请用 action=select，别手写）", #sel)
end

ACTIONS.key = function(B, args)
    local name = norm_key(args.name)
    if name == "" then return "key 需要 name（" .. KEYS .. "）" end
    if not KEY_OK[name] then
        return "不认识的键 " .. name .. "；可用：" .. KEYS .. "（enter/esc 这类别名会映射成 OK/BACK）"
    end
    local r, err = B.desktop({ cmd = "key", name = name }, 8)
    if not r then return "发键失败：" .. tostring(err) end
    if r.ok == false then return "被拒：" .. tostring(r.error) end
    -- changed 来自盒子自己算的状态指纹：比「发完就当成功」可信
    local moved = r.changed == true and "状态已变"
        or (r.changed == false and "状态没变（到头了？）" or "")
    return "已发 " .. name .. (moved ~= "" and (" · " .. moved) or "")
end

ACTIONS.click = function(B, args)
    local r, err = B.desktop({ cmd = "click", id = args.id }, 8)
    if not r then return "点击失败：" .. tostring(err) end
    if r.ok == false then return "被拒：" .. tostring(r.error) end
    return "已点击 " .. tostring(args.id)
end

-- 按名字选中：省掉「先 list 再抄 id」那一步
ACTIONS.select = function(B, args)
    local name = tostring(args.name or "")
    if name == "" then return "select 需要 name" end
    local r, err = B.desktop({ cmd = "click", id = "select." .. name }, 8)
    if not r then return "选中失败：" .. tostring(err) end
    if r.ok == false then return "选中被拒：" .. tostring(r.error) .. "（名字要和 list 里 select.* 完全一致）" end
    return "已选中 " .. name .. "（再 nav.ok 才是打开）"
end

-- 截图 + 拉回本机，返回本地路径（图片可直接 read）
ACTIONS.shot = function(B, args, env)
    local out = args.out
    if not out or out == "" then
        -- 默认落 ~（不是 /tmp）：截出来就是给人看/给别的工具用的，别放会被清的目录
        local home = os.getenv("HOME") or os.getenv("TMPDIR") or "/tmp"
        out = string.format("%s/box-shot-%s.png", home, os.date("%Y%m%d-%H%M%S"))
    end
    local app = args.app or "desktop"
    local p, err = B.capture(app, nil, out)
    if not p then return "截图失败：" .. tostring(err) end
    return "截图 -> " .. p .. "（read 这个路径看图）"
end

ACTIONS.reader = function(B, args)
    local cmd = args.cmd or "state"
    if cmd == "open" then
        if not args.path or args.path == "" then return "reader open 需要 path" end
        local r, err = B.reader({ cmd = "call", fn = "openBook", args = { path = args.path } }, 20)
        if not r then return "阅读器没应答：" .. tostring(err) end
        if r.ok == false then return "打开失败：" .. tostring(r.error) end
        return "已在阅读器打开 " .. args.path
    end
    local payload = { cmd = cmd }
    if args.id then payload.id = args.id end
    if args.fn then payload.fn = args.fn end
    if args.args then payload.args = args.args end
    local r, err = B.reader(payload, 10)
    if not r then return "阅读器没应答（没起？用 box{action=\"exec\",cmd=\"ls /opt/reader\"} 看）：" .. tostring(err) end
    local ok, enc = pcall(require("cjson").encode, r)
    return ok and enc or tostring(r)
end

ACTIONS.play = function(B, args)
    local cmd = args.cmd or "status"
    if args.seconds then cmd = cmd .. " " .. tostring(args.seconds) end
    if args.delta then cmd = cmd .. " " .. tostring(args.delta) end
    local r, err = B.player(cmd, 8)
    if not r then return "播放器没应答（没在播？）：" .. tostring(err) end
    local ok, enc = pcall(require("cjson").encode, r)
    return ok and enc or tostring(r)
end

ACTIONS.movie = function(B, args)
    if not args.path or args.path == "" then return "movie 需要 path（NAS 路径或盒子本地路径）" end
    local out = B.movie(args.path, args.from, args.seconds)
    return "已起片：" .. args.path .. "\n" .. tostring(out or ""):gsub("%s+$", "")
end

ACTIONS.exec = function(B, args)
    if not args.cmd or args.cmd == "" then return "exec 需要 cmd" end
    local out = B.exec(args.cmd, args.timeout or 20)
    out = tostring(out or ""):gsub("%s+$", "")
    if out == "" then return "(无输出)" end
    return out
end

local SCHEMA = {
    name = "box",
    description = "盒子（x96src）遥控：state 看屏幕上是什么 / key 发键(nav.right,nav.ok…) / select 按名字选中 "
        .. "/ shot 截图拉回本机 / reader 阅读器 / play 播放器控制 / movie 起片 / exec 逃生口。"
        .. "走盒子上 app 自带的 automation socket（ssh 过去发一行收一行），不用 xdotool 抓屏。",
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                enum = { "state", "full", "list", "key", "click", "select", "shot", "reader", "play", "movie", "exec" },
                description = "要执行的动作（默认 state）",
            },
            name = { type = "string", description = "key: 键名；select: 条目名（与 list 里 select.* 一致）" },
            id = { type = "string", description = "click: action id，如 select.星际穿越 / nav.ok" },
            cmd = { type = "string", description = "reader/play: 子命令（reader: ping|list|state|click|call；play: status|pause|resume|toggle|mute|vol|seek|quit）；exec: 远端命令" },
            path = { type = "string", description = "reader open / movie 的文件路径（可 dav:/… NAS 路径）" },
            fn = { type = "string", description = "reader call: 函数名" },
            args = { type = "object", description = "reader call: 参数对象" },
            seconds = { type = "number", description = "play seek: 秒数；movie: 播放时长" },
            delta = { type = "number", description = "play vol/seek: 相对量，如 -10" },
            out = { type = "string", description = "shot: 本地输出 png 路径（默认 ~/box-shot-<时间>.png）" },
            app = { type = "string", description = "shot: desktop(默认) 或 reader" },
            timeout = { type = "number", description = "exec: 超时秒，默认 20" },
            no_tv_check = { type = "boolean", description = "排错用：跳过电视前置检查（默认每次先 sdb ensure：开电视 + 确认可操作 + 信号在 HDMI2）" },
            tv_port = { type = "number", description = "电视 HDMI 口号，默认 2" },
        },
        required = { "action" },
    },
}

return {
    schema = SCHEMA,
    run = function(args, env)
        args = args or {}
        local action = args.action or "state"
        local fn = ACTIONS[action]
        if not fn then
            local names = {}
            for k in pairs(ACTIONS) do names[#names + 1] = k end
            table.sort(names)
            return "box: unknown action " .. tostring(action) .. "; 可用: " .. table.concat(names, "|")
        end
        local ok, B = pcall(lib, env)
        if not ok then return "error: box 载入 lib 失败: " .. tostring(B) end
        local block, note = tv_gate(args, env)
        if block then return block end
        local ok2, res = pcall(fn, B, args, env)
        if not ok2 then return "error: box " .. action .. ": " .. tostring(res) end
        return (note or "") .. res
    end,
}
