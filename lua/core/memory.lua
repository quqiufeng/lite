-- 上下文记忆：基于 my_db KV cache（mmap 零拷贝 + 前缀/模糊/标签搜索）。
local cjson = require("cjson")
local cache = require("ffi.cache")
local Prompt = require("core.prompt")

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
    local h = cache.open(base, (opts.max_mb or 100) * 1024 * 1024)
    if not h then return nil, "cache_open failed: " .. base end
    return setmetatable({
        h = h,
        dir = base,
        flush_ms = (tonumber(opts.flush_sec) or 30) * 1000,
        last_sync = os.time() * 1000,
    }, M)
end

function M:close()
    if self.h then
        cache.sync(self.h)
        cache.close(self.h)
        self.h = nil
    end
end

function M:sync()
    if not self.h then return nil end
    self.last_sync = os.time() * 1000
    return cache.sync(self.h)
end

-- 主循环/agent 定期调用：默认 30 秒落盘一次。
function M:tick(now_ms)
    if not self.h then return false end
    now_ms = now_ms or (os.time() * 1000)
    if now_ms - (self.last_sync or 0) >= (self.flush_ms or 30000) then
        self:sync()
        return true
    end
    return false
end

function M:put(ns, key, value, ttl)
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
    return cache.del(self.h, join(ns, key)) == 0
end

function M:search_prefix(prefix, opts)
    return cache.search_prefix(self.h, prefix, opts or { max_results = 100 })
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
        if not cwd then return nil end
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

function M:remember_working(key, content, ttl)
    return self:put("/agent/working", key, {
        t = "working",
        c = content,
        ts = os.time(),
    }, ttl or TTL.working)
end

function M:remember_turn(session_id, turn, user, assistant, tools)
    local key = string.format("%s/turn/%d", session_id or "session", turn or 0)
    local ok = self:put("/agent/session", key, {
        t = "turn",
        u = user,
        a = assistant,
        tools = tools,
        ts = os.time(),
    }, TTL.long)
    self:touch_session(session_id, nil, nil, user, turn)
    return ok
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

-- ASCII 词 + CJK bigram，避免中文 query 退化成“随机命中”。
local function build_terms(query)
    local terms, seen = {}, {}
    for w in query:gmatch("[%w_%-]+") do add_term(terms, seen, w) end

    local chars = utf8_chars(query)
    local cjk = {}
    for _, ch in ipairs(chars) do
        if #ch > 1 then cjk[#cjk + 1] = ch end
    end
    if #cjk == 1 then add_term(terms, seen, cjk[1]) end
    for i = 1, #chars - 1 do
        local a, b = chars[i], chars[i + 1]
        if #a > 1 and #b > 1 then add_term(terms, seen, a .. b) end
    end

    if #terms > 32 then
        for i = #terms, 33, -1 do table.remove(terms, i) end
    end
    return terms
end

-- 从记忆导入某个 session 的历史轮次（JSONL 缺失时兜底）。
function M:session_message_count(id)
    local rows = self:search_prefix(
        string.format("/agent/session/%s/msg/", tostring(id)),
        { max_results = 0 })
    return #rows
end

function M:session_messages(session_id, limit)
    limit = limit or 20
    local id = tostring(session_id)

    local msg_rows = self:search_prefix(
        string.format("/agent/session/%s/msg/", id),
        { max_results = 0 })
    if #msg_rows > 0 then
        local msgs = {}
        for _, r in ipairs(msg_rows) do
            local ok, m = pcall(cjson.decode, r.value)
            if ok and type(m) == "table" then msgs[#msgs + 1] = m end
        end
        while #msgs > limit do table.remove(msgs, 1) end
        local meta = self:session_meta(id)
        return msgs, (meta and tonumber(meta.turns)) or 0
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

function M:recall(query, limit, opts)
    limit = limit or 6
    opts = opts or {}
    query = tostring(query or "")
    local terms = build_terms(query)
    local session_prefix = "/agent/session/"
    local want_session = opts.session_id and (session_prefix .. tostring(opts.session_id) .. "/") or nil

    local function score(text, key, tags)
        if #terms == 0 then return 0.5 end
        local hay = (tostring(text) .. " " .. tostring(key)):lower()
        local hits = 0
        for _, w in ipairs(terms) do
            if hay:find(w, 1, true) then hits = hits + 1 end
        end
        for _, t in ipairs(tags or {}) do
            local tl = tostring(t):lower()
            for _, w in ipairs(terms) do
                if tl == w then hits = hits + 1 end
            end
        end
        if hits == 0 then return 0 end
        return hits / #terms
    end

    local seen, out = {}, {}
    local function add(r)
        if want_session and r.key:sub(1, #session_prefix) == session_prefix then
            if r.key:sub(1, #want_session) ~= want_session then return end
        end
        if seen[r.key] then return end
        seen[r.key] = true
        local ok, data = pcall(cjson.decode, r.value)
        data = ok and data or { c = r.value }
        local text
        if data.t == "turn" and data.u then
            text = tostring(data.u) .. " => " .. tostring(data.a or "")
        else
            text = tostring(data.c or data.a or r.value)
        end
        local sc = score(text, r.key, data.tags)
        if sc > 0 then
            out[#out + 1] = { key = r.key, data = data, text = text, score = sc }
        end
    end

    local prefixes = { "/agent/knowledge/", "/agent/working/" }
    prefixes[#prefixes + 1] = want_session or session_prefix
    for _, p in ipairs(prefixes) do
        for _, r in ipairs(self:search_prefix(p, { max_results = limit * 8 })) do
            add(r)
        end
    end

    for _, w in ipairs(terms) do
        for _, r in ipairs(cache.search_tag(self.h, w, { max_results = limit * 4 })) do
            add(r)
        end
    end

    table.sort(out, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.key < b.key
    end)
    if #out > limit then
        for i = #out, limit + 1, -1 do table.remove(out, i) end
    end
    return out
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
    return {
        count = cache.count(self.h),
        used = cache.memory_used(self.h),
        max = cache.memory_max(self.h),
    }
end

return M
