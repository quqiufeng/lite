-- 键序列解析：UTF-8 / 方向键 / Ctrl / bracketed paste。
local utf8 = require("tui.utf8")

local M = {}
M.__index = M

local CSI_KEYS = {
    A = "up", B = "down", C = "right", D = "left",
    H = "home", F = "end", Z = "tab",
    ["3~"] = "delete", ["5~"] = "pgup", ["6~"] = "pgdown",
    ["1~"] = "home", ["7~"] = "home", ["4~"] = "end", ["8~"] = "end",
}

local function parse_escape(buf, i)
    local b2 = buf:byte(i + 1)
    if not b2 then return nil end

    if b2 == 0x5b then -- '['
        local final
        for j = i + 2, #buf do
            local b = buf:byte(j)
            if b >= 0x40 and b <= 0x7e then final = j; break end
        end
        if not final then return nil end
        local seq = buf:sub(i + 2, final)
        local key = CSI_KEYS[seq]
        if key then return seq, final + 1, { key = key } end
        return seq, final + 1, { key = "escape", seq = seq }
    elseif b2 == 0x4f then -- 'O'
        local b3 = buf:byte(i + 2)
        if not b3 then return nil end
        local c = string.char(b3)
        local map = { A = "up", B = "down", C = "right", D = "left",
                      H = "home", F = "end" }
        return c, i + 3, { key = map[c] or "escape", seq = c }
    end

    return nil, i + 2, { key = "escape" }
end

function M.new()
    return setmetatable({ buf = "" }, M)
end

function M:feed(s)
    if s and s ~= "" then self.buf = self.buf .. s end
    local events = {}
    local buf = self.buf
    local i = 1

    while i <= #buf do
        local b = buf:byte(i)
        if b == 0x1b then
            if buf:sub(i, i + 5) == "\27[200~" then
                local endp = buf:find("\27[201~", i + 6, true)
                if not endp then break end
                events[#events + 1] = { key = "paste", text = buf:sub(i + 6, endp - 1) }
                i = endp + 6
            else
                local _, ni, ev = parse_escape(buf, i)
                if not ni then break end
                events[#events + 1] = ev
                i = ni
            end
        elseif b == 13 then
            events[#events + 1] = { key = "enter" }
            i = i + 1
        elseif b == 10 then
            events[#events + 1] = { key = "newline" }
            i = i + 1
        elseif b == 127 or b == 8 then
            events[#events + 1] = { key = "backspace" }
            i = i + 1
        elseif b == 9 then
            events[#events + 1] = { key = "tab" }
            i = i + 1
        elseif b >= 1 and b <= 26 then
            events[#events + 1] = { key = "ctrl", char = string.char(b + 96) }
            i = i + 1
        else
            local ch, ni = utf8.decode(buf, i)
            if not ch then break end
            events[#events + 1] = { key = "char", text = ch }
            i = ni
        end
    end

    self.buf = buf:sub(i)
    return events
end

return M
