-- 工具集：bash / read / write / edit / todo（全部自动，限制在 workspace 内）。
local Todos = require("core.todos")
local Sandbox = require("core.sandbox")
local Proc = require("core.proc")
local Text = require("core.text")

local M = {}
M.__index = M

local MAX_OUT = 30000
local IMAGE_MAX = 20 * 1024 * 1024
local READ_MAX_LINES = 2000
local READ_MAX_BYTES = 50 * 1024
local READ_LINE_MAX = 2000

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

local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end

local function is_dir(path)
    local p = io.popen("test -d " .. shq(path) .. " && echo 1 || echo 0")
    if not p then return false end
    local s = p:read("*l")
    p:close()
    return s == "1"
end

local function read_head(path, n)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read(n or 4096)
    f:close()
    return s or ""
end

local function sniff_image(sample)
    if #sample >= 8
        and sample:sub(1, 8) == string.char(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) then
        return "image/png"
    end
    if #sample >= 3 and sample:byte(1) == 0xFF and sample:byte(2) == 0xD8 and sample:byte(3) == 0xFF then
        return "image/jpeg"
    end
    if #sample >= 6 and (sample:sub(1, 6) == "GIF87a" or sample:sub(1, 6) == "GIF89a") then
        return "image/gif"
    end
    if #sample >= 12 and sample:sub(1, 4) == "RIFF" and sample:sub(9, 12) == "WEBP" then
        return "image/webp"
    end
    return nil
end

local function looks_binary(sample)
    if #sample == 0 then return false end
    local bad = 0
    for i = 1, #sample do
        local b = sample:byte(i)
        if b == 0 then return true end
        if b < 9 or (b > 13 and b < 32) then bad = bad + 1 end
    end
    return bad / #sample > 0.3
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

local function realpath(path)
    local p = io.popen("realpath -m " .. shq(path) .. " 2>/dev/null", "r")
    if not p then return nil end
    local s = p:read("*l")
    p:close()
    if not s or s == "" then return nil end
    return s
end

function M.new(opts)
    opts = opts or {}
    local cwd = opts.cwd or os.getenv("PWD") or "."
    local self = setmetatable({
        cwd = cwd,
        memory = opts.memory,
        ctx = opts.ctx,
        todos = Todos.new(opts.ctx, opts.memory),
        sandbox = Sandbox.enabled(opts.sandbox),
        sandbox_net = opts.sandbox_net ~= false,
        pending_attachment = nil,
    }, M)
    self.real_root = realpath(cwd) or normalize(cwd):gsub("/+$", "")

    local function exists(path)
        local f = io.open(path, "rb")
        if f then f:close(); return true end
        return false
    end
    local root = os.getenv("LITE_ROOT")
    local candidates = {
        root and (root:gsub("/+$", "") .. "/third_party/luajit/src/luajit"),
        normalize(cwd):gsub("/+$", "") .. "/third_party/luajit/src/luajit",
    }
    for _, p in ipairs(candidates) do
        if p and exists(p) then self.luajit = p; break end
    end
    return self
end

function M:_env_prefix()
    if not self.luajit then return "" end
    local dir = self.luajit:match("^(.*)/[^/]+$")
    return "export PATH=" .. shq(dir) .. ":\"$PATH\"; "
        .. "export LITE_LUAJIT=" .. shq(self.luajit) .. "; "
end

function M:take_attachment()
    local att = self.pending_attachment
    self.pending_attachment = nil
    return att
end

