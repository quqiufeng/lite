-- 系统 prompt 组装 + 记忆块格式化 + recall 查询构造。
-- 参考 Pi system-prompt sections 与 Reasonix prefix/recall 的稳定前缀思路。
local M = {}

local ORDER = { "preamble", "tools", "capabilities", "native", "rules", "memory", "project_context", "cwd" }
local DEFAULT_PROJECT_CHARS = 4000
local context_cache = {}

local function read_capped(path, max)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a") or ""
    f:close()
    if s == "" then return nil end
    if #s > max then s = s:sub(1, max) .. "\n... [truncated]" end
    return s
end

function M.project_context(cwd)
    local explicit = os.getenv("LITE_INSTRUCTIONS_FILE")
    local candidates = {}
    if explicit then
        if explicit == "" or explicit == "/dev/null" then return nil end
        if explicit:sub(1, 1) ~= "/" then explicit = tostring(cwd) .. "/" .. explicit end
        candidates = { explicit }
    else
        candidates = {
            tostring(cwd) .. "/AGENTS.md",
            tostring(cwd) .. "/CLAUDE.md",
            tostring(cwd) .. "/.lite/instructions.md",
        }
    end

    local cap = tonumber(os.getenv("LITE_INSTRUCTIONS_CHARS")) or DEFAULT_PROJECT_CHARS
    for _, path in ipairs(candidates) do
        if context_cache[path] ~= nil then
            if context_cache[path] then return context_cache[path] end
        else
            local text = read_capped(path, cap)
            if text then
                local ctx = { path = path, content = text }
                context_cache[path] = ctx
                return ctx
            end
            context_cache[path] = false
        end
    end
    return nil
end

local RULES = {
    "Inspect the workspace before changing it; read a file before editing.",
    "bash runs on the host with the workspace as cwd; it can access the network and filesystem and is not sandboxed unless the user enables it.",
    "Do not assume commands are sandboxed or auto-approved; avoid destructive operations unless the user asks.",
    "Use edit for small changes; write only for new files or full rewrites.",
    "Tool output is truncated; narrow reads/commands when output is large.",
    "Use read for files, directories, and images (JPEG/PNG/GIF/WebP); images are attached for visual understanding and may also come from temp dirs, while text reads stay inside the workspace; use resize to scale them.",
    "Native extensions: LuaJIT bundles FFI. If a system .so already provides the capability, bind only the needed symbols with ffi.cdef + ffi.load in lua/ffi/<feature>.lua and expose it as a tool; use a small C shim under src/<feature>/ only for complex ABI or performance. Package non-libc .so files in dist/lib with $ORIGIN RPATH instead of depending on Python/Node or external binaries.",
    "When built-ins and system libraries are insufficient, use native(action=\"build\", name=..., code=...) to compile a small C/C++ helper in helper/ and native(action=\"run\", ...) to call it. Export char *lite_helper(const char *input); input/output are UTF-8 strings (usually JSON). Prefer existing tools first; native helpers run in-process and need approval.",
    "Be concise, use the user's language, and show file paths clearly.",
    "For simple yes/no/status/version questions, answer directly from the latest evidence; use at most one targeted check (git log -1, lite --version, stat). Do not repeatedly run git log/status or dump whole scripts.",
    "For weather/news/live data, use bash network (e.g. curl) if available; never inspect git/repo docs for it. If network or the required source is unavailable, say so directly.",
    "The newest tool result and current files override older memory or compact digests; verify stale facts instead of repeating them.",
    "If two consecutive tool results add no new information, stop inspecting and answer.",
    "For multi-step work, keep a todo list with the todo tool; mark one item in_progress and update it as you go.",
    "You may be invoked by serve/wake without an interactive user; report what you did and leave durable state in memory/todos.",
}

