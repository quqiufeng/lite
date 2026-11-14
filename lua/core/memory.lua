-- 上下文记忆：基于 my_db KV cache（mmap 零拷贝 + 前缀/模糊/标签搜索）。
local cjson = require("cjson")
local ffi = require("ffi")
local bit = require("bit")
local cache = require("ffi.cache")
local Prompt = require("core.prompt")
local net = require("core.net")

-- 进程内追踪账本（trace.prof）：召回耗时单独记一笔。
local ok_prof, prof = pcall(require, "trace.prof")
if not ok_prof then prof = nil end

pcall(ffi.cdef, [[
int open(const char *pathname, int flags, unsigned int mode);
int flock(int fd, int operation);
int getpid(void);
]])

local O_CREAT = 0x40
local O_RDWR = 2
-- O_CLOEXEC：mem.lock 的 fd 不能被 exec 的子进程继承。否则父进程退出后，
-- 残留的长命子进程（ffmpeg/vlc/voice loop）仍持有那份 open file description，
-- flock 一直不放 → 之后每个 lite 启动都抢不到锁、静默降级 readonly，
-- remember/todo 全废，只能重启才能发现（实测踩过：语音会话的 ffmpeg 录了半小时）。
local O_CLOEXEC = 0x80000
local LOCK_EX = 2
local LOCK_NB = 4
local LOCK_UN = 8
-- 重抢节流：锁被占时别让每次 put 都 open+flock（默认 2 秒一次）。
local RECLAIM_THROTTLE_MS = 2000
-- include/cache.h:16 的 CACHE_ERR_NOENT，del 用它区分「本来就没有」和真失败。
local CACHE_ERR_NOENT = -4

local M = {}
M.__index = M

local TTL = {
    working = 5 * 60 * 1000,
    short = 60 * 60 * 1000,
    long = 24 * 60 * 60 * 1000,
    permanent = 0,
}
M.TTL = TTL

local function join(ns, key)
    ns = ns or "/"
    if ns:sub(1, 1) ~= "/" then ns = "/" .. ns end
    if ns:sub(-1) ~= "/" then ns = ns .. "/" end
    return ns .. tostring(key or "")
end

-- mem.lock 里写下"谁占着"（pid + 启动时间），抢锁失败的一方才能直接报出
-- 「被 pid 4242 (lite) 占着」，而不是一句 "another lite holds mem.lock"
-- 让用户自己去 ps 里翻。只在已经持有锁之后写，不会踩到别人。
local function write_owner(path)
    local f = io.open(path, "w")
    if not f then return end
    f:write(string.format("%d %d\n", ffi.C.getpid(), os.time()))
    f:close()
end

