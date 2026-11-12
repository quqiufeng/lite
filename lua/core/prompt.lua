-- 系统 prompt 组装 + 记忆块格式化 + recall 查询构造。
-- 参考 Pi system-prompt sections 与 Reasonix prefix/recall 的稳定前缀思路。
local M = {}

-- 注意：时钟/轮次预算这类每轮都变的内容不能进 system（会让 prefix cache 每轮失效），
-- 走 M.runtime_block 追加到本轮末尾。
local ORDER = { "preamble", "tools", "capabilities", "native", "rules", "memory", "project_context", "cwd" }
local DEFAULT_PROJECT_CHARS = 16000
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
    "bash runs on the host with the workspace as cwd; it can reach the network and filesystem and is not sandboxed unless the user enables it.",
    "Do not assume commands are sandboxed or auto-approved; avoid destructive operations unless asked.",
    "Use edit for small changes; write only for new files or full rewrites.",
    "Tool output is truncated; narrow reads and commands when output is large.",
    "read handles files, directories, and images; text reads stay inside the workspace, images may also come from temp dirs.",
    "Be concise, use the user's language, and show file paths clearly.",
    "For simple yes/no/status/version questions, answer directly from the latest evidence; use at most one targeted check (git log -1, lite --version, stat). Do not repeat git log/status or dump whole scripts.",
    "For live external data use web; if truncated, retry with a larger max_chars or a more specific URL. Never inspect git/repo docs for live data, and never invent it.",
    "Newest tool results and current files override older memory or summaries; verify stale facts instead of repeating them.",
    "The current request overrides any older unfinished task: do not resume, verify, commit, or report it unless asked.",
    "For read-only requests (read, inspect, list, summarize), do not run tests/builds or modify files unless asked; do not turn it into an unrequested audit.",
    "If the request has multiple parts or sources, address every part in the final answer; never silently drop one.",
    "After git log, summarize the relevant commits instead of only running the command.",
    "If two consecutive tool results add no new information, stop inspecting and answer.",
    "For multi-step work keep a todo list; one item in_progress at a time.",
    "You may be invoked by serve/wake without a user; report what you did and leave durable state in memory/todos.",
}

function M.sections(ctx, opts)
    opts = opts or {}
    local cwd = ctx.session.cwd or "."

    -- 工具**名单**不进 system：helper 增删一个插件就会让这段字节变一次，
    -- 于是 system prompt 整段前缀缓存作废（一次 helper 变动 = 整晚 miss）。
    -- 名字表改由 runtime_block 追加在本轮末尾（见 M.runtime_block），
    -- system 因此与工具集无关，可以做到逐字节常量。
    local tools = "Each tool's name, description, parameters, and defaults are sent in the API " ..
        "`tools` field, which is authoritative. Use exactly those names."

    local rules = {}
    for _, r in ipairs(RULES) do rules[#rules + 1] = "- " .. r end

    local project = M.project_context(cwd)

    return {
        preamble = "You are lite, a concise terminal coding agent running in the user's workspace. " ..
            "Help the user inspect files, run commands, and modify code.",
        tools = tools,
        capabilities = table.concat({
            "You can act on the user's machine, not just chat:",
            "- Inspect and change the workspace with bash/read/write/edit; bash runs on the host.",
            "- Operate local processes and network; when DISPLAY is available, use ffi/x11.lua and ffi/xdo.lua (LuaJIT FFI to libX11/libxdo) for window focus, mouse, keyboard, and screenshots without xdotool/wmctrl.",
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

-- 每轮易变上下文：本地时钟 + 循环预算。作为本轮最后一条 system 消息追加，
-- 让 system prompt（前缀）保持字节稳定，命中 provider 的 prefix cache。
function M.runtime_block(ctx, opts)
    opts = opts or {}
    local lines = { "Current local date/time: " .. os.date("%Y-%m-%d %A %H:%M:%S %Z") .. "." }
    -- 工具名单放这里而不是 system：这块本来每轮都在变（时钟），多一行名字不多付
    -- 一次缓存；而 system 因为不再含名单而变成常量，helper 增删插件也不会再把它打散。
    local names = {}
    for _, schema in ipairs(opts.tools or {}) do
        local fn = schema["function"] or {}
        if fn.name then names[#names + 1] = fn.name end
    end
    if #names > 0 then
        lines[#lines + 1] = "Tool names available in this process: " .. table.concat(names, ", ") .. "."
    end
    local turn = tonumber(opts.turn)
    local max_turns = tonumber(opts.max_turns)
        or tonumber(ctx and ctx.settings and ctx.settings.max_turns)
    if turn and max_turns then
        lines[#lines + 1] = string.format(
            "Tool-loop turn %d/%d: %d turn(s) left before the loop stops and you must answer with what you have.",
            turn, max_turns, math.max(max_turns - turn, 0))
    end
    return table.concat(lines, "\n")
end

-- 上下文预算：与 runtime_block 一样每轮都在变，只能追加在末尾。
-- 模型要能自己判断"还能塞多少、什么时候会被压缩"，否则它会一直读大文件、
-- 直到 harness 在它不知情的时候把历史压成摘要。
function M.budget_block(ctx, opts)
    opts = opts or {}
    local used = tonumber(opts.used)
    local budget = tonumber(opts.budget)
        or tonumber(ctx and ctx.settings and ctx.settings.context_chars)
    if not used or not budget or budget <= 0 then return "" end
    local left = budget - used
    local line
    if left >= 0 then
        line = string.format("Context budget: %d/%d chars used (%.0f%%); %d chars left before compaction",
            used, budget, used / budget * 100, left)
    else
        line = string.format("Context budget: %d/%d chars used; over by %d chars, compaction is due",
            used, budget, -left)
    end
    local ratio = tonumber(opts.tok_per_char)
    if ratio and ratio > 0 then
        line = line .. string.format(" (~%d tokens left).", math.floor(math.max(left, 0) * ratio))
    else
        line = line .. "."
    end
    return line
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
