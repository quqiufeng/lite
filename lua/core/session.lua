-- 会话持久化：JSONL，一条消息一行。
local cjson = require("cjson")

local M = {}
M.__index = M

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function default_dir()
    return (os.getenv("XDG_DATA_HOME") or ((os.getenv("HOME") or ".") .. "/.local/share"))
        .. "/lite/sessions"
end

-- 原始 transcript 只保留最近 N 条；更老的只靠 turn 摘要/事实召回。
-- tool 结果通常是最大的一块，入库前先截断，避免一条命令吃满 mem.bin。
local RAW_KEEP = tonumber(os.getenv("LITE_SESSION_RAW_KEEP")) or 200
local TOOL_STORE_MAX = tonumber(os.getenv("LITE_TOOL_RESULT_CHARS")) or 8192
local JSONL_PRUNE_EVERY = 64

local function clip_utf8(s, max)
    s = tostring(s or "")
    if max <= 0 or #s <= max then return s end
    local cut = max
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut) .. "…"
end

local function store_copy(msg, limit)
    if type(msg) ~= "table" or msg.role ~= "tool" then return msg end
    if type(msg.content) ~= "string" or #msg.content <= limit then return msg end
    return {
        role = msg.role,
        tool_call_id = msg.tool_call_id,
        content = clip_utf8(msg.content, limit),
    }
end

local function prune_jsonl(self)
    local f = io.open(self.path, "r")
    if not f then return end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
    if #lines <= self.raw_keep then return end
    local tmp = self.path .. ".tmp"
    local w = io.open(tmp, "w")
    if not w then return end
    local keep_from = #lines - self.raw_keep + 1
    for i, line in ipairs(lines) do
        local keep = i >= keep_from
        if not keep then
            local ok, msg = pcall(cjson.decode, line)
            keep = ok and type(msg) == "table" and msg.role == "user"
        end
        if keep then w:write(line, "\n") end
    end
    w:close()
    os.rename(tmp, self.path)
end

