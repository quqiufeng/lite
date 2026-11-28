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
--   box{action="book", cmd="text"}            # 当前页正文（走盒子上的 reader-agent）
--   box{action="book", cmd="read", n=5}       # 连读 5 页（JSON）
--   box{action="browser", cmd="open", url="https://news.ycombinator.com"}
--   box{action="browser", cmd="js", js="document.title"}
--   box{action="browser", cmd="shot"}          # 网页视口截图拉回本机
--   box{action="browser", cmd="pages"}         # 有几个 page / 各自 url
--   box{action="keybd", cmd="state"}           # 遥控守护现在把键派给谁
--   box{action="call", fn="reader.next"}       # 桌面白名单里的 call 原语
--   box{action="movie", path="dav:/sata11-…/片.mkv"}
--   box{action="play", cmd="pause"}
--
-- 三条链各走各的壳（都已在盒子上封装好，本插件只负责 ssh 到位 + 传参）：
--   reader-agent → /opt/reader/tools/reader-agent（自带 LUA_CPATH，cjson 在 /opt/reader/lib）
--   浏览器       → /root/cdp/cdp_do.lua（零依赖 CDP 执行器，端口 9222）
--   遥控键       → /tmp/keybd.sock（一行 JSON 一问一答）
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
-- browser/book/keybd/call 同理：CDP 截图、读正文、查遥控守护、调 call 原语都不经过
-- HDMI 那一路，先开电视只会让「查一眼」变成「等电视醒」。
local TV_FREE = { shot = true, exec = true, browser = true, book = true, keybd = true, call = true }

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

local function encode(v)
    local ok, s = pcall(require("cjson").encode, v)
    return ok and s or tostring(v)
end

-- cdp_do.lua 的日志一行一类：[page]/[load]/[js]/[info]/[shot]。取最后一条同类即可
-- （同一类可能打两次：截图的 [page] 与导航的 [page]）。
local function last_line(out, tag)
    local val
    for line in tostring(out or ""):gmatch("[^\r\n]+") do
        local v = line:match("^%[" .. tag .. "%]%s*(.*)$")
        if v then val = v end
    end
    return val
end

-- 有 [js]/[info] 就只回那一块（窄屏友好）；出错把整份 log 原样给，里面有 [js:err]/ERROR。
-- 注意 js 结果可能是**多行**（innerText），所以不能用「取最后一条 [js] 行」那种写法：
-- 从标记处取到 [done] 之前，否则正文只剩第一行（踩过：YouTube 正文只回了 "HK"）。
local function block_after(out, tag)
    out = tostring(out or "")
    local s = out:find("%[" .. tag .. "%]%s*")
    if not s then return nil end
    local body = out:sub(s):gsub("^%[[^%]]+%]%s*", "")
    body = body:gsub("\n%[done%].*$", "")
    body = body:gsub("%s+$", "")
    if body == "" then return nil end
    return body
end

local function format_cdp(out)
    local v = block_after(out, "js") or block_after(out, "info")
    if v then return v end
    out = tostring(out or ""):gsub("%s+$", "")
    if out == "" then return "CDP 无输出（chromium 起了吗？box{action=\"browser\",cmd=\"pages\"}）" end
    return out
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

-- 桌面白名单里的 call 原语（select 之类被 caps 拒掉的就走这条，id 由调用方给全）
ACTIONS.call = function(B, args)
    if not args.fn or args.fn == "" then return "call 需要 fn（如 reader.next / nav.back / select.星际穿越）" end
    local payload = args.args or {}
    local r, err = B.desktop({ cmd = "call", fn = args.fn, args = payload }, args.timeout or 15)
    if not r then return "桌面没应答：" .. tostring(err) end
    local ok, enc = pcall(require("cjson").encode, r)
    if not ok then return tostring(r) end
    return (r.ok == false) and ("call 被拒：" .. enc) or enc
end

-- 遥控守护（/tmp/keybd.sock）：看它现在把键派给谁、有哪些 app、强行 focus
-- 坑：socket 认 `name`（evdev 名 RIGHT/ENTER/BACK…），不认 `key`；写错字段它回
-- "unknown key: "（名字是空串），看着像键名不存在，其实是字段名不对。
local NAV_ALIAS = {
    ["nav.right"] = "RIGHT", ["nav.left"] = "LEFT", ["nav.up"] = "UP", ["nav.down"] = "DOWN",
    ["nav.ok"] = "OK", ["ok"] = "OK", ["back"] = "BACK", ["enter"] = "ENTER", ["menu"] = "MENU",
    ["home"] = "HOME", ["end"] = "END", ["pageup"] = "PAGEUP", ["pagedown"] = "PAGEDOWN",
    ["tab"] = "TAB", ["esc"] = "ESC", ["space"] = "SPACE", ["f5"] = "F5",
}
local function key_name(s)
    s = tostring(s or "")
    if s == "" then return "" end
    return NAV_ALIAS[s:lower()] or s:upper()
