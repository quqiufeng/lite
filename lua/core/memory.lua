-- 上下文记忆：基于 my_db KV cache（mmap 零拷贝 + 前缀/模糊/标签搜索）。
local cjson = require("cjson")
local cache = require("ffi.cache")

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
    }, TTL.short)
    self:remember_working("last", (user or "") .. "\n" .. (assistant or ""))
    return ok
end

function M:recall(query, limit)
    limit = limit or 6
    query = tostring(query or "")
    local q = query:lower()

    local words = {}
    for w in q:gmatch("[%w_%-]+") do
        if #w >= 2 then words[#words + 1] = w end
    end

    local function score(text, key, tags)
        if #words == 0 then return 0.5 end
        local hay = (tostring(text) .. " " .. tostring(key)):lower()
        local hits = 0
        for _, w in ipairs(words) do
            if hay:find(w, 1, true) then hits = hits + 1 end
        end
        for _, t in ipairs(tags or {}) do
            local tl = tostring(t):lower()
            for _, w in ipairs(words) do
                if tl == w then hits = hits + 1 end
            end
        end
        if hits == 0 then return 0 end
        return hits / #words
    end

    local seen, out = {}, {}
    local function add(r)
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

    for _, p in ipairs({ "/agent/knowledge/", "/agent/session/", "/agent/working/" }) do
        for _, r in ipairs(self:search_prefix(p, { max_results = limit * 8 })) do
            add(r)
        end
    end

    for _, w in ipairs(words) do
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
    local limit = tonumber(opts.limit) or 6
    local max_chars = tonumber(opts.max_chars) or 2000
    local item_chars = tonumber(opts.item_chars) or 400

    local items = self:recall(query, limit)
    if #items == 0 then return "" end

    local lines = { "Relevant memory (local KV cache):" }
    local used = #lines[1]
    for _, it in ipairs(items) do
        local text = tostring(it.text or ""):gsub("%s+", " ")
        if #text > item_chars then text = text:sub(1, item_chars) .. "..." end
        local line = "- [" .. it.key .. "] " .. text
        if used + #line + 1 > max_chars then break end
        lines[#lines + 1] = line
        used = used + #line + 1
    end
    return table.concat(lines, "\n")
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
