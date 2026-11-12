-- 探活去抖：master 采样远端 serve 的 /health，连续 N 次「活着且空闲」才拿主意。
--
-- 为什么不在单点上做判决：
--   * `alive()` 是「尽快」而非「瞬时」——`kill -9` 后没收尸前 `kill(pid,0)` 仍成功，
--     这一次采样会报 shell=true（偏安全的那一侧：该等就多等一轮，不会误杀在跑的命令）；
--   * serve 是单协程，主循环一卡（同步 C 调用、前台工具）整个 /health 答不上来，
--     一次超时只说明「此刻没空答」，不说明「死了」。
-- 两类噪声都靠「多采几次」吸收，所以判定放在采样流上；真正要写死的纪律是去抖，
-- 不是精度。shell_sec 只作展示，不参与判定（长命令跑一小时也是活着）。
local ffi = require("ffi")
ffi.cdef[[ int usleep(unsigned int usec); ]]

local M = {}

-- 退出码语义（tools.exit_note 认识 124/126/127，这里是本模块自己的通道）
M.OK = 0           -- 可以唤醒
M.BUSY = 3         -- 还在干活 / 刚 kill 未收尸
M.UNREACHABLE = 4  -- 一次都没答上来
M.UNSTABLE = 5     -- 有答有超时，凑不满连续空闲

local Watch = {}
Watch.__index = Watch

-- 纯判定：只吃计数，不碰 I/O，单测直接喂。
function M.decide(samples, idle, busy, down)
    if idle >= samples then return "wake", "idle x" .. samples end
    if down >= samples then return "unreachable", "no answer in " .. samples .. " samples" end
    if busy > 0 then return "busy", "shell/busy seen " .. busy .. "/" .. samples end
    return "unstable", "flaky: idle " .. idle .. ", timeouts " .. down
end

function M.new(opts)
    opts = opts or {}
    return setmetatable({
        samples = math.max(1, math.floor(tonumber(opts.samples) or 3)),
        interval = math.max(0, tonumber(opts.interval) or 2),
        timeout = math.max(1, tonumber(opts.timeout) or 5),
        n = 0, idle = 0, busy = 0, down = 0,
        decision = nil, reason = nil, last = nil, trace = {},
    }, Watch)
end

-- sample = { ok = bool, busy = bool, shell = bool, pid = n, shell_sec = n, err = str }
function Watch:feed(sample)
    sample = sample or { ok = false, err = "no sample" }
    self.n = self.n + 1
    self.last = sample
    if not sample.ok then
        self.down = self.down + 1
    elseif sample.busy or sample.shell then
        self.busy = self.busy + 1
    else
        self.idle = self.idle + 1
    end
    self.trace[#self.trace + 1] = {
        n = self.n,
        ok = sample.ok and true or false,
        busy = sample.busy and true or false,
        shell = sample.shell and true or false,
        shell_sec = sample.shell_sec,
        -- 注意：`sample.ok and nil or …` 会落到 or 分支（nil 是 falsy），别用这个惯用法
        err = (not sample.ok) and (sample.err or "no answer") or nil,
    }
    if self.n >= self.samples then
        self.decision, self.reason = M.decide(self.samples, self.idle, self.busy, self.down)
    end
    return self.decision
end

function Watch:exit_code()
    if self.decision == "wake" then return M.OK end
    if self.decision == "busy" then return M.BUSY end
    if self.decision == "unreachable" then return M.UNREACHABLE end
    return M.UNSTABLE
end

-- 一次 HTTP GET，返回 sample。任何失败（连不上、超时、坏 JSON）都算 down，
-- 不区分原因：master 侧对这三种的反应一样（再采一次）。
local function sample_once(host, port, timeout)
    local http = require("core.http")
    local cjson = require("cjson")
    local url = string.format("http://%s:%d/health", host, port)
    local rc, code, body = http.get(url, nil, 64 * 1024, timeout)
    if rc ~= 0 then return { ok = false, err = "curl rc=" .. rc .. ": " .. tostring(body) } end
    if code ~= 200 then return { ok = false, err = "http " .. tostring(code) } end
    local ok, obj = pcall(cjson.decode, body or "")
    if not ok or type(obj) ~= "table" then return { ok = false, err = "bad json" } end
    return {
        ok = true,
        busy = obj.busy and true or false,
        shell = obj.shell and true or false,
        queued = tonumber(obj.queued),
        pid = tonumber(obj.pid),
        shell_sec = tonumber(obj.shell_sec),
    }
end

-- 采样 N 次（间隔 interval 秒），返回 Watch 实例（decision/reason/trace 都在上面）。
function M.run(host, port, opts)
    host = host or "127.0.0.1"
    port = tonumber(port)
    assert(port, "serve_watch: missing port")
    local w = M.new(opts)
    while w.n < w.samples do
        if w.n > 0 and w.interval > 0 then
            ffi.C.usleep(math.floor(w.interval * 1000000))
        end
        w:feed(sample_once(host, port, w.timeout))
    end
    return w
end

return M
