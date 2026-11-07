-- 无 TTY 整屏快照：给 AI 直接读取 TUI 状态。
local Screen = require("tui.screen")
local Transcript = require("tui.transcript")
local Composer = require("tui.composer")
local Status = require("tui.status")
local TodoView = require("tui.todo_view")
local Diff = require("tui.diff")
local DiffView = require("tui.diff_view")

local M = {}

local HINT = "lite TUI · Enter 发送 · Ctrl+J 换行 · Tab 补全 · /session 会话 · Ctrl+G diff · Ctrl+T todo · ? help · Ctrl+D 退出"

local function populate(transcript, messages, plugin_errors)
    transcript:add("info", HINT)
    for _, err in ipairs(plugin_errors or {}) do
        transcript:add("info", string.format("plugin %s failed: %s", err.name, err.error))
    end
    for _, m in ipairs(messages or {}) do
        if m.role == "user" then
            transcript:add("user", m.content or "")
        elseif m.role == "assistant" then
            if (m.content or "") ~= "" then transcript:add("assistant", m.content) end
        elseif m.role == "tool" then
            local s = tostring(m.content or "")
            if #s > 4000 then s = s:sub(1, 4000) .. "\n... [truncated]" end
            local b = transcript:add("tool", "● tool result\n" .. s)
            b.tool = true
        end
    end
end

local function esc(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

function M.render(ctx, opts)
    opts = opts or {}
    local w = tonumber(opts.width) or 100
    local h = tonumber(opts.height) or 30
    local screen = Screen.new(w, h)

    if opts.todo then
        local v = TodoView.new(ctx.session.todos or {}, { width = w, height = h })
        v:render(screen, w, h)
        return screen:snapshot_text()
    end

    if opts.diff then
        local files = Diff.parse(opts.diff_patch or "")
        if #files > 0 then
            local v = DiffView.new(files, {
                width = w, height = h,
                mode = w >= 100 and "split" or "unified",
            })
            v:render(screen, w, h)
        else
            screen:put(1, 1, "no diff", "gray")
        end
        return screen:snapshot_text()
    end

    local transcript = Transcript.new()
    populate(transcript, opts.messages, opts.plugin_errors)

    local composer = Composer.new()
    if opts.text and opts.text ~= "" then composer:insert(opts.text) end

    local composer_h = math.max(1, math.min(6, composer:height(6)))
    if composer_h > h - 2 then composer_h = math.max(1, h - 2) end
    local composer_y = h - composer_h
    local transcript_h = math.max(1, composer_y - 1)

    transcript:render(screen, 1, 1, w, transcript_h)
    local cx, cy = composer:render(screen, 1, composer_y, w, "default", composer_h)
    Status.render(screen, h, w, ctx, {
        mem = opts.mem or 0,
        hits = 0,
        todos = ctx.session.todos or {},
    })
    screen.cursor.x = cx
    screen.cursor.y = cy
    screen.cursor.visible = true
    return screen:snapshot_text()
end

function M.write(path, ctx, opts)
    local text = M.render(ctx, opts)
    local f, err = io.open(path, "w")
    if not f then return nil, err end
    if tostring(path):match("%.html$") then
        f:write("<!doctype html><meta charset=\"utf-8\"><pre>", esc(text), "</pre>\n")
    else
        f:write(text, "\n")
    end
    f:close()
    return text
end

return M
