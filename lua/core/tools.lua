-- 工具集：bash / read / write / edit / resize / native / todo；文件路径限制在 workspace 内。
local cjson = require("cjson")
local Todos = require("core.todos")
local Sandbox = require("core.sandbox")
local Proc = require("core.proc")
local Text = require("core.text")
local http = require("core.http")

local M = {}
M.__index = M

local MAX_OUT = 30000
-- bash 单独一档：编译/测试输出真正的信息常在**尾部**（报错、失败摘要），
-- 只留头部会迫使模型重跑一遍，反而更贵。参考 Pi/Reasonix：头部+尾部双端保留。
local BASH_MAX_OUT = 32768
local IMAGE_MAX = 20 * 1024 * 1024
local READ_MAX_LINES = 2000
local READ_MAX_BYTES = 50 * 1024
local READ_LINE_MAX = 2000
local BUILTIN_TOOLS = {
    bash = true, web = true, read = true, resize = true, native = true,
    write = true, edit = true, remember = true, recall = true, todo = true,
    lua = true,
}

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- head+tail 双端保留。只留头部会砍掉编译错误/测试失败摘要，模型必须重跑，
-- 那是"省 token 反而更贵"的典型。marker 里给出原始字节数，让模型知道被截了。
local function truncate_mid(s, cap)
    s = tostring(s or "")
    cap = cap or MAX_OUT
    if #s <= cap then return s end
    -- 先按 2/3 头、1/3 尾切，再生成 marker 并扣掉它占的长度。
    local head = math.floor(cap * 2 / 3)
    local tail = cap - head
    local omitted = #s - head - tail
    local marker = string.format(
        "\n... [truncated %d bytes of %d; narrow the command, or use head/tail] ...\n",
        omitted, #s)
    head = math.max(0, head - math.floor(#marker / 2))
    tail = math.max(0, cap - #marker - head)
    return s:sub(1, head) .. marker .. s:sub(#s - tail + 1)
end

local function truncate(s)
    return truncate_mid(s, MAX_OUT)
end

-- 供 TUI 的异步 bash 路径复用：那一路的 proc 输出原来完全不过限，
-- 一条 `cat 5MB日志` 直接顶满窗口。
function M.limit_output(s, cap)
    return truncate_mid(s, cap or MAX_OUT)
end
M.BASH_MAX_OUT = BASH_MAX_OUT

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
    -- normalize 会丢掉 "."，相对 cwd（如 "."）会变成 "/"；优先用 realpath 结果。
    local root = (self.real_root or normalize(self.cwd)):gsub("/+$", "")
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
    local list = {
        {
            type = "function",
            ["function"] = {
                name = "bash",
                description = "Run a shell command on the host. Network access (curl/wget) is allowed; use bash for builds/tests and live external data. Do not inspect repository files with it unless the user asks about the project.",
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
                name = "lua",
                description = "Run a Lua snippet out-of-process (tools/lua.sh -e, 30s timeout). "
                    .. "The snippet sees `args` (JSON `input`, if given) and can return a value "
                    .. "(tables are JSON-encoded). LuaJIT FFI and bundled cjson are available. "
                    .. "Use it for one-off logic, FFI probing, or data munging without writing files.",
                parameters = {
                    type = "object",
                    properties = {
                        code = { type = "string" },
                        input = {
                            type = "object",
                            description = "optional JSON value exposed to the snippet as `args`",
                        },
                        timeout = {
                            type = "integer",
                            description = "seconds before the snippet is killed (default 30, max 120)",
                        },
                    },
                    required = { "code" },
                },
            },
        },
        {
            type = "function",
            ["function"] = {
                name = "web",
                description = "Fetch an HTTP(S) URL through the bundled libcurl wrapper (GET, redirects, timeout). "
                    .. "Use only for live external data such as weather/news; never for repository files. "
                    .. "Returns the response body, optionally capped by max_chars.",
                parameters = {
                    type = "object",
                    properties = {
                        url = { type = "string" },
                        max_chars = { type = "integer" },
                    },
                    required = { "url" },
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
                name = "ocr",
                description = "OCR an image (Chinese/English, PP-OCRv4). "
                    .. "Path may be in the workspace or temp dirs; set boxes=true for coordinates.",
                parameters = {
                    type = "object",
                    properties = {
                        path = { type = "string" },
                        boxes = { type = "boolean" },
                    },
                    required = { "path" },
                },
            },
        },
        {
            type = "function",
            ["function"] = {
                name = "resize",
                description = "Resize an image (PNG/JPEG/WebP) in the workspace. "
                    .. "Uses lite's bundled native image library; keeps aspect ratio "
                    .. "unless force is true and both width and height are given.",
                parameters = {
                    type = "object",
                    properties = {
                        path = { type = "string" },
                        width = { type = "integer" },
                        height = { type = "integer" },
                        output = { type = "string" },
                        force = { type = "boolean" },
                    },
                    required = { "path" },
                },
            },
        },
        {
            type = "function",
            ["function"] = {
                name = "native",
                description = "Self-extend: build/run a C/C++ helper .so in helper/ via LuaJIT FFI, "
                    .. "or wrap it as a Lua tool. C ABI: char *lite_helper(const char *input) and "
                    .. "optional void lite_helper_free(char *out); input/output are UTF-8 strings "
                    .. "(usually JSON). wrap writes helper/<name>.lua + schema so it becomes callable.",
                parameters = {
                    type = "object",
                    properties = {
                        action = { type = "string", enum = { "build", "run", "wrap", "remove", "list" } },
                        name = { type = "string" },
                        code = { type = "string" },
                        lang = { type = "string", enum = { "c", "c++" } },
                        libs = { type = "array", items = { type = "string" } },
                        input = { type = "string" },
                        lua = { type = "string" },
                        description = { type = "string" },
                        parameters = { type = "object" },
                        scope = { type = "string", enum = { "local", "global" } },
                    },
                    required = { "action" },
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
    for _, schema in ipairs(self:_helper_schemas()) do
        list[#list + 1] = schema
    end
    return list
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
    return truncate_mid(out, BASH_MAX_OUT)
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

local function read_roots()
    local env = os.getenv("LITE_READ_DIRS")
    local raw
    if env ~= nil then
        raw = {}
        for part in env:gmatch("[^:]+") do raw[#raw + 1] = part end
    else
        raw = { os.getenv("TMPDIR") or "/tmp", "/tmp", "/var/tmp" }
    end
    local out, seen = {}, {}
    for _, path in ipairs(raw) do
        local root = normalize(path):gsub("/+$", "")
        if root ~= "" and not seen[root] then
            seen[root] = true
            out[#out + 1] = root
        end
    end
    return out
end

function M:_resolve_external_image(path)
    if not path or path:sub(1, 1) ~= "/" then return nil end
    local real = realpath(path) or normalize(path)
    for _, root in ipairs(read_roots()) do
        if real == root or real:sub(1, #root + 1) == root .. "/" then
            local head = read_head(real, 16) or ""
            if sniff_image(head) then return real end
        end
    end
    return nil
end

function M:web(url, max_chars)
    url = tostring(url or "")
    if not url:match("^https?://") then
        return "error: web URL must start with http:// or https://"
    end
    local rc, status, body = http.get(url, {}, 1024 * 1024)
    if rc ~= 0 then return "error: web request failed: " .. tostring(body) end
    if status ~= 200 then
        return string.format("error: HTTP %d: %s", status, tostring(body):sub(1, 500))
    end
    local cap = tonumber(max_chars) or 12000
    if #body > cap then body = body:sub(1, cap) .. "\n... [web truncated]" end
    return body
end

function M:read(path, offset, limit)
    local abs, err = self:resolve(path)
    if not abs then
        abs = self:_resolve_external_image(path)
        if not abs then return "error: " .. err end
    end

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

function M:ocr(path, boxes)
    local abs, err = self:resolve(path)
    if not abs then
        abs = self:_resolve_external_image(path)
        if not abs then return "error: " .. err end
    end
    if is_dir(abs) then return "error: cannot OCR a directory: " .. abs end
    if not file_size(abs) then return "error: cannot stat file: " .. abs end

    if self.ocr_module == nil then
        local ok, mod = pcall(require, "ffi.ocr")
        self.ocr_module = ok and mod or false
    end
    if not self.ocr_module then return "error: OCR module not available" end
    local ready, rerr = self.ocr_module.ready()
    if not ready then return "error: OCR unavailable: " .. tostring(rerr) end

    local text, list, terr = self.ocr_module.text(abs)
    if terr then return "error: OCR failed: " .. tostring(terr) end
    if boxes then
        return text .. "\n\n" .. cjson.encode(list or {})
    end
    if text == "" then return "(no text detected)" end
    return text
end

function M:_command_backend()
    if self.image_backend ~= nil then return self.image_backend or nil end
    local function ok(cmd)
        local rc = os.execute(cmd .. " >/dev/null 2>&1")
        return rc == 0 or rc == true
    end
    if ok("python3 -c 'import PIL'") then
        self.image_backend = "pil"
    elseif ok("command -v convert") then
        self.image_backend = "convert"
    elseif ok("command -v magick") then
        self.image_backend = "magick"
    elseif ok("command -v ffmpeg") then
        self.image_backend = "ffmpeg"
    else
        self.image_backend = false
    end
    return self.image_backend or nil
end

function M:_native_image_modules()
    if self.image_native ~= nil then return self.image_native end
    local mods = {}
    local ok, Lite = pcall(require, "ffi.image")
    if ok and Lite.available() then
        mods[#mods + 1] = { name = "lite_image", mod = Lite }
    end
    local ok2, Magick = pcall(require, "ffi.magick")
    if ok2 and Magick.available() then
        mods[#mods + 1] = { name = "magick", mod = Magick }
    end
    self.image_native = mods
    return mods
end

-- 输出路径许可：workspace 内任意位置，或白名单临时目录（与 read 的图片白名单一致）。
-- 截图默认落在 $TMPDIR，缩放产物也要能留在同一处，否则 /tmp 的图每次都得
-- 搬回仓库才能缩，既多余又污染工作区。
function M:_resolve_output(p)
    local abs = self:resolve(p)
    if abs then return abs end
    if not p or p:sub(1, 1) ~= "/" then return nil end
    local real = realpath(p) or normalize(p)
    for _, root in ipairs(read_roots()) do
        if real == root or real:sub(1, #root + 1) == root .. "/" then return real end
    end
    return nil
end

function M:resize(path, width, height, output, force)
    -- 输入允许白名单临时目录里的图片（与 read 一致）：截图先落在
    -- $TMPDIR/lite-shot/，需要缩到合适尺寸再喂给模型。
    local abs, err = self:resolve(path)
    if not abs then
        abs = self:_resolve_external_image(path)
        if not abs then return "error: " .. err end
    end
    if is_dir(abs) then return "error: cannot resize a directory: " .. abs end
    if not file_size(abs) then return "error: cannot stat file: " .. abs end

    local w = tonumber(width)
    local h = tonumber(height)
    if w and w <= 0 then w = nil end
    if h and h <= 0 then h = nil end
    if not w and not h then return "error: width or height is required" end
    if w then w = math.floor(w) end
    if h then h = math.floor(h) end

    local out_abs
    if output and output ~= "" then
        out_abs = self:_resolve_output(output)
        if not out_abs then return "error: output must be inside workspace or a temp dir: " .. output end
    else
        local dir, base, ext = abs:match("^(.*)/([^/]+)%.([%w]+)$")
        if not dir then return "error: cannot derive output path; pass output" end
        out_abs = string.format("%s/%s-%sx%s.%s", dir, base,
            w and tostring(w) or "auto", h and tostring(h) or "auto", ext)
        out_abs = self:_resolve_output(out_abs)
        if not out_abs then
            -- 理论上不可达（派生路径与输入同目录，输入已通过白名单校验）
            local root = self.real_root or (realpath(self.cwd) or normalize(self.cwd)):gsub("/+$", "")
            out_abs = string.format("%s/artifacts/resized/%s-%sx%s.%s", root, base,
                w and tostring(w) or "auto", h and tostring(h) or "auto", ext)
            os.execute("mkdir -p " .. shq(root .. "/artifacts/resized") .. " 2>/dev/null")
        end
    end
    if out_abs == abs then
        return "error: output path equals input; choose a different output"
    end

    local errors = {}
    for _, item in ipairs(self:_native_image_modules()) do
        local ok, nerr = item.mod.resize(abs, out_abs, w or 0, h or 0, force)
        if ok and file_size(out_abs) then
            return string.format("resized %s -> %s (%s)", abs, out_abs,
                (w and tostring(w) or "auto") .. "x" .. (h and tostring(h) or "auto"))
        end
        errors[#errors + 1] = item.name .. ": " .. tostring(nerr)
        os.remove(out_abs)
    end

    local backend = self:_command_backend()
    if not backend then
        if #errors > 0 then return "error: " .. table.concat(errors, "; ") end
        return "error: no image backend available (need liblite_image, ImageMagick, Python PIL, or ffmpeg)"
    end

    local command
    if backend == "pil" then
        local script = table.concat({
            "import sys",
            "from PIL import Image",
            "s=Image.open(sys.argv[1])",
            "w=int(sys.argv[3]); h=int(sys.argv[4]); force=sys.argv[5]=='1'",
            "if force and w>0 and h>0:",
            " s=s.resize((w,h))",
            "else:",
            " tw=w if w>0 else 10**9; th=h if h>0 else 10**9",
            " r=min(tw/s.width, th/s.height)",
            " s=s.resize((max(1,round(s.width*r)), max(1,round(s.height*r))))",
            "s.save(sys.argv[2])",
        }, "\n")
        command = string.format("python3 -c %s %s %s %d %d %s",
            shq(script), shq(abs), shq(out_abs), w or 0, h or 0,
            (force and w and h) and "1" or "0")
    else
        local geometry
        if w and h then
            geometry = w .. "x" .. h
        elseif w then
            geometry = w .. "x"
        else
            geometry = "x" .. h
        end
        if backend == "convert" or backend == "magick" then
            local exe = backend == "convert" and "convert" or "magick"
            if force and w and h then geometry = geometry .. "!" end
            command = string.format("%s %s -resize %s %s",
                exe, shq(abs), shq(geometry), shq(out_abs))
        else
            local scale
            if w and h then
                scale = w .. ":" .. h
                if not force then
                    scale = scale .. ":force_original_aspect_ratio=decrease"
                end
            elseif w then
                scale = w .. ":-1"
            else
                scale = "-1:" .. h
            end
            command = string.format("ffmpeg -y -v error -i %s -vf %s %s",
                shq(abs), shq("scale=" .. scale), shq(out_abs))
        end
    end

    local run = self:bash(command)
    if not file_size(out_abs) then
        errors[#errors + 1] = backend .. ": " .. tostring(run)
        return "error: resize failed: " .. table.concat(errors, "; ")
    end
    return string.format("resized %s -> %s (%s)", abs, out_abs,
        (w and tostring(w) or "auto") .. "x" .. (h and tostring(h) or "auto"))
end

local NATIVE_ABI = "char *lite_helper(const char *input); void lite_helper_free(char *out);"

local function lite_root_dir()
    local root = os.getenv("LITE_ROOT")
    if not root or root == "" then return nil end
    return normalize(root):gsub("/+$", "")
end

local function write_abs(path, content)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then os.execute("mkdir -p " .. shq(dir)) end
    local f, err = io.open(path, "wb")
    if not f then return nil, tostring(err) end
    f:write(content or "")
    f:close()
    return true
end

function M:_helper_roots()
    local roots = {}
    local local_dir = normalize(self.cwd):gsub("/+$", "") .. "/helper"
    roots[#roots + 1] = { scope = "local", dir = local_dir }
    local root = lite_root_dir()
    if root then
        local global_dir = root .. "/helper"
        if global_dir ~= local_dir then
            roots[#roots + 1] = { scope = "global", dir = global_dir }
        end
    end
    return roots
end

function M:_helper_root(scope)
    scope = scope or "local"
    for _, root in ipairs(self:_helper_roots()) do
        if root.scope == scope then return root end
    end
    return nil, "unknown helper scope: " .. tostring(scope)
end

function M:_helper_name(name)
    name = tostring(name or "")
    if not name:match("^[%w_][%w_%-]*$") then
        return nil, "invalid helper name (use letters, digits, _ or -)"
    end
    return name
end

function M:_helper_paths(name, scope)
    local ok, err = self:_helper_name(name)
    if not ok then return nil, err end
    local root, rerr = self:_helper_root(scope)
    if not root then return nil, rerr end
    local dir = root.dir
    return {
        name = name,
        scope = root.scope,
        dir = dir,
        src = dir .. "/" .. name .. ".c",
        lua = dir .. "/" .. name .. ".lua",
        tool = dir .. "/" .. name .. ".tool.json",
        manifest = dir .. "/" .. name .. ".json",
        so = dir .. "/" .. name .. ".so",
    }
end

local function unique_so(path)
    local base = path:gsub("%.so$", "")
    local stamp = os.time()
    local candidate = string.format("%s-%d.so", base, stamp)
    local n = 0
    while file_size(candidate) do
        n = n + 1
        candidate = string.format("%s-%d-%d.so", base, stamp, n)
    end
    return candidate
end

function M:_helper_so_abs(name)
    local ok, err = self:_helper_name(name)
    if not ok then return nil, err end
    for _, root in ipairs(self:_helper_roots()) do
        local so_path
        local f = io.open(root.dir .. "/" .. name .. ".json", "rb")
        if f then
            local raw = f:read("*a")
            f:close()
            local ok, manifest = pcall(cjson.decode, raw or "")
            if ok and type(manifest) == "table" and type(manifest.so) == "string" then
                local rel = manifest.so:gsub("^helper/", "")
                if rel:sub(1, 1) ~= "/" and not rel:find("%.%.") then
                    so_path = root.dir .. "/" .. rel
                end
            end
        end
        if not so_path then so_path = root.dir .. "/" .. name .. ".so" end
        if file_size(so_path) then return so_path end
    end
    return nil, "helper not built (run native action=build first)"
end

function M:_helper_find(name, need_lua)
    for _, root in ipairs(self:_helper_roots()) do
        local paths = self:_helper_paths(name, root.scope)
        if paths then
            if need_lua then
                -- schema 可以内嵌在 .lua 里，.tool.json 变成可选
                if file_size(paths.lua) then return paths end
            elseif file_size(paths.src) or file_size(paths.manifest) then
                return paths
            end
        end
    end
    return nil
end

function M:native_build(name, code, lang, libs, scope)
    local p, err = self:_helper_paths(name, scope)
    if not p then return "error: " .. err end
    code = tostring(code or "")
    if code == "" then return "error: code is required" end
    lang = (lang == "c++" or lang == "cpp" or lang == "cxx") and "c++" or "c"

    local src = p.src
    if lang == "c++" then src = src:gsub("%.c$", ".cpp") end
    local ok, werr = write_abs(src, code)
    if not ok then return "error: " .. tostring(werr) end

    local so_abs = unique_so(p.so)
    local cc = lang == "c++" and "c++" or "cc"
    local parts = { cc, "-shared", "-fPIC", "-O2", "-Wall", "-Wextra" }
    if lang == "c++" then parts[#parts + 1] = "-std=c++17" end
    parts[#parts + 1] = "-o"
    parts[#parts + 1] = shq(so_abs)
    parts[#parts + 1] = shq(src)
    if type(libs) == "string" then libs = { libs } end
    for _, lib in ipairs(libs or {}) do
        lib = tostring(lib)
        if lib:match("^[%w_%+%-%.]+$") then
            parts[#parts + 1] = "-l" .. lib
        end
    end

    local out = self:bash(table.concat(parts, " "))
    if not file_size(so_abs) then
        return "error: helper build failed\n" .. tostring(out)
    end

    local manifest = {
        name = p.name,
        scope = p.scope,
        lang = lang,
        source = src:match("[^/]+$"),
        so = so_abs:match("[^/]+$"),
        built_at = os.time(),
        abi = NATIVE_ABI,
    }
    local mok, merr = write_abs(p.manifest, cjson.encode(manifest))
    if not mok then return "error: " .. tostring(merr) end

    local cleanup = io.popen("ls -1 " .. shq(p.dir) .. " 2>/dev/null")
    if cleanup then
        local pattern = "^" .. p.name:gsub("%-", "%%-") .. "%-.*%.so$"
        for line in cleanup:lines() do
            if line:match(pattern) then
                local old = p.dir .. "/" .. line
                if old ~= so_abs then os.remove(old) end
            end
        end
        cleanup:close()
    end

    return "built native helper " .. p.name .. " (" .. p.scope .. ") -> " ..
        so_abs:match("[^/]+$") ..
        "\nABI: " .. NATIVE_ABI ..
        "\nCall: native(action=\"run\", name=\"" .. p.name .. "\", input=\"...\")"
end

function M:native_run(name, input)
    local so_abs, serr = self:_helper_so_abs(name)
    if not so_abs then return "error: " .. tostring(serr) end

    local ffi = require("ffi")
    pcall(ffi.cdef, [[
        char *lite_helper(const char *input);
        void lite_helper_free(char *out);
    ]])
    local ok, lib = pcall(ffi.load, so_abs)
    if not ok then return "error: ffi.load failed: " .. tostring(lib) end
    local okf, fn = pcall(function() return lib.lite_helper end)
    if not okf or fn == nil then return "error: helper does not export lite_helper" end

    local arg
    if type(input) == "table" then
        arg = cjson.encode(input)
    elseif input == nil then
        arg = "{}"
    else
        arg = tostring(input)
    end

    local out = fn(arg)
    if out == nil then return "(helper returned NULL)" end
    local s = ffi.string(out)
    local free_ok, free = pcall(function() return lib.lite_helper_free end)
    if free_ok and free ~= nil then pcall(free, out) end
    if s == "" then return "(empty output)" end
    return truncate(s)
end

function M:native_list()
    local roots = self:_helper_roots()
    local lines = {}
    for _, root in ipairs(roots) do
        local p = io.popen("ls -1 " .. shq(root.dir) .. " 2>/dev/null")
        if p then
            for line in p:lines() do
                if line:sub(1, 1) ~= "." then
                    lines[#lines + 1] = string.format("[%s] %s", root.scope, line)
                end
            end
            p:close()
        end
    end
    if #lines == 0 then return "(no native helpers)" end
    return table.concat(lines, "\n")
end

-- helper lua 文件返回 { schema = {...}, run = function(args, env) } 即可内嵌声明。
-- 老写法（<name>.tool.json + <name>.lua）继续可用；两者同时存在时 .tool.json 优先。
local function helper_lua_schema(name, path)
    local chunk, lerr = loadfile(path)
    if not chunk then return nil, "load failed: " .. tostring(lerr) end
    local ok, mod = pcall(chunk)
    if not ok then return nil, "load failed: " .. tostring(mod) end
    if type(mod) ~= "table" or type(mod.run) ~= "function" then
        return nil, "must return { run = function(args, env) }"
    end
    local schema = mod.schema
    if type(schema) ~= "table" or type(schema.parameters) ~= "table" then return nil end
    if schema.name ~= nil and schema.name ~= name then
        return nil, "schema.name does not match file name"
    end
    return schema
end

-- 扫描一次就是一次 ls fork。原来每轮 schemas() 都扫，既是白烧 fork，也让运行中
-- 新建的 helper 悄悄挤进工具列表 —— schema 一变前缀缓存全废。这里固定成会话快照，
-- 运行时试验请用 lua 工具（进程外 -e），改 helper 后重启生效。
function M:_scan_helper_schemas()
    local seen = {}
    local out = {}
    local errors = {}
    local function push(name, schema)
        seen[name] = true
        out[#out + 1] = {
            type = "function",
            ["function"] = {
                name = name,
                description = schema.description or "",
                parameters = schema.parameters,
            },
        }
    end
    for _, root in ipairs(self:_helper_roots()) do
        local listed = io.popen("ls -1 " .. shq(root.dir) .. " 2>/dev/null")
        if listed then
            local entries = {}
            for line in listed:lines() do entries[#entries + 1] = line end
            listed:close()

            local by_name = {}
            local order = {}
            for _, line in ipairs(entries) do
                local name = line:match("^([%w_][%w_%-]*)%.tool%.json$")
                if name and not BUILTIN_TOOLS[name] and not seen[name] then
                    local raw = read_file(root.dir .. "/" .. line)
                    local ok, schema = pcall(cjson.decode, raw or "")
                    if ok and type(schema) == "table"
                        and (schema.name == nil or schema.name == name)
                        and type(schema.parameters) == "table" then
                        push(name, schema)
                    end
                end
                local bare = line:match("^([%w_][%w_%-]*)%.lua$")
                if bare and not by_name[bare] then
                    by_name[bare] = true
                    order[#order + 1] = bare
                end
            end
            table.sort(order)

            for _, bare in ipairs(order) do
                if not seen[bare] and not BUILTIN_TOOLS[bare] then
                    local lua_path = root.dir .. "/" .. bare .. ".lua"
                    if file_size(lua_path) then
                        local schema, err = helper_lua_schema(bare, lua_path)
                        if schema then
                            push(bare, schema)
                        elseif err then
                            errors[bare] = err
                        end
                    end
                end
            end
        end
    end
    self._helper_errors = errors
    return out
end

function M:_helper_schemas()
    if not self._helper_cache then
        self._helper_cache = self:_scan_helper_schemas()
    end
    return self._helper_cache
end

function M:_run_helper_tool(name, args)
    if BUILTIN_TOOLS[name] then return nil end
    local p = self:_helper_find(name, true)
    if not p then return nil end

    local chunk, lerr = loadfile(p.lua)
    if not chunk then
        return "error: helper lua load failed: " .. tostring(lerr)
    end
    local ok, mod = pcall(chunk)
    if not ok or type(mod) ~= "table" or type(mod.run) ~= "function" then
        return "error: helper lua must return { run = function(args, env) }"
    end

    local ffi = require("ffi")
    local env = {
        cwd = normalize(self.cwd):gsub("/+$", ""),
        helper_dir = p.dir,
        scope = p.scope,
        ffi = ffi,
        load = function(n)
            local so, serr = self:_helper_so_abs(n)
            if not so then error(serr) end
            return ffi.load(so)
        end,
        call = function(n, input)
            return self:native_run(n, input)
        end,
    }
    local ok2, res = pcall(mod.run, args or {}, env)
    if not ok2 then
        return "error: helper " .. name .. ": " .. tostring(res)
    end
    if res == nil then return "(helper returned nil)" end
    return truncate(tostring(res))
end

function M:native_wrap(name, lua_code, description, parameters, scope)
    local p, err = self:_helper_paths(name, scope)
    if not p then return "error: " .. err end
    if BUILTIN_TOOLS[name] then return "error: cannot override built-in tool " .. name end
    lua_code = tostring(lua_code or "")
    if lua_code == "" then return "error: lua code is required" end
    if type(parameters) ~= "table" then
        return "error: parameters must be a JSON schema object"
    end
    local ok, werr = write_abs(p.lua, lua_code)
    if not ok then return "error: " .. tostring(werr) end
    local schema = {
        name = name,
        description = tostring(description or ("native helper " .. name)),
        parameters = parameters,
    }
    local ok2, werr2 = write_abs(p.tool, cjson.encode(schema))
    if not ok2 then return "error: " .. tostring(werr2) end
    return "installed helper tool " .. name .. " (" .. p.scope .. ")" ..
        "; call it as " .. name .. "(...)"
end

function M:native_remove(name, scope)
    local p, err = self:_helper_paths(name, scope)
    if not p then return "error: " .. err end
    for _, path in ipairs({
        p.lua, p.tool, p.manifest, p.so, p.src,
        p.src:gsub("%.c$", ".cpp"),
    }) do
        os.remove(path)
    end
    local listing = io.popen("ls -1 " .. shq(p.dir) .. " 2>/dev/null")
    if listing then
        local pattern = "^" .. p.name:gsub("%-", "%%-") .. "%-.*%.so$"
        for line in listing:lines() do
            if line:match(pattern) then os.remove(p.dir .. "/" .. line) end
        end
        listing:close()
    end
    return "removed helper " .. name .. " (" .. p.scope .. ")"
end

function M:native(action, name, code, lang, libs, input, lua_code, description, parameters, scope)
    if action == "build" then
        return self:native_build(name, code, lang, libs, scope)
    elseif action == "run" then
        return self:native_run(name, input)
    elseif action == "wrap" then
        return self:native_wrap(name, lua_code, description, parameters, scope)
    elseif action == "remove" then
        return self:native_remove(name, scope)
    elseif action == "list" then
        return self:native_list()
    end
    return "error: action must be build, run, wrap, remove, or list"
end

-- lua 工具：进程外跑一段 LuaJIT（tools/lua.sh -e），参数以 JSON 走环境变量。
-- 刻意不做进程内 loadstring：死循环会卡住 agent，崩溃会带崩主进程。
local LUA_TOOL_ADAPTER = [=[
local okj, cjson = pcall(require, "cjson")
if not okj then io.write("error: cjson unavailable") os.exit(0) end
local raw = os.getenv("LITE_LUA_ARGS") or "{}"
local okd, req = pcall(cjson.decode, raw)
if not okd or type(req) ~= "table" then
  io.write("error: bad args: " .. tostring(req)) os.exit(0)
end
args = req.input
local chunk, err = loadstring(req.code or "", "=lua")
if not chunk then io.write("error: " .. tostring(err)) os.exit(0) end
local ok, res = pcall(chunk)
if not ok then io.write("error: " .. tostring(res)) os.exit(0) end
if type(res) == "table" then
  local okj2, j = pcall(cjson.encode, res)
  if okj2 then res = j end
end
if res ~= nil then io.write(tostring(res)) end
os.exit(0)
]=]

local function lua_plugin_bin(cwd)
    local cands = {}
    local root = lite_root_dir()
    if root then cands[#cands + 1] = root .. "/tools/lua.sh" end
    cands[#cands + 1] = (normalize(cwd or "."):gsub("/+$", "")) .. "/tools/lua.sh"
    for _, p in ipairs(cands) do
        local f = io.open(p, "r")
        if f then
            f:close()
            return p
        end
    end
    return nil
end

function M:lua(args)
    args = args or {}
    local code = tostring(args.code or "")
    if code == "" then return "error: code is required" end
    local bin = lua_plugin_bin(self.cwd)
    if not bin then return "error: tools/lua.sh not found (set LITE_ROOT)" end
    local req = { code = code }
    if args.input ~= nil then req.input = args.input end
    local ok, payload = pcall(cjson.encode, req)
    if not ok then return "error: cannot encode input: " .. tostring(payload) end
    local timeout = math.floor(tonumber(args.timeout) or 30)
    if timeout < 1 then timeout = 1 end
    if timeout > 120 then timeout = 120 end
    -- tools/lua.sh 会 cd 到 LITE_CWD：插件脚本按相对路径找模块/数据文件，
    -- 而不是跟着 agent 进程的 cwd（TUI 里通常是仓库根）跑。
    local root = self.real_root or self.cwd or "."
    local cmd = "LITE_CWD=" .. shq(root) .. " timeout " .. tostring(timeout)
        .. " env LITE_LUA_ARGS=" .. shq(payload)
        .. " " .. shq(bin) .. " -e " .. shq(LUA_TOOL_ADAPTER)
    -- LuaJIT 的 popen:close() 只返回 true，拿不到退出码，所以让 shell 回显 rc。
    local proc = io.popen("sh -c " .. shq(cmd .. '; echo "__lite_rc=$?"') .. " 2>&1")
    if not proc then return "error: cannot spawn " .. tostring(bin) end
    local out = proc:read("*a") or ""
    proc:close()
    local rc = tonumber(out:match("__lite_rc=(%d+)%s*$"))
    out = out:gsub("%s*__lite_rc=%d+%s*$", "")
    if rc == 124 then
        return "error: timeout after " .. tostring(timeout) .. "s"
    end
    return truncate(out)
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
        elseif name == "web" then
            return self:web(args.url, args.max_chars)
        elseif name == "lua" then
            return self:lua(args)
        elseif name == "read" then
            return self:read(args.path, args.offset, args.limit)
        elseif name == "ocr" then
            return self:ocr(args.path, args.boxes)
        elseif name == "resize" then
            return self:resize(args.path, args.width, args.height, args.output, args.force)
        elseif name == "native" then
            return self:native(args.action, args.name, args.code, args.lang, args.libs,
                args.input, args.lua, args.description, args.parameters, args.scope)
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
        local helper_out = self:_run_helper_tool(name, args)
        if helper_out ~= nil then return helper_out end
        return "error: unknown tool " .. tostring(name)
    end)
    if not ok then return "error: " .. tostring(out) end
    return truncate(out)
end

return M