function M.recent_ids(dir, limit)
    dir = dir or default_dir()
    limit = limit or 10
    local ids = {}
    local p = io.popen("ls -1t " .. shq(dir) .. "/*.jsonl 2>/dev/null")
    if not p then return ids end
    for line in p:lines() do
        local id = line:match("([^/]+)%.jsonl$")
        if id then
            ids[#ids + 1] = id
            if #ids >= limit then break end
        end
    end
    p:close()
    return ids
end

function M.new_id()
    local base = os.date("%Y%m%d-%H%M%S")
    local id = base
    local n = 1
    while true do
        local f = io.open(default_dir() .. "/" .. id .. ".jsonl", "r")
        if not f then break end
        f:close()
        n = n + 1
        id = base .. "-" .. n
    end
    return id
end

function M.clean(messages)
    local out = {}
    for _, m in ipairs(messages or {}) do
        if m.role ~= "system" then out[#out + 1] = m end
    end
    return out
end

-- 去掉尾部多余的 "/"，根目录除外。
local function norm_cwd(p)
    p = tostring(p or "")
    if p == "/" then return p end
    return (p:gsub("/+$", ""))
end

-- 从 system prompt 里取 <cwd>...</cwd> 的精确值（prompt.lua 生成）。
-- 旧会话没有这一段时返回 nil。
local function system_cwd(content)
    if type(content) ~= "string" then return nil end
    local v = content:match("<cwd>%s*\n(.-)\n%s*</cwd>")
    if not v then return nil end
    return norm_cwd(v)
end

local function is_path_char(c)
    return c ~= "" and c:match("[%w%-%._~/]") ~= nil
end

-- 旧会话（无 <cwd> 段）兜底：子串命中还要求两侧都是路径边界，
-- 否则 /a/b 会误命中 /a/b/c 的会话（换到父目录时把子目录的对话带出来）。
local function cwd_mentioned(content, cwd)
    local text = tostring(content)
    local i = 1
    while true do
        local a, b = text:find(cwd, i, true)
        if not a then return false end
        local before = a > 1 and text:sub(a - 1, a - 1) or ""
        local after = text:sub(b + 1, b + 1)
        if not is_path_char(before) and not is_path_char(after) then return true end
        i = a + 1
    end
end

-- 该会话是否属于 cwd：有 <cwd> 段就精确比对，没有才退回边界匹配。
local function session_matches_cwd(msgs, cwd)
    cwd = norm_cwd(cwd)
    for _, m in ipairs(msgs) do
        if m.role == "system" then
            local marked = system_cwd(m.content)
            if marked then return marked == cwd end
        end
    end
    for _, m in ipairs(msgs) do
        if m.role == "system" and cwd_mentioned(m.content, cwd) then return true end
    end
    return false
end

function M.for_cwd(cwd, limit, dir)
    limit = limit or 10
    local out = {}
    for _, id in ipairs(M.recent_ids(dir, limit * 4)) do
        local s = M.new({ session = { id = id } }, { dir = dir, id = id })
        local msgs = s:load()
        local match = session_matches_cwd(msgs, cwd)
        if match then
            local preview = ""
            for _, m in ipairs(msgs) do
                if m.role == "user" and (m.content or "") ~= "" then
                    preview = m.content
                    break
                end
            end
            out[#out + 1] = {
                id = id,
                path = s.path,
                messages = msgs,
                preview = tostring(preview):gsub("%s+", " "):sub(1, 80),
            }
            if #out >= limit then break end
        end
    end
    return out
end

-- 启动/切换会话时恢复上下文：只认当前目录 mem.bin（KV）里的会话。
-- 全局 JSONL 仅作镜像备份，不参与恢复——否则删掉目录下的 mem.bin 后
-- 旧对话仍会从 ~/.local/share/lite/sessions 里被拉回来，违背「记忆跟着目录走」。
function M.from_memory(memory, cwd, limit)
    if not memory or type(memory.list_sessions) ~= "function" then return nil end
    for _, meta in ipairs(memory:list_sessions(cwd, limit or 5)) do
        local msgs, max_turn = memory:session_messages(meta.id, 50)
        if msgs and #msgs > 0 then
            return { id = meta.id, messages = msgs, turn = max_turn or meta.turns or 0 }
        end
    end
    return nil
end

function M.new(ctx, opts)
    opts = opts or {}
    local base = opts.dir or default_dir()
    local id = tostring(opts.id or ctx.session.id)
    local self = setmetatable({
        ctx = ctx,
        dir = base,
        id = id,
        path = base .. "/" .. id .. ".jsonl",
        memory = opts.memory,
        seq = tonumber(opts.seq) or 0,
        raw_keep = tonumber(opts.raw_keep) or RAW_KEEP,
        tool_store_chars = tonumber(opts.tool_store_chars) or TOOL_STORE_MAX,
        prune_every = tonumber(opts.prune_every) or JSONL_PRUNE_EVERY,
        raw_trimmed = tonumber(opts.raw_trimmed) or 0,
    }, M)
    os.execute("mkdir -p " .. shq(base))
    return self
end

function M:append(msg)
    local stored = store_copy(msg, self.tool_store_chars)
    local f = io.open(self.path, "a")
    if not f then return false end
    local ok, line = pcall(cjson.encode, stored)
    if ok then f:write(line, "\n") end
    f:close()

    self.seq = self.seq + 1
    if self.memory then
        local ttl = self.memory.TTL and self.memory.TTL.long or 0
        local meta = self._meta
        if not meta then
            meta = self.memory:session_meta(self.id)
            if not meta then
                -- 恢复失败时 seq 从 0 起，若不看 meta 就会从 msg/00000001 覆盖写，
                -- 旧的 1367 条消息被最新几轮顶掉。meta 缺失则补建，存在则对齐 seq。
                meta = self.memory:ensure_session(self.id)
            end
            self._meta = meta
        end
        local count = tonumber(meta and meta.messages) or 0
        if count > self.seq then self.seq = count + 1 end
        self.memory:put("/agent/session",
            self.id .. "/msg/" .. string.format("%08d", self.seq), stored, ttl)

        -- 只保留最近 raw_keep 条原始消息；更老的由 turn 摘要/recall 兜底。
        if self.raw_keep > 0 and self.seq > self.raw_keep then
            local drop = self.seq - self.raw_keep
            local from = (self.raw_trimmed or 0) + 1
            for i = from, drop do
                local key = "/agent/session"
                local sub = self.id .. "/msg/" .. string.format("%08d", i)
                local old = self.memory:get(key, sub)
                -- user 的消息永久保留；只淘汰 tool / 旧 assistant 原文。
                if not (type(old) == "table" and old.role == "user") then
                    self.memory:del(key, sub)
                end
            end
            if drop > self.raw_trimmed then self.raw_trimmed = drop end
        end

        if meta then
            meta.messages = self.seq
            meta.updated = os.time()
            self.memory:put("/agent/session", self.id .. "/meta", meta,
                self.memory.TTL and self.memory.TTL.permanent or 0)
        end
    end
    if self.seq > self.raw_keep and self.seq % self.prune_every == 0 then
        prune_jsonl(self)
    end
    return ok
end

function M:save()
    local tmp = self.path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    for _, msg in ipairs(self.ctx.session.messages) do
        local ok, line = pcall(cjson.encode, msg)
        if ok then f:write(line, "\n") end
    end
    f:close()
    os.rename(tmp, self.path)
    return true
end

function M:load()
    local f = io.open(self.path, "r")
    if not f then return {} end
    local out = {}
    for line in f:lines() do
        if line ~= "" then
            local ok, msg = pcall(cjson.decode, line)
            if ok then out[#out + 1] = msg end
        end
    end
    f:close()
    if #out > self.seq then self.seq = #out end
    return out
end

return M
