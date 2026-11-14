-- unified diff 解析 / split 配对 / 行内词级 diff。
local utf8 = require("tui.utf8")
local TUI = require("ffi.tui")

local M = {}

local MAX_TOKENS = 160
local MAX_AREA = 20000

local function strip_path(path)
    if not path then return nil end
    path = path:gsub("\t.*$", "")
    path = path:gsub('"', "")
    if path == "" or path == "/dev/null" then return nil end
    path = path:gsub("^[ab]/", "")
    return path
end

local function split_git_paths(rest)
    local last, i = nil, 1
    while true do
        local p = rest:find(" b/", i, true)
        if not p then break end
        last = p
        i = p + 1
    end
    if not last then return nil, nil end
    return rest:sub(1, last - 1):gsub("^a/", ""), rest:sub(last + 1):gsub("^b/", "")
end

function M.parse(text)
    text = tostring(text or "")
    if text ~= "" and text:sub(-1) ~= "\n" then text = text .. "\n" end

    local files = {}
    local cur, hunk
    local old_no, new_no

    for line in text:gmatch("(.-)\n") do
        line = line:gsub("\r$", "")

        if line:sub(1, 11) == "diff --git " then
            local a, b = split_git_paths(line:sub(12))
            cur = {
                path = b,
                old_path = a,
                status = "modified",
                additions = 0,
                deletions = 0,
                hunks = {},
            }
            files[#files + 1] = cur
            hunk = nil
        elseif not cur then
            -- 兼容裸 unified diff（diff -u）
            if line:sub(1, 4) == "--- " then
                cur = { path = nil, old_path = strip_path(line:sub(5)),
                        status = "modified", additions = 0, deletions = 0, hunks = {} }
                files[#files + 1] = cur
            end
        else
            if line:sub(1, 13) == "new file mode" then
                cur.status = "added"
            elseif line:sub(1, 17) == "deleted file mode" then
                cur.status = "deleted"
            elseif line:sub(1, 12) == "rename from " then
                cur.old_path = line:sub(13)
                cur.status = "renamed"
            elseif line:sub(1, 10) == "rename to " then
                cur.path = line:sub(11)
            elseif line:sub(1, 4) == "--- " then
                local p = strip_path(line:sub(5))
                if p then cur.old_path = p end
            elseif line:sub(1, 4) == "+++ " then
                local p = strip_path(line:sub(5))
                if p then cur.path = p end
                if cur.old_path == nil and cur.status ~= "added" then cur.status = "added" end
            elseif line:sub(1, 13) == "Binary files " or line == "GIT binary patch" then
                cur.binary = true
            elseif line:sub(1, 2) == "@@" then
                local os_, ns_, tail = line:match("^@@ %-(%d+)[^ ]* %+(%d+)[^ ]* @@(.*)$")
                if os_ then
                    old_no, new_no = tonumber(os_), tonumber(ns_)
                    hunk = {
                        old_start = old_no,
                        new_start = new_no,
                        header = line,
                        section = tail or "",
                        rows = {},
                    }
                    cur.hunks[#cur.hunks + 1] = hunk
                end
            elseif hunk then
                local p = line:sub(1, 1)
                local row
                if p == " " then
                    row = { kind = "ctx", old = old_no, new = new_no, text = line:sub(2) }
                    old_no, new_no = old_no + 1, new_no + 1
                elseif p == "-" then
                    row = { kind = "del", old = old_no, text = line:sub(2) }
                    old_no = old_no + 1
                    cur.deletions = cur.deletions + 1
                elseif p == "+" then
                    row = { kind = "add", new = new_no, text = line:sub(2) }
                    new_no = new_no + 1
                    cur.additions = cur.additions + 1
                elseif p == "\\" then
                    local last = hunk.rows[#hunk.rows]
                    if last then last.no_newline = true end
                end
                if row then
                    hunk.rows[#hunk.rows + 1] = row
                end
            end
        end
    end

    for _, f in ipairs(files) do
        if not f.path then f.path = f.old_path or "?" end
    end
    return files
end

local function is_word(ch)
    return ch:match("^[%w_]$") ~= nil
end

local function tokenize(s)
    local out, buf, kind = {}, {}, nil

    local function flush()
        if #buf > 0 then
            out[#out + 1] = table.concat(buf)
            buf = {}
        end
        kind = nil
    end

    local i = 1
    while i <= #s do
        local ch, ni = utf8.decode(s, i)
        if not ch then ch, ni = s:sub(i, i), i + 1 end

        local k
        if ch:match("^%s$") then
            k = "space"
        elseif is_word(ch) then
            k = "word"
        else
            k = "sym"
        end

        if k == "space" then
            if kind ~= "space" then flush(); kind = "space" end
            buf[#buf + 1] = " "
        elseif k == "word" then
            if kind ~= "word" then flush(); kind = "word" end
            buf[#buf + 1] = ch
        else
            flush()
            out[#out + 1] = ch
        end
        i = ni
    end
    flush()
    return out
end

local function finish(list)
    local out = {}
    for i = #list, 1, -1 do out[#out + 1] = list[i] end
    local merged = {}
    for _, seg in ipairs(out) do
        local last = merged[#merged]
        if last and last.changed == seg.changed then
            last.text = last.text .. seg.text
        else
            merged[#merged + 1] = { text = seg.text, changed = seg.changed }
        end
    end
    return merged
end

-- 增量合并：C 给的是**正向**操作流，边遍历边并相邻同类段，
-- 省掉「先攒反向列表、再整体反转、再合并」的两趟。
local function push_seg(out, text, changed)
    local last = out[#out]
    if last and last.changed == changed then
        last.text = last.text .. text
    else
        out[#out + 1] = { text = text, changed = changed }
    end
end

-- token 字符串 → 小整数，C 侧只比整数（不碰字符串、不做哈希）。
-- 编号状态 st = {map, n} 必须**跨 a/b 共用**：各自 intern 会让同一 token
-- 拿到不同 ID、新 token 又从头编号撞上旧号，C 侧就会把不相等当相等。
local function intern(list, st)
    local ids, map, n = {}, st.map, st.n
    for i = 1, #list do
        local t = list[i]
        local id = map[t]
        if not id then
            n = n + 1
            id = n
            map[t] = id
        end
        ids[i] = id
    end
    st.n = n
    return ids
end

-- ops: 0=双方 1=只在左（删） 2=只在右（增），正向顺序
local function assemble(a, b, ops, nops)
    local left, right = {}, {}
    local ia, ib = 1, 1
    for k = 0, nops - 1 do
        local op = ops[k]
        if op == 0 then
            push_seg(left, a[ia], false)
            push_seg(right, b[ib], false)
            ia = ia + 1
            ib = ib + 1
        elseif op == 1 then
            push_seg(left, a[ia], true)
            ia = ia + 1
        else
            push_seg(right, b[ib], true)
            ib = ib + 1
        end
    end
    return left, right
end

local function fallback(a, b)
    local n = math.min(#a, #b)
    local p = 0
    while p < n and a[p + 1] == b[p + 1] do p = p + 1 end

    local s = 0
    while s < n - p and a[#a - s] == b[#b - s] do s = s + 1 end

    local left, right = {}, {}
    for i = 1, p do
        left[#left + 1] = { text = a[i], changed = false }
        right[#right + 1] = { text = b[i], changed = false }
    end
    for i = p + 1, #a - s do left[#left + 1] = { text = a[i], changed = true } end
    for i = p + 1, #b - s do right[#right + 1] = { text = b[i], changed = true } end
    for i = #a - s + 1, #a do
        left[#left + 1] = { text = a[i], changed = false }
        right[#right + 1] = { text = b[#b - (#a - i)], changed = false }
    end

    local function merge(list)
        local m = {}
        for _, seg in ipairs(list) do
            local last = m[#m]
            if last and last.changed == seg.changed then
                last.text = last.text .. seg.text
            else
                m[#m + 1] = { text = seg.text, changed = seg.changed }
            end
        end
        return m
    end
    return merge(left), merge(right)
end

function M.intraline(old, new)
    old, new = tostring(old or ""), tostring(new or "")
    local a, b = tokenize(old), tokenize(new)
    if #a == 0 and #b == 0 then return { left = {}, right = {} } end
    if #a > MAX_TOKENS or #b > MAX_TOKENS or #a * #b > MAX_AREA then
        local l, r = fallback(a, b)
        return { left = l, right = r }
    end

    -- C 路径：LCS + 回溯在 C 里做（一次 FFI 调用），Lua 只按操作流并段。
    -- 缺库或面积超限（DP 缓冲装不下）返回 nil，落到下面的纯 Lua DP。
    local st = { map = {}, n = 0 }
    local ai = intern(a, st)
    local bi = intern(b, st)
    local ops, nops = TUI.intraline(ai, #a, bi, #b)
    if ops then
        local l, r = assemble(a, b, ops, nops)
        return { left = l, right = r }
    end

    local n, m = #a, #b
    local dp = {}
    for i = 0, n do dp[i] = {} end
    for i = 1, n do
        local di, prev = dp[i], dp[i - 1]
        for j = 1, m do
            if a[i] == b[j] then
                di[j] = (prev[j - 1] or 0) + 1
            else
                local x, y = prev[j] or 0, di[j - 1] or 0
                di[j] = x > y and x or y
            end
        end
    end

    local left, right = {}, {}
    local i, j = n, m
    while i > 0 and j > 0 do
        if a[i] == b[j] then
            left[#left + 1] = { text = a[i], changed = false }
            right[#right + 1] = { text = b[j], changed = false }
            i, j = i - 1, j - 1
        elseif (dp[i - 1][j] or 0) >= (dp[i][j - 1] or 0) then
            left[#left + 1] = { text = a[i], changed = true }
            i = i - 1
        else
            right[#right + 1] = { text = b[j], changed = true }
            j = j - 1
        end
    end
    while i > 0 do left[#left + 1] = { text = a[i], changed = true }; i = i - 1 end
    while j > 0 do right[#right + 1] = { text = b[j], changed = true }; j = j - 1 end

    return { left = finish(left), right = finish(right) }
end

-- 把一个 hunk 的 del/add 段配成 split 行；1:1 时附行内 segments。
function M.pair(hunk)
    local rows = hunk.rows or {}
    local out = {}
    local i = 1
    while i <= #rows do
        local r = rows[i]
        if r.kind == "ctx" then
            out[#out + 1] = { kind = "ctx", left = r, right = r }
            i = i + 1
        else
            local dels, adds = {}, {}
            while i <= #rows and rows[i].kind == "del" do
                dels[#dels + 1] = rows[i]; i = i + 1
            end
            while i <= #rows and rows[i].kind == "add" do
                adds[#adds + 1] = rows[i]; i = i + 1
            end

            if #dels == 0 and #adds == 0 then
                i = i + 1
            else
                local segs
                if #dels == 1 and #adds == 1 then
                    segs = M.intraline(dels[1].text, adds[1].text)
                end
                local n = math.max(#dels, #adds)
                for k = 1, n do
                    local l, rr = dels[k], adds[k]
                    local row = {
                        kind = (l and rr) and "change" or (l and "del" or "add"),
                        left = l,
                        right = rr,
                    }
                    if segs and k == 1 then
                        row.left_segs = segs.left
                        row.right_segs = segs.right
                    end
                    out[#out + 1] = row
                end
            end
        end
    end
    return out
end

-- 工具结果里带改动就返回整段 patch（自动弹两栏用）。
-- 只有 edit/write 成功改文件才算；bash 输出里顺带打印的 diff 不算。
function M.tool_patch(name, result)
    if name ~= "edit" and name ~= "write" then return nil end
    if type(result) ~= "string" then return nil end
    if not result:match("^edited ") and not result:match("^wrote ") then return nil end
    if not result:find("diff --git ", 1, true) then return nil end
    return result
end

return M