-- 读锁文件里的持有者信息。老版本留下的空文件 / 残破内容一律返回 nil，
-- 调用方按"未知进程"处理，不能因此崩掉。
function M:owner()
    local f = io.open(self.lock_path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    if not line then return nil end
    local pid, ts = line:match("^(%d+)%s*(%d*)")
    pid = tonumber(pid)
    if not pid or pid <= 0 then return nil end
    local comm
    local cf = io.open("/proc/" .. pid .. "/comm", "r")
    if cf then
        comm = cf:read("*l")
        cf:close()
        if comm then comm = comm:gsub("%s+$", "") end
    end
    return { pid = pid, started = tonumber(ts) or nil, comm = comm, alive = comm ~= nil }
end

local function hash_str(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

function M:cwd_index_prefix(cwd)
    return "/agent/index/cwd/" .. hash_str(tostring(cwd or "")) .. "/"
end

function M.new(opts)
    opts = opts or {}
    local base = opts.dir
    if not base then
        base = opts.cwd or os.getenv("PWD") or "."
    end
    os.execute("mkdir -p '" .. base:gsub("'", "'\\''") .. "'")

    local lock_fd = ffi.C.open(base .. "/mem.lock", bit.bor(O_CREAT, O_RDWR, O_CLOEXEC), 420)
    if lock_fd < 0 then
        return nil, string.format("cannot open %s/mem.lock (errno %d)", base, ffi.errno())
    end
    -- 写进程持独占锁；只读诊断命令不加锁，允许在 TUI/serve 运行时读取。
    local readonly = opts.readonly and true or false
    local lock_busy = false
    if readonly then
        -- 只读实例连 fd 都不留：留着 fd 既白漏一个句柄，又会让 probe_lock 误判
        -- "锁是我自己占着的"（cdata 恒真），诊断就永远报 busy。
        net.close(lock_fd)
        lock_fd = nil
    elseif ffi.C.flock(lock_fd, bit.bor(LOCK_EX, LOCK_NB)) ~= 0 then
        -- 抢不到锁：降级为只读实例，进程继续跑（不写记忆、不刷盘）。
        ffi.C.flock(lock_fd, LOCK_UN)
        net.close(lock_fd)
        lock_fd = nil
        readonly = true
        lock_busy = true
    end

    local h = cache.open(base, (opts.max_mb or 100) * 1024 * 1024)
    if not h then
        if lock_fd then
            ffi.C.flock(lock_fd, LOCK_UN)
            net.close(lock_fd)
        end
        return nil, "cache_open failed: " .. base
    end
    -- 抢到锁才写持有者：写实例的 pid 落在 mem.lock 里，后来者能指名道姓。
    if not readonly then write_owner(base .. "/mem.lock") end
    return setmetatable({
        h = h,
        dir = base,
        lock_path = base .. "/mem.lock",
        lock_fd = lock_fd,
        readonly = readonly,
        lock_busy = lock_busy,
        lock_retry_ms = tonumber(opts.lock_retry_ms) or RECLAIM_THROTTLE_MS,
        flush_ms = (tonumber(opts.flush_sec) or 30) * 1000,
        last_sync = os.time() * 1000,
    }, M)
end

-- 抢锁失败只降级、不自愈是旧版的坑：另一个残留实例（或被 exec 继承 fd 的
-- 长命子进程）一退出，本进程本该恢复写，却因为 readonly 是启动时定死的，
-- 整轮会话 remember/todo 全废，只能重启。实测踩过：08:28 那次连续 3 次
-- "error: remember failed"，重启才恢复。
-- 这里在写路径上惰性重抢，带节流：锁还被占着时不至于每次 put 都 open+flock，
-- 抢到就地把实例升级回可写，调用方无需知道降级发生过。
function M:reclaim(now_ms)
    if not self.lock_busy then return not self.readonly end
    now_ms = now_ms or (os.time() * 1000)
    if self.lock_retry_at and now_ms < self.lock_retry_at then return false end
    self.lock_retry_at = now_ms + (self.lock_retry_ms or RECLAIM_THROTTLE_MS)
    local fd = ffi.C.open(self.lock_path, bit.bor(O_CREAT, O_RDWR, O_CLOEXEC), 420)
    if fd < 0 then return false end
    if ffi.C.flock(fd, bit.bor(LOCK_EX, LOCK_NB)) ~= 0 then
        net.close(fd)
        return false
    end
    self.lock_fd, self.readonly, self.lock_busy = fd, false, false
    self.lock_retry_at = nil
    self.reclaimed = (self.reclaimed or 0) + 1
    write_owner(self.lock_path)
    return true
end

-- 探一下写锁此刻是否空着（开→NB flock→放），不改自身状态。
-- 只读诊断命令（`lite state`）用它回答"现在有没有别的实例在写"：
-- 自己没抢锁的实例靠 readonly 字段是看不出别人占没占的。
function M:probe_lock()
    if self.lock_fd then return { free = false, self_held = true, lock = self:owner() } end
    local fd = ffi.C.open(self.lock_path, bit.bor(O_CREAT, O_RDWR, O_CLOEXEC), 420)
    if fd < 0 then return { free = nil } end
    local ok = ffi.C.flock(fd, bit.bor(LOCK_EX, LOCK_NB)) == 0
    if ok then ffi.C.flock(fd, LOCK_UN) end
    net.close(fd)
    return { free = ok, lock = ok and nil or self:owner() }
end

-- 一次性快照：状态栏 / `lite state` 用它判断"我现在到底能不能落盘"。
-- readonly 曾经是启动时定死又没人看的私有字段，用户只能在半天后发现
-- 历史缺了一段；这里把它变成可观测的东西，顺带带上占锁进程和写失败次数。
function M:status()
    local probe = self:probe_lock()
    local lock = nil
    if self.lock_busy or probe.free == false then lock = self:owner() end
    return {
        dir = self.dir,
        readonly = self.readonly and true or false,
        lock_busy = self.lock_busy and true or false,
        writable = self.lock_fd ~= nil,
        free = probe.free,
        lock = lock,
        write_failures = self.write_failures or 0,
        reclaimed = self.reclaimed or 0,
    }
end

function M:close()
    if self.h then
        self:maybe_compact()
        cache.sync(self.h)
        cache.close(self.h)
        self.h = nil
    end
    if self.lock_fd then
        ffi.C.flock(self.lock_fd, LOCK_UN)
        net.close(self.lock_fd)
        self.lock_fd = nil
    end
end

function M:sync()
    if not self.h then return nil end
    -- tick 每 30 秒调一次，锁一空出来就能自动恢复落盘，不必等到有写操作。
    if self.readonly and not self:reclaim() then return nil end
    self.last_sync = os.time() * 1000
    return cache.sync(self.h)
end

-- 更新/淘汰只把旧 entry 标记删除，物理空间不会自动复用；当池占用达到
-- 存活数据两倍且足够大时，原地重排一次，避免 mem.bin 随长会话单调增长。
function M:maybe_compact()
    if not self.h or self.readonly then return nil end
    local phys = cache.pool_used(self.h) or 0
    local live = cache.memory_used(self.h) or 0
    if phys > 16 * 1024 * 1024 and phys > live * 2 then
        return cache.compact(self.h)
    end
    return nil
end

-- 主循环/agent 定期调用：默认 30 秒落盘一次。
function M:tick(now_ms)
    if not self.h then return false end
    now_ms = now_ms or (os.time() * 1000)
    if now_ms - (self.last_sync or 0) >= (self.flush_ms or 30000) then
        self:sync()
        self:maybe_compact()
        return true
    end
    return false
end

-- 抢不到锁时的统一说法：谁占着、在哪个目录。写失败、启动拒绝、
-- `lite state` 三处共用一份文案，别再各写一句让人对不上号。
function M.lock_message(dir, owner)
    local who = "another lite process"
    if owner and owner.pid then
        who = string.format("pid %d", owner.pid)
        if owner.comm and owner.comm ~= "" then who = who .. " (" .. owner.comm .. ")" end
        if owner.alive == false then who = who .. ", already gone?" end
    end
    return string.format("%s holds mem.lock in %s", who, tostring(dir))
end

function M:put(ns, key, value, ttl)
    if self.readonly and not self:reclaim() then
        -- 丢掉一次写就是丢一段历史：计个数，让 status/状态栏能报出来。
        self.write_failures = (self.write_failures or 0) + 1
        return false, "readonly memory (" .. M.lock_message(self.dir, self:owner()) .. ")"
    end
    local full = join(ns, key)
    local ok, s = pcall(cjson.encode, value)
    if not ok then return false, s end
    -- 落盘写是 mmap KV，通常几十 µs，但锁竞争/页换出时会突然变慢，
    -- 记一笔才能分清「记忆慢」还是「模型慢」。
    local t0 = prof and prof.now_ms()
    local wok = cache.set(self.h, full, s, ttl or 0) == 0
    if prof and t0 then prof.record("memory.put", prof.now_ms() - t0, wok, #s) end
    return wok
end

function M:get(ns, key)
    local s = cache.get(self.h, join(ns, key))
    if not s then return nil end
    local ok, v = pcall(cjson.decode, s)
    return ok and v or s
end

function M:del(ns, key)
    if self.readonly and not self:reclaim() then
        self.write_failures = (self.write_failures or 0) + 1
        return false
    end
    local t0 = prof and prof.now_ms()
    local rc = cache.del(self.h, join(ns, key))
    local dok = rc == 0
    -- NOENT(-4) 是「本来就没有」而不是错误：旧会话截断会重扫已删的键，
    -- 混进 err 会把真正的写失败彻底淹掉。单列成 miss 计数，err 只留真失败。
    local miss = rc == CACHE_ERR_NOENT
    if miss then self.del_miss = (self.del_miss or 0) + 1 end
    if prof and t0 then prof.record("memory.del", prof.now_ms() - t0, dok or miss) end
    return dok
end

function M:search_prefix(prefix, opts)
    return cache.search_prefix(self.h, prefix, opts or { max_results = 100 })
end

function M:search_range(start_key, end_key, opts)
    return cache.search_range(self.h, start_key, end_key, opts or { max_results = 100 })
end

function M:session_meta(id)
    local meta = self:get("/agent/session", tostring(id) .. "/meta")
    return type(meta) == "table" and meta or nil
end

function M:ensure_session(id, cwd, model, title)
    id = tostring(id or "session")
    local meta = self:session_meta(id)
    local now = os.time()
    if not meta then
        meta = {
            id = id, cwd = cwd, model = model, title = title or "",
            created = now, updated = now, turns = 0,
        }
    else
        meta.id = meta.id or id
        if cwd then meta.cwd = cwd end
        if model then meta.model = model end
        if title and title ~= "" and (not meta.title or meta.title == "") then
            meta.title = tostring(title):gsub("%s+", " "):sub(1, 80)
        end
        meta.updated = now
    end
    self:put("/agent/session", id .. "/meta", meta, TTL.permanent)
    if meta.cwd then
        self:put("/agent/index/cwd", hash_str(meta.cwd) .. "/" .. id, meta, TTL.permanent)
    end
    return meta
end

function M:touch_session(id, cwd, model, title, turn)
    id = tostring(id or "session")
    local meta = self:session_meta(id)
    if not meta then
        -- 没有 cwd 也必须建 meta：启动期（TUI 恢复、serve 唤醒）先记轮次后补 cwd，
        -- 早先这里 return nil 会让整段会话没有 meta，messages/turns 全丢。
        meta = self:ensure_session(id, cwd, model, title)
    end
    meta.updated = os.time()
    if cwd then meta.cwd = cwd end
    if model then meta.model = model end
    if title and title ~= "" and (not meta.title or meta.title == "") then
        meta.title = tostring(title):gsub("%s+", " "):sub(1, 80)
    end
    if turn and turn > (tonumber(meta.turns) or 0) then meta.turns = turn end
    self:put("/agent/session", id .. "/meta", meta, TTL.permanent)
    if meta.cwd then
        self:put("/agent/index/cwd", hash_str(meta.cwd) .. "/" .. id, meta, TTL.permanent)
    end
    return meta
end

function M:list_sessions(cwd, limit)
    limit = limit or 10
    local out, seen = {}, {}
    local prefix = self:cwd_index_prefix(cwd)
    for _, r in ipairs(self:search_prefix(prefix, { max_results = limit * 4 })) do
        local ok, meta = pcall(cjson.decode, r.value)
        if ok and type(meta) == "table" then
            local id = meta.id or tostring(r.key):match("/([^/]+)$")
            if id and not seen[id] then
                seen[id] = true
                meta.id = id
                out[#out + 1] = meta
            end
        end
    end

    if #out == 0 then
        for _, r in ipairs(self:search_prefix("/agent/session/", { max_results = limit * 8 })) do
            if tostring(r.key):sub(-5) == "/meta" then
                local ok, meta = pcall(cjson.decode, r.value)
                if ok and type(meta) == "table" and meta.cwd == cwd then
                    local id = meta.id or tostring(r.key):match("/session/([^/]+)/meta$")
                    if id and not seen[id] then
                        seen[id] = true
                        meta.id = id
                        out[#out + 1] = meta
                    end
                end
            end
        end
    end

    table.sort(out, function(a, b) return (a.updated or 0) > (b.updated or 0) end)
    while #out > limit do table.remove(out) end
    return out
end

-- 全库会话（跨 cwd），按最近更新降序。给「换了目录但 mem.bin 还是那份」兜底用：
-- 会话的 meta.cwd 是创建时写死的绝对路径，文件搬走后按 cwd 找不到它，
-- 但数据还在库里，得有个不看 cwd 的入口把它捞出来。
function M:list_all_sessions(limit)
    limit = limit or 20
    local out, seen = {}, {}
    for _, r in ipairs(self:search_prefix("/agent/session/", { max_results = limit * 4 })) do
        local id = tostring(r.key):match("/session/([^/]+)/meta$")
        if id and not seen[id] then
            local meta = self:session_meta(id)
            if type(meta) == "table" then
                seen[id] = true
                meta.id = id
                out[#out + 1] = meta
            end
        end
    end
    table.sort(out, function(a, b) return (a.updated or 0) > (b.updated or 0) end)
    while #out > limit do table.remove(out) end
    return out
end

function M:remember_fact(key, content, tags, ttl)
    return self:put("/agent/knowledge", key, {
        t = "fact",
        c = content,
        tags = tags or {},
        ts = os.time(),
    }, ttl or TTL.permanent)
end

-- 工作记忆按会话隔离：给了 session_id 就落到 /agent/session/<sid>/working/<key>，
-- 否则退回目录级的 /agent/working/<key>（跨会话共享）。
-- 目录级的 /agent/working 是给调度器（wake）这类运行态用的，不进 recall。
function M:remember_working(key, content, ttl, session_id)
    local value = { t = "working", c = content, ts = os.time() }
    if session_id then
        return self:put("/agent/session",
            string.format("%s/working/%s", tostring(session_id), tostring(key)),
            value, ttl or TTL.working)
    end
    return self:put("/agent/working", key, value, ttl or TTL.working)
end

-- 单轮对话落盘上限。最初的理由是"assistant 可能是整段工具循环输出，实测 63KB"，
-- 但工具输出正文根本进不了 turn（tool_names 只留名字，见下），63KB 只出现在
-- 工具循环被迫停止的那条异常路径（agent.lua:759）；主路径存的是最终回答
-- （agent.lua:939），干净且短。所以这里真正要防的不是"大"，而是"长回答里的
-- 结论被砍掉"——早期用 clip_utf8 从头截断，把答案、代码块、表格这些几乎总在
-- 尾部的东西整段丢掉，且几乎没有兜底：msg/ 全文过了 raw_keep 会被 prune，自动
-- 注入也只要 user 原话（assistant 只有显式 recall transcript=true 才看得到），
-- turn 自身现在虽是永久，但它逐轮独立、从不合并，跨轮结论无人承载。
-- 所以 turn 必须自己存全，并靠下面的 epoch 折叠层补跨轮视图。
local TURN_USER_MAX = 800
local TURN_ASSIST_MAX = 1536

local function clip_utf8(s, max)
    s = tostring(s or "")
    if max <= 0 or #s <= max then return s end
    local cut = max
    -- 退到 UTF-8 起始字节，避免把多字节字符劈成半个
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut) .. "…"
end

-- 取首句：折叠成 epoch 时每轮只留一句。确定性（同一份 turn 永远得到同一段文本，
-- 不像模型摘要每次措辞都不一样），长度可控，且能在 clip 前保住句读。
local function first_sentence(s, max)
    s = tostring(s or ""):gsub("%s+", " ")
    s = s:match("^%s*(.-)%s*$") or s
    if s == "" then return "" end
    local best
    for _, pat in ipairs({ "%.[%s]", "%。", "！", "？", "!", "?" }) do
        local _, en = s:find(pat)
        if en and (not best or en < best) then best = en end
    end
    if best then s = s:sub(1, best) end
    return clip_utf8(s, max)
end

-- 头尾拼接截断：保留开头和结尾，中间用省略标记接起来。
--
-- turn 落盘用它而不是 clip_utf8 的纯头部截断：对话的结论、代码块、表格几乎都在
-- 尾部，砍掉头留着尾或砍掉尾留着头都是丢关键信息。带上"略 N 字"的标记而不是
-- 静默拼接，是为了让读到的模型知道这段不连续——否则它会把首尾当成相邻内容。
local function utf8_count(s, from, to)
    local n, i = 0, from
    while i <= to do
        local b = s:byte(i)
        i = i + ((b < 0x80) and 1 or ((b < 0xE0) and 2 or ((b < 0xF0) and 3 or 4)))
        n = n + 1
    end
    return n
end

-- head_ratio：开头占比。assistant 结论在尾 → 1/3；user 提问通常在首 → 2/3。
local function clip_head_tail(s, max, head_ratio)
    s = tostring(s or "")
    if max <= 0 or #s <= max then return s end
    head_ratio = head_ratio or 0.5
    -- 给"…（中间略 N 字）…"留位置：固定 28 字节 + 最多 7 位数字
    local reserve = 40
    local room = max - reserve
    if room < 64 then return clip_utf8(s, max) end
    local hlen = math.floor(room * head_ratio)
    local tlen = room - hlen

    -- 两端退到 UTF-8 起始字节，避免劈开多字节字符（与 clip_window 同规则）
    local hstop = hlen
    while hstop > 0 do
        local b = s:byte(hstop + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        hstop = hstop - 1
    end
    local tstart = #s - tlen + 1
    if tstart < 1 then tstart = 1 end
    while tstart <= #s do
        local b = s:byte(tstart)
        if not b or b < 0x80 or b >= 0xC0 then break end
        tstart = tstart + 1
    end
    if tstart <= hstop then return s end

    local dropped = utf8_count(s, hstop + 1, tstart - 1)
    return s:sub(1, hstop) .. "…（中间略 " .. dropped .. " 字）…" .. s:sub(tstart)
end

-- 命中窗口裁剪：长文本只取命中词周围一段，而不是从头部截断。
-- turn/working 的正文可能几千字，答案常在尾部；头部截断等于把 token 花在
-- 与查询无关的前言上。terms 是小写词表，按 UTF-8 边界取 ±max/3 的窗口。
local function clip_window(s, max, terms)
    s = tostring(s or "")
    if max <= 0 or #s <= max then return s end
    local low = s:lower()
    local best
    for _, w in ipairs(terms or {}) do
        local pos = low:find(w, 1, true)
        if pos and (not best or pos < best) then best = pos end
    end
    local start = 1
    if best then
        start = best - math.floor(max / 3)
        if start < 1 then start = 1 end
    end
    -- 两端都退到 UTF-8 起始字节，避免劈开多字节字符
    while start > 1 do
        local b = s:byte(start)
        if not b or b < 0x80 or b >= 0xC0 then break end
        start = start - 1
    end
    local stop = start + max - 1
    if stop > #s then stop = #s end
    while stop < #s do
        local b = s:byte(stop + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        stop = stop - 1
    end
    local head = start > 1 and "…" or ""
    local tail = stop < #s and "…" or ""
    return head .. s:sub(start, stop) .. tail
end

-- tools 只留名字：参数（大段文件内容/命令输出）是纯噪音，且体积最大。
local function tool_names(tools)
    if type(tools) ~= "table" then
        return tools and tostring(tools) or nil
    end
    local out = {}
    for _, t in ipairs(tools) do
        local name
        if type(t) == "table" then
            name = tostring(t.name or t.tool or t[1] or "tool")
        else
            name = tostring(t)
        end
        out[#out + 1] = name
        if #out >= 12 then break end
    end
    return #out > 0 and out or nil
end

-- 参数摘要：工具名单独一条信息量太低（"bash" 等于没说），但完整参数（文件内容、
-- 命令输出）又是最大的噪音源。取折中：每个工具挑一个「抓手」字段——执行了什么
-- 命令、改了哪个文件、搜了什么词——截到 40 字节。纯白名单解析，不做推理。
-- 只影响 epoch 的拼装，不影响原始 msg/（那边是完整记录）。
local ARG_KEYS = { "command", "cmd", "path", "file", "file_path", "filename",
                   "pattern", "query", "url", "code" }
local function tool_digests(tools)
    if type(tools) ~= "table" then return nil end
    local out = {}
    for _, t in ipairs(tools) do
        if type(t) == "table" then
            local name = tostring(t.name or t.tool or t[1] or "tool")
            local args = t.args or t.arguments or t[2]
            local grab
            if type(args) == "string" and args ~= "" then
                local ok, d = pcall(cjson.decode, args)
                args = ok and type(d) == "table" and d or nil
            end
            if type(args) == "table" then
                for _, k in ipairs(ARG_KEYS) do
                    local v = args[k]
                    if type(v) == "string" and v ~= "" then grab = v; break end
                    if type(v) == "number" then grab = tostring(v); break end
                end
            end
            if grab then
                grab = grab:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
                out[#out + 1] = name .. ": " .. clip_utf8(grab, 40)
            else
                out[#out + 1] = name
            end
        else
            out[#out + 1] = tostring(t)
        end
        if #out >= 2 then break end   -- 一轮调十个工具只留头两个，够定位了
    end
    return #out > 0 and out or nil
end

-- 末句：工具轮的开场白（"好的，我看一下"）没有信息，结论写在最后一句。
-- 用 plain find 找最后一个句末标点的起点，比按 UTF-8 字节猜可靠得多。
local SENT_END = { "。", "！", "？", "!", "?", "\n" }
local function last_sentence(s, max)
    s = tostring(s or ""):gsub("%s+$", "")
    if s == "" then return "" end
    local best = 0
    for _, e in ipairs(SENT_END) do
        local from = 1
        while true do
            local a, b = s:find(e, from, true)
            if not a then break end
            if b + 1 > best and b < #s then best = b + 1 end
            from = b + 1
        end
    end
    if best > 1 then s = s:sub(best) end
    s = s:gsub("^%s+", "")
    if s == "" then return "" end
    return clip_utf8(s, max)
end

function M:remember_turn(session_id, turn, user, assistant, tools)
    local sid = tostring(session_id or "session")
    local meta = self:session_meta(sid)
    local prev = tonumber(meta and meta.turns) or 0
    turn = tonumber(turn) or 0
    -- turn 编号必须单调：恢复路径现在用 session_messages() 返回的真实上界
    -- （memory.lua:max_turn 扫 turn/ 键），正常不会倒退；这里只留一道兜底，
    -- 防止调用方传 0 时覆盖掉 turn/1。
    if turn <= prev then turn = prev + 1 end
    local key = string.format("%s/turn/%d", sid, turn)
    local ok = self:put("/agent/session", key, {
        t = "turn",
        u = clip_head_tail(user, TURN_USER_MAX, 2 / 3),
        a = clip_head_tail(assistant, TURN_ASSIST_MAX, 1 / 3),
        tools = tool_names(tools),
        ta = tool_digests(tools),
        ts = os.time(),
    -- 存 permanent：turn 是「提炼层」，msg/ 原文才是 24h 热区。早先这里跟着
    -- 原文一起用 long，一天后 meta 还在、会话还能列出来，点进去却一条摘要都没有
    -- ——会话空壳。和 usage/meta 同理，摘要必须跟着会话走。
    }, TTL.permanent)
    self:touch_session(sid, nil, nil, user, turn)
    -- 每 EPOCH_EVERY 轮折一层 epoch：跨轮结论只有合并后才可检索，逐轮 turn
    -- 各说各话，谁也不会承载「这个项目最后定了什么」。
    if M.EPOCH_EVERY > 0 and turn % M.EPOCH_EVERY == 0 then
        pcall(self.fold_epoch, self, sid, turn - M.EPOCH_EVERY + 1, turn)
    end
    return ok
end

-- ── epoch：确定性的跨轮折叠层 ──────────────────────────────────────────
-- 为什么不用模型摘要：同一段记忆两次摘要措辞不同 → 召回结果不稳定、不可复现，
-- 而且每轮都要多一次调用。这里要的不是「压缩比」，是「可检索性」，所以用
-- 首句 + 工具名做纯文本拼装：零模型参与、可复现、可 diff。
M.EPOCH_EVERY = 8
-- 一轮 u+a 合计短于这个字节数、且没调工具 → 视为无信息轮，不进 epoch。
local EPOCH_MIN_INFO = 24

function M:fold_epoch(session_id, from, to)
    local sid = tostring(session_id or "session")
    from, to = tonumber(from), tonumber(to)
    if not from or not to or to < from then return false end
    local key = string.format("%s/epoch/%d-%d", sid, from, to)
    if self:get("/agent/session", key) then return false end  -- 幂等：重复触发不重写
    local lines, tools_all, got = {}, {}, 0
    for i = from, to do
        local d = self:get("/agent/session", string.format("%s/turn/%d", sid, i))
        if type(d) == "table" then
            got = got + 1
            local u = first_sentence(d.u, 120)
            local a = first_sentence(d.a, 200)
            -- 确定性去噪：寒暄/确认类轮次（"好的"、"继续"、"收到"）塞进 epoch
            -- 只会稀释信号、吃掉召回窗口。规则很死：两边都短于 12 字节且没用
            -- 工具 = 没有新信息。不用模型判断，才不会出现同一批 turn 两种折法。
            local tl = table.concat(d.tools or {}, ",")
            if #u + #a >= EPOCH_MIN_INFO or tl ~= "" then
                if tl ~= "" then
                    -- 工具轮：抓手是"对什么做了什么"，加上结论（末句）。
                    -- 首句在这里基本是"好的，我先看下"，占了 200 字节预算却零信息。
                    local dig = table.concat(d.ta or d.tools or {}, "; ")
                    local tail = last_sentence(d.a, 120)
                    lines[#lines + 1] = string.format("[%d] %s →（%s）%s", i, u, dig, tail)
                else
                    lines[#lines + 1] = string.format("[%d] %s → %s", i, u, a)
                end
            end
            for _, t in ipairs(d.tools or {}) do tools_all[t] = true end
        end
    end
    if got == 0 or #lines == 0 then return false end
    local tags = {}
    for t in pairs(tools_all) do tags[#tags + 1] = t end
    table.sort(tags)
    return self:put("/agent/session", key, {
        t = "epoch",
        c = string.format("第%d-%d轮（%d/%d 轮有信息）：\n%s", from, to, #lines, got,
            table.concat(lines, "\n")),
        from = from, to = to,
        tags = tags,
        ts = os.time(),
    }, TTL.permanent)
end

-- usage 落盘：进程一退，会话级命中率就没了，事后再想复盘"这一晚到底发了多少请求、
-- 前缀命中多少"只能靠猜。这里只存累计计数，一条 JSON 几百字节，每轮覆盖写一次。
--
-- 存 permanent 而不是 long：long 只有 1 天，隔天回来看就空了；usage 和 meta 一样
-- 属于"会话的账本"，跟着会话走。召回白名单只放 fact/turn/working，这个 key 不会被
-- recall 带进 prompt。
local USAGE_FIELDS = {
    "requests", "prompt", "completion", "cache_hit", "cache_miss",
    "prefix_hit", "prefix_denom",
    -- 前缀 reset 按原因分账：fold（摘要压缩）与 hard_window（丢弃兜底）代价不同，
    -- 混算的话命中率抖动无法归因。
    "reset_fold", "reset_hard", "reset_window", "reset_other",
    -- 每请求 miss 二分归因：紧跟 reset 的那条 vs 其余。均值差 =
    -- "trim 一次平均白付多少 token"，与"新增内容本来不可缓存"分开看。
    "miss_after_reset", "req_after_reset", "miss_clean", "req_clean",
    -- 没拿到真 usage（estimated 兜底）的请求数，不计入 cache_hit/cache_miss。
    "usage_unknown",
    -- reset 计数的起点（那一刻的 requests）。reset_* 是后加的字段，老快照里没有；
    -- 不记起点就会拿"整会话的 requests"当分母，把 trim 率算小一半以上
    -- （实测 3293/10872=30%，同口径其实是 3293/4045=81%）。
    "reset_epoch_requests",
}

function M:save_usage(session_id, usage)
    if type(usage) ~= "table" then return false end
    local sid = tostring(session_id or "session")
    local out = {}
    for _, k in ipairs(USAGE_FIELDS) do
        out[k] = math.floor(tonumber(usage[k]) or 0)
    end
    local last = type(usage.last) == "table" and usage.last or {}
    out.last_prompt = math.floor(tonumber(last.prompt) or 0)
    out.last_reuse = tonumber(last.reuse)
    out.last_reset = type(usage.last_reset) == "table" and usage.last_reset or nil
    -- 逐请求明细（环形）单独拷一份，别把 session 里的表引用塞进 KV：
    -- 那份还会被 add_usage 继续改，落盘的就该是快照。字段名压到一个字母，
    -- 24 条也就几百字节。
    local ring = type(usage.miss_ring) == "table" and usage.miss_ring or nil
    if ring and #ring > 0 then
        local copy, from = {}, 0
        local cap = 24
        if #ring > cap then from = #ring - cap end
        for i = from + 1, #ring do
            local e = ring[i]
            if type(e) == "table" then
                copy[#copy + 1] = {
                    p = math.floor(tonumber(e.p) or 0),
                    m = e.m and math.floor(tonumber(e.m) or 0) or nil,
                    u = e.u or nil,
                    r = e.r or nil,
                }
            end
        end
        if #copy > 0 then out.miss_ring = copy end
    end
    out.ts = os.time()
    return self:put("/agent/session", sid .. "/usage", out, TTL.permanent)
end

function M:load_usage(session_id)
    local sid = tostring(session_id or "session")
    local u = self:get("/agent/session", sid .. "/usage")
    if type(u) ~= "table" then return nil end
    return u
end

-- [埋点] usage 落点：`/agent/usage/day/<YYYY-MM-DD>` 是每日账本的唯一真身。
-- 每日用量桶：`/agent/usage` 下 `day/<YYYY-MM-DD>`，跨会话累加。
-- 会话级 usage 是"这个会话的账本"，覆盖写、跟着会话走；跨天/跨会话问
-- "今天比昨天烧得多不多"它答不了，所以另记一条按天累加的。
local USAGE_DAY_FIELDS = {
    "requests", "prompt", "completion", "cache_hit", "cache_miss",
}

function M:usage_daykey(day)
    return "day/" .. tostring(day or os.date("%Y-%m-%d"))
end

function M:add_usage_day(delta, day)
    if type(delta) ~= "table" then return false end
    local key = self:usage_daykey(day)
    local cur = self:get("/agent/usage", key)
    if type(cur) ~= "table" then cur = {} end
    cur.day = key:sub(5)
    for _, k in ipairs(USAGE_DAY_FIELDS) do
        cur[k] = math.floor((tonumber(cur[k]) or 0) + (tonumber(delta[k]) or 0))
    end
    cur.updated = os.time()
    return self:put("/agent/usage", key, cur, TTL.permanent)
end

function M:usage_day(day)
    local v = self:get("/agent/usage", self:usage_daykey(day))
    if type(v) ~= "table" then return nil end
    return v
end

-- 最近 n 天（含今天），日期升序；没账的天跳过。
function M:usage_days(n, now)
    n = math.max(1, math.floor(tonumber(n) or 7))
    now = now or os.time()
    local out = {}
    for i = n - 1, 0, -1 do
        local day = os.date("%Y-%m-%d", now - i * 86400)
        local v = self:usage_day(day)
        if v then
            v.day = day
            out[#out + 1] = v
        end
    end
    return out
end

local function utf8_chars(s)
    local out = {}
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        local n
        if b < 0x80 then n = 1
        elseif b < 0xE0 then n = 2
        elseif b < 0xF0 then n = 3
        else n = 4 end
        out[#out + 1] = s:sub(i, i + n - 1)
        i = i + n
    end
    return out
end

local function add_term(terms, seen, term)
    term = tostring(term or ""):lower()
    if #term >= 2 and not seen[term] then
        seen[term] = true
        terms[#terms + 1] = term
    end
end

-- 虚字表：CJK bigram 里两个音节都只是语气/代词/结构助词时，这条 term 不携带任何
-- 语义信息，却几乎每句中文都命中（「为什么」→ 为什/什么 曾把「为什么停下」召回到
-- 跟当前话题毫无关系的旧消息）。判据是「两个字都在表里」，只要有一个实词就放行，
-- 所以「为什么每个指令」里的 每个/个指/指令 不受影响。
local STOP_CHARS = {}
do
    local s = "的了吗呢吧啊呀嘛哦是我不你他她它们这那哪有和就都也还再又很太更最"
        .. "为什怎何如么样个些一上下中要会能可对把被给让从向于在以与及而但却只"
        .. "话说用做去来到过起出得地道着之其此该每"
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        local n = (b < 0x80) and 1 or (b < 0xE0 and 2 or (b < 0xF0 and 3 or 4))
        STOP_CHARS[s:sub(i, i + n - 1)] = true
        i = i + n
    end
end

local function all_stop(term)
    local chars = utf8_chars(term)
    if #chars == 0 then return false end
    for _, ch in ipairs(chars) do
        if not STOP_CHARS[ch] then return false end
    end
    return true
end

-- ASCII 词 + CJK bigram，避免中文 query 退化成“随机命中”。
local function build_terms(query)
    local terms, seen = {}, {}
    for w in query:gmatch("[%w_%-]+") do add_term(terms, seen, w) end

    local chars = utf8_chars(query)
    local cjk = {}
    for _, ch in ipairs(chars) do
        if #ch > 1 then cjk[#cjk + 1] = ch end
    end
    if #cjk == 1 and not STOP_CHARS[cjk[1]] then add_term(terms, seen, cjk[1]) end
    for i = 1, #chars - 1 do
        local a, b = chars[i], chars[i + 1]
        if #a > 1 and #b > 1 then
            local term = a .. b
            -- 全虚字的 bigram 不参与打分：它在几乎每句中文里都命中，IDF 也压不住。
            if not all_stop(term) then add_term(terms, seen, term) end
        end
    end

    if #terms > 32 then
        for i = #terms, 33, -1 do table.remove(terms, i) end
    end
    return terms
end

-- 从记忆导入某个 session 的历史轮次（JSONL 缺失时兜底）。
function M:session_message_count(id)
    local meta = self:session_meta(id)
    if meta and tonumber(meta.messages) then return tonumber(meta.messages) end
    local rows = self:search_prefix(
        string.format("/agent/session/%s/msg/", tostring(id)),
        { max_results = 0 })
    return #rows
end

function M:max_turn(session_id)
    local id = tostring(session_id)
    local rows = self:search_prefix(
        string.format("/agent/session/%s/turn/", id), { max_results = 0 })
    local max_n = 0
    for _, r in ipairs(rows) do
        local n = tonumber(tostring(r.key):match("/turn/(%d+)$"))
        if n and n > max_n then max_n = n end
    end
    local meta = self:session_meta(id)
    local by_meta = tonumber(meta and meta.turns) or 0
    return math.max(max_n, by_meta)
end

function M:session_messages(session_id, limit)
    limit = limit or 20
    local id = tostring(session_id)

    local msg_prefix = string.format("/agent/session/%s/msg/", id)
    local meta = self:session_meta(id)
    local count = meta and tonumber(meta.messages) or nil
    local msg_rows
    if count and count > 0 then
        local start = math.max(1, count - limit + 1)
        msg_rows = self:search_range(
            msg_prefix .. string.format("%08d", start),
            msg_prefix .. "99999999~",
            { max_results = limit })
    else
        msg_rows = self:search_prefix(msg_prefix, { max_results = 0 })
    end
    if #msg_rows > 0 then
        local msgs = {}
        for _, r in ipairs(msg_rows) do
            local ok, m = pcall(cjson.decode, r.value)
            if ok and type(m) == "table" then msgs[#msgs + 1] = m end
        end
        while #msgs > limit do table.remove(msgs, 1) end
        -- 真正的上界是 turn/ 里最大的编号：meta.turns 是 touch_session 记录的计数器，
        -- 恢复失败/崩溃退出时会落后于实际键，照它写下一轮就会覆盖 turn/1、turn/2。
        return msgs, self:max_turn(id)
    end

    local prefix = string.format("/agent/session/%s/turn/", id)
    local rows = self:search_prefix(prefix, { max_results = 0 })
    local turns, max_n = {}, 0
    for _, r in ipairs(rows) do
        local n = tonumber(tostring(r.key):match("/turn/(%d+)$"))
        local ok, data = pcall(cjson.decode, r.value)
        if n and ok and type(data) == "table" then
            turns[#turns + 1] = { n = n, data = data }
            if n > max_n then max_n = n end
        end
    end
    table.sort(turns, function(a, b) return a.n < b.n end)
    while #turns > limit do table.remove(turns, 1) end

    local msgs = {}
    for _, t in ipairs(turns) do
        if t.data.u then msgs[#msgs + 1] = { role = "user", content = tostring(t.data.u) } end
        if t.data.a then
            msgs[#msgs + 1] = { role = "assistant", content = tostring(t.data.a) }
        end
    end
    local meta = self:session_meta(id)
    return msgs, math.max(max_n, tonumber(meta and meta.turns) or 0)
end

function M:prune_session_messages(session_id, keep)
    local id = tostring(session_id)
    local meta = self:session_meta(id)
    local count = tonumber(meta and meta.messages) or 0
    keep = tonumber(keep) or 200
    if count <= keep then return 0 end
    local drop = count - keep
    local removed = 0
    for i = 1, drop do
        local sub = id .. "/msg/" .. string.format("%08d", i)
        local old = self:get("/agent/session", sub)
        if not (type(old) == "table" and old.role == "user") then
            if self:del("/agent/session", sub) then removed = removed + 1 end
        end
    end
    return removed
end

function M:recall(query, limit, opts)
    local p_t0 = prof and prof.now_ms()
    limit = limit or 6
    opts = opts or {}
    query = tostring(query or "")
    -- 召回统计：只看得到「注入了几条」，看不到「扫了多少候选、丢了多少」，
    -- 调权重就只能靠感觉。计数器只在进程内，stats() 里输出。
    local st = self.stat or { calls = 0, candidates = 0, injected = 0, dropped = 0 }
    self.stat = st
    st.calls = st.calls + 1
    local terms = build_terms(query)
    local session_prefix = "/agent/session/"
    local want_session = opts.session_id and (session_prefix .. tostring(opts.session_id) .. "/") or nil

    -- 自命中闸门：本轮刚落盘的用户原文（以及最近 skip_recent 条 msg）不参与召回。
    -- 它们本来就在窗口里，query 又正是这句话本身（prompt.recall_query 把最新 user 文本
    -- 直接当查询串），所以 100% 命中，白占名额把长期事实挤掉。
    local skip_text = opts.skip_text and tostring(opts.skip_text) or nil
    local cutoff_seq
    do
        local n = tonumber(opts.skip_recent) or 0
        if want_session and n > 0 then
            local ok_c, cnt = pcall(self.session_message_count, self, opts.session_id)
            if ok_c and tonumber(cnt) then cutoff_seq = tonumber(cnt) - n end
        end
    end

    -- 打分候选池：先收集原文（hay），扫完再统一按 IDF + 长度 + 年龄打分。
    -- 旧版 hits/#terms 让 200 字笔记和 2 万字整段对话同分，同分又按 a.key<b.key
    -- 排序（字典序里 msg<turn<working，越旧越靠前），所以召回质量一直不稳。
    local tstat = {}
    for _, w in ipairs(terms) do tstat[w] = { df = 0, w = 1 } end

    local seen, out, turns_kept = {}, {}, 0
    -- 被原始字节预筛剪掉、连 JSON 都没解的条目数。它只用于把 IDF 的 n 还原成
    -- 「不做预筛时的候选池大小」，保证打分结果与优化前逐位一致。
    local pruned = 0
    local working_prefix = "/agent/working/"
    local KNOW = "/agent/knowledge/"
    local SESS = "/agent/session/"

    -- 显式 recall（opts.transcript=true）才允许翻 assistant/tool 原文：
    -- 自动注入永远只要 user 原话，中间产物一条都不进每轮 prompt。
    local allow_transcript = opts.transcript == true
    -- 单条 transcript 的返回上限。tool 结果落盘时已截到 LITE_TOOL_RESULT_CHARS(8192)，
    -- 但 8192 字符一条 ×5 就顶满整个窗口；显式 recall 只是「看一眼那段」，
    -- 头 1200 字足够定位，要看全文再 recall 一次更窄的词或直接重跑命令。
    local transcript_max = tonumber(opts.transcript_max) or 1200

    -- 白名单：只放「长期事实」和「会话内可复用的轮次/工作笔记」进来。
    -- 原始 transcript（/<sid>/msg/<seq>）和 <sid>/meta 一律不注入：msg 是逐条原始
    -- JSON，一条就能吃掉整个字符预算，还会把最近几轮的原文反复塞给模型。
    local function allowed(key)
        if key:sub(1, #KNOW) == KNOW then return "fact" end
        if key:sub(1, #SESS) == SESS then
            local rest = key:sub(#SESS + 1)
            local kind = rest:match("^[^/]+/([^/]+)/")
            if kind == "turn" then return "turn" end
            -- epoch：每 N 轮折叠出的跨轮结论。它的存在就是为了「一次 recall 就能
            -- 拿到阶段性答案」，所以直连白名单，权重也高于单轮 turn。
            if kind == "epoch" then return "epoch" end
            if kind == "working" then return "working" end
            -- 原始 transcript：自动注入只放 user 原文（用户自己的话不过期）；
            -- 显式 recall 时额外放 assistant/tool（kind="trunc"，低权重、有截断），
            -- 否则 hard_window 丢掉的 tool 结果就是黑洞——文案让模型 recall，
            -- 却什么也捞不回来。
            if kind == "msg" then return allow_transcript and "trunc" or "user" end
        end
        return nil
    end

    -- epoch 排在 fact 与 working 之间：它比单轮 turn 更值钱（跨轮结论），
    -- 但仍不该盖过人工 remember 下来的长期事实。
    -- kinds：显式收窄到某一层。recall(query, kind="fact") 这种指令不该被
    -- turn 的同词命中稀释——模型问「之前定的结论」，要的就是结论层。
    local kinds
    if opts.kind and opts.kind ~= "" then
        kinds = {}
        for _, k in ipairs(type(opts.kind) == "table" and opts.kind or { opts.kind }) do
            kinds[tostring(k)] = true
        end
    end
    local WEIGHT = { fact = 1.0, epoch = 0.85, working = 0.9, user = 0.8, turn = 0.6, trunc = 0.35 }

    local function add(r)
        -- 目录级 /agent/working（wake 调度状态、todos 兜底）属于运行态：
        -- 既不该跨会话注入，也不该被 tag 检索带进来。
        if r.key:sub(1, #working_prefix) == working_prefix then return end
        local kind = allowed(r.key)
        if not kind then return end
        -- kind 过滤放在 add()：白名单外的类别根本不进候选池。这样 df/IDF 也只在
        -- 同一层里估，不会被另一层的词频带偏（fact 里的「文件」不该压低 turn 里
        -- 同一个词的权重）。
        if want_session and r.key:sub(1, #session_prefix) == session_prefix then
            if r.key:sub(1, #want_session) ~= want_session then return end
        end
        if seen[r.key] then return end
        seen[r.key] = true
        -- 解码前按原始字节预筛。候选要得分，某个 term 必须出现在它的文本或 tags 里，
        -- 而这两者（正文 + data.tags）都原样躺在 value 的 JSON 里。JSON 转义会让字面
        -- 匹配失效（"\u4f18" 里没有「优」的字节），所以只在 value 不含反斜杠时才敢剪：
        -- 没有转义 = 字节即文本，此时「一个 term 都不出现」与打分阶段的 hits>0 淘汰
        -- 完全等价——它们命中数恒为 0，本来就进不了 kept，剪掉的只是 cjson 解码开销。
        -- 实测真实查询能剪掉候选池的 5%~40%（长尾窄查询剪得最狠）。
        -- 与打分口径严格对齐，否则就是误剪（真实回归：含大写 "LITE-42" 的条目
        -- 在预筛阶段被剪掉，recall 直接返回 0）。打分比的是 hay=(text.." "..key):lower()，
        -- 所以这里必须 ①大小写归一 ②把 key 也算进来（term 可能只命中 key 里的
        -- 路径片段如 "turn/"），缺一不可。JSON 里 text 与 tags 都是原样字节，
        -- 故「JSON 里一个 term 都没有」⟹「text 里没有」，剪掉的必然 hits==0。
        if #terms > 0 and not r.value:find("\\", 1, true) then
            local hit = false
            for j = 1, #terms do
                if r.value:find(terms[j], 1, true) then hit = true; break end
            end
            if not hit then
                -- 原始字节没中才付小写拷贝（:lower 只动 ASCII，CJK 字节原样）。
                local lowv = r.value:lower()
                local lowk = r.key:lower()
                for j = 1, #terms do
                    local w = terms[j]
                    if lowv:find(w, 1, true) or lowk:find(w, 1, true) then
                        hit = true; break
                    end
                end
            end
            if not hit then pruned = pruned + 1; return end
        end
        local ok, data = pcall(cjson.decode, r.value)
        -- 解码失败的条目不是「文本」，是坏数据（写一半、加密残留、二进制尾巴）。
        -- 早先回退成 { c = r.value } 会把这些字节原样拼进 prompt。
        if not ok or type(data) ~= "table" then return end
        if kind == "user" and data.role ~= "user" then return end
        if kind == "trunc" then
            -- user 原话一旦被显式召回，按 user 权重算；assistant/tool 才走低权重。
            if data.role == "user" then
                kind = "user"
            elseif data.role ~= "tool" and data.role ~= "assistant" then
                return
            end
        end
        if kinds and not kinds[kind] then return end
        if kind == "user" and cutoff_seq then
            local seq = tonumber(r.key:match("/(%d+)$") or "")
            if seq and seq > cutoff_seq then return end
        end
        local text
        if kind == "user" or kind == "trunc" then
            if type(data.content) ~= "string" then return end
            text = kind == "trunc" and clip_utf8(data.content, transcript_max) or data.content
        elseif data.t == "turn" and data.u then
            text = tostring(data.u) .. " => " .. tostring(data.a or "")
        else
            text = tostring(data.c or data.a or "")
        end
        if text == "" then return end
        if skip_text and skip_text ~= "" and text == skip_text then return end
        local tl = {}
        for _, t in ipairs(data.tags or {}) do tl[#tl + 1] = tostring(t):lower() end
        out[#out + 1] = {
            key = r.key, data = data, text = text, kind = kind,
            ts = tonumber(data.ts),
            hay = (text .. " " .. r.key):lower(),
            tags_low = table.concat(tl, " "),
        }
    end

    -- 只召回长期事实与会话内内容。
    -- 目录级 /agent/working（wake 调度状态、todos 兜底）属于运行态，不注入 prompt；
    -- 会话级工作记忆在 /agent/session/<id>/working/，由下面的 session 前缀覆盖。
    -- 扫描分槽：knowledge 一次；会话内按 turn/ working/ msg/ 分开扫。
    -- 旧版按 "/agent/session/<sid>/" 整棵前缀扫，字典序 msg<turn<working，
    -- 长会话里 msg 把候选窗口吃满，turn/working 永远进不了候选。
    -- 候选池：IDF 的 df 是在候选池上估的，池子只比 limit 大一点时，
    -- df 估计方差极大（一个词在全库很常见，在小池子里可能只出现 1 次 → 被当成
    -- 稀有词重奖），而长尾的相关轮次压根进不了池。旧版 limit*8，limit=6 时
    -- 候选只有 48 条，等于在 48 条上给全库打分。放到底线 160、随 limit 线性放宽，
    -- 再设上限防止大 limit 把扫描次数炸掉；最终条数仍由 limit 卡。
    local cand = tonumber(opts.candidates)
    if not cand or cand <= 0 then
        cand = math.max(limit * 8, 160)
        if cand > 600 then cand = 600 end
    end
    local scans = 0
    local function scan(p, n)
        scans = scans + 1
        for _, r in ipairs(self:search_prefix(p, { max_results = n or cand })) do
            add(r)
        end
    end
    scan("/agent/knowledge/")
    if want_session then
        scan(want_session .. "turn/")
        scan(want_session .. "epoch/")
        scan(want_session .. "working/")
        -- msg/ 也扫：user 原文永久保留（add() 按 role 过滤掉 assistant/tool）。
        -- 单独一槽 + 有界，不会像旧版整棵前缀扫那样把 turn/working 挤掉。
        scan(want_session .. "msg/", math.floor(cand / 2))
    else
        -- 跨会话召回（recall 工具）：按 cwd 索引取最近几个会话，逐个扫 turn/ 与
        -- working/，每个槽有界，不会被 msg/meta 挤掉。
        local ok_s, list = pcall(self.list_sessions, self, opts.cwd or self.cwd, 6)
        if ok_s and type(list) == "table" then
            for _, meta in ipairs(list) do
                if type(meta) == "table" and meta.id then
                    local base = session_prefix .. meta.id .. "/"
                    scan(base .. "turn/", math.floor(cand / 4))
                    scan(base .. "epoch/", math.floor(cand / 6))
                    scan(base .. "working/", math.floor(cand / 8))
                end
            end
        end
    end

    -- tag 检索：旧版对每个 term 各扫一次（terms 上限 32 → 每轮 30+ 次线性扫描）。
    -- 前 8 个 term 覆盖绝大部分命中，长尾丢掉换扫描次数。
    -- 现在走 cache.search_tags：一批 term 一遍遍历（索引命中照旧 O(1)，未命中的
    -- term 回退 value 子串扫描但全库只走一趟），结果与逐个调用取并集相同。
    do
        local slice = {}
        for i = 1, math.min(#terms, 8) do slice[#slice + 1] = terms[i] end
        if #slice > 0 then
            scans = scans + 1
            for _, r in ipairs(cache.search_tags(self.h, slice,
                { max_results = math.floor(cand / 2) * #slice })) do
                add(r)
            end
        end
    end

    -- 统一打分：IDF（候选里到处出现 = 不值钱）+ 长度归一（长文命中更廉价）
    -- + 年龄衰减（30 天减半）。空/无命中直接淘汰，不再「人人 0.5」。
    -- n 是「不预筛时的候选池大小」：pruned 那些条目一个 term 都没命中，对 df 没有
    -- 贡献，但旧版它们也计入 n，IDF 基数就用它，补回去打分结果才与旧版逐位相同。
    local n = #out + pruned
    -- 命中位图：第 j 个 term 命中本条目时置 bit(j-1)。上面 drain 一遍，下面打分
    -- 直接查位，不再对 hay/tags_low 做第二趟子串查找（旧版两趟各 candidates×terms 次）。
    -- terms 上限 32（build_terms 截断），正好一个 32 位掩码装得下。
    local hbits, tbits = {}, {}
    for i = 1, #out do
        local it = out[i]
        local hb, tb = 0, 0
        for j = 1, #terms do
            local w = terms[j]
            if it.hay:find(w, 1, true) then
                tstat[w].df = tstat[w].df + 1
                hb = bit.bor(hb, bit.lshift(1, j - 1))
            elseif it.tags_low:find(w, 1, true) then
                tstat[w].df = tstat[w].df + 1
                tb = bit.bor(tb, bit.lshift(1, j - 1))
            end
        end
        hbits[i], tbits[i] = hb, tb
    end
    for _, w in ipairs(terms) do
        tstat[w].w = math.log(1 + (n + 1) / (tstat[w].df + 1))
    end
    -- tot 是「所有 term 权重之和」，与候选条目无关，从逐条循环里提出来算一次。
    local totw = 0
    for _, w in ipairs(terms) do totw = totw + tstat[w].w end
    local now = os.time()
    -- 衰减半径按 kind 分开。原先一律 30 天减半，等于把刚做的「turn 永久化」在
    -- 打分阶段又抵消掉：存了 90 天的 turn decay≈0.25，同分必被新 turn 挤掉，
    -- 库里永久存在、召回里等于不存在。提炼层（turn/epoch）比原始对话慢一个
    -- 数量级老化，原始 transcript 反而该掉得更快。
    local DECAY_DAYS = { turn = 180, epoch = 365, trunc = 14 }
    st.candidates = st.candidates + #out
    st.scans = (st.scans or 0) + scans
    local kept = {}
    for i = 1, #out do
        local it = out[i]
        local hb, tb = hbits[i], tbits[i]
        local hits = 0
        for j = 1, #terms do
            local b = bit.lshift(1, j - 1)
            if bit.band(hb, b) ~= 0 then
                hits = hits + tstat[terms[j]].w
            elseif bit.band(tb, b) ~= 0 then
                hits = hits + tstat[terms[j]].w * 0.5
            end
        end
        if hits > 0 then
            -- epoch 天生比单轮长（多轮拼装），长度惩罚会把「信息多」当成
            -- 「注水多」来罚，正好罚反。它的长度是结构性的，给满分。
            local lenpen = it.kind == "epoch" and 1 or (1 / (1 + math.log(1 + #it.text / 600)))
            local age = it.ts and math.max(0, now - it.ts) or 0
            local decay = 1 / (1 + age / ((DECAY_DAYS[it.kind] or 30) * 86400))
            it.score = (hits / math.max(totw, 1e-9)) * lenpen * decay * (WEIGHT[it.kind] or 1.0)
            kept[#kept + 1] = it
        end
    end
    out = kept
    table.sort(out, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if (a.ts or 0) ~= (b.ts or 0) then return (a.ts or 0) > (b.ts or 0) end
        return a.key > b.key
    end)
    if #out > limit then
        for i = #out, limit + 1, -1 do table.remove(out, i) end
    end
    -- 最多两条 transcript：轮次权重已经调低，但同分时仍可能挤满整块，
    -- 而重复的旧对话对下一轮几乎没有信息量。事实/工作笔记不受此限。
    local keep = {}
    local users_kept, truncs_kept, epochs_kept = 0, 0, 0
    for _, it in ipairs(out) do
        if it.kind == "turn" then
            turns_kept = turns_kept + 1
            if turns_kept > 2 then goto continue end
        elseif it.kind == "epoch" then
            -- epoch 是本层最值钱的条目，但也别让它把整块记忆占满：两段就能
            -- 交代一个阶段的来龙去脉，再多就该收紧查询词了。
            epochs_kept = epochs_kept + 1
            if epochs_kept > 2 then goto continue end
        elseif it.kind == "user" then
            users_kept = users_kept + 1
            if users_kept > 4 then goto continue end
        elseif it.kind == "trunc" then
            -- 显式 recall 的原文只是「回看一眼」，3 条封顶：再多就把窗口
            -- 从「模型自己想 recall 的那段」挤回「一堆中间产物」。
            truncs_kept = truncs_kept + 1
            if truncs_kept > 3 then goto continue end
        end
        keep[#keep + 1] = it
        ::continue::
    end
    -- 返回预算：显式 recall 的每条文本按 item_chars 取命中窗口（不是头部截断）。
    -- 0/未给 = 不限，保持旧行为。
    local item_chars = tonumber(opts.item_chars) or 0
    if item_chars > 0 then
        for _, it in ipairs(keep) do
            it.text = clip_window(it.text, item_chars, terms)
        end
    end
    st.injected = st.injected + #keep
    st.dropped = st.dropped + math.max(0, #out - #keep)
    if p_t0 then
        prof.record("memory.recall", prof.now_ms() - p_t0, true, #keep)
        prof.hist("memory.recall_items", #keep)
    end
    return keep
end

-- 搜索 + 组装：按字符预算拼成可注入 prompt 的记忆块。
function M:assemble(query, opts)
    opts = opts or {}
    local items = self:recall(query, tonumber(opts.limit) or 6, opts)
    return Prompt.memory_block(items, opts), items
end

function M:context(query, limit)
    if type(limit) == "table" then return self:assemble(query, limit) end
    return self:assemble(query, { limit = limit })
end

function M:search(query, opts)
    return self:recall(query, (opts and opts.limit) or 6)
end

function M:stats()
    if not self.h then return {} end
    local st = self.stat or {}
    return {
        count = cache.count(self.h),
        used = cache.memory_used(self.h),
        max = cache.memory_max(self.h),
        recall_calls = st.calls or 0,
        recall_candidates = st.candidates or 0,
        recall_scans = st.scans or 0,
        recall_injected = st.injected or 0,
        recall_dropped = st.dropped or 0,
        del_miss = self.del_miss or 0,
    }
end

return M
