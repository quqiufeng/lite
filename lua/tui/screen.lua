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
    self:clear()
    self.prev = {}
end

function M:invalidate()
    self.prev = {}
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

local function styled_row(row, w)
    local out = {}
    local cur = nil
    for x = 1, w do
        local cell = row[x]
        local ch = (cell and cell.ch ~= "") and cell.ch or " "
        if cell and cell.cont then
            ch = nil
        end
        if ch then
            local style = cell and cell.style or "default"
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
            out[#out + 1] = styled_row(self.rows[y] or {}, self.w)
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
