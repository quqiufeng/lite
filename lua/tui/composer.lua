-- 多行输入框：光标移动 / 编辑 / 历史。
local utf8 = require("tui.utf8")

local M = {}
M.__index = M

local function prev_boundary(line, cx)
    if cx <= 1 then return 1 end
    local j = cx - 1
    while j > 1 do
        local b = line:byte(j)
        if b >= 0x80 and b < 0xC0 then j = j - 1 else break end
    end
    return j
end

local function next_boundary(line, cx)
    if cx > #line then return #line + 1 end
    local _, ni = utf8.decode(line, cx)
    return ni or (cx + 1)
end

local function split_lines(s)
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

function M.new()
    return setmetatable({
        lines = { "" },
        cy = 1,
        cx = 1,
        hist = {},
        hist_idx = 0,
    }, M)
end

function M:clear()
    self.lines = { "" }
    self.cy, self.cx = 1, 1
end

function M:is_empty()
    return #self.lines == 1 and self.lines[1] == ""
end

function M:get_text()
    return table.concat(self.lines, "\n")
end

function M:set_text(text)
    self.lines = split_lines(text or "")
    self.cy = #self.lines
    self.cx = #self.lines[self.cy] + 1
end

function M:replace_token(start_byte, text)
    local line = self.lines[self.cy]
    if not line or start_byte < 1 or start_byte > self.cx then return end
    self.lines[self.cy] = line:sub(1, start_byte - 1) .. text .. line:sub(self.cx)
    self.cx = start_byte + #text
end

function M:insert(text)
    if not text or text == "" then return end
    local seg = split_lines(text)
    local line = self.lines[self.cy]
    local head = line:sub(1, self.cx - 1)
    local tail = line:sub(self.cx)

    if #seg == 1 then
        self.lines[self.cy] = head .. seg[1] .. tail
        self.cx = self.cx + #seg[1]
        return
    end

    self.lines[self.cy] = head .. seg[1]
    for k = 2, #seg - 1 do
        table.insert(self.lines, self.cy + k - 1, seg[k])
    end
    table.insert(self.lines, self.cy + #seg - 1, seg[#seg] .. tail)
    self.cy = self.cy + #seg - 1
    self.cx = #seg[#seg] + 1
end

function M:backspace()
    local line = self.lines[self.cy]
    if self.cx > 1 then
        local p = prev_boundary(line, self.cx)
        self.lines[self.cy] = line:sub(1, p - 1) .. line:sub(self.cx)
        self.cx = p
    elseif self.cy > 1 then
        local prev = self.lines[self.cy - 1]
        self.lines[self.cy - 1] = prev .. line
        table.remove(self.lines, self.cy)
        self.cy = self.cy - 1
        self.cx = #prev + 1
    end
end

function M:delete()
    local line = self.lines[self.cy]
    if self.cx <= #line then
        local n = next_boundary(line, self.cx)
        self.lines[self.cy] = line:sub(1, self.cx - 1) .. line:sub(n)
    elseif self.cy < #self.lines then
        self.lines[self.cy] = line .. self.lines[self.cy + 1]
        table.remove(self.lines, self.cy + 1)
    end
end

function M:left()
    if self.cx > 1 then
        self.cx = prev_boundary(self.lines[self.cy], self.cx)
    elseif self.cy > 1 then
        self.cy = self.cy - 1
        self.cx = #self.lines[self.cy] + 1
    end
end

function M:right()
    local line = self.lines[self.cy]
    if self.cx <= #line then
        self.cx = next_boundary(line, self.cx)
    elseif self.cy < #self.lines then
        self.cy = self.cy + 1
        self.cx = 1
    end
end

function M:up()
    if self.cy > 1 then
        self.cy = self.cy - 1
        self.cx = math.min(self.cx, #self.lines[self.cy] + 1)
    end
end

function M:down()
    if self.cy < #self.lines then
        self.cy = self.cy + 1
        self.cx = math.min(self.cx, #self.lines[self.cy] + 1)
    end
end

function M:home() self.cx = 1 end
function M:end_() self.cx = #self.lines[self.cy] + 1 end

function M:push_history(text)
    text = text or self:get_text()
    if text == "" then return end
    if self.hist[#self.hist] ~= text then
        self.hist[#self.hist + 1] = text
    end
    self.hist_idx = 0
end

function M:history_prev()
    if #self.hist == 0 then return end
    self.hist_idx = (self.hist_idx == 0) and #self.hist or (self.hist_idx - 1)
    self:set_text(self.hist[self.hist_idx])
end

function M:history_next()
    if self.hist_idx == 0 then return end
    self.hist_idx = self.hist_idx + 1
    if self.hist_idx > #self.hist then
        self.hist_idx = 0
        self:set_text("")
    else
        self:set_text(self.hist[self.hist_idx])
    end
end

function M:height(max_h)
    max_h = max_h or 6
    return math.min(#self.lines, max_h)
end

-- 渲染到屏幕底部；返回光标屏幕坐标。
function M:render(screen, x, y, w, style, max_h)
    max_h = max_h or 6
    local h = math.min(#self.lines, max_h)
    local offset = 0
    if self.cy > h then offset = self.cy - h end

    for k = 1, h do
        local row = y + k - 1
        local line = self.lines[offset + k] or ""
        screen:put(x, row, line, style)
    end

    local cur_line = self.lines[self.cy] or ""
    local prefix = cur_line:sub(1, self.cx - 1)
    local cx = x + utf8.width_str(prefix)
    return cx, y + (self.cy - offset) - 1
end

return M
