-- 对话区：消息块 / 自动换行 / 流式追加 / 工具折叠 / 滚动。
local utf8 = require("tui.utf8")
local Markdown = require("tui.markdown")

local M = {}
M.__index = M

local STYLE = {
    user = "cyan",
    assistant = "default",
    reasoning = "gray",
    tool = "yellow",
    error = "red",
    info = "gray",
}

local PREFIX = {
    user = "› ",
    assistant = "",
    reasoning = "… ",
    tool = "",
    error = "! ",
    info = "· ",
}

local function split_raw(s)
    local out = {}
    local i = 1
    while true do
        local p = s:find("\n", i, true)
        if not p then out[#out + 1] = s:sub(i); break end
        out[#out + 1] = s:sub(i, p - 1)
        i = p + 1
    end
    return out
end

local function wrap(text, w)
    if w < 1 then w = 1 end
    local out = {}
    local line, width = {}, 0
    local i = 1
    while i <= #text do
        local ch, ni, cp = utf8.decode(text, i)
        if not ch then
            ch, ni, cp = text:sub(i, i), i + 1, text:byte(i)
        end
        local cw = utf8.width(ch, cp)
        if width + cw > w and width > 0 then
            out[#out + 1] = table.concat(line)
            line, width = {}, 0
        end
        line[#line + 1] = ch
        width = width + cw
        i = ni
    end
    out[#out + 1] = table.concat(line)
    return out
end

function M.new()
    return setmetatable({
        blocks = {},
        stream_block = nil,
        last_tool = nil,
        scroll = 0,
        total = 0,
        max_scroll = 0,
    }, M)
end

function M:add(kind, text)
    local b = { kind = kind, text = text or "", expanded = false }
    self.blocks[#self.blocks + 1] = b
    return b
end

function M:clear()
    self.blocks = {}
    self.stream_block = nil
    self.reasoning_block = nil
    self.last_tool = nil
    self.scroll = 0
end

function M:stream_append(text)
    if not self.stream_block then
        self.stream_block = self:add("assistant", "")
        self.blocks[#self.blocks] = self.stream_block
    end
    self.stream_block.text = self.stream_block.text .. (text or "")
end

function M:end_stream()
    self.stream_block = nil
end

function M:reasoning_append(text)
    if not self.reasoning_block then
        self.reasoning_block = self:add("reasoning", "")
    end
    self.reasoning_block.text = self.reasoning_block.text .. (text or "")
end

function M:end_reasoning()
    self.reasoning_block = nil
end

function M:tool_start(name, args)
    local hint = ""
    if type(args) == "table" then
        hint = tostring(args.command or args.path or args.query or "")
    end
    local b = self:add("tool", "● " .. tostring(name) .. (hint ~= "" and (" " .. hint) or ""))
    b.tool = true
    self.last_tool = b
end

function M:tool_result(name, result)
    local s = tostring(result or "")
    if #s > 4000 then s = s:sub(1, 4000) .. "\n... [truncated]" end
    local b = self.last_tool
    if not b then
        b = self:add("tool", "● " .. tostring(name))
        self.last_tool = b
    end
    b.result = (b.result or "") .. s
    if s:find("diff --git ", 1, true) then
        local _, nl = s:gsub("\n", "")
        if nl <= 40 then b.expanded = true end
    end
end

function M:toggle_last_tool()
    local b = self.last_tool
    if b then b.expanded = not b.expanded end
end

function M:build_lines(w)
    local lines = {}
    for _, b in ipairs(self.blocks) do
        local text = b.text or ""
        if b.result and (b.expanded or b.tool) then
            text = text .. "\n" .. b.result
        end
        if text == "" then
            -- 空 assistant（纯 tool call）不占行
        else
            if #lines > 0 then lines[#lines + 1] = { text = "", style = "default" } end

            if b.kind == "assistant" then
                local key = w .. "|" .. text
                if b._md_key ~= key then
                    local wrapped = {}
                    for _, mline in ipairs(Markdown.render(text)) do
                        for _, cells in ipairs(Markdown.wrap(mline, w)) do
                            wrapped[#wrapped + 1] = cells
                        end
                    end
                    b._md_key = key
                    b._md_cells = wrapped
                end
                for _, cells in ipairs(b._md_cells or {}) do
                    lines[#lines + 1] = { cells = cells }
                end
            else
                local raw = split_raw(text)
                if b.tool and not b.expanded and #raw > 6 then
                    local keep = 4
                    local rest = #raw - keep
                    local cut = {}
                    for i = 1, keep do cut[i] = raw[i] end
                    cut[#cut + 1] = string.format("... +%d lines (Ctrl+O)", rest)
                    raw = cut
                end
                local prefix = PREFIX[b.kind] or ""
                local style = STYLE[b.kind] or "default"
                for ri, rawline in ipairs(raw) do
                    local pre = (ri == 1) and prefix or ""
                    local avail = w - (ri == 1 and utf8.width_str(pre) or 0)
                    if avail < 1 then avail = 1 end
                    local wrapped = wrap(rawline, avail)
                    for wi, seg in ipairs(wrapped) do
                        lines[#lines + 1] = {
                            text = (wi == 1 and pre or "") .. seg,
                            style = style,
                        }
                    end
                end
            end
        end
    end
    return lines
end

function M:render(screen, x, y, w, h)
    local lines = self:build_lines(w)
    self.total = #lines
    self.max_scroll = math.max(0, self.total - h)
    if self.scroll > self.max_scroll then self.scroll = self.max_scroll end
    if self.scroll < 0 then self.scroll = 0 end

    local start = self.total - h - self.scroll + 1
    if start < 1 then start = 1 end
    for k = 1, h do
        local line = lines[start + k - 1]
        if not line then break end
        if line.cells then
            local cx = x
            for _, c in ipairs(line.cells) do
                cx = screen:put(cx, y + k - 1, c.text, c.style)
            end
        else
            screen:put(x, y + k - 1, line.text, line.style)
        end
    end
end

function M:scroll_up(n)
    self.scroll = math.min(self.max_scroll, self.scroll + (n or 1))
end

function M:scroll_down(n)
    self.scroll = math.max(0, self.scroll - (n or 1))
end

function M:reset_scroll()
    self.scroll = 0
end

return M