end

ACTIONS.keybd = function(B, args)
    local cmd = args.cmd or "state"
    local ok_cmd = { state = true, apps = true, key = true, focus = true, learn = true,
        reload = true, rescan = true, quit = true }
    if not ok_cmd[cmd] then return "keybd 不认 " .. tostring(cmd) .. "；可用: state|apps|key|focus|learn|reload|rescan|quit" end
    local payload = { cmd = cmd }
    if args.name then payload.name = key_name(args.name) end
    if args.id then payload.app = args.id end
    if args.delta then payload.delta = args.delta end
    -- learn 的开关是 on:true/false（arity 由 n 给：n=0 关，其余开）
    if cmd == "learn" then payload.on = (tonumber(args.n) ~= 0) end
    local r, err = B.keybd(payload, args.timeout or 8)
    if not r then return "遥控守护没应答（keybd 没起？）：" .. tostring(err) end
    local ok, enc = pcall(require("cjson").encode, r)
    return ok and enc or tostring(r)
end

-- 浏览器：走盒子上的 cdp_do.lua（CDP，端口默认 9222）
ACTIONS.browser = function(B, args)
    local cmd = args.cmd or "pages"
    if cmd == "pages" or cmd == "list" then
        local v, err = B.cdp_pages()
        if not v then return tostring(err) end
        if #v == 0 then return "CDP 通了但没有 page（浏览器没开窗？）" end
        local lines = { string.format("%d 个 page：", #v) }
        for i, p in ipairs(v) do
            lines[#lines + 1] = string.format("%d. %s — %s", i, tostring(p.url or "?"), tostring(p.title or ""))
        end
        return table.concat(lines, "\n")
    end
    if cmd == "open" or cmd == "nav" or cmd == "goto" then
        if not args.url or args.url == "" then return "browser open 需要 url" end
        local out = B.cdp(args.url, nil, { timeout = args.timeout or 45 })
        local page = last_line(out, "page")
        if not page then return format_cdp(out) end
        -- 导航完顺手问一句落到的 title/href（cdp_do 不给 js 时自己会打过）
        local info = last_line(out, "info")
        return info and (page .. "\n" .. info) or page
    end
    if cmd == "js" then
        if not args.js or args.js == "" then return "browser js 需要 js 表达式，如 document.title" end
        local out = B.cdp("-", args.js, { timeout = args.timeout or 30 })
        return format_cdp(out)
    end
    if cmd == "text" then
        local expr = args.js
            or "document.body.innerText.replace(/\\n{3,}/g,'\\n\\n').slice(0,4000)"
        local out = B.cdp("-", expr, { timeout = args.timeout or 35 })
        return format_cdp(out)
    end
    if cmd == "shot" then
        local remote = (args.path and args.path ~= "") and args.path or "/tmp/lite-box-web.png"
        local out = B.cdp("-", "@shot", { shot = remote, timeout = args.timeout or 45 })
        local line = last_line(out, "shot")
        if not line then return "截图失败：" .. format_cdp(out) end
        local stamp = os.date("%Y%m%d-%H%M%S")
        local local_path = (args.out and args.out ~= "") and args.out
            or (os.getenv("HOME") or "/tmp") .. "/box-web-" .. stamp .. ".png"
        local p, sz = B.pull(remote, local_path)
        if not p then return "截图出了但拉回失败：" .. tostring(sz) end
        return string.format("已截网页并拉回本机：%s（%d 字节，可直接 read）", p, sz)
    end
    return "browser 不认 " .. tostring(cmd) .. "；可用: pages|open|js|text|shot"
end

-- 阅读器正文通道：走盒子上的 reader-agent（它自带 LUA_CPATH，cjson 在 /opt/reader/lib）
-- 与 action=reader（native socket）差别：reader 是「点按键」，book 是「拿文本」。
local BOOK_ARGV = {
    ["state"] = {}, ["launch"] = {}, ["text"] = {}, ["toc"] = {}, ["bookmark"] = {},
    ["settings"] = {}, ["snapshot"] = {},
    ["open"] = { "path", "page" }, ["read"] = { "n" }, ["next"] = { "n" },
    ["goto"] = { "page" }, ["goto-chapter"] = { "chapter", "page" },
    ["toc.open"] = {}, ["toc.select"] = { "idx" }, ["toc.activate"] = { "idx" },
    ["settings.open"] = {}, ["settings.adjust"] = { "idx", "delta" },
    ["capture"] = { "path" },
}

ACTIONS.book = function(B, args)
    local cmd = args.cmd or "text"
    local fields = BOOK_ARGV[cmd]
    if not fields then
        local names = {}
        for k in pairs(BOOK_ARGV) do names[#names + 1] = k end
        table.sort(names)
        return "book 不认 " .. tostring(cmd) .. "；可用: " .. table.concat(names, "|")
    end
    local argv = { cmd }
    for _, f in ipairs(fields) do
        local v = args[f]
        if v ~= nil and v ~= "" then argv[#argv + 1] = tostring(v) end
    end
    local remote = (cmd == "capture")
        and ((args.path and args.path ~= "" and args.path) or "/tmp/lite-box-book.png") or nil
    if remote and argv[2] ~= remote then argv[2] = remote end
    local box_reply = B.reader_agent(argv, args.timeout or 60)
    local out = tostring(box_reply or ""):gsub("%s+$", "")
    if out == "" then return "reader-agent 没输出（阅读器没起？先 book cmd=state 或 action=reader cmd=ping）" end
    -- cmd=capture 就拉回本机（判据用 cmd，不是靠输出里出现 "capture"：
    -- reader-agent 的 capture 只回 {"path":…,"ok":true}，按输出找关键词永远拉不回来）
    -- path = 盒子上的落图路径，out = 本机路径；两者别混用（写反了会两边都不存在）
    if remote then
        local stamp = os.date("%Y%m%d-%H%M%S")
        local local_path = (args.out and args.out ~= "" and args.out)
            or ((os.getenv("HOME") or "/tmp") .. "/box-book-" .. stamp .. ".png")
        local p, sz = B.pull(remote, local_path)
        if p then return string.format("%s\n已拉回本机：%s（%d 字节）", out, p, sz) end
        return out .. "\n（拉回失败，盒子上的图在 " .. remote .. "；没出图就看 out 是不是写成了盒子路径）"
    end
    return out
end

local SCHEMA = {
    name = "box",
    description = "盒子（x96src）遥控：state 看屏幕上是什么 / key 发键(nav.right,nav.ok…) / select 按名字选中 "
        .. "/ shot 截图拉回本机 / reader 阅读器按键 / book 阅读器正文(toc/text/read/goto) / "
        .. "browser 浏览器 CDP(pages/open/js/text/shot) / play 播放器控制 / movie 起片 / keybd 遥控守护 / "
        .. "call 桌面 call 原语 / exec 逃生口。"
        .. "走盒子上现成的 automation socket 与已封装脚本（ssh 过去发一行收一行，luajit -e 带好 LUA_PATH），"
        .. "不用 xdotool 抓屏、不复刻协议。",
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                enum = { "state", "full", "list", "key", "click", "select", "shot", "reader", "book",
                    "browser", "play", "movie", "keybd", "call", "exec" },
                description = "要执行的动作（默认 state）",
            },
            name = { type = "string",
                description = "key: 键名；select: 条目名（与 list 里 select.* 一致）；"
                    .. "keybd key: evdev 键名 RIGHT/LEFT/UP/DOWN/OK/ENTER/BACK/MENU…（nav.ok 这类别名也认）" },
            id = { type = "string", description = "click: action id，如 select.星际穿越 / nav.ok；keybd focus: app 名" },
            cmd = { type = "string",
                description = "reader: ping|list|state|click|call；book: state|open|text|read|next|goto|"
                    .. "goto-chapter|toc|toc.open|toc.select|toc.activate|settings|bookmark|capture|snapshot；"
                    .. "browser: pages|open|js|text|shot；play: status|pause|resume|toggle|mute|vol|seek|quit；"
                    .. "keybd: state|apps|key|focus|reload|rescan|learn；exec: 远端命令" },
            path = { type = "string", description = "reader/book open: 书路径；movie: 片路径（可 dav:/… NAS）；browser shot: 盒子上的落图路径" },
            url = { type = "string", description = "browser open: 要导航的网址" },
            js = { type = "string", description = "browser js: JS 表达式（如 document.title）；browser text: 可覆盖取正文表达式" },
            fn = { type = "string", description = "reader call / call: 函数名" },
            args = { type = "object", description = "reader call / call: 参数对象" },
            n = { type = "number", description = "book read/next: 页数，默认 1" },
            page = { type = "number", description = "book open/goto/goto-chapter: 页码（从 1 起）" },
            chapter = { type = "number", description = "book goto-chapter: 第几章" },
            idx = { type = "number", description = "book toc.select/toc.activate/settings.adjust: 条目序号" },
            seconds = { type = "number", description = "play seek: 秒数；movie: 播放时长" },
            delta = { type = "number", description = "play vol/seek / keybd: 相对量，如 -10" },
            out = { type = "string", description = "shot/browser shot/book capture: 本地输出 png 路径（默认 ~/box-*.png）" },
            app = { type = "string", description = "shot: desktop(默认) 或 reader" },
            timeout = { type = "number", description = "远端超时秒（exec 默认 20，book 默认 60，browser 默认 30-45）" },
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
