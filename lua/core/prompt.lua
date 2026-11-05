-- 系统 prompt 组装 + 记忆块格式化 + recall 查询构造。
-- 参考 Pi system-prompt sections 与 Reasonix prefix/recall 的稳定前缀思路。
local M = {}

local ORDER = { "preamble", "tools", "rules", "memory", "project_context", "cwd" }
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
    "Keep bash commands scoped to the workspace; avoid destructive operations.",
    "Use edit for small changes; write only for new files or full rewrites.",
    "Tool output is truncated; narrow reads/commands when output is large.",
    "Use read for files, directories, and images (JPEG/PNG/GIF/WebP); images are attached for visual understanding.",
    "Be concise, use the user's language, and show file paths clearly.",
    "For multi-step work, keep a todo list with the todo tool; mark one item in_progress and update it as you go.",
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
