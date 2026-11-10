-- lens（旧名 codesearch）：代码索引 / 符号 / 调用图 / 数据流 / 语义搜索。
-- 工具名 = 文件名（lens），实现模块仍是 src/codesearch + lua/ffi/codesearch.lua。
-- 数据默认落在 $LITE_CS_HOME（缺省 ~/.local/share/lite/codesearch），
-- 每个项目一个 analysis 目录，KV 落在其 kv/ 子目录，避免和 lite 自己的
-- mem.bin 写实例抢锁。实现是 liblite_codesearch.so（从 /opt/my_db 全量迁移），
-- 语义向量需要 /opt/models 下的 Jina 模型与 ONNX Runtime。

local CS = require("ffi.codesearch")
local cjson = require("cjson")

local function env(name)
    local v = os.getenv(name)
    if v and v ~= "" then return v end
end

local function cpu_count()
    local n = 0
    local f = io.open("/proc/cpuinfo")
    if f then
        for line in f:lines() do
            if line:match("^processor%s*:") then n = n + 1 end
        end
        f:close()
    end
    return n > 0 and n or 1
end

local function worker_count(args)
    if args.workers then return args.workers end
    local n = env("LITE_CS_WORKERS")
    n = n and tonumber(n)
    if n and n > 0 then return n end
    return args.fork and cpu_count() or 1
end

local function home()
    local h = env("LITE_CS_HOME")
    if h then return (h:gsub("/+$", "")) end
    local x = env("XDG_DATA_HOME")
    if x then return (x:gsub("/+$", "")) .. "/lite/codesearch" end
    local hh = env("HOME") or "/tmp"
    return hh .. "/.local/share/lite/codesearch"
end

local function abs_path(p, cwd)
    if not p or p == "" then p = "." end
    if p:sub(1, 1) == "/" then return (p:gsub("(.)/+$", "%1")) end
    local base = cwd or env("PWD") or "."
    if p == "." then return (base:gsub("(.)/+$", "%1")) end
    return (base .. "/" .. p)
end

local function basename(p)
    local b = p:gsub("/+$", ""):match("([^/]+)$") or "workspace"
    return b
end

local function safe_name(s)
    return (s:gsub("[^%w%._%-]", "_"))
end

local has_index, index_candidates   -- 定义在下方，paths() 里先用

local function paths(args, ctx)
    local repo = abs_path(args.path, ctx and ctx.cwd)
    local project = safe_name(args.project or basename(repo))
    local analysis = args.analysis_dir or os.getenv("LITE_CS_ANALYSIS")
        or (home() .. "/" .. project)
    analysis = (analysis:gsub("/+$", ""))
    -- 默认目录没有索引时，按项目名去已知位置找一份（项目名可能带 _cache 后缀，
    -- 也可能落在 /opt/code_caches/<project>_cache），找到就直接用，省掉手写长路径。
    if not args.analysis_dir and has_index and not has_index(analysis) then
        local hit
        for _, dir in ipairs(index_candidates and index_candidates() or {}) do
            local base = dir:match("([^/]+)$") or ""
            if base == project or base == project .. "_cache"
                or base:gsub("_cache$", "") == project then hit = dir break end
        end
        if hit then analysis = hit end
    end
    local kv = args.kv_dir or (analysis .. "/kv")
    local ns = args.ns or ("/code/" .. project)
    return repo, project, analysis, kv, ns
end

local function one_line(s, n)
    if not s or s == "" then return "" end
    s = tostring(s):gsub("%s+", " ")
    if #s > n then s = s:sub(1, n) .. "..." end
    return s
end

