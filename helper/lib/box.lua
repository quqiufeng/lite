-- helper/lib/box.lua — 盒子（x96src）三个自动化 socket 的胶水层
--
-- 盒子上的 app 各自开 Unix socket（不是 xdotool 抓屏），协议极简：**发一行、收一行**。
--   /tmp/desktop-automation.sock      桌面：JSON  {"cmd":"brief|state|list|click|key|call"}
--   /tmp/native-reader-automation.sock 阅读器：JSON {"cmd":"ping|list|state|click|call"}
--   /tmp/play.sock                    播放器：**纯文本** status|pause|resume|vol ±N|seek N|quit
-- 三类都是「一行去一行回」，所以只用一条 python 转发脚本，不复刻协议。
--
-- 为什么用 python3 而不是 socat/nc：盒子上两个都没装（走过一次弯路：把"socat 缺失"
-- 读成了"socket 已死"）。python3 是盒子上现成的，socket 模块直接可用。
-- 为什么把脚本先落到 /tmp 再调用、而不是每次 `python3 -c`：ssh 会把命令串交给远端
-- shell 再解析一遍，嵌套引号在 JSON 载荷上必踩坑。落一次盘，之后只传裸路径。
--
-- 全部操作走 ssh（免密已配好）。主机名可用 LITE_BOX_HOST 覆盖。

local cjson = require("cjson")

local M = {}

M.host = os.getenv("LITE_BOX_HOST") or "x96src"
M.DESKTOP = "/tmp/desktop-automation.sock"
M.READER = "/tmp/native-reader-automation.sock"
M.PLAY = "/tmp/play.sock"

local PY_PATH = "/tmp/lite-box-sock.py"

-- 一行去一行回。不要在这里加单引号：脚本要能被外层 shell 安全包裹。
-- 第一行是版本戳：盒子上可能留着旧脚本，ensure_py 靠它判断要不要覆盖
-- （只判 test -s 会被旧版本卡住，改完不生效——踩过一次）。
local PY_VER = "lite-box-sock v2"
local PY = [[
# lite-box-sock v2
import socket, sys
p = sys.stdin.read()
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(float(sys.argv[2]) if len(sys.argv) > 2 else 8.0)
    s.connect(sys.argv[1])
except OSError as e:
    # 缺 socket ≠ 协议错：单独给哨兵，别让调用方看见 traceback
    sys.stdout.write("__SOCKERR__ " + type(e).__name__)
    sys.exit(0)
try:
    s.sendall((p.strip() + "\n").encode())
    b = b""
    while b"\n" not in b:
        d = s.recv(65536)
        if not d:
            break
        b += d
except OSError as e:
    sys.stdout.write("__SOCKERR__ " + type(e).__name__)
    sys.exit(0)
s.close()
sys.stdout.write(b.decode("utf-8", "replace"))
]]

local function shq(s)
    s = tostring(s or "")
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- 跑远端命令。stdin_data 走临时文件重定向（io.popen 不能同时喂 stdin 和读 stdout）。
local function ssh(remote_cmd, stdin_data, timeout)
    timeout = timeout or 20
    local tf, redir = nil, ""
    if stdin_data then
        tf = os.tmpname()
        local f = assert(io.open(tf, "wb"))
        f:write(stdin_data)
        f:close()
        redir = " < " .. shq(tf)
    end
    local cmd = string.format("timeout %d ssh -o BatchMode=yes -o ConnectTimeout=6 %s %s%s 2>&1",
        timeout, shq(M.host), shq(remote_cmd), redir)
    local p = io.popen(cmd, "r")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    if tf then os.remove(tf) end
    return out
end

M.ssh = ssh

local py_ready = false

local function ensure_py()
    if py_ready then return true end
    -- 判版本戳而不是判存在：旧脚本留在 /tmp 会让新逻辑静默失效
    local chk = ssh("head -1 " .. PY_PATH .. " 2>/dev/null")
    if not chk:find(PY_VER, 1, true) then
        ssh("cat > " .. PY_PATH, PY)
        local again = ssh("head -1 " .. PY_PATH .. " 2>/dev/null")
        if not again:find(PY_VER, 1, true) then
            error("box: 无法在 " .. M.host .. " 落转发脚本（ssh 不通？）: " .. chk:sub(1, 200))
        end
    end
    py_ready = true
    return true
