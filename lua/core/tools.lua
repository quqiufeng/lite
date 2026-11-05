-- 工具集：bash / read / write / edit（全部自动，限制在 workspace 内）。
local M = {}
M.__index = M

local MAX_OUT = 30000

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function truncate(s)
    s = tostring(s or "")
    if #s <= MAX_OUT then return s end
    return s:sub(1, MAX_OUT) .. "\n... [truncated " .. (#s - MAX_OUT) .. " bytes]"
end

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, tostring(err) end
    local s = f:read("*a")
    f:close()
    return s
end

function M.new(opts)
    opts = opts or {}
    return setmetatable({
        cwd = opts.cwd or os.getenv("PWD") or ".",
        memory = opts.memory,
    }, M)
end

local function normalize(path)
    local parts = {}
    for seg in tostring(path):gmatch("[^/]+") do
        if seg == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return "/" .. table.concat(parts, "/")
end

function M:resolve(p)
    if not p or p == "" then return nil, "empty path" end
    local root = normalize(self.cwd):gsub("/+$", "")
    local abs = p
    if p:sub(1, 1) ~= "/" then abs = root .. "/" .. p end
    abs = normalize(abs)
    if abs == root or abs:sub(1, #root + 1) == root .. "/" then
        return abs
    end
    return nil, "path outside workspace: " .. abs
end

function M:schemas()
    return {
        {
            type = "function",
            ["function"] = {
                name = "bash",
                description = "Run a shell command in the workspace (auto-approved).",
                parameters = {
                    type = "object",
                    properties = { command = { type = "string" } },
                    required = { "command" },
                },
            },
        },
        {
            type = "function",
            ["function"] = {
                name = "read",
                description = "Read a text file in the workspace.",
                parameters = {
                    type = "object",
                    properties = {
                        path = { type = "string" },
                        offset = { type = "integer" },
                        limit = { type = "integer" },
                    },
                    required = { "path" },
                },
            },
        },
        {
            type = "function",
            ["function"] = {
                name = "write",
                description = "Write a text file in the workspace.",
                parameters = {
                    type = "object",
                    properties = {
                        path = { type = "string" },
                        content = { type = "string" },
                    },
                    required = { "path", "content" },
                },
            },
        },
        {
            type = "function",
            ["function"] = {
                name = "edit",
                description = "Replace the first occurrence of old text with new text.",
                parameters = {
                    type = "object",
                    properties = {
                        path = { type = "string" },
                        old = { type = "string" },
                        new = { type = "string" },
                    },
                    required = { "path", "old", "new" },
                },
            },
        },
        {
            type = "function",
            ["function"] = {
                name = "remember",
                description = "Save a long-term fact to local context memory.",
                parameters = {
                    type = "object",
                    properties = {
                        key = { type = "string" },
                        content = { type = "string" },
                        tags = { type = "array", items = { type = "string" } },
                    },
                    required = { "key", "content" },
                },
            },
        },
        {
            type = "function",
            ["function"] = {
                name = "recall",
                description = "Search local context memory for relevant facts or past turns.",
                parameters = {
                    type = "object",
                    properties = {
                        query = { type = "string" },
                        limit = { type = "integer" },
                    },
                    required = { "query" },
                },
            },
        },
    }
end

function M:bash(command)
    local p = io.popen("timeout 120 bash -lc " .. shq(command) .. " 2>&1", "r")
    if not p then return "error: cannot start bash" end
    local out = p:read("*a") or ""
    local ok = p:close()
    if not ok then out = out .. "\n[exit nonzero]" end
    return truncate(out)
end

function M:read(path, offset, limit)
    local abs, err = self:resolve(path)
    if not abs then return "error: " .. err end
    local s, rerr = read_file(abs)
    if not s then return "error: " .. rerr end
    if offset or limit then
        local lines = {}
        for line in (s .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
        local first = math.max(1, tonumber(offset) or 1)
        local last = limit and (first + tonumber(limit) - 1) or #lines
        local out = {}
        for i = first, math.min(last, #lines) do out[#out + 1] = lines[i] end
        s = table.concat(out, "\n")
    end
    return truncate(s)
end

function M:write(path, content)
    local abs, err = self:resolve(path)
    if not abs then return "error: " .. err end
    local dir = abs:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then os.execute("mkdir -p " .. shq(dir)) end
    local f, oerr = io.open(abs, "wb")
    if not f then return "error: " .. tostring(oerr) end
    f:write(content or "")
    f:close()
    return string.format("wrote %d bytes to %s", #(content or ""), abs)
end

function M:edit(path, old, new)
    local abs, err = self:resolve(path)
    if not abs then return "error: " .. err end
    local s, rerr = read_file(abs)
    if not s then return "error: " .. rerr end
    if not old or old == "" then return "error: empty old text" end
    local i = s:find(old, 1, true)
    if not i then return "error: old text not found in " .. abs end
    s = s:sub(1, i - 1) .. (new or "") .. s:sub(i + #old)
    local f, oerr = io.open(abs, "wb")
    if not f then return "error: " .. tostring(oerr) end
    f:write(s)
    f:close()
    return "edited " .. abs
end

function M:execute(name, args)
    args = args or {}
    local ok, out = pcall(function()
        if name == "bash" then
            return self:bash(args.command or "")
        elseif name == "read" then
            return self:read(args.path, args.offset, args.limit)
        elseif name == "write" then
            return self:write(args.path, args.content or "")
        elseif name == "edit" then
            return self:edit(args.path, args.old, args.new)
        elseif name == "remember" then
            if not self.memory then return "error: memory disabled" end
            local ok = self.memory:remember_fact(args.key, args.content, args.tags)
            if not ok then return "error: remember failed" end
            return "remembered " .. tostring(args.key)
        elseif name == "recall" then
            if not self.memory then return "error: memory disabled" end
            local items = self.memory:recall(args.query, args.limit or 5)
            if #items == 0 then return "no memory found" end
            local out = {}
            for _, it in ipairs(items) do
                out[#out + 1] = string.format("[%s] %s", it.key, it.text)
            end
            return table.concat(out, "\n")
        end
        return "error: unknown tool " .. tostring(name)
    end)
    if not ok then return "error: " .. tostring(out) end
    return truncate(out)
end

return M
