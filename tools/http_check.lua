-- tools/http_check.lua —— HTTP 无数据超时回归（LITE_HTTP_LOW_SPEED_TIME）
--
-- 为什么要有这条：CURLOPT_TIMEOUT 只管总时长。服务端半开（不发 FIN、LB 黑洞、
-- 进程被 kill 而 socket 还挂着）时一个字节都不来，没有 LOW_SPEED 就要干等 300s，
-- 而报的还是含糊的 "Timeout was reached"。修法是 apply_idle_timeout()（http.lua:102），
-- 1 B/s × N 秒。这条测试就是钉住它：以后谁把它删了/挪了，回归会红。
--
-- 全离线：fork 一个纯 libc 桩服务端（不依赖 nc/socat，本机没有），
-- 绑 127.0.0.1:0 让内核挑端口，避免端口冲突和「起服务等就绪」的竞态。
--
-- 断言挑「用户能看见的」：卡死的请求多久收场、rc 是不是超时、正常快请求有没有被误杀。
-- 注意 2s 粒度：设 T 时实测在 T+2s 中止，这是 curl 低速判定的检查间隔，
-- 所以区间给得宽（< T+12），别收紧成 T+2 —— 会随机器负载抖。
local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local ffi = require("ffi")
local C = ffi.C

ffi.cdef[[
int socket(int, int, int);
int bind(int, const void *, unsigned int);
int listen(int, int);
int accept(int, void *, unsigned int *);
int close(int);
int setsockopt(int, int, int, const void *, unsigned int);
int getsockname(int, void *, unsigned int *);
long read(int, void *, unsigned long);
long write(int, const void *, unsigned long);
int fork(void);
int kill(int, int);
int waitpid(int, int *, int);
int prctl(int, ...);
unsigned int alarm(unsigned int);
int setenv(const char *, const char *, int);
int unsetenv(const char *);
int open(const char *, int, ...);
int dup2(int, int);

// 不在这里声明 clock_gettime：lua/trace/prof.lua 也声明它（struct lite_prof_ts），
// 而它用 pcall(ffi.cdef)，冲突会被静默吞掉：谁先声明谁生效，后者的调用
// 就按错签名传参，运行期直接 "cannot convert struct"。时钟一律借 prof.now_ms。
struct sockaddr_in {
    unsigned short sin_family;
    unsigned short sin_port;
    unsigned int   sin_addr;
    char           sin_zero[8];
};
]]

local AF_INET, SOCK_STREAM, SOL_SOCKET, SO_REUSEADDR = 2, 1, 1, 2

local now_ms = require("trace.prof").now_ms

-- 子进程必须把 stdout/stderr 接到 /dev/null：它继承父进程的管道，
-- 留着不放会让 `... | grep` 一直等不到 EOF（在 test.sh 里表现为整条回归挂住）。
-- 另外两道保险，因为这条测试「坏掉」的表现恰恰是主进程被 timeout 强杀：
--   PR_SET_PDEATHSIG(SIGKILL) —— 父进程一死桩就跟着死，不留孤儿占着端口；
--   alarm(120) —— 万一父进程状态诡异，桩自己到点自杀，绝不长期驻留。
local function detach_stdio()
    local fd = C.open("/dev/null", 2)   -- O_RDWR
    if fd >= 0 then
        C.dup2(fd, 1)
        C.dup2(fd, 2)
        if fd > 2 then C.close(fd) end
    end
    pcall(C.prctl, 1, 9, 0, 0, 0)       -- PR_SET_PDEATHSIG = 1, SIGKILL = 9
    pcall(C.alarm, 120)
end

local fails, total = 0, 0
local function check(ok, name, detail)
    total = total + 1
    if not ok then
        fails = fails + 1
        io.stderr:write(string.format("FAIL %s%s\n", name, detail and (" (" .. detail .. ")") or ""))
    end
    return ok
end

-- ---------------------------------------------------------------- 桩服务端
-- mode = "stall"：accept 后一个字节都不回，也不 close（半开，正是要复现的故障）
-- mode = "fast" ：accept 后立刻回 200 + 2 字节，用来确认正常请求没被误杀
local function listen_local()
    local fd = C.socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 then return nil, "socket failed" end
    local one = ffi.new("int[1]", 1)
    C.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, one, 4)
    local sa = ffi.new("struct sockaddr_in")
    sa.sin_family = AF_INET
    sa.sin_port = 0                                  -- 内核挑端口
    -- 127.0.0.1：直接用字节写，绕开 htons/htonl 是不是符号的不确定性
    local p = ffi.cast("unsigned char *", sa)
    p[4], p[5], p[6], p[7] = 127, 0, 0, 1
    -- 端口 0 就是全零，不用动

    if C.bind(fd, sa, 16) ~= 0 then C.close(fd); return nil, "bind failed" end
    if C.listen(fd, 16) ~= 0 then C.close(fd); return nil, "listen failed" end

    local len = ffi.new("unsigned int[1]", 16)
    local got = ffi.new("struct sockaddr_in")
    if C.getsockname(fd, got, len) ~= 0 then C.close(fd); return nil, "getsockname failed" end
    local g = ffi.cast("unsigned char *", got)
    local port = g[2] * 256 + g[3]                       -- big-endian
    return fd, port
end

