-- 上下文记忆：基于 my_db KV cache（mmap 零拷贝 + 前缀/模糊/标签搜索）。
local cjson = require("cjson")
local ffi = require("ffi")
local bit = require("bit")
local cache = require("ffi.cache")
local Prompt = require("core.prompt")
local net = require("core.net")

pcall(ffi.cdef, [[
int open(const char *pathname, int flags, unsigned int mode);
int flock(int fd, int operation);
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
    if not readonly and ffi.C.flock(lock_fd, bit.bor(LOCK_EX, LOCK_NB)) ~= 0 then
        -- 抢不到锁：降级为只读实例，进程继续跑（不写记忆、不刷盘）。
        ffi.C.flock(lock_fd, LOCK_UN)
        net.close(lock_fd)
        lock_fd = nil
        readonly = true
        lock_busy = true
    end

    local h = cache.open(base, (opts.max_mb or 100) * 1024 * 1024)
    if not h then
        ffi.C.flock(lock_fd, LOCK_UN)
        net.close(lock_fd)
        return nil, "cache_open failed: " .. base
    end
    return setmetatable({
        h = h,
        dir = base,
        lock_fd = lock_fd,
        readonly = readonly,
        lock_busy = lock_busy,
        flush_ms = (tonumber(opts.flush_sec) or 30) * 1000,
        last_sync = os.time() * 1000,
    }, M)
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
    if self.readonly then return nil end
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

function M:put(ns, key, value, ttl)
    if self.readonly then return false, "readonly memory" end
    local full = join(ns, key)
    local ok, s = pcall(cjson.encode, value)
    if not ok then return false, s end
    return cache.set(self.h, full, s, ttl or 0) == 0
end

function M:get(ns, key)
    local s = cache.get(self.h, join(ns, key))
    if not s then return nil end
    local ok, v = pcall(cjson.decode, s)
    return ok and v or s
end

function M:del(ns, key)
    if self.readonly then return false end
    return cache.del(self.h, join(ns, key)) == 0
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

-- 单轮对话落盘上限：assistant 侧可能是整段工具循环输出，原样存会让一条 turn
-- 赶上几十 KB（实测 63KB），召回预算被一条记录吃光。截断而不是丢弃。
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
        u = clip_utf8(user, TURN_USER_MAX),
        a = clip_utf8(assistant, TURN_ASSIST_MAX),
        tools = tool_names(tools),
        ts = os.time(),
    }, TTL.long)
    self:touch_session(sid, nil, nil, user, turn)
    return ok
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
    local working_prefix = "/agent/working/"
    local KNOW = "/agent/knowledge/"
    local SESS = "/agent/session/"

    -- 白名单：只放「长期事实」和「会话内可复用的轮次/工作笔记」进来。
    -- 原始 transcript（/<sid>/msg/<seq>）和 <sid>/meta 一律不注入：msg 是逐条原始
    -- JSON，一条就能吃掉整个字符预算，还会把最近几轮的原文反复塞给模型。
    local function allowed(key)
        if key:sub(1, #KNOW) == KNOW then return "fact" end
        if key:sub(1, #SESS) == SESS then
            local rest = key:sub(#SESS + 1)
            local kind = rest:match("^[^/]+/([^/]+)/")
            if kind == "turn" then return "turn" end
            if kind == "working" then return "working" end
            -- 原始 transcript：只有 user 原文放行（用户自己的话不过期），assistant/tool
            -- 的原始 JSON 一律不进 prompt —— 下面 add() 里按 data.role 二次过滤。
            if kind == "msg" then return "user" end
        end
        return nil
    end

    local WEIGHT = { fact = 1.0, working = 0.9, user = 0.8, turn = 0.6 }

    local function add(r)
        -- 目录级 /agent/working（wake 调度状态、todos 兜底）属于运行态：
        -- 既不该跨会话注入，也不该被 tag 检索带进来。
        if r.key:sub(1, #working_prefix) == working_prefix then return end
        local kind = allowed(r.key)
        if not kind then return end
        if want_session and r.key:sub(1, #session_prefix) == session_prefix then
            if r.key:sub(1, #want_session) ~= want_session then return end
        end
        if seen[r.key] then return end
        seen[r.key] = true
        local ok, data = pcall(cjson.decode, r.value)
        -- 解码失败的条目不是「文本」，是坏数据（写一半、加密残留、二进制尾巴）。
        -- 早先回退成 { c = r.value } 会把这些字节原样拼进 prompt。
        if not ok or type(data) ~= "table" then return end
        if kind == "user" and data.role ~= "user" then return end
        if kind == "user" and cutoff_seq then
            local seq = tonumber(r.key:match("/(%d+)$") or "")
            if seq and seq > cutoff_seq then return end
        end
        local text
        if kind == "user" then
            if type(data.content) ~= "string" then return end
            text = data.content
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
    local scans = 0
    local function scan(p, n)
        scans = scans + 1
        for _, r in ipairs(self:search_prefix(p, { max_results = n or limit * 8 })) do
            add(r)
        end
    end
    scan("/agent/knowledge/")
    if want_session then
        scan(want_session .. "turn/")
        scan(want_session .. "working/")
        -- msg/ 也扫：user 原文永久保留（add() 按 role 过滤掉 assistant/tool）。
        -- 单独一槽 + 有界，不会像旧版整棵前缀扫那样把 turn/working 挤掉。
        scan(want_session .. "msg/", limit * 4)
    else
        -- 跨会话召回（recall 工具）：按 cwd 索引取最近几个会话，逐个扫 turn/ 与
        -- working/，每个槽有界，不会被 msg/meta 挤掉。
        local ok_s, list = pcall(self.list_sessions, self, opts.cwd or self.cwd, 6)
        if ok_s and type(list) == "table" then
            for _, meta in ipairs(list) do
                if type(meta) == "table" and meta.id then
                    local base = session_prefix .. meta.id .. "/"
                    scan(base .. "turn/", limit * 4)
                    scan(base .. "working/", limit * 2)
                end
            end
        end
    end

    -- tag 检索：旧版对每个 term 各扫一次（terms 上限 32 → 每轮 30+ 次线性扫描）。
    -- 前 8 个 term 覆盖绝大部分命中，长尾丢掉换扫描次数。
    for i = 1, math.min(#terms, 8) do
        scans = scans + 1
        for _, r in ipairs(cache.search_tag(self.h, terms[i], { max_results = limit * 4 })) do
            add(r)
        end
    end

    -- 统一打分：IDF（候选里到处出现 = 不值钱）+ 长度归一（长文命中更廉价）
    -- + 年龄衰减（30 天减半）。空/无命中直接淘汰，不再「人人 0.5」。
    local n = #out
    for _, it in ipairs(out) do
        for _, w in ipairs(terms) do
            if it.hay:find(w, 1, true) or it.tags_low:find(w, 1, true) then
                tstat[w].df = tstat[w].df + 1
            end
        end
    end
    for _, w in ipairs(terms) do
        tstat[w].w = math.log(1 + (n + 1) / (tstat[w].df + 1))
    end
    local now = os.time()
    st.candidates = st.candidates + #out
    local kept = {}
    for _, it in ipairs(out) do
        local hits, tot = 0, 0
        for _, w in ipairs(terms) do
            local tw = tstat[w].w
            tot = tot + tw
            if it.hay:find(w, 1, true) then
                hits = hits + tw
            elseif it.tags_low:find(w, 1, true) then
                hits = hits + tw * 0.5
            end
        end
        if hits > 0 then
            local lenpen = 1 / (1 + math.log(1 + #it.text / 600))
            local age = it.ts and math.max(0, now - it.ts) or 0
            local decay = 1 / (1 + age / (30 * 86400))
            it.score = (hits / math.max(tot, 1e-9)) * lenpen * decay * (WEIGHT[it.kind] or 1.0)
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
    local users_kept = 0
    for _, it in ipairs(out) do
        if it.kind == "turn" then
            turns_kept = turns_kept + 1
            if turns_kept > 2 then goto continue end
        elseif it.kind == "user" then
            users_kept = users_kept + 1
            if users_kept > 4 then goto continue end
        end
        keep[#keep + 1] = it
        ::continue::
    end
    st.injected = st.injected + #keep
    st.dropped = st.dropped + math.max(0, #out - #keep)
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
        recall_injected = st.injected or 0,
        recall_dropped = st.dropped or 0,
    }
end

return M