end

-- 给 socket 发一行文本（JSON 或纯文本都行），解回一行 JSON。
-- 返回 table, err
function M.line(sock, text, timeout)
    local oke = pcall(ensure_py)
    if not oke then return nil, "no python3/ssh on " .. M.host end
    local out = ssh(string.format("python3 %s %s %d", PY_PATH, sock, timeout or 8), text, (timeout or 8) + 12)
    out = tostring(out or ""):gsub("%s+$", "")
    local sockerr = out:match("__SOCKERR__%s+(%S+)")
    if sockerr then
        return nil, string.format("%s 上没有 %s（对应的 app 没起？）", M.host, sock)
    end
    if out == "" then return nil, "socket 无应答（app 没起？" .. sock .. "）" end
    local ok, v = pcall(cjson.decode, out)
    if not ok then return nil, out:sub(1, 300) end
    return v
end

-- JSON 命令
function M.json(sock, tbl, timeout)
    local ok, body = pcall(cjson.encode, tbl)
    if not ok then return nil, "encode failed" end
    return M.line(sock, body, timeout)
end

function M.desktop(tbl, timeout) return M.json(M.DESKTOP, tbl, timeout) end
function M.reader(tbl, timeout) return M.json(M.READER, tbl, timeout) end
function M.player(text, timeout) return M.line(M.PLAY, text, timeout) end

-- 盒子上跑命令（逃生口）
function M.exec(cmd, timeout) return ssh(cmd, nil, timeout) end

-- ── 盒子上「已经封装好的 lua 脚本」：不在这里复刻协议，ssh 过去按名跑 ────────
-- 三个入口各有各的壳，别混：
--   /opt/reader/tools/reader-agent  阅读器 CLI（自带 LUA_CPATH，cjson 在 /opt/reader/lib）
--   /root/cdp/cdp_do.lua            浏览器 CDP 执行器（零依赖，只用 bit/ffi）
--   /tmp/keybd.sock                 遥控守护（JSON 一行去一行回，M.json 就够）
M.READER_AGENT = os.getenv("LITE_BOX_READER_AGENT") or "/opt/reader/tools/reader-agent"
M.CDP = os.getenv("LITE_BOX_CDP") or "/root/cdp/cdp_do.lua"
M.CDP_PORT = tonumber(os.getenv("LITE_BOX_CDP_PORT") or 9222)
M.KEYBD = "/tmp/keybd.sock"

-- 自己起的 `luajit -e` 要带路径：盒子上的库散在 /opt/reader、/opt/desktop、/opt/keybord，
-- 且 cjson.so 只在 /opt/reader/lib/lua/5.1（系统 luajit 的默认 cpath 里没有）。
M.LUA_PATH = "/opt/reader/?.lua;/opt/reader/lua/?.lua;/opt/desktop/?.lua;"
    .. "/opt/desktop/??/?.lua;/opt/keybord/?.lua;;"
M.LUA_CPATH = "/opt/reader/lib/lua/5.1/?.so;;"

local luajit_bin = nil
-- 盒子上的 luajit 有多份（系统 /usr/local/bin、阅读器自带 /opt/reader/bin），随便哪份都能跑
function M.luajit()
    if luajit_bin then return luajit_bin end
    for _, p in ipairs({ "/usr/local/bin/luajit", "/opt/reader/bin/luajit" }) do
        if ssh("test -x " .. shq(p) .. " && echo y"):find("y") then
            luajit_bin = p
            return p
        end
    end
    luajit_bin = "luajit" -- 退到 PATH；错了下面报「command not found」也能看懂
    return luajit_bin
end

local function lua_env()
    return string.format("LUA_PATH=%s LUA_CPATH=%s ", shq(M.LUA_PATH), shq(M.LUA_CPATH))
end

-- 在盒子上跑一段 lua（luajit -e），路径已就位，stdout 原样返回
function M.lua(code, timeout)
    return ssh(lua_env() .. shq(M.luajit()) .. " -e " .. shq(code), nil, timeout or 25)
end

