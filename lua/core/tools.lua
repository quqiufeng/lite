-- 工具集：bash / read / write / edit / todo（全部自动，限制在 workspace 内）。
local Todos = require("core.todos")

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

local function split_lines(s)
    local out = {}
    if s == "" then return out end
    local p = 1
    while true do
        local q = s:find("\n", p, true)
        if not q then
            out[#out + 1] = s:sub(p)
            break
        end
        out[#out + 1] = s:sub(p, q - 1)
        p = q + 1
        if p > #s then break end
    end
    return out
end

-- 为一次 edit 生成单 hunk unified diff（带 3 行上下文）。
local function make_edit_diff(root, abs, before, i, old, new)
    local rel = abs
    if root and root ~= "" and abs:sub(1, #root + 1) == root .. "/" then
        rel = abs:sub(#root + 2)
    end

    local before_match = before:sub(1, i - 1)
    local _, nl = before_match:gsub("\n", "")
    local start_line = nl + 1
    local line_start = (before_match:find("\n[^\n]*$") or 0) + 1

    local j = i + #old - 1
    local nl_end = before:find("\n", j, true)
    local line_end = nl_end or #before

    local prefix = before:sub(line_start, i - 1)
    local suffix = before:sub(j + 1, line_end)
    local old_block = before:sub(line_start, line_end)
    local new_block = prefix .. (new or "") .. suffix

    local old_lines = split_lines(old_block)
    local new_lines = split_lines(new_block)
    if new_block == "" then new_lines = {} end

    local all = split_lines(before)
    local ctx_before = {}
    for k = math.max(1, start_line - 3), start_line - 1 do
        if all[k] then ctx_before[#ctx_before + 1] = all[k] end
    end

    local after_start = start_line + #old_lines
    local ctx_after = {}
    for k = after_start, math.min(#all, after_start + 2) do
        if all[k] then ctx_after[#ctx_after + 1] = all[k] end
    end

    local old_start = start_line - #ctx_before
    local old_count = #ctx_before + #old_lines + #ctx_after
    local new_count = #ctx_before + #new_lines + #ctx_after

    local out = {
        "diff --git a/" .. rel .. " b/" .. rel,
        "--- a/" .. rel,
        "+++ b/" .. rel,
        string.format("@@ -%d,%d +%d,%d @@", old_start, old_count, old_start, new_count),
    }
    for _, line in ipairs(ctx_before) do out[#out + 1] = " " .. line end
    for _, line in ipairs(old_lines) do out[#out + 1] = "-" .. line end
    for _, line in ipairs(new_lines) do out[#out + 1] = "+" .. line end
    for _, line in ipairs(ctx_after) do out[#out + 1] = " " .. line end

    return table.concat(out, "\n")
end

function M.new(opts)
    opts = opts or {}
    return setmetatable({
        cwd = opts.cwd or os.getenv("PWD") or ".",
        memory = opts.memory,
        ctx = opts.ctx,
        todos = Todos.new(opts.ctx, opts.memory),
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
        {
            type = "function",
            ["function"] = {
                name = "todo",
                description = "Replace the task list for multi-step work. Provide the full list.",
                parameters = {
                    type = "object",
                    properties = {
                        items = {
                            type = "array",
                            items = {
                                type = "object",
                                properties = {
                                    content = { type = "string" },
                                    status = {
                                        type = "string",
                                        enum = { "pending", "in_progress", "completed", "cancelled" },
                                    },
                                },
                                required = { "content", "status" },
                            },
                        },
                    },
                    required = { "items" },
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

    local before = s
    s = before:sub(1, i - 1) .. (new or "") .. before:sub(i + #old)
    local f, oerr = io.open(abs, "wb")
    if not f then return "error: " .. tostring(oerr) end
    f:write(s)
    f:close()

    local root = normalize(self.cwd):gsub("/+$", "")
    local diff = make_edit_diff(root, abs, before, i, old, new or "")
    return "edited " .. abs .. "\n" .. diff
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
        elseif name == "todo" then
            if not self.todos then return "error: todo disabled" end
            return self.todos:set(args.items)
        end
        return "error: unknown tool " .. tostring(name)
    end)
    if not ok then return "error: " .. tostring(out) end
    return truncate(out)
end

return M
