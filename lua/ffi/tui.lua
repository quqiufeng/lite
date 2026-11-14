-- TUI 文本内核 FFI（liblite_tui.so）：显示宽度 / 折行 / 逐字符 cell / 行内 diff。
--
-- 为什么走 C：TUI 每帧按显示宽度折行+填 cell，纯 Lua 每字符要 3~4 次 s:byte、
-- 一个 s:sub、一次 wcwidth FFI 调用；大 diff 一帧几十万次，实测 diff 布局占
-- 整帧 29%。C 侧把「按宽度走字符」的循环整体做一个函数，Lua 只处理「行 run」
-- 而不是「字符行」。语义与 lua/tui/utf8.lua + diff_layout.wrap_segments 逐位一致
-- （非法字节算宽度 1、组合字符宽度 0、超宽字符 col==0 时仍落行首、末尾 '\n'
-- 产生末尾空行）。
--
-- 缺 .so 或缓冲区装不下时**返回 nil**，调用方回退纯 Lua 实现；两条路径必须
-- 输出完全相同的行/宽度，tools/auto_unit.lua 里对拍。
local ffi = require("ffi")

ffi.cdef[[
int lite_tui_width(const char *s, int n);
int lite_tui_count_lines(const char *s, int n, int width);
int lite_tui_wrap(const char *s, int n, int width, int *breaks, int maxbreaks);
int lite_tui_wrap_segs(const char *s, int n, const int *segoff, int nseg,
                       int width, int *out, int maxruns, int *out_lines);
int lite_tui_cells(const char *s, int n, int *out, int maxcells);
int lite_tui_intraline(const int *a, int na, const int *b, int nb,
                       unsigned char *ops, int max_ops);
]]

local lib, lib_path, load_err = require("ffi.libfind").load("liblite_tui.so")

local M = {}

-- 复用的 int 缓冲：runs 是 wrap_segs 的输出（每 run 4 int），
-- offs 是段偏移（每段 1 int），cells 是逐字符三元组。
local runs, runs_cap = nil, 0
local offs, offs_cap = nil, 0
local cells, cells_cap = nil, 0

local function grow_int(cur, cur_cap, need)
    if cur and cur_cap >= need then return cur, cur_cap end
    local cap = cur_cap > 0 and cur_cap or 256
    while cap < need do cap = cap * 2 end
    return ffi.new("int[?]", cap), cap
end

function M.available()
    return lib ~= nil
end

function M.error()
    return load_err
end

function M.lib_path()
    return lib_path
end

-- 字符串显示宽度（列数）。缺库返回 nil。
function M.width(s)
    if not lib then return nil end
    s = tostring(s or "")
    local n = #s
    if n == 0 then return 0 end
    return lib.lite_tui_width(s, n)
end

-- 把样式段拼成 (text, offsets)；段文本 0 长度也保留一个 run 边界。
local function flatten(segs)
    local n = #segs
    if n == 0 then return "", nil end
    local parts, need = {}, 0
    for i = 1, n do
        local t = segs[i].text or ""
        parts[i] = t
        need = need + #t
    end
    local s = n == 1 and parts[1] or table.concat(parts)
    offs, offs_cap = grow_int(offs, offs_cap, n + 1)
    local o = 0
    offs[0] = 0
    for i = 1, n do
        o = o + #parts[i]
        offs[i] = o
    end
    return s, n
end

