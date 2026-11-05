-- diff 视图布局：unified / split + wrap 高度 + 前缀和虚拟化。
local utf8 = require("tui.utf8")
local Diff = require("tui.diff")

local M = {}
M.__index = M

local GUTTER = " │ "
local GUTTER_W = 3
local TAB_WIDTH = 4

local function expand_tabs(s)
    return (tostring(s or ""):gsub("\t", string.rep(" ", TAB_WIDTH)))
end

local function wrap_segments(segs, width)
    if width < 1 then width = 1 end
    local lines = { {} }
    local line = lines[1]
    local col = 0

    local function newline()
        lines[#lines + 1] = {}
        line = lines[#lines]
        col = 0
    end

    for _, seg in ipairs(segs) do
        local text = seg.text or ""
        local style = seg.style
        local i = 1
        while i <= #text do
            local ch, ni, cp = utf8.decode(text, i)
            if not ch then ch, ni, cp = text:sub(i, i), i + 1, text:byte(i) end
            if ch == "\n" then
                newline()
            else
                local cw = utf8.width(ch, cp)
                if col + cw > width and col > 0 then newline() end
                line[#line + 1] = { text = ch, style = style }
                col = col + cw
            end
            i = ni
        end
    end
    return lines
end

local function styled(segs, base, hl)
    local out = {}
    for _, s in ipairs(segs) do
        out[#out + 1] = {
            text = expand_tabs(s.text),
            style = s.changed and hl or base,
        }
    end
    return out
end

local function one(text, style)
    return { { text = expand_tabs(text), style = style } }
end

local function count_lines(segs, width)
    return #wrap_segments(segs, width)
end

local function render_cells(screen, x, y, cells)
    local cx = x
    for _, c in ipairs(cells) do
        cx = screen:put(cx, y, c.text, c.style)
    end
    return cx
end

function M.new(files, mode, width)
    local self = setmetatable({
        files = files or {},
        mode = mode or "unified",
        width = math.max(20, width or 80),
        rows = {},
        hunks = {},
        file_rows = {},
    }, M)

    local maxno = 0
    for _, f in ipairs(self.files) do
        for _, h in ipairs(f.hunks or {}) do
            for _, r in ipairs(h.rows or {}) do
                if (r.old or 0) > maxno then maxno = r.old end
                if (r.new or 0) > maxno then maxno = r.new end
            end
        end
    end
    self.lnw = math.max(3, #tostring(maxno))

    if self.mode == "split" then
        self.left_w = math.max(10, math.floor((self.width - GUTTER_W) / 2))
        self.right_w = math.max(10, self.width - GUTTER_W - self.left_w)
    end

    for fi, f in ipairs(self.files) do
        self:_add_file(f, fi)
    end
    self:_finalize()
    return self
end

function M:_add_row(row)
    self.rows[#self.rows + 1] = row
    return row
end

function M:_add_file(f, fi)
    if fi > 1 then
        self:_add_row({ kind = "blank", height = 1, cells = one("", "default") })
    end

    local mark = ({ added = "A", deleted = "D", renamed = "R" })[f.status] or "M"
    local header = string.format("%s %s  +%d -%d", mark, f.path or "?",
        f.additions or 0, f.deletions or 0)
    local cells = one(header, "diff_file")
    self:_add_row({ kind = "file", cells = cells, height = count_lines(cells, self.width) })
    self.file_rows[#self.file_rows + 1] = #self.rows

    if f.binary then
        local bc = one("binary file (not rendered)", "dim")
        self:_add_row({ kind = "binary", cells = bc, height = count_lines(bc, self.width) })
        return
    end

    for _, h in ipairs(f.hunks or {}) do
        local hc = one(h.header or "", "diff_hunk")
        self:_add_row({ kind = "hunk", cells = hc, height = count_lines(hc, self.width) })
        self.hunks[#self.hunks + 1] = { row = #self.rows, label = h.header or "" }

        local paired = Diff.pair(h)
        if self.mode == "split" then
            for _, p in ipairs(paired) do self:_add_split_row(p) end
        else
            for _, p in ipairs(paired) do self:_add_unified_row(p) end
        end
    end
end

function M:_num(n)
    if not n then return string.rep(" ", self.lnw) end
    return string.format("%" .. self.lnw .. "d", n)
end

function M:_add_unified_row(p)
    local function prefix(n, sign, base)
        return { text = sign .. self:_num(n) .. " ", style = base }
    end

    if p.kind == "ctx" then
        local cells = { prefix(p.left.new, " ", "diff_ctx") }
        cells[#cells + 1] = { text = expand_tabs(p.left.text), style = "diff_ctx" }
        self:_add_row({ kind = "ctx", cells = cells, height = count_lines(cells, self.width) })
    elseif p.kind == "del" then
        local base = "diff_del"
        local cells = { prefix(p.left.old, "-", base) }
        for _, c in ipairs(styled(p.left_segs or one(p.left.text, base), base, "diff_del_hl")) do
            cells[#cells + 1] = c
        end
        self:_add_row({ kind = "del", cells = cells, height = count_lines(cells, self.width) })
    elseif p.kind == "add" then
        local base = "diff_add"
        local cells = { prefix(p.right.new, "+", base) }
        for _, c in ipairs(styled(p.right_segs or one(p.right.text, base), base, "diff_add_hl")) do
            cells[#cells + 1] = c
        end
        self:_add_row({ kind = "add", cells = cells, height = count_lines(cells, self.width) })
    elseif p.kind == "change" then
        local lbase, abase = "diff_del", "diff_add"
        local lc = { prefix(p.left.old, "-", lbase) }
        for _, c in ipairs(styled(p.left_segs or one(p.left.text, lbase), lbase, "diff_del_hl")) do
            lc[#lc + 1] = c
        end
        self:_add_row({ kind = "del", cells = lc, height = count_lines(lc, self.width) })

        local ac = { prefix(p.right.new, "+", abase) }
        for _, c in ipairs(styled(p.right_segs or one(p.right.text, abase), abase, "diff_add_hl")) do
            ac[#ac + 1] = c
        end
        self:_add_row({ kind = "add", cells = ac, height = count_lines(ac, self.width) })
    end
end

function M:_add_split_row(p)
    local function side(row, num, base, hl, segs)
        if not row then
            return { { text = string.rep(" ", self.lnw) .. " ", style = "diff_num" } }
        end
        local cells = { { text = self:_num(num) .. " ", style = "diff_num" } }
        for _, c in ipairs(styled(segs or one(row.text, base), base, hl)) do
            cells[#cells + 1] = c
        end
        return cells
    end

    local left_cells, right_cells
    if p.kind == "ctx" then
        left_cells = side(p.left, p.left.old, "diff_ctx", "diff_ctx")
        right_cells = side(p.right, p.right.new, "diff_ctx", "diff_ctx")
    elseif p.kind == "del" then
        left_cells = side(p.left, p.left.old, "diff_del", "diff_del_hl", p.left_segs)
        right_cells = side(nil)
    elseif p.kind == "add" then
        left_cells = side(nil)
        right_cells = side(p.right, p.right.new, "diff_add", "diff_add_hl", p.right_segs)
    else
        left_cells = side(p.left, p.left.old, "diff_del", "diff_del_hl", p.left_segs)
        right_cells = side(p.right, p.right.new, "diff_add", "diff_add_hl", p.right_segs)
    end

    self:_add_row({
        kind = "split",
        left_cells = left_cells,
        right_cells = right_cells,
        height = math.max(
            count_lines(left_cells, self.left_w),
            count_lines(right_cells, self.right_w),
            1),
    })
end

function M:_finalize()
    local prefix = { [1] = 0 }
    for i, row in ipairs(self.rows) do
        prefix[i + 1] = prefix[i] + (row.height or 1)
    end
    self.prefix = prefix
    self.total = prefix[#self.rows + 1] or 0
end

function M:max_scroll(viewport_h)
    return math.max(0, (self.total or 0) - (viewport_h or 0))
end

function M:row_at(scroll)
    local n = #self.rows
    if n == 0 then return nil end
    if scroll < 0 then scroll = 0 end
    local lo, hi = 1, n
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if self.prefix[mid] <= scroll then lo = mid else hi = mid - 1 end
    end
    return lo, scroll - self.prefix[lo]
end

function M:scroll_for_row(row_index)
    return self.prefix[row_index] or 0
end

function M:next_hunk(scroll, dir)
    dir = dir or 1
    local best
    for _, h in ipairs(self.hunks) do
        local pos = self.prefix[h.row] or 0
        if dir > 0 then
            if pos > scroll and (not best or pos < best) then best = pos end
        else
            if pos < scroll and (not best or pos > best) then best = pos end
        end
    end
    return best
end

function M:_row_lines(row)
    if row.kind == "split" then
        local ll = wrap_segments(row.left_cells, self.left_w)
        local rl = wrap_segments(row.right_cells, self.right_w)
        local n = math.max(#ll, #rl, 1)
        local out = {}
        for k = 1, n do out[k] = { left = ll[k], right = rl[k] } end
        return out
    end
    local lines = wrap_segments(row.cells, self.width)
    local out = {}
    for k, cells in ipairs(lines) do out[k] = { cells = cells } end
    return out
end

function M:render(screen, x, y, h, scroll)
    local n = #self.rows
    if n == 0 then
        screen:put(x, y, "No changes", "dim")
        return
    end
    if scroll < 0 then scroll = 0 end
    local max_s = self:max_scroll(h)
    if scroll > max_s then scroll = max_s end

    local idx, skip = self:row_at(scroll)
    local line_y = y
    while idx and idx <= n and line_y < y + h do
        local row = self.rows[idx]
        local lines = self:_row_lines(row)
        for k = skip + 1, #lines do
            if line_y >= y + h then break end
            local line = lines[k]
            if row.kind == "split" then
                if line.left then render_cells(screen, x, line_y, line.left) end
                screen:put(x + self.left_w, line_y, GUTTER, "diff_gutter")
                if line.right then
                    render_cells(screen, x + self.left_w + GUTTER_W, line_y, line.right)
                end
            else
                render_cells(screen, x, line_y, line.cells)
            end
            line_y = line_y + 1
        end
        idx = idx + 1
        skip = 0
    end
end

return M