function M:resolve(p)
    if not p or p == "" then return nil, "empty path" end
    local root = normalize(self.cwd):gsub("/+$", "")
    local abs = p
    if p:sub(1, 1) ~= "/" then abs = root .. "/" .. p end
    abs = normalize(abs)
    if not (abs == root or abs:sub(1, #root + 1) == root .. "/") then
        return nil, "path outside workspace: " .. abs
    end

    -- 防 symlink 越界：解析真实路径后再校验一次。
    local real = realpath(abs) or abs
    local real_root = self.real_root or root
    if real == real_root or real:sub(1, #real_root + 1) == real_root .. "/" then
        return abs
    end
    return nil, "path outside workspace (symlink): " .. real
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
                description = "Read a text file, list a directory, or read an image "
                    .. "(JPEG/PNG/GIF/WebP) in the workspace. Image data is attached "
                    .. "to the conversation for visual understanding.",
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

function M:start_bash(command)
    local run
    local command2 = self:_env_prefix() .. command
    if self.sandbox then
        local wrapped, serr = Sandbox.wrap(command2, {
            cwd = self.real_root or normalize(self.cwd),
            network = self.sandbox_net,
        })
        if not wrapped then return nil, serr end
        run = wrapped
    else
        run = "bash -lc " .. shq(command2)
    end
    return Proc.new(run, { timeout = 120 })
end

function M:bash(command)
    local cmd
    local command2 = self:_env_prefix() .. command
    if self.sandbox then
        local wrapped, serr = Sandbox.wrap(command2, {
            cwd = self.real_root or normalize(self.cwd),
            network = self.sandbox_net,
        })
        if not wrapped then return "error: " .. tostring(serr) end
        cmd = wrapped
    else
        cmd = "bash -lc " .. shq(command2)
    end

    local p = io.popen("timeout 120 " .. cmd .. " 2>&1", "r")
    if not p then return "error: cannot start bash" end
    local out = p:read("*a") or ""
    local ok = p:close()
    if not ok then out = out .. "\n[exit nonzero]" end
    return truncate(out)
end

local function read_dir(abs, offset, limit)
    local p = io.popen("ls -1ap " .. shq(abs) .. " 2>&1", "r")
    if not p then return "error: cannot list directory: " .. abs end
    local items = {}
    for line in p:lines() do
        if line ~= "./" and line ~= "../" then items[#items + 1] = line end
    end
    p:close()

    local first = math.max(1, tonumber(offset) or 1)
    local lim = tonumber(limit) or READ_MAX_LINES
    local out = {}
    for i = first, math.min(#items, first + lim - 1) do
        out[#out + 1] = items[i]
    end
    return table.concat(out, "\n") .. string.format("\n(%d entries)", #items)
end

local function read_text(abs, offset, limit)
    local s, err = read_file(abs)
    if not s then return "error: " .. err end
    local first = math.max(1, tonumber(offset) or 1)
    local lim = tonumber(limit) or READ_MAX_LINES
    local total, count, bytes, more = 0, 0, 0, false
    local out = {}

    for line in (s .. "\n"):gmatch("(.-)\n") do
        total = total + 1
        if total >= first and count < lim then
            local text = line
            if #text > READ_LINE_MAX then text = text:sub(1, READ_LINE_MAX) .. " ..." end
            local item = string.format("%d: %s", total, text)
            if bytes + #item + 1 > READ_MAX_BYTES then
                more = true
                break
            end
            out[#out + 1] = item
            bytes = bytes + #item + 1
            count = count + 1
        end
        if count >= lim then
            more = true
            break
        end
    end

    local res = table.concat(out, "\n")
    if more then
        res = res .. string.format("\n\n(Showing lines %d-%d. Use offset=%d to continue.)",
            first, first + count - 1, first + count)
    else
        res = res .. string.format("\n\n(End of file - total %d lines)", total)
    end
    return res
end

function M:read(path, offset, limit)
    local abs, err = self:resolve(path)
    if not abs then return "error: " .. err end

    if is_dir(abs) then return read_dir(abs, offset, limit) end

    local size = file_size(abs)
    if not size then return "error: cannot stat file: " .. abs end

    local head = read_head(abs, 4096) or ""
    if head:sub(1, 4) == "%PDF" then
        return "error: PDF read is not supported by this model; convert it to an image or text"
    end

    local mime = sniff_image(head)
    if mime then
        if size > IMAGE_MAX then
            return string.format("error: image too large (%d bytes > %d)", size, IMAGE_MAX)
        end
        local bytes, rerr = read_file(abs)
        if not bytes then return "error: " .. rerr end
        self.pending_attachment = {
            mime = mime,
            data = Text.base64(bytes),
            path = abs,
            size = size,
        }
        return string.format("Image read successfully: %s (%s, %d bytes)", abs, mime, size)
    end

    if looks_binary(head) then
        return "error: cannot read binary file: " .. abs
    end
    return read_text(abs, offset, limit)
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
