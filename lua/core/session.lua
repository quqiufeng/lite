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
    }, M)
    os.execute("mkdir -p " .. shq(base))
    return self
end

function M:append(msg)
    local f = io.open(self.path, "a")
    if not f then return false end
    local ok, line = pcall(cjson.encode, msg)
    if ok then f:write(line, "\n") end
    f:close()

    self.seq = self.seq + 1
    if self.memory then
        local ttl = self.memory.TTL and self.memory.TTL.long or 0
        self.memory:put("/agent/session",
            self.id .. "/msg/" .. string.format("%08d", self.seq), msg, ttl)
        local meta = self.memory:session_meta(self.id)
        if meta then
            meta.messages = self.seq
            self.memory:put("/agent/session", self.id .. "/meta", meta,
                self.memory.TTL and self.memory.TTL.permanent or 0)
        end
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
