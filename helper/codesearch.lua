-- codesearch：代码索引 / 符号 / 调用图 / 数据流 / 语义搜索。
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

local function paths(args, ctx)
    local repo = abs_path(args.path, ctx and ctx.cwd)
    local project = safe_name(args.project or basename(repo))
    local analysis = args.analysis_dir or (home() .. "/" .. project)
    analysis = analysis:gsub("/+$", "")
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
            t[#t + 1] = type(v) == "table" and (v.name or "?") or tostring(v)
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

local function need_built(d, what)
    local meta = ((d.files or {})["chunks_meta.jsonl"] or {})
    if not meta.exists then
        error("codesearch: index not found for this project; run action=build first", 0)
    end
    if what == "kv" then
        local f = io.open(d.analysis_dir .. "/kv/mem.bin", "rb")
        if not f then
            error("codesearch: KV import missing; run action=build (or action=import)", 0)
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

return {
    schema = {
        name = "codesearch",
        description = "代码库索引与检索：建索引/调用图/数据流，按符号、上下文、语义查询。数据在 ~/.local/share/lite/codesearch/<project>，与 lite 记忆隔离。",
        parameters = {
            type = "object",
            properties = {
                action = { type = "string", enum = { "build", "index", "import", "search", "symbol", "context", "exact", "dataflow", "status" },
                           description = "build=全流程；index=只切块；import=analysis 导入 KV；search=语义+关键词；symbol/context/exact=结构化查询；dataflow=函数读写了哪些变量 / 变量流过哪些函数；status=看产物" },
                query = { type = "string", description = "符号名、标识符、自然语言查询，或 exact 的完整 KV key" },
                path = { type = "string", description = "仓库路径（index/build，默认 cwd）" },
                project = { type = "string", description = "项目名（默认取仓库目录名），决定 analysis/KV 目录与 namespace" },
                type = { type = "string", description = "query 类型：auto/exact/symbol/context/search，默认 auto" },
                max_results = { type = "integer", description = "返回条数，默认 10，上限 100" },
                depth = { type = "integer", description = "context 调用链向上展开深度，默认 0，上限 5" },
                kind = { type = "string", description = "按符号 kind 过滤：function/struct/macro/..." },
                lang = { type = "string", description = "按语言过滤：c/cpp/python/javascript/go/rust" },
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
            required = { "action" },
        },
    },

    run = function(args, ctx)
        if not CS.available then
            error("codesearch: liblite_codesearch.so not built (see build/liblite_codesearch.so)", 0)
        end
        local repo, project, analysis, kv, ns = paths(args, ctx)
        local action = args.action or "status"

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
            return fmt_status(CS.check(analysis))
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
        elseif action == "search" or action == "symbol" or action == "context" or action == "exact" then
            if not args.query or args.query == "" then
                error("codesearch: query required for " .. action, 0)
            end
            if action ~= "exact" then
                local d0 = CS.check(analysis)
                if not d0 then error("codesearch: cannot read analysis dir " .. analysis, 0) end
                need_built(d0, "kv")
            end

            local t = action == "search" and "search" or action
            -- 只有语义搜索才需要 vector engine；symbol/context/exact 传空目录，
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
            if action == "exact" then return fmt_results(d) end
            return fmt_results(d)
        end

        error("codesearch: unknown action " .. tostring(action), 0)
    end,
}