-- 折行：返回 lines（每行是 { {text=,style=}, ... }）与行数；缺库/溢出返回 nil。
-- 空行是空表（高度语义与纯 Lua 版一致）。
function M.wrap_segs(segs, width)
    if not lib then return nil end
    local nseg = #segs
    if nseg == 0 then return {}, 1 end
    width = math.floor(tonumber(width) or 0)
    if width < 1 then width = 1 end

    local s, n = flatten(segs)
    if #s == 0 then
        return { {} }, 1
    end

    local nlines = ffi.new("int[1]")
    -- 每个 run 4 个 int：want 是**run 数**，缓冲按 int 数分配，传给 C 的是 run 数。
    local want = nseg * 2 + 8
    for _ = 1, 12 do
        runs, runs_cap = grow_int(runs, runs_cap, want * 4)
        local got = lib.lite_tui_wrap_segs(s, #s, offs, n, width, runs,
            math.floor(runs_cap / 4), nlines)
        if got >= 0 then
            local total = nlines[0]
            local lines = {}
            for k = 1, total do lines[k] = nil end
            local cur = 0
            for k = 0, got - 1 do
                local line = runs[k * 4 + 0] + 1
                local b = runs[k * 4 + 1]
                local len = runs[k * 4 + 2]
                local seg = segs[runs[k * 4 + 3] + 1]
                while cur < line do
                    cur = cur + 1
                    lines[cur] = lines[cur] or {}
                end
                local cells_of_line = lines[line] or {}
                lines[line] = cells_of_line
                cells_of_line[#cells_of_line + 1] = {
                    text = s:sub(b + 1, b + len),
                    style = seg and seg.style,
                }
            end
            for k = 1, total do lines[k] = lines[k] or {} end
            return lines, total
        end
        want = (-got) + 8
    end
    return nil
end

-- 只要行数（列表虚拟化用它算高度，比生成 run 便宜）。
function M.count_lines(segs, width)
    if not lib then return nil end
    local nseg = #segs
    if nseg == 0 then return 1 end
    width = math.floor(tonumber(width) or 0)
    if width < 1 then width = 1 end
    local s = flatten(segs)
    if #s == 0 then return 1 end
    return lib.lite_tui_count_lines(s, #s, width)
end

-- 逐字符扫描：返回 cdata int 缓冲（每 3 个：起始字节/字节长/显示宽度）
-- 与单元数；缺库或超限返回 nil。宽度 0 的（组合字符）由调用方挂到前一 cell。
function M.cells(s)
    if not lib then return nil end
    s = tostring(s or "")
    local n = #s
    if n == 0 then return nil, 0 end
    local want = n
    for _ = 1, 12 do
        cells, cells_cap = grow_int(cells, cells_cap, want)
        local got = lib.lite_tui_cells(s, n, cells, cells_cap)
        if got >= 0 then return cells, got, s end
        want = (-got) + 8
    end
    return nil
end

-- 行内词级 diff：a/b 是 intern 成整数的 token 序列（1 基 Lua 表，这里拷进
-- cdata 做 LCS + 回溯）。返回 ops 字节缓冲（0=相等 1=删 2=增，**正向**顺序）
-- 与操作数；缺库/超限（DP 面积 > 20000）返回 nil，调用方走 fallback。
--
-- 调用方硬约束：a/b 的整数 ID 必须**共用一套编号**（同一个 map + 同一个计数器）。
-- 各自从头编号时同一 token 拿到不同 ID、不同 token 又撞号，C 侧只比整数，
-- 于是把不相等当相等 —— 输出「整行未变」的假 diff，不报错、只有肉眼看得出。
local ta, ta_cap = nil, 0
local tb, tb_cap = nil, 0
local topts, topts_cap = nil, 0

function M.intraline(ai, na, bi, nb)
    if not lib or na <= 0 or nb <= 0 then return nil end
    ta, ta_cap = grow_int(ta, ta_cap, na)
    tb, tb_cap = grow_int(tb, tb_cap, nb)
    for k = 1, na do ta[k - 1] = ai[k] end
    for k = 1, nb do tb[k - 1] = bi[k] end
    local need = na + nb
    topts, topts_cap = grow_int(topts, topts_cap, need)
    local buf = ffi.cast("unsigned char *", topts)
    local got = lib.lite_tui_intraline(ta, na, tb, nb, buf, need)
    if got < 0 then return nil end
    return buf, got
end

return M
