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

function M.for_cwd(cwd, limit, dir)
    limit = limit or 10
    local out = {}
    for _, id in ipairs(M.recent_ids(dir, limit * 4)) do
        local s = M.new({ session = { id = id } }, { dir = dir, id = id })
        local msgs = s:load()
        local match = false
        for _, m in ipairs(msgs) do
            if m.role == "system" and tostring(m.content):find(cwd, 1, true) then
                match = true
                break
            end
        end
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