local function fmt_status(d)
    local out = { string.format("analysis: %s", d.analysis_dir) }
    local f = d.files or {}
    for _, name in ipairs({ "chunks_meta.jsonl", "chunks_text.txt", "word_freq.json",
                            "call_graph.json", "dataflow.json" }) do
        local x = f[name] or {}
        local info = x.exists and (tostring(x.bytes) .. "B") or "missing"
        local lines = x.lines
        if lines and lines >= 0 then info = info .. "  " .. lines .. " lines"
        elseif x.exists then info = info .. "  large" end
        out[#out + 1] = string.format("  %-20s %s", name, info)
    end
    local vs = d.vectors or {}
    if #vs == 0 then
        out[#out + 1] = "  vectors             none"
    else
        for _, v in ipairs(vs) do
            out[#out + 1] = string.format("  %-20s %dB", v.name, v.bytes or 0)
        end
    end
    local m = d.models or {}
    out[#out + 1] = string.format("  models              jina=%s ort=%s (%s)",
        tostring(m.jina_onnx), tostring(m.onnxruntime), tostring(m.model_dir))
    if not (((d.files or {})["chunks_meta.jsonl"] or {}).exists) and index_candidates then
        local c = index_candidates()
        if #c > 0 then
            local want = d.analysis_dir:match("([^/]+)$")
            local pick
            for _, dir in ipairs(c) do
                if want and dir:find(want, 1, true) then pick = dir break end
            end
            if pick then
                out[#out + 1] = "  hint                no index here; pass analysis_dir=" .. pick
            else
                -- 没有同名索引：别瞎指一个别的项目，只列出现有的
                local names = {}
                for _, dir in ipairs(c) do
                    names[#names + 1] = (dir:match("([^/]+)$") or dir):gsub("_cache$", "")
                end
                out[#out + 1] = "  hint                no index for this project; built: "
                    .. table.concat(names, ", ")
            end
        end
    end
    return table.concat(out, "\n")
end

local function fmt_results(d, max_chars)
    local rs = d.results or {}
    local out = { string.format('%s "%s" -> %d result(s), %d ms',
        d.type or "?", d.query or "", #rs, d.timing_ms or 0) }
    local total = 0
    for i, r in ipairs(rs) do
        local line
        if r.entries then
            line = string.format("[%d] %s (exact)", i, r._key or "?")
            out[#out + 1] = line
            out[#out + 1] = "    " .. one_line(cjson.encode(r.entries), 800)
        else
            line = string.format("[%d] %s  %s:%s  kind=%s", i,
                r.name or "?", r.file or "?", tostring(r.line_start or "?"), r.kind or "")
            if r.score then line = line .. string.format("  score=%.3f", r.score) end
            out[#out + 1] = line
            if r.signature and r.signature ~= "" then
                out[#out + 1] = "    sig: " .. one_line(r.signature, 200)
            end
            if r.content and r.content ~= "" then
                out[#out + 1] = "    " .. one_line(r.content, 400)
            end
        end
        total = total + #line
        if total > (max_chars or 8000) then
            out[#out + 1] = "... (capped, raise max_results or use json=true)"
            break
        end
    end
    return table.concat(out, "\n")
end

local function fmt_context(d, max_chars)
    local ctx = d.context or {}
    local sym = ctx.symbol or (d.results or {})[1] or {}
    local out = { string.format("%s  %s:%s  kind=%s", sym.name or "?",
        sym.file or "?", tostring(sym.line or sym.line_start or "?"), sym.kind or "") }
    local function names(label, arr, cap)
        if not arr or #arr == 0 then return end
        local t = {}
        for i, v in ipairs(arr) do
            if i > (cap or 30) then t[#t + 1] = "..."; break end
            if type(v) == "table" then
                -- 间接调用：obj->fn()/obj.fn() 只能按裸名挂边，标出来让调用方打折
                local s = v.name or "?"
                if v.indirect then s = s .. "[via " .. (v.via or "?") .. "]" end
                t[#t + 1] = s
            else
                t[#t + 1] = tostring(v)
            end
        end
        out[#out + 1] = string.format("%s(%d): %s", label, #arr, table.concat(t, ", "))
    end
    names("callers", ctx.callers)
    names("callees", ctx.callees)
    local paths = ctx.call_paths or {}
    if #paths > 0 then
        local t = {}
        for i, p in ipairs(paths) do
            if i > 10 then t[#t + 1] = "..."; break end
            t[#t + 1] = table.concat(p, " -> ")
        end
        out[#out + 1] = "paths: " .. table.concat(t, " | ")
    end
    local df = ctx.dataflow or {}
    local vars = {}
    local function add_var(name, data)
        local occ = data.occurrences or {}
        local lines = {}
        for i, o in ipairs(occ) do
            if i > 6 then lines[#lines + 1] = "..."; break end
            lines[#lines + 1] = string.format("%s:%s %s",
                o.file or "?", tostring(o.line or "?"), o.type or "")
        end
        vars[#vars + 1] = string.format("%s(%d) %s", name or "?", #occ,
            table.concat(lines, "; "))
    end
    for _, entry in ipairs(df) do
        local data = entry.data
        if type(data) == "table" then
            if data.occurrences then
                add_var(data.name, data)
            else
                local keys = {}
                for k in pairs(data) do keys[#keys + 1] = k end
                table.sort(keys)
                for i, k in ipairs(keys) do
                    if i > 20 then vars[#vars + 1] = "..."; break end
                    add_var(k, data[k])
                end
            end
        end
    end
    if #vars > 0 then
        out[#out + 1] = "dataflow: " .. table.concat(vars, "\n          ")
    end
    local s = table.concat(out, "\n")
    if #s > (max_chars or 8000) then s = s:sub(1, max_chars or 8000) .. "\n... (capped)" end
    return s
end

local function fmt_dataflow(d)
    local rs = d.results or {}
    if #rs == 0 then
        return string.format('dataflow "%s" not found (run action=import to rebuild ' ..
            'dataflow funcs index, or check the spelling)', d.query or "")
    end
    local out = {}
    for _, entry in ipairs(rs) do
        if entry.kind == "function" then
            out[#out + 1] = string.format("func %s — %d var(s)", entry.func or "?",
                tonumber(entry.var_count) or 0)
            for _, v in ipairs(entry.vars or {}) do
                local occ = v.occurrences or {}
                local lines = {}
                for i, o in ipairs(occ) do
                    if i > 6 then lines[#lines + 1] = "..."; break end
                    lines[#lines + 1] = string.format("%s:%s %s", o.file or "?",
                        tostring(o.line or "?"), o.type or "")
                end
                out[#out + 1] = string.format("  %s line %s  occ_in_func=%s  %s",
                    v.var or "?", tostring(v.line or "?"),
                    tostring(v.occurrences_in_func or #occ), table.concat(lines, "; "))
            end
        elseif entry.kind == "variable" then
            out[#out + 1] = string.format("var %s — %s occurrence(s) across %d func(s)",
                entry.var or "?", tostring(entry.occurrence_count or 0), #(entry.funcs or {}))
            for _, f in ipairs(entry.funcs or {}) do
                local lines = {}
                for i, l in ipairs(f.lines or {}) do
                    if i > 8 then lines[#lines + 1] = "..."; break end
                    lines[#lines + 1] = tostring(l)
                end
                out[#out + 1] = string.format("  %s (%s) lines %s", f.func or "?",
                    tostring(f.count or 0), table.concat(lines, ","))
            end
        elseif entry.kind == "candidates" then
            out[#out + 1] = string.format('"%s" not found; similar functions: %s',
                entry.query or "?", table.concat(entry.functions or {}, ", "))
        end
    end
    local s = table.concat(out, "\n")
    if #s > 8000 then s = s:sub(1, 8000) .. "\n... (capped)" end
    return s
end

local function fmt_symbols(d)
    local rs = d.results or {}
    if #rs == 0 then return string.format('symbol "%s" not found', d.query or "") end
    local out = {}
    for i, r in ipairs(rs) do
        out[#out + 1] = string.format("[%d] %s  %s:%s  kind=%s", i, r.name or "?",
            r.file or "?", tostring(r.line or r.line_start or "?"), r.kind or "")
        if r.content and r.content ~= "" then
            out[#out + 1] = "    " .. one_line(r.content, 400)
        end
    end
    return table.concat(out, "\n")
end

local function check_stage(name, r)
    if not r then error("codesearch: " .. name .. " failed: " .. tostring(CS.lib and "no result" or "library missing"), 0) end
    if r.ok == false or (r.exit and r.exit ~= 0) then
        error(string.format("codesearch: %s failed (exit %s): %s", name,
            tostring(r.exit), tostring(r.error or "")), 0)
    end
    return r
end

has_index = function(dir)
    local f = io.open(dir .. "/chunks_meta.jsonl", "rb")
    if f then f:close() return true end
    return false
end

-- 索引不在默认路径时报错要可自修（AGENTS.md §5）：把磁盘上真实存在的索引列出来，
-- 免得调用方看着「run action=build first」去重跑几小时的建索引。
index_candidates = function()
    local out, seen = {}, {}
    local function scan(glob)
        local p = io.popen("ls -d " .. glob .. " 2>/dev/null")
        if not p then return end
        for line in p:lines() do
            line = line:gsub("/+$", "")
            if line ~= "" and not seen[line] and has_index(line) then
                seen[line] = true
                out[#out + 1] = line
            end
        end
        p:close()
    end
    scan("/opt/code_caches/*_cache")
    scan("/opt/code_caches/*")
    scan(home() .. "/*")
    return out
end

local function need_built(d, what)
    local meta = ((d.files or {})["chunks_meta.jsonl"] or {})
    if not meta.exists then
        local cands = index_candidates()
        local hint = ""
        if #cands > 0 then
            -- 项目名相关的排前面，最多列 8 个，别把 20 多份索引全糊到报错里
            local want = tostring(d.analysis_dir):match("([^/]+)$") or ""
            local head, tail = {}, {}
            for _, dir in ipairs(cands) do
                if want ~= "" and dir:find(want, 1, true) and #head < 3 then head[#head + 1] = dir
                else tail[#tail + 1] = dir end
            end
            local list = {}
            for _, dir in ipairs(head) do list[#list + 1] = dir end
            for _, dir in ipairs(tail) do
                if #list >= 8 then break end
                list[#list + 1] = dir
            end
            hint = "\navailable indexes: " .. table.concat(list, ", ")
                .. (#cands > #list and string.format(" (+%d more)", #cands - #list) or "")
                .. "\n  -> pass analysis_dir=<dir> (add project=<name> when the KV namespace differs)"
        end
        error(string.format("codesearch: no index at %s\n"
            .. "fix: analysis_dir=<dir> overrides it (default ~/.local/share/lite/codesearch/<project>, "
            .. "LITE_CS_ANALYSIS changes the default), or action=build creates one%s",
            tostring(d.analysis_dir), hint), 0)
    end
    if what == "kv" then
        local kvf = d.analysis_dir .. "/kv/mem.bin"
        local f = io.open(kvf, "rb")
        if not f then
            error(string.format("codesearch: KV import missing at %s\n"
                .. "fix: action=import (or action=build) with the same analysis_dir/kv_dir", kvf), 0)
        end
        f:close()
    end
end

local function do_build(args, repo, project, analysis, kv, ns)
    local stages = {}
    local function stage(name, fn)
        local r = fn()
        check_stage(name, r)
        stages[#stages + 1] = name .. " ok"
        return r
    end

    stage("index", function()
        return CS.index({ repo = repo, analysis_dir = analysis,
                          workers = worker_count(args),
                          fork = args.fork, skip_kinds = args.skip_kinds,
                          include_dirs = args.include_dirs,
                          excludes = args.excludes, plugins = args.plugins })
    end)
    stage("word_freq", function() return CS.word_freq(analysis) end)
    stage("callgraph", function() return CS.callgraph(analysis) end)
    stage("dataflow", function() return CS.dataflow(analysis) end)
    stage("import", function() return CS.import(analysis, ns, kv, args.only_dataflow) end)

    local caps = CS.check(analysis) or {}
    local models = caps.models or {}
    local want_vec = args.vector ~= false and not env("LITE_CS_DISABLE_VECTOR")
    if want_vec and models.jina_onnx and models.onnxruntime then
        stage("vectorize", function()
            return CS.vectorize(analysis, args.model or "jina", project,
                                { batch = args.batch, fp16 = args.fp16 })
        end)
    elseif want_vec then
        stages[#stages + 1] = "vectorize skipped (model/onnxruntime missing)"
    else
        stages[#stages + 1] = "vectorize skipped (disabled)"
    end

    local st = CS.check(analysis)
    return "build: " .. project .. "\n  " .. table.concat(stages, "\n  ") ..
        "\n" .. fmt_status(st)
end

-- ── 组合动作：locate（搜+读）/ grep（作用域搜）/ peek（定点读）──────────────
-- 这三条来自 src/codesearch/code_search_best_practices.md 里最高频的组合拳：
--   search → 人工拼 read（两次往返，且常读错行）⇒ locate 直接内联源码窗口
--   整仓 grep（慢 + 噪声命中）                  ⇒ grep 先按目录/文件收窄 + 护栏
--   read 文件再数行号                            ⇒ peek 给 file:line 直接读窗口
-- 读源码的硬上限：单行 200 字符、总输出 8000 字符，超了明确说怎么调。
local SNIP_LINE_MAX = 200
local GREP_MAX_FILES_DEFAULT = 3000

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function abs_file(p, base)
    if not p or p == "" then return nil end
    if p:sub(1, 1) == "/" then return p end
    return ((base or env("PWD") or "."):gsub("/+$", "")) .. "/" .. p
end

-- 读 [first, last]；行号右对齐，输出可以直接当 file:line 引用回填。
local function read_window(path, first, last)
    if not path then return nil, "no path" end
    local f = io.open(path, "rb")
    if not f then return nil, "cannot open " .. path end
    first = math.max(1, tonumber(first) or 1)
    last = math.max(first, tonumber(last) or first)
    local out, n, cut = {}, 0, false
    for line in f:lines() do
        n = n + 1
        if n >= first and n <= last then
            line = line:gsub("\r$", "")
            if #line > SNIP_LINE_MAX then
                line = line:sub(1, SNIP_LINE_MAX) .. " …"
                cut = true
            end
            out[#out + 1] = string.format("%5d| %s", n, line)
        end
        if n > last then break end
    end
    f:close()
    if #out == 0 then
        return nil, string.format("line %d beyond EOF (%d lines)", first, n)
    end
    return table.concat(out, "\n") .. (cut and "\n      (long lines cut at 200 chars)" or "")
end

local function is_dir(p)
    local f = io.popen("test -d " .. shell_quote(p) .. " && echo 1 || echo 0")
    if not f then return false end
    local r = f:read("*l")
    f:close()
    return r == "1"
end

-- 护栏用：目录下最多数到 cap+1 个文件就停（find | head 靠 SIGPIPE 提前退出）。
local function scan_file_count(dir, cap)
    local cmd = string.format("find %s -maxdepth 8 -type f 2>/dev/null | head -n %d | wc -l",
        shell_quote(dir), cap + 1)
    local f = io.popen(cmd)
    if not f then return 0 end
    local s = f:read("*l") or "0"
    f:close()
    return tonumber(s) or 0
end

-- 单次查询：type 决定走向量（search）还是 KV（symbol/context/exact）。
local function cs_query(args, kv, ns, analysis, t, maxr)
    return CS.query({
        query = args.query, repo = ns, type = t,
        kv_dir = kv,
        -- 只有语义搜索需要 vector engine，其余传空目录避免每次加载 ONNX
        analysis_dir = (t == "search") and analysis or "",
        model = args.model or "jina",
        max_results = maxr or args.max_results or 10, depth = args.depth or 0,
        no_boost = args.no_boost, kind = args.kind, lang = args.lang, file = args.file,
    })
end

local function do_locate(args, ctx, analysis, kv, ns)
    if not args.query or args.query == "" then
        error("codesearch: query required for locate (symbol name or natural language)\n"
            .. "required: query (string); optional: max_results (default 3), lines (default 40), "
            .. "before (default 2), kind/lang/file, type", 0)
    end
    local maxr = math.min(tonumber(args.max_results) or 3, 10)
    local budget = tonumber(args.max_chars) or 8000
    local before = tonumber(args.before) or 2
    local want = math.max(1, tonumber(args.lines) or 40)

    local t = args.type
    if t == "auto" then t = nil end
    t = t or "search"

    local notes = {}
    local d, err = cs_query(args, kv, ns, analysis, t, maxr)
    if (not d or #((d or {}).results or {}) == 0) and not args.type then
        -- 没向量 / 没命中就退回 KV 符号查找，别让调用方自己猜该用哪个 action
        notes[#notes + 1] = string.format('%s: %s -> retried as symbol',
            t, tostring(err or "no hit"))
        d, err = cs_query(args, kv, ns, analysis, "symbol", maxr)
        t = "symbol"
    end
    if not d then error("codesearch: locate failed: " .. tostring(err), 0) end

    local rs = d.results or {}
    -- best practices §10 的不变量：语义 top1 score 应 > 0.3；低分说明索引或措辞有问题，
    -- 别让噪声命中被当成「找到了」。
    if rs[1] and rs[1].score and rs[1].score < 0.35 then
        notes[#notes + 1] = string.format("top score %.3f < 0.35 — weak match, "
            .. "换个符号名/关键词或 action=grep pattern=...", rs[1].score)
    end
    local out = { string.format('%s "%s" -> %d result(s), %d with source [static]',
        d.type or t, tostring(args.query), #rs, math.min(#rs, maxr)) }
    local used = #out[1]
    local nxt = {}
    for i = 1, math.min(#rs, maxr) do
        local r = rs[i]
        local line = tonumber(r.line_start or r.line) or 1
        local head = string.format("[%d] %s  %s:%d  kind=%s%s", i, r.name or "?",
            tostring(r.file), line, r.kind or "",
            r.score and string.format("  score=%.3f", r.score) or "")
        out[#out + 1] = head
        used = used + #head + 1
        local last = line + want - 1
        if tonumber(r.line_end) and tonumber(r.line_end) < last then
            last = tonumber(r.line_end)          -- chunk 边界更准：函数没被腰斩
        end
        local snip, serr = read_window(abs_file(r.file, ctx and ctx.cwd),
            math.max(1, line - before), last)
        snip = snip or ("      (" .. tostring(serr) .. ")")
        if used + #snip > budget then
            out[#out + 1] = "      ... (budget reached: lower max_results/lines or raise max_chars)"
            break
        end
        out[#out + 1] = snip
        used = used + #snip + 1
        if r.name then
            nxt[#nxt + 1] = string.format("action=context query=%s depth=2   # %s",
                r.name, tostring(r.file))
        end
    end
    if #notes > 0 then
        out[#out + 1] = "note: " .. table.concat(notes, "; ")
    end
    out[#out + 1] = "-- next --"
    for i = 1, math.min(#nxt, 4) do out[#out + 1] = "  " .. nxt[i] end
    if rs[1] and rs[1].file then
        out[#out + 1] = string.format("  action=grep path=%s pattern=<re>", tostring(rs[1].file))
    end
    out[#out + 1] = "  [static] 证据要跑起来才算 [verified]（best practices §3）"
    return table.concat(out, "\n")
end

local function do_grep(args, ctx)
    local pattern = args.pattern or (args.fixed and args.query) or args.query
    if not pattern or pattern == "" then
        error("codesearch: pattern required for grep (POSIX regex; fixed=true 时按字面串)\n"
            .. "required: pattern (string); optional: path (目录或文件, default cwd), "
            .. "ext, fixed, ignore_case, max_hits, per_file", 0)
    end
    local path = abs_file(args.path or args.file or ".", ctx and ctx.cwd)
    -- 注意：上面的 env() 未命中时返回「零个值」，直接 tonumber(env(...)) 会变成零参数
    -- 调用而炸 "value expected"，所以先 or "" 兜一个实参。
    local cap = tonumber(env("LITE_CS_GREP_MAX_FILES") or "") or GREP_MAX_FILES_DEFAULT
    if is_dir(path) then
        local n = scan_file_count(path, cap)
        if n > cap then
            error(string.format("codesearch: refusing whole-tree grep under %s (>%d files, "
                .. "noise + slow).\nfix: narrow first — action=locate query=\"...\" then "
                .. "grep path=<file> or path=<subdir>; LITE_CS_GREP_MAX_FILES raises the cap",
                path, cap), 0)
        end
    end
    if not ctx or not ctx.call then
        error("codesearch: grep needs the cgrep native helper (env.call); "
            .. "call it through lite instead of loadfile()", 0)
    end
    local res = ctx.call("cgrep", cjson.encode({
        pattern = pattern, path = path, ext = args.ext,
        ignore_case = (args.ignore_case ~= false), fixed = (args.fixed == true),
        max_hits = tonumber(args.max_hits) or 120, per_file = tonumber(args.per_file) or 10,
        threads = tonumber(args.threads) or 4,
    }))
    local ok, d = pcall(cjson.decode, tostring(res))
    if not ok or type(d) ~= "table" or not d.ok then
        error("codesearch: grep failed: " .. tostring(ok and d and d.error or res):sub(1, 300), 0)
    end
    local nhits = d.count or (type(d.hits) == "table" and #d.hits) or 0
    local out = { string.format('grep /%s/ in %s -> %d hit(s) in %d file(s), scanned %d, %d ms%s',
        pattern, path, nhits, d.files or 0, d.scanned or 0, d.ms or 0,
        d.truncated and " (truncated, raise max_hits)" or "") }
    local seen, shown, used, files = {}, 0, 0, {}
    for _, h in ipairs(type(d.hits) == "table" and d.hits or {}) do
        local key = h.file .. ":" .. h.line
        if not seen[key] then                   -- C 端一行多命中会重复，按 file:line 去重
            seen[key] = true
            local line = string.format("%s:%d: %s", h.file, h.line, (h.text or ""):gsub("^%s+", ""))
            used = used + #line + 1
            if used > 8000 then out[#out + 1] = "... (output capped, raise per_file/max_hits)"; break end
            out[#out + 1] = line
            shown = shown + 1
            if #files < 3 and not files[h.file] then files[#files + 1] = h.file; files[h.file] = true end
        end
    end
    if shown == 0 then
        out[#out + 1] = "(no match)"
        -- cgrep 走 POSIX ERE，不是 Lua pattern：`%.`/`%d` 这类转义在 ERE 里是字面 `%`，
        -- 照搬 Lua 写法会静默 0 命中，所以给一条原地改法。
        if (not args.fixed) and pattern:find("%", 1, true) then
            out[#out + 1] = "hint: POSIX ERE, not Lua patterns — use \\. for a literal dot "
                .. "(or fixed=true for a literal string); %d/%s/%w do not exist here"
        end
    end
    for i = 1, #files do
        out[#out + 1] = string.format("-- next --\n  action=peek path=%s line=<n> lines=40", files[i])
        break
    end
    return table.concat(out, "\n")
end

local function do_peek(args, ctx, kv, ns)
    local path = args.path or args.file
    local line = tonumber(args.line)
    local out = {}
    if (not path or path == "") and args.query and args.query ~= "" then
        local d, err = CS.query({ query = args.query, repo = ns, type = "symbol",
            kv_dir = kv, analysis_dir = "", max_results = 1 })
        local r = d and (d.results or {})[1]
        if not r then
            error(string.format("codesearch: peek needs path=<file:line> (symbol %q not found: %s)",
                tostring(args.query), tostring(err)), 0)
        end
        path, line = r.file, r.line_start or r.line
        out[#out + 1] = string.format("%s  %s:%s  kind=%s", r.name or "?", tostring(path),
            tostring(line), r.kind or "")
    end
    if not path or path == "" then
        error("codesearch: peek needs path=<file> [line=N] or query=<symbol>\n"
            .. "required: path (string); optional: line, lines (default 40), before (default 5)", 0)
    end
    path = abs_file(path, ctx and ctx.cwd)
    local lines = math.max(1, tonumber(args.lines) or 40)
    local before = tonumber(args.before) or 5
    local first = math.max(1, (line or 1) - before)
    local snip, serr = read_window(path, first, first + lines - 1)
    if not snip then error("codesearch: peek failed: " .. tostring(serr), 0) end
    out[#out + 1] = string.format("-- %s:%d-%d", path, first, first + lines - 1)
    out[#out + 1] = snip
    out[#out + 1] = string.format("-- next --\n  action=grep path=%s pattern=<re>", path)
    return table.concat(out, "\n")
end

local schema = {
        name = "lens",
        description = "代码库索引与检索：建索引/调用图/数据流，按符号、上下文、语义查询。"
            .. "locate=搜+内联源码窗口（recommended 起点），peek=file:line 读窗口，"
            .. "grep=作用域 cgrep（拒整仓扫描）。数据在 ~/.local/share/lite/codesearch/<project>，与 lite 记忆隔离。",
        parameters = {
            type = "object",
            properties = {
                action = { type = "string", enum = { "build", "index", "import", "search", "symbol", "context", "exact", "file", "dataflow", "status", "locate", "peek", "grep" },
                           description = "省略时按参数推断：pattern→grep，query→locate，path→peek，都没有→status。locate=搜+内联源码（默认起手式）；peek=file:line 读窗口；grep=作用域 cgrep；build=全流程；index=只切块（不刷新 KV，要 import 才可查）；import=analysis 导入 KV；search=语义+关键词；symbol/context/exact=结构化查询；file=按文件列 chunk；dataflow=函数读写了哪些变量 / 变量流过哪些函数；status=看产物" },
                query = { type = "string", description = "符号名（可省略表前缀，M.foo 查 foo 也行）、自然语言查询、文件路径，或 exact 的完整 KV key；peek 时=符号名（免给 path）" },
                pattern = { type = "string", description = "grep 的正则（fixed=true 时按字面串）" },
                line = { type = "integer", description = "peek 的行号（默认 1，给了 before/lines 就围绕它读）" },
                lines = { type = "integer", description = "locate/peek 读取行数（locate 默认 40，peek 默认 40）" },
                before = { type = "integer", description = "locate/peek 命中行前保留的上下文行（默认 2/5）" },
                path = { type = "string", description = "仓库路径（index/build，默认 cwd）；grep/peek 时=要扫的目录或文件路径" },
                project = { type = "string", description = "项目名（默认取仓库目录名），决定 analysis/KV 目录与 namespace" },
                type = { type = "string", description = "query 类型：auto/exact/symbol/context/search，默认 auto" },
                max_results = { type = "integer", description = "返回条数，默认 10，上限 100" },
                depth = { type = "integer", description = "context 调用链向上展开深度，默认 0，上限 5" },
                kind = { type = "string", description = "按符号 kind 过滤：function/struct/macro/..." },
                lang = { type = "string", description = "按语言过滤：c/cpp/python/lua/javascript/typescript/go/rust/java/kotlin/ruby/php/objc/csharp" },
                file = { type = "string", description = "按文件名子串过滤（语义搜索）" },
                model = { type = "string", description = "向量模型 jina（默认）或 mpnet" },
                no_boost = { type = "boolean", description = "关闭 TF-IDF/调用者 boost" },
                vector = { type = "boolean", description = "build 时是否做语义向量化（默认 true，缺模型自动跳过）" },
                workers = { type = "integer", description = "index 进程数；默认 1，fork=true 时默认 CPU 核数" },
                fork = { type = "boolean", description = "index 用 fork 多进程并行（fresh 进程更快；已加载 ORT 的会话慎用）" },
                batch = { type = "integer", description = "向量化 batch，默认 128；长 chunk 多时降到 64" },
                fp16 = { type = "boolean", description = "用 model_fp16.onnx 推理（默认开；GPU 约快 1.5-2x）" },
                excludes = { type = "string", description = "index 跳过目录，逗号分隔" },
                skip_kinds = { type = "string", description = "按 ctags kind 过滤，逗号分隔，如 header,file,enumerator,macro（内核推荐）" },
                include_dirs = { type = "string", description = "把默认 noise 目录重新纳入，如 tools,utils" },
                plugins = { type = "string", description = "index 插件 registry JSON 路径" },
                only_dataflow = { type = "boolean", description = "import 只导入 dataflow（增量更新时用）" },
                analysis_dir = { type = "string", description = "覆盖 analysis 目录（高级）" },
                kv_dir = { type = "string", description = "覆盖 KV 目录（高级）" },
                json = { type = "boolean", description = "返回原始 JSON 而不是摘要文本" },
            },
        },
}

-- 内部文案沿用模块名 codesearch，暴露前统一换成工具名 lens。
local function run_inner(args, ctx)
        if not CS.available then
            error("codesearch: liblite_codesearch.so not built (see build/liblite_codesearch.so)", 0)
        end
        local repo, project, analysis, kv, ns = paths(args, ctx)
        local action = args.action
        if action == nil or action == "" then
            -- 省掉 action 时按给了什么参数推断，别让「只想搜一下」白跑成 status。
            if args.pattern and args.pattern ~= "" then action = "grep"
            elseif args.query and args.query ~= "" then action = "locate"
            elseif args.path and args.path ~= "" then action = "peek"
            else action = "status" end
        end

        if action == "build" then
            return do_build(args, repo, project, analysis, kv, ns)
        elseif action == "index" then
            local r = check_stage("index", CS.index({
                repo = repo, analysis_dir = analysis,
                workers = worker_count(args),
                fork = args.fork, skip_kinds = args.skip_kinds,
                include_dirs = args.include_dirs,
                excludes = args.excludes, plugins = args.plugins }))
            if args.json then return cjson.encode(r) end
            return "index 只切块，KV 未刷新（symbol/search/exact 查不到新代码）。" ..
                "要可查再跑 action=import（或 action=build 全流程）。\n" ..
                fmt_status(CS.check(analysis))
        elseif action == "import" then
            check_stage("import", CS.import(analysis, ns, kv, false))
            return "import ok: " .. ns .. " -> " .. kv
        elseif action == "status" then
            local d = CS.check(analysis)
            if not d then error("codesearch: status failed", 0) end
            if args.json then return cjson.encode(d) end
            return fmt_status(d)
        elseif action == "dataflow" then
            if not args.query or args.query == "" then
                error("codesearch: query required for dataflow (function or variable name)", 0)
            end
            local d0 = CS.check(analysis)
            if not d0 then error("codesearch: cannot read analysis dir " .. analysis, 0) end
            need_built(d0, "kv")
            local d, err = CS.dataflow_query(args.query, kv, ns, args.max_results or 10)
            if not d then error("codesearch: dataflow query failed: " .. tostring(err), 0) end
            if args.json then return cjson.encode(d) end
            return fmt_dataflow(d)
        elseif action == "locate" then
            return do_locate(args, ctx, analysis, kv, ns)
        elseif action == "peek" then
            return do_peek(args, ctx, kv, ns)
        elseif action == "grep" then
            return do_grep(args, ctx)
        elseif action == "search" or action == "symbol" or action == "context"
            or action == "exact" or action == "file" then
            if not args.query or args.query == "" then
                error("codesearch: query required for " .. action, 0)
            end
            -- symbol/context/file/exact 查的是 KV 里的符号表；语义 search 只要
            -- vectors/ + chunks_meta（KV 只用来 boost），所以别对 search 强求 kv。
            if action ~= "exact" and action ~= "search" then
                local d0 = CS.check(analysis)
                if not d0 then error("codesearch: cannot read analysis dir " .. analysis, 0) end
                need_built(d0, "kv")
            end

            local t = action
            -- 只有语义搜索才需要 vector engine；其余传空目录，
            -- 避免每次查询都白加载 ONNX 模型（~1s + 数百 MB）。
            local analysis_arg = (t == "search") and analysis or ""
            local d, err = CS.query({
                query = args.query, repo = ns, type = args.type and args.type ~= "auto" and args.type or t,
                kv_dir = kv, analysis_dir = analysis_arg, model = args.model or "jina",
                max_results = args.max_results or 10, depth = args.depth or 0,
                no_boost = args.no_boost, kind = args.kind, lang = args.lang, file = args.file,
            })
            if not d then error("codesearch: query failed: " .. tostring(err), 0) end
            if args.json then return cjson.encode(d) end
            if action == "context" then return fmt_context(d) end
            if action == "symbol" then return fmt_symbols(d) end
            return fmt_results(d)
        end

        error("codesearch: unknown action " .. tostring(action), 0)
end

return {
    schema = schema,
    run = function(args, ctx)
        local ok, res = pcall(run_inner, args, ctx)
        if ok then return res end
        error((tostring(res):gsub("^codesearch: ", "lens: ", 1)), 0)
    end,
}
