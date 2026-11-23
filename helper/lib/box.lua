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
    local cmd = string.format("timeout 20 scp -q -o BatchMode=yes %s %s 2>&1",
        shq(M.host .. ":" .. remote), shq(local_path))
    local p = io.popen(cmd, "r")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    local f = io.open(local_path, "rb")
    if not f then return nil, "scp 拉回失败: " .. tostring(out):sub(1, 200) end
    local sz = f:seek("end")
    f:close()
    if not sz or sz == 0 then return nil, "截图 0 字节: " .. tostring(out):sub(1, 200) end
    return local_path
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
