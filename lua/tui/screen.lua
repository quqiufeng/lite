-- 虚拟 cell buffer：宽字符、行级 diff、快照。
local utf8 = require("tui.utf8")

local M = {}
M.__index = M

local STYLES = {
    default = "",
    dim = "\27[2m",
    bold = "\27[1m",
    reverse = "\27[7m",
    red = "\27[31m",
    green = "\27[32m",
    yellow = "\27[33m",
    blue = "\27[34m",
    magenta = "\27[35m",
    cyan = "\27[36m",
    gray = "\27[90m",
    diff_file = "\27[1m",
    diff_hunk = "\27[36m",
    diff_num = "\27[90m",
    diff_ctx = "\27[0m",
    diff_del = "\27[31m",
    diff_add = "\27[32m",
    diff_del_hl = "\27[41;97m",
    diff_add_hl = "\27[42;30m",
    diff_gutter = "\27[90m",
    italic = "\27[3m",
    code = "\27[33m",
    code_block = "\27[36m",
    heading = "\27[1;35m",
    heading2 = "\27[1;36m",
    quote = "\27[90m",
    link = "\27[34m",
}

function M.new(w, h)
    local self = setmetatable({
        w = w or 80,
        h = h or 24,
        rows = {},
        prev = {},
        sel = nil,
        cursor = { x = 1, y = 1, visible = false },
    }, M)
    self:clear()
    return self
end

function M:clear()
    self.rows = {}
    for y = 1, self.h do self.rows[y] = {} end
end

function M:resize(w, h)
    self.w, self.h = w, h
    self.sel = nil
    self:clear()
    self.prev = {}
end

function M:invalidate()
    self.prev = {}
end

-- 鼠标选区：左上 (y0,x0) → 右下 (y1,x1)，坐标都是 1 基屏幕列/行。
-- 高亮只在渲染时叠加 reverse，不改动字符本身。
function M:set_selection(y0, x0, y1, x1)
    if y1 < y0 or (y1 == y0 and x1 < x0) then
        y0, x0, y1, x1 = y1, x1, y0, x0
    end
    self.sel = { y0 = y0, x0 = x0, y1 = y1, x1 = x1 }
    self.prev = {}
end

function M:clear_selection()
    if not self.sel then return end
    self.sel = nil
    self.prev = {}
end

function M:has_selection()
    return self.sel ~= nil
end

-- 选区在当前行的可见区间；行内返回 [x0,x1]。
local function sel_span(sel, y, w)
    if not sel or y < sel.y0 or y > sel.y1 then return nil end
    local a = (y == sel.y0) and sel.x0 or 1
    local b = (y == sel.y1) and sel.x1 or w
    if a > b then return nil end
    return a, b
end

-- 选区文本：每行去掉尾部空白，首尾空行去掉。
function M:selection_text()
    local sel = self.sel
    if not sel then return "" end
    local lines = {}
    for y = sel.y0, sel.y1 do
        local a, b = sel_span(sel, y, self.w)
        if a then
            local row = self.rows[y] or {}
            local seg = {}
            -- 按屏幕列取，不能按压缩后的字符数组取：中文宽字符占两列。
            for x = a, math.min(b, self.w) do
                local cell = row[x]
                if cell and cell.cont then
                    -- 宽字符的后半列，字符已在起始列加入。
                elseif cell and cell.ch ~= "" then
                    seg[#seg + 1] = cell.ch
                else
                    seg[#seg + 1] = " "
                end
            end
            lines[#lines + 1] = (table.concat(seg):gsub("%s+$", ""))
        else
            lines[#lines + 1] = ""
        end
    end
    while #lines > 0 and lines[1] == "" do table.remove(lines, 1) end
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
    return table.concat(lines, "\n")
end

-- 写入文本；返回下一个 x。超出边界自动截断。
function M:put(x, y, text, style)
    if y < 1 or y > self.h then return x end
    local row = self.rows[y]
    local i = 1
    while i <= #text do
        local ch, ni, cp = utf8.decode(text, i)
        if not ch then
            ch, ni, cp = string.sub(text, i, i), i + 1, string.byte(text, i)
        end
        if ch == "\n" then
            i = ni
        else
            local cw = utf8.width(ch, cp)
            if cw == 0 then
                if x > 1 then
                    local prev = row[x - 1]
                    if prev then prev.ch = prev.ch .. ch end
                end
            elseif x + cw - 1 <= self.w then
                row[x] = { ch = ch, style = style }
                if cw == 2 then row[x + 1] = { ch = "", style = style, cont = true } end
                x = x + cw
            else
                break
            end
            i = ni
        end
    end
    return x
end

-- 用文本填满一行到宽度 w（用于状态栏/背景）。
function M:line(y, text, style, width)
    width = width or self.w
    if y < 1 or y > self.h then return end
    local row = {}
    for x = 1, width do row[x] = { ch = " ", style = style } end
    self.rows[y] = row
    self:put(1, y, text, style)
end

function M:row_text(y)
    local row = self.rows[y] or {}
    local out = {}
    for x = 1, self.w do
        local cell = row[x]
        if not (cell and cell.cont) then
            out[#out + 1] = (cell and cell.ch ~= "") and cell.ch or " "
        end
    end
    return table.concat(out)
end

local function styled_row(row, w, sel, y)
    local out = {}
    local cur = nil
    local a, b = sel_span(sel, y, w)
    for x = 1, w do
        local cell = row[x]
        local ch = (cell and cell.ch ~= "") and cell.ch or " "
        if cell and cell.cont then
            ch = nil
        end
        if ch then
            local style = cell and cell.style or "default"
            if a and x >= a and x <= b then style = "reverse" end
            if style ~= cur then
                out[#out + 1] = "\27[0m" .. (STYLES[style] or "")
                cur = style
            end
            out[#out + 1] = ch
        end
    end
    out[#out + 1] = "\27[0m"
    return table.concat(out)
end

-- 行级 diff：只重绘变化行，返回一帧 ANSI 字符串。
function M:render()
    local out = {}
    for y = 1, self.h do
        local text = self:row_text(y)
        if text ~= self.prev[y] then
            out[#out + 1] = string.format("\27[%d;1H", y)
            out[#out + 1] = styled_row(self.rows[y] or {}, self.w, self.sel, y)
            out[#out + 1] = "\27[K"
        end
    end
    if self.cursor.visible then
        out[#out + 1] = string.format("\27[%d;%dH\27[?25h", self.cursor.y, self.cursor.x)
    else
        out[#out + 1] = "\27[?25l"
    end

    self.prev = {}
    for y = 1, self.h do self.prev[y] = self:row_text(y) end
    return table.concat(out)
end

function M:snapshot_text()
    local out = {}
    for y = 1, self.h do
        out[y] = self:row_text(y):gsub("%s+$", "")
    end
    return table.concat(out, "\n")
end

return M
