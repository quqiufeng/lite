-- helper/sprof.lua — Scheme 层热点报告：LuaJIT 直读版（对标 tools/sprof.static.py）
-- 输入是 #staticpy-prof 1 的 TSV（hits / ss / line / col）；不跑 Chez、不派生子进程。
-- 折算规则与 dist/sprof 逐行对齐：`;; <py>:<行>` 注释把 Scheme 行号折回 py 行，
-- `(define (static_foo ...))` 之后的语句记到 foo 名下；无 py 归属的 hits 单独算「运行时」。
-- 比 sprof 多一层：JSON 里函数同时给 py 归属 hits / 运行时 hits / 合计，
-- 因为只看归属 hits 会低估「自己代码薄、调用运行时厚」的函数。

local SCHEMA = {
    description = "Scheme 层热点（读 ~/iso_gen/prof/*.prof，折算回 py 行；不跑 Chez）。"
        .. "JSON 模式额外给每函数 归属/运行时/合计 hits。",
    parameters = {
        type = "object",
        properties = {
            prof = { type = "string", description = "prof 文件路径，或程序名（如 translator → ~/iso_gen/prof/translator.prof）；省略则取 last.txt / 最新的 .prof" },
            ss = { type = "string", description = "merged.ss 路径，覆盖 prof 的 #ss 头" },
            top = { type = "integer", description = "每节保留条数，默认 20" },
            fn_only = { type = "boolean", description = "只出语句级（跳过函数级两节），同 --fn-only" },
            json = { type = "boolean", description = "返回结构化 JSON 而不是文本报告" },
        },
    },
}

local function read_text(p)
    local f = io.open(p, "rb")
    if not f then return "" end
    local s = f:read("*a") or ""
    f:close()
    return s
end