local function serve_forever(fd, mode)
    local buf = ffi.new("char[4096]")
    local resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
    while true do
        local c = C.accept(fd, nil, nil)
        if c < 0 then break end
        if mode == "fast" then
            C.read(c, buf, 4096)                         -- 读掉请求（阻塞没关系，客户端已发）
            C.write(c, resp, #resp)
            C.close(c)
        else
            -- stall：什么都不做，也不 close。fd 一直开到进程被杀 —— 这就是半开。
            -- 不 read 避免阻塞在「客户端还没发数据」的连接上。
        end
    end
end

local lfd, port_or_err = listen_local()
if not lfd then
    io.stderr:write("FAIL http.stub (" .. tostring(port_or_err) .. ")\n")
    os.exit(1)
end
local port = port_or_err

-- 先 fork 再 require http：子进程里根本不 load libcurl，避免 fork+curl 的隐患。
local pid = C.fork()
if pid < 0 then
    io.stderr:write("FAIL http.stub (fork failed)\n")
    os.exit(1)
end
if pid == 0 then
    detach_stdio()
    serve_forever(lfd, "stall")
    os.exit(0)
end
C.close(lfd)  -- 父进程不留监听 fd，子进程自己有一份

local http = require("core.http")

local function cleanup()
    C.kill(pid, 9)
    C.waitpid(pid, nil, 0)
end

local function set_idle(v)
    if v == nil then C.unsetenv("LITE_HTTP_LOW_SPEED_TIME")
    else C.setenv("LITE_HTTP_LOW_SPEED_TIME", tostring(v), 1) end
end

-- 桩服务端只能固定一种模式（fork 一次），所以 stall / fast 各 fork 一次。
-- 这里先跑 stall 相关的三条，再换 fast —— 用两级 fork 反而更绕，直接串两个阶段。
local URL = "http://127.0.0.1:" .. port .. "/v1/chat/completions"
local HDR = { "content-type: application/json" }
local BODY = '{"model":"stub","stream":true,"messages":[{"role":"user","content":"hi"}]}'

-- ① 阻塞通道：stall + T=1 必须在 ~T+2s 收场，rc=28（CURLE_OPERATION_TIMEDOUT）
set_idle(1)
local t0 = now_ms()
local rc, status = http.post_stream(URL .. "?p1", HDR, BODY, nil)
local el1 = now_ms() - t0
check(tonumber(rc) == 28, "http.stall.blocking.rc", "rc=" .. tostring(rc))
check(el1 < 12000, "http.stall.blocking.fast_enough",
    string.format("elapsed=%.2fs 应远小于 300s 总超时", el1 / 1000))

-- ② multi 通道（agent 主链路）：同一条 setup_easy，必须同样收场
local m = http.multi_new()
local req = http.request(m, URL .. "?p2", HDR, BODY, nil)
check(req ~= nil, "http.stall.multi.request")
local done, t_multi0 = nil, now_ms()
while now_ms() - t_multi0 < 20000 do
    local out = http.poll(m, 50)
    if #out > 0 then done = out[1]; break end
end
local el2 = now_ms() - t_multi0
check(done ~= nil and tonumber(done.rc) == 28, "http.stall.multi.rc",
    done and ("rc=" .. tostring(done.rc)) or "never finished")
check(el2 < 12000, "http.stall.multi.fast_enough", string.format("elapsed=%.2fs", el2 / 1000))
http.multi_free(m)

-- ③ T=0 表示关掉：stall 下 4s 内不该收场（证明 0 真的没设 LOW_SPEED_TIME）
set_idle(0)
local m0 = http.multi_new()
local req0 = http.request(m0, URL .. "?p3", HDR, BODY, nil)
check(req0 ~= nil, "http.off.request")
local t_off = now_ms()
local finished_early = false
while now_ms() - t_off < 4000 do
    local out = http.poll(m0, 50)
    if #out > 0 then finished_early = true; break end
end
check(not finished_early, "http.off.disabled",
    "LITE_HTTP_LOW_SPEED_TIME=0 时 4s 内不该放弃")
http.multi_free(m0)

cleanup()

-- ④ 正常快请求不能被误杀：换 fast 模式的桩，走默认（不设 env）
local lfd2, port2 = listen_local()
if not lfd2 then
    check(false, "http.stub2", tostring(port2))
else
    local pid2 = C.fork()
    if pid2 == 0 then
        detach_stdio()
        serve_forever(lfd2, "fast")
        os.exit(0)
    end
    C.close(lfd2)
    C.unsetenv("LITE_HTTP_LOW_SPEED_TIME")   -- 回默认 120s
    local t1 = now_ms()
    local rc4, st4, body4 = http.post_stream("http://127.0.0.1:" .. port2 .. "/ok", HDR, BODY, nil)
    local el4 = now_ms() - t1
    check(tonumber(rc4) == 0, "http.fast.rc", "rc=" .. tostring(rc4))
    check(tonumber(st4) == 200, "http.fast.status", "status=" .. tostring(st4))
    check(body4 == "ok", "http.fast.body", "body=" .. tostring(body4))
    check(el4 < 3000, "http.fast.no_false_positive", string.format("elapsed=%.2fs", el4 / 1000))
    C.kill(pid2, 9)
    C.waitpid(pid2, nil, 0)
end

if fails > 0 then
    io.stderr:write(string.format("FAIL http (%d/%d 断言失败)\n", fails, total))
    os.exit(1)
end
print(string.format("OK http (%d checks)", total))
