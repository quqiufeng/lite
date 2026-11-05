-- 全屏 diff pager：滚动 / hunk / split-unified / 单文件。
local Layout = require("tui.diff_layout")
local utf8 = require("tui.utf8")

local M = {}
M.__index = M

local MIN_SPLIT_WIDTH = 100

function M.new(files, opts)
    opts = opts or {}
    local self = setmetatable({
        files = files or {},
        width = opts.width or 80,
        height = opts.height or 24,
        mode = opts.mode or "unified",
        scroll = 0,
        single = false,
        file_index = 1,
    }, M)
    self.content_h = math.max(1, self.height - 2)
    self:_rebuild()
    return self
end

function M:_visible_files()
    if self.single and self.files[self.file_index] then
        return { self.files[self.file_index] }
    end
    return self.files
end

function M:_rebuild()
    if self.width < MIN_SPLIT_WIDTH then self.mode = "unified" end
    self.layout = Layout.new(self:_visible_files(), self.mode, self.width)
    self:_clamp()
end

function M:_clamp()
    local m = self.layout:max_scroll(self.content_h)
    if self.scroll > m then self.scroll = m end
    if self.scroll < 0 then self.scroll = 0 end
end

function M:set_size(w, h)
    local changed = w ~= self.width
    self.width, self.height = w, h
    self.content_h = math.max(1, h - 2)
    if changed then
        self:_rebuild()
    else
        self:_clamp()
    end
end

function M:toggle_mode()
    if self.width < MIN_SPLIT_WIDTH then return end
    self.mode = self.mode == "split" and "unified" or "split"
    self:_rebuild()
end

function M:_current_file_index()
    local idx = 1
    for i, row in ipairs(self.layout.file_rows) do
        if self.layout.prefix[row] <= self.scroll then idx = i else break end
    end
    return idx
end

function M:toggle_single()
    if self.single then
        self.single = false
    else
        self.file_index = self:_current_file_index()
        self.single = true
    end
    self:_rebuild()
    self.scroll = 0
end

function M:next_file(dir)
    local n = #self.files
    if n == 0 then return end
    self.file_index = ((self.file_index - 1 + dir) % n) + 1
    self:_rebuild()
    self.scroll = 0
end

function M:_jump_hunk(dir)
    local pos = self.layout:next_hunk(self.scroll, dir)
    if pos then self.scroll = pos end
end

function M:handle(ev)
    local k = ev.key

    if k == "char" then
        local c = ev.text
        if c == "q" then return "close" end
        if c == "j" then self.scroll = self.scroll + 1
        elseif c == "k" then self.scroll = self.scroll - 1
        elseif c == "g" then self.scroll = 0
        elseif c == "G" then self.scroll = self.layout:max_scroll(self.content_h)
        elseif c == "n" then self:_jump_hunk(1)
        elseif c == "p" then self:_jump_hunk(-1)
        elseif c == "f" then self:toggle_single()
        elseif c == "]" then self:next_file(1)
        elseif c == "[" then self:next_file(-1)
        end
    elseif k == "escape" then
        return "close"
    elseif k == "up" then
        self.scroll = self.scroll - 1
    elseif k == "down" then
        self.scroll = self.scroll + 1
    elseif k == "pgup" then
        self.scroll = self.scroll - self.content_h
    elseif k == "pgdown" then
        self.scroll = self.scroll + self.content_h
    elseif k == "home" then
        self.scroll = 0
    elseif k == "end" then
        self.scroll = self.layout:max_scroll(self.content_h)
    elseif k == "tab" then
        self:toggle_mode()
    elseif k == "ctrl" and ev.char == "c" then
        return "close"
    end

    self:_clamp()
end

local function stats(files)
    local add, del = 0, 0
    for _, f in ipairs(files) do
        add = add + (f.additions or 0)
        del = del + (f.deletions or 0)
    end
    return add, del
end

function M:render(screen, w, h)
    self:set_size(w, h)

    local add, del = stats(self.files)
    local title = string.format(" DIFF  %d files  +%d -%d  [%s]",
        #self.files, add, del, self.mode)
    if self.single and self.files[self.file_index] then
        title = title .. "  " .. (self.files[self.file_index].path or "?")
    end
    title = title .. " "
    screen:line(1, title, "reverse", w)

    self.layout:render(screen, 1, 2, self.content_h, self.scroll)

    local total = self.layout.total or 0
    local right = string.format(" %d/%d ", math.min(total, self.scroll + self.content_h), total)
    local hint = " ↑↓ PgUp/PgDn · n/p hunk · Tab split/unified · f single · ]/[ file · q close "
    local avail = w - utf8.width_str(right) - 1
    if avail > 0 then
        local cut, cw, i = {}, 0, 1
        while i <= #hint and cw + 1 <= avail do
            local ch, ni, cp = utf8.decode(hint, i)
            if not ch then break end
            local c = utf8.width(ch, cp)
            if cw + c > avail then break end
            cut[#cut + 1] = ch
            cw = cw + c
            i = ni
        end
        hint = table.concat(cut)
    else
        hint = ""
    end
    local gap = math.max(0, w - utf8.width_str(hint) - utf8.width_str(right))
    screen:line(h, hint .. string.rep(" ", gap) .. right, "reverse", w)
end

return M