local function exists(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

local function trim(s)
    s = s:gsub("^[ \t\r\n\v\f]+", "")
    return (s:gsub("[ \t\r\n\v\f]+$", ""))
end

-- Python split_nl：按 \n 切，末尾空串丢掉
local function split_nl(s)
    local out = {}
    for line in (s .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    return out
end

-- Python split_ws_tab：只按 \t 切
local function split_tab(s)
    local out, cur = {}, 1
    while true do
        local p = s:find("\t", cur, true)
        if not p then out[#out + 1] = s:sub(cur); return out end
        out[#out + 1] = s:sub(cur, p - 1)
        cur = p + 1
    end
end

local function pad_left(s, w)
    if #s >= w then return s end
    return string.rep(" ", w - #s) .. s
end

local function comment_label(t)
    if t:sub(1, 2) ~= ";;" then return "" end
    local body = trim(t:sub(3))
    local u = body:find(".py:", 1, true)
    if not u then return "" end
    local j, k = u + 4, u + 4
    while k <= #body and body:sub(k, k):match("%d") do k = k + 1 end
    if k == j then return "" end
    return body:sub(1, k - 1)
end

local function def_name(t)
    t = trim(t)
    local h = "(define ("
    if t:sub(1, #h) ~= h then return "" end
    local rest = t:sub(#h + 1)
    local k = 1
    while k <= #rest do
        local c = rest:sub(k, k)
        if c == " " or c == ")" or c == "(" then break end
        k = k + 1
    end
    local nm = rest:sub(1, k - 1)
    if nm:sub(1, 7) == "static_" then return nm:sub(8) end
    return nm
end

-- labels[i]/fns[i] 对应 merged.ss 第 i 行
local function scan_labels(ss_text)
    local labels, fns = {}, {}
    local cur, curfn, pending = "", "", ""
    local i = 0
    for line in (ss_text .. "\n"):gmatch("(.-)\n") do
        local lab = comment_label(trim(line))
        local fn = def_name(line)
        if #lab > 0 then
            cur, pending = lab, lab
        elseif #fn > 0 then
            curfn = fn
            if #pending > 0 then curfn = fn .. "  (" .. pending .. ")" end
        end
        i = i + 1
        labels[i], fns[i] = cur, curfn
    end
    return labels, fns
end

local function bump(d, names, key, add)
    local old = d[key]
    if not old then d[key] = add; names[#names + 1] = key
    else d[key] = old + add end
end

local function pct(part, whole)
    if whole <= 0 then return "  0.0%" end
    local sh = math.floor(part * 1000 / whole)
    return pad_left(string.format("%d.%d", math.floor(sh / 10), sh % 10), 6) .. "%"
end

local function pnum(part, whole, dp)
    if whole <= 0 then return 0 end
    local m = 10 ^ (dp or 1)
    return math.floor(part * m * 100 / whole + 0.5) / m
end

local function top_rows(d, names, limit)
    local out, used, total, got = {}, {}, #names, 0
    while got < limit and got < total do
        local best, bestv = nil, -1
        for i = 1, total do
            local k = names[i]
            if not used[k] then
                local v = d[k]
                if v > bestv then bestv, best = v, k end
            end
        end
        if not best then break end
        used[best] = true
        out[#out + 1] = { best, bestv }
        got = got + 1
    end
    return out
end

local function split_label(lab)
    local u = lab:find(".py:", 1, true)
    if not u then return lab, 0 end
    return lab:sub(1, u + 2), tonumber(lab:sub(u + 4)) or 0
end

local function src_line(cache, pyfile, lineno)
    local txt = cache[pyfile]
    if not txt then
        txt = read_text(pyfile)
        cache[pyfile] = txt
    end
    if #txt == 0 or lineno <= 0 then return "" end
    local lines = split_nl(txt)
    if lineno > #lines then return "" end
    return trim(lines[lineno])
end

local function home() return os.getenv("HOME") or "" end

-- prof 路径：显式 > 程序名 > last.txt（只认 .prof）> 目录里最新的 .prof
local function resolve_prof(a)
    local prof = a.prof
    if prof and #prof > 0 then
        if exists(prof) then return prof end
        local cand = home() .. "/iso_gen/prof/" .. prof:gsub("%.prof$", "") .. ".prof"
        if exists(cand) then return cand end
        return prof
    end
    local dir = home() .. "/iso_gen/prof"
    local last = trim(read_text(dir .. "/last.txt"))
    if #last > 0 and last:sub(-5) == ".prof" and exists(last) then return last end
    local p = io.popen("ls -1t " .. dir .. "/*.prof 2>/dev/null | head -1")
    local newest = ""
    if p then newest = trim(p:read("*a") or ""); p:close() end
    if #newest > 0 then return newest end
    if #last > 0 then return last end
    return dir .. "/static.prof"
end

local function analyze(a)
    local prof = resolve_prof(a)
    local limit = tonumber(a.top) or 20
    local txt = read_text(prof)
    if #txt == 0 then
        return { err = "sprof: 读不到 prof 文件: " .. prof,
                 hint = "先做一次剖析构建: STATICPY_PROFILE=source bash staticpy/static_build_comfycli.sh <x.static.py> <out>" }
    end
    local ss_path, mode = a.ss or "", "?"
    local rows = {}
    for _, ln in ipairs(split_nl(txt)) do
        if ln:sub(1, 4) == "#ss " then
            if #ss_path == 0 then ss_path = ln:sub(5) end
        elseif ln:sub(1, 6) == "#mode " then
            mode = ln:sub(7)
        elseif ln:sub(1, 1) ~= "#" and #trim(ln) > 0 then
            rows[#rows + 1] = ln
        end
    end
    ss_path = trim(ss_path)
    if #ss_path == 0 or ss_path == "?" then ss_path = "" end
    local ss_text = read_text(ss_path)
    if #ss_text == 0 then
        return { err = "sprof: 读不到 Scheme 源: " .. ss_path, prof = prof,
                 hint = "merged.ss 在 ~/iso_gen/staticpy-cache/，清理缓存后会消失；用 ss= 指定" }
    end

    local labels, fns = scan_labels(ss_text)
    local stmt_d, stmt_n = {}, {}
    local rt_d, rt_n = {}, {}
    local fn_d, fn_n = {}, {}
    local fn_rt, fn_rt_n = {}, {}
    local total, runtime = 0, 0
    for _, row in ipairs(rows) do
        local f = split_tab(row)
        if #f >= 3 then
            local cnt = tonumber(f[1]) or 0
            local ln = math.floor(tonumber(f[3]) or 0)
            total = total + cnt
            local lab, fn = "", ""
            if ln >= 1 and ln <= #labels then lab, fn = labels[ln], fns[ln] end
            if #lab == 0 then
                runtime = runtime + cnt
                local rf = (#fn > 0) and fn or "?"
                bump(rt_d, rt_n, rf, cnt)
                bump(fn_rt, fn_rt_n, rf, cnt)
            else
                bump(stmt_d, stmt_n, lab, cnt)
                if #fn > 0 then bump(fn_d, fn_n, fn, cnt) end
            end
        end
    end
    return { prof = prof, ss = ss_path, mode = mode, limit = limit,
             total = total, runtime = runtime,
             stmt_d = stmt_d, stmt_n = stmt_n,
             rt_d = rt_d, rt_n = rt_n,
             fn_d = fn_d, fn_n = fn_n,
             fn_rt = fn_rt, fn_rt_n = fn_rt_n }
end

local function render(r, fn_only)
    local out = {}
    out[#out + 1] = "sprof — Scheme 层热点（mode=" .. r.mode .. "）"
    out[#out + 1] = "  prof: " .. r.prof
    out[#out + 1] = "  ss  : " .. r.ss
    out[#out + 1] = "  总计 " .. r.total .. " hits，其中 " .. r.runtime
        .. " 落在运行时（prelude/stdlib，无 py 归属）"
    if not fn_only then
        out[#out + 1] = ""
        out[#out + 1] = "  函数级（按计入的表达式 hits 排序）"
        out[#out + 1] = "   hits      占比  函数"
        for _, e in ipairs(top_rows(r.fn_d, r.fn_n, r.limit)) do
            out[#out + 1] = "  " .. pad_left(tostring(e[2]), 9) .. "  " .. pct(e[2], r.total) .. "  " .. e[1]
        end
        out[#out + 1] = ""
        out[#out + 1] = "  运行时函数级（prelude/stdlib，无 py 归属；? = 顶层/未归因）"
        out[#out + 1] = "   hits      占比  运行时函数"
        for _, e in ipairs(top_rows(r.rt_d, r.rt_n, r.limit)) do
            out[#out + 1] = "  " .. pad_left(tostring(e[2]), 9) .. "  " .. pct(e[2], r.total) .. "  " .. e[1]
        end
    end
    out[#out + 1] = ""
    out[#out + 1] = "  语句级（hits 最高的 py 行 = 最该改的那一行）"
    out[#out + 1] = "   hits      占比  位置"
    local cache = {}
    for _, e in ipairs(top_rows(r.stmt_d, r.stmt_n, r.limit)) do
        local pyf, ln = split_label(e[1])
        out[#out + 1] = "  " .. pad_left(tostring(e[2]), 9) .. "  " .. pct(e[2], r.total) .. "  "
            .. pyf .. ":" .. tostring(ln)
        local snip = src_line(cache, pyf, ln)
        if #snip > 0 then out[#out + 1] = "             | " .. snip end
    end
    return table.concat(out, "\n")
end

-- 自带极简 JSON 编码：不依赖 cjson（bare luajit 里没有）
local function esc(x)
    local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
    return (x:gsub('[%c"\\]', function(c) return map[c] or string.format("\\u%04x", c:byte()) end))
end

local function enc(v)
    local t = type(v)
    if v == nil then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v then return "null" end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.10g", v)
    end
    if t == "string" then return '"' .. esc(v) .. '"' end
    if t == "table" then
        if v.__obj then
            local parts = {}
            for _, kv in ipairs(v.__obj) do parts[#parts + 1] = '"' .. esc(kv[1]) .. '":' .. enc(kv[2]) end
            return "{" .. table.concat(parts, ",") .. "}"
        end
        local parts = {}
        for _, x in ipairs(v) do parts[#parts + 1] = enc(x) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    return "null"
end

local function render_json(r)
    local cache = {}
    local seen = {}
    for _, n in ipairs(r.fn_n) do seen[n] = true end
    for _, n in ipairs(r.fn_rt_n) do seen[n] = true end
    local all, order = {}, 0
    for n in pairs(seen) do
        order = order + 1
        local a, b = r.fn_d[n] or 0, r.fn_rt[n] or 0
        all[#all + 1] = { name = n, attributed = a, runtime = b, hits = a + b, order = order }
    end
    table.sort(all, function(x, y)
        if x.hits ~= y.hits then return x.hits > y.hits end
        return x.order < y.order
    end)
    local fns = {}
    for i = 1, math.min(#all, r.limit) do
        local e = all[i]
        fns[#fns + 1] = { __obj = {
            { "name", e.name }, { "hits", e.hits },
            { "pct", pnum(e.hits, r.total, 1) },
            { "attributed", e.attributed }, { "runtime", e.runtime },
        } }
    end
    local stmts = {}
    for _, e in ipairs(top_rows(r.stmt_d, r.stmt_n, r.limit)) do
        local pyf, ln = split_label(e[1])
        stmts[#stmts + 1] = { __obj = {
            { "file", pyf }, { "line", ln }, { "hits", e[2] },
            { "pct", pnum(e[2], r.total, 1) }, { "src", src_line(cache, pyf, ln) },
        } }
    end
    local rt = {}
    for _, e in ipairs(top_rows(r.rt_d, r.rt_n, r.limit)) do
        rt[#rt + 1] = { __obj = {
            { "name", e[1] }, { "hits", e[2] }, { "pct", pnum(e[2], r.total, 1) },
        } }
    end
    return enc({ __obj = {
        { "prof", r.prof }, { "ss", r.ss }, { "mode", r.mode },
        { "total", r.total }, { "attributed", r.total - r.runtime },
        { "runtime", r.runtime }, { "runtime_pct", pnum(r.runtime, r.total, 1) },
        { "functions", fns }, { "runtime_functions", rt }, { "statements", stmts },
    } })
end


return {
    schema = SCHEMA,
    run = function(args, env)
        args = args or {}
        local r = analyze(args)
        if r.err then
            local out = { r.err }
            if r.hint then out[#out + 1] = "  " .. r.hint end
            return table.concat(out, "\n")
        end
        if args.json then return render_json(r) end
        return render(r, args.fn_only and true or false)
    end,
}