-- 跑盒子上的 .lua 文件（argv 逐项按位置传，脚本自己解析）
function M.script(path, argv, timeout)
    local q = { shq(M.luajit()), shq(path) }
    for _, a in ipairs(argv or {}) do q[#q + 1] = shq(tostring(a)) end
    return ssh(table.concat(q, " "), nil, timeout or 40)
end

-- 阅读器 CLI：位置参数，输出一行 JSON（text 例外，是纯正文）
function M.reader_agent(argv, timeout)
    local q = { shq(M.READER_AGENT) }
    for _, a in ipairs(argv or {}) do q[#q + 1] = shq(tostring(a)) end
    return ssh(table.concat(q, " "), nil, timeout or 60)
end

-- 浏览器 CDP：url="-" 表示不动当前页（读/操作现有页面）；js="@shot" 截视口图到盒子上
-- （cdp_do.lua 的约定）。返回它自己的 log 全文：每行 [page]/[load]/[js]/[info]/[shot]。
function M.cdp(url, js, opts)
    opts = opts or {}
    local argv = { url or "-" }
    if js and js ~= "" then
        argv[2] = js
        argv[3] = tostring(M.CDP_PORT)
        if opts.shot then argv[4] = opts.shot end
    end
    local q = { shq(M.luajit()), shq(M.CDP) }
    for _, a in ipairs(argv) do q[#q + 1] = shq(tostring(a)) end
    return ssh(table.concat(q, " "), nil, opts.timeout or 40)
end

-- /json/list：有几个 page、各自 url/title（浏览器没开时这里最先看得出来）
function M.cdp_pages()
    local out = ssh(string.format("curl -s --max-time 4 http://127.0.0.1:%d/json/list", M.CDP_PORT), nil, 12)
    out = tostring(out or ""):gsub("%s+$", "")
    if out == "" then return nil, "CDP 端口没应答（chromium 没起 / 没开 --remote-debugging-port）" end
    local ok, v = pcall(cjson.decode, out)
    if not ok then return nil, "CDP 返回非 JSON: " .. out:sub(1, 200) end
    return v
end

-- 遥控守护（keybd）：cmd=state|apps|key|focus|reload|rescan|learn
function M.keybd(tbl, timeout)
    return M.json(M.KEYBD, tbl, timeout or 8)
end

-- scp 拉回一个盒子上的文件（截图/PDF 都走这条）
-- 本地父目录不存在时 scp 会静默什么都不写，所以先 mkdir -p（踩过：out=/tmp/boxt/bb.png 静默失败）
function M.pull(remote, local_path)
    local dir = local_path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then os.execute("mkdir -p " .. shq(dir) .. " 2>/dev/null") end
    local cmd = string.format("timeout 25 scp -q -o BatchMode=yes %s %s 2>&1",
        shq(M.host .. ":" .. remote), shq(local_path))
    local p = io.popen(cmd, "r")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    local f = io.open(local_path, "rb")
    if not f then return nil, "scp 拉回失败: " .. tostring(out):sub(1, 200) end
    local sz = f:seek("end")
    f:close()
    if not sz or sz == 0 then return nil, "拉回 0 字节: " .. tostring(out):sub(1, 200) end
    return local_path, sz
end

-- 截图：app.capture 在盒子上出图，再 scp 拉回本机（read 只能看本地图）
function M.capture(app, remote, local_path)
    remote = remote or "/tmp/lite-box-shot.png"
    local sock = (app == "reader") and M.READER or M.DESKTOP
    local r, err
    if app == "reader" then
        r, err = M.reader({ cmd = "call", fn = "capture", args = { path = remote } })
    else
        r, err = M.desktop({ cmd = "call", fn = "app.capture", args = { path = remote } })
    end
    if not r then return nil, tostring(err) end
    if r.ok == false then return nil, tostring(r.error) end
    local p, perr = M.pull(remote, local_path)
    if not p then return nil, perr end
    return p
end

-- 用 /root/play.sh 起片（-d 后台）。路径可以是 NAS 上的 dav 路径，不落地直连播。
function M.movie(path, from, secs)
    local args = { "/root/play.sh", "-d", path }
    if from then args[#args + 1] = tostring(from) end
    if secs then args[#args + 1] = tostring(secs) end
    local q = {}
    for _, a in ipairs(args) do q[#q + 1] = shq(a) end
    return ssh("setsid nohup " .. table.concat(q, " ") .. " >/tmp/play-launch.log 2>&1 & sleep 1; tail -5 /tmp/play-launch.log")
end

return M