function M.sections(ctx, opts)
    opts = opts or {}
    local cwd = ctx.session.cwd or "."

    local tool_lines = {}
    for _, schema in ipairs(opts.tools or {}) do
        local fn = schema["function"] or {}
        if fn.name then
            tool_lines[#tool_lines + 1] = string.format("- %s: %s",
                fn.name, fn.description or "")
        end
    end
    local tools = #tool_lines > 0 and table.concat(tool_lines, "\n")
        or "(none)\nAdditional tools may be available."

    local rules = {}
    for _, r in ipairs(RULES) do rules[#rules + 1] = "- " .. r end
    rules[#rules + 1] = "- Use remember(key, content, tags) for durable project facts."
    rules[#rules + 1] = "- Use recall(query, limit) when older context is needed."

    local project = M.project_context(cwd)

    return {
        preamble = "You are lite, a concise terminal coding agent running in the user's workspace. " ..
            "Help the user inspect files, run commands, and modify code.",
        tools = tools,
        capabilities = table.concat({
            "You can act on the user's machine, not just chat:",
            "- Inspect and change the workspace with bash/read/write/edit; bash runs on the host.",
            "- Operate local processes and network; when DISPLAY is available, use automation/x11.lua and automation/xdo.lua (LuaJIT FFI to libX11/libxdo) for window focus, mouse, keyboard, and screenshots without xdotool/wmctrl.",
            "- Read images (JPEG/PNG/GIF/WebP), OCR Chinese/English text with the ocr tool, and resize with the bundled native image library.",
            "- Extend yourself: bind any installed system .so with LuaJIT FFI, or use native to write C/C++, compile helper/<name>.so, write a Lua wrapper + schema, and immediately call the new tool.",
            "- Maintain a todo list and persist/recall durable facts in workspace memory.",
            "- In serve/wake mode you may run without a user present.",
            "- Sandbox/approval policy still applies: bash may be sandboxed, native/FFI runs in-process and needs approval when configured.",
        }, "\n"),
        native = table.concat({
            "Use this self-extension flow only when built-in tools and system libraries are insufficient.",
            "1. Write C or C++ exporting: char *lite_helper(const char *input); and optionally void lite_helper_free(char *out); input/output are UTF-8 strings, usually JSON.",
            "2. Build: native(action=\"build\", name=\"x\", code=..., lang=\"c\", libs={\"m\"}). Default scope=local writes <cwd>/helper; scope=global writes $LITE_ROOT/helper.",
            "3. Test directly: native(action=\"run\", name=\"x\", input=\"...\"). Read the returned string and fix the code if needed.",
            "4. Make it a real tool: native(action=\"wrap\", name=\"x\", lua=..., description=..., parameters={...}). The Lua chunk must return { run = function(args, env) ... end }; it is discovered immediately as x(...).",
            "5. env fields: cwd, helper_dir, scope, ffi, load(name) for the latest .so (declare symbols with env.ffi.cdef), call(name, input) for a native helper.",
            "6. Rebuild creates a new .so path and the next call uses it; no restart. Plugins may also be placed manually in <cwd>/helper (preferred) or $LITE_ROOT/helper.",
            "7. You may also compile manually with bash (cc -shared -fPIC ...), and call a workspace .so with luajit -e/ffi.load.",
            "Native helpers run in-process and are not sandboxed; keep them narrow, prefer existing tools first, and respect approval.",
        }, "\n"),
        rules = table.concat(rules, "\n"),
        memory = "You have persistent local memory for this workspace (mem.bin). " ..
            "A <memory> message may be inserted with entries retrieved for the current request; " ..
            "it can be stale, so use it only when relevant. The prompt keeps only recent turns; " ..
            "older turns live in memory. Call recall(query, limit) for more, and remember(...) " ..
            "to persist durable facts.",
        project_context = project and string.format(
            "Project-specific instructions from %s:\n<project_instructions path=\"%s\">\n%s\n</project_instructions>",
            project.path, project.path, project.content) or "",
        cwd = tostring(cwd),
    }
end

function M.render(sections)
    local out = { sections.preamble or "" }
    for _, name in ipairs(ORDER) do
        if name ~= "preamble" then
            local content = sections[name]
            if content and content ~= "" then
                out[#out + 1] = string.format("<%s>\n%s\n</%s>", name, content, name)
            end
        end
    end
    return table.concat(out, "\n\n")
end

function M.system_prompt(ctx, opts)
    return M.render(M.sections(ctx, opts))
end

-- 记忆块：预算内注入，明确告知可能过期并提示 recall。
function M.memory_block(items, opts)
    if not items or #items == 0 then return "" end
    opts = opts or {}
    local max_chars = tonumber(opts.max_chars) or 2400
    local item_chars = tonumber(opts.item_chars) or 400

    local lines = {
        "<retrieved_memory>",
        "Retrieved from local workspace memory for this request (may be stale; use only if relevant):",
    }
    local used = #lines[1] + #lines[2]
    for _, it in ipairs(items) do
        local text = tostring(it.text or ""):gsub("%s+", " ")
        if #text > item_chars then text = text:sub(1, item_chars) .. "..." end
        local line = string.format("- [%s] %s", tostring(it.key or "?"), text)
        if used + #line + 1 > max_chars then break end
        lines[#lines + 1] = line
        used = used + #line + 1
    end
    lines[#lines + 1] = "Call recall(query, limit) if you need more older context."
    lines[#lines + 1] = "</retrieved_memory>"
    return table.concat(lines, "\n")
end

local TODO_MARK = {
    pending = "[ ]",
    in_progress = "[~]",
    completed = "[x]",
    cancelled = "[-]",
}

function M.todos_block(items)
    if not items or #items == 0 then return "" end
    local lines = {
        "<todos>",
        "Current task list (update it with the todo tool):",
    }
    for _, it in ipairs(items) do
        lines[#lines + 1] = string.format("- %s %s",
            TODO_MARK[it.status] or "[ ]", it.content or "")
    end
    lines[#lines + 1] = "</todos>"
    return table.concat(lines, "\n")
end

-- 短追问带上上一轮 user，提升“继续/那个”这类指代的召回。
function M.recall_query(text, messages)
    local latest = tostring(text or "")
    local prev
    local n = #(messages or {})
    for i = n - 1, 1, -1 do
        local m = messages[i]
        if m.role == "user" and type(m.content) == "string" and m.content ~= latest then
            prev = m.content
            break
        end
    end
    local q = latest
    if prev and #latest < 80 then
        q = latest .. "\n" .. tostring(prev):sub(1, 200)
    end
    return q:sub(1, 600)
end

return M
