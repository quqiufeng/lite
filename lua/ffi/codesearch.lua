-- lite_codesearch FFI：代码索引 / 符号与调用图 / 数据流 / 语义向量搜索。
-- 所有 C 入口都是 JSON 字符串进、JSON 字符串出；这里统一转成 Lua 表。
local ffi = require("ffi")
local cjson = require("cjson")

ffi.cdef[[
char* lite_cs_index(const char* repo, const char* out_dir, int workers,
                    const char* excludes, const char* plugins);
char* lite_cs_index_ex(const char* repo, const char* out_dir, int workers,
                       const char* excludes, const char* plugins, int use_fork);
char* lite_cs_index_ext(const char* repo, const char* out_dir, int workers,
                        const char* excludes, const char* plugins, int use_fork,
                        const char* skip_kinds);
char* lite_cs_word_freq(const char* analysis_dir);
char* lite_cs_vectorize(const char* analysis_dir, const char* model, const char* name);
char* lite_cs_vectorize_ex(const char* analysis_dir, const char* model, const char* name,
                           int batch, int fp16);
char* lite_cs_callgraph(const char* analysis_dir);
char* lite_cs_dataflow(const char* analysis_dir);
char* lite_cs_import(const char* analysis_dir, const char* ns,
                     const char* kv_dir, int only_dataflow);
char* lite_cs_query(const char* query, const char* repo, const char* type,
                    const char* kv_dir, const char* analysis_dir, const char* model,
                    int max_results, int depth, int no_boost,
                    const char* kind, const char* lang, const char* file);
char* lite_cs_check(const char* analysis_dir);
char* lite_cs_capabilities(void);
const char* lite_cs_error(void);
void lite_cs_free(char* p);
]]

local function env(name)
    local v = os.getenv(name)
    if v and v ~= "" then return v end
    return nil
end

local function self_root()
    local src = (debug.getinfo(1, "S") or {}).source or ""
    local path = src:match("^@(.+)$")
    local dir = path and path:match("^(.*)/[^/]+$")
    local root = dir and dir:match("^(.*)/[^/]+/[^/]+$")
    if root and root ~= "" then return root end
end

local ROOTS = {}
for _, r in ipairs({ env("LITE_ROOT"), self_root(), "." }) do
    r = (r or ""):gsub("/+$", "")
    if r ~= "" and r ~= "/" then ROOTS[#ROOTS + 1] = r end
end

local function first_file(paths)
    for _, p in ipairs(paths) do
        local f = io.open(p, "rb")
        if f then f:close(); return p end
    end
end

local LIB
local load_err
local explicit = env("LITE_CS_LIB")
local candidates = {}
if explicit then candidates[#candidates + 1] = explicit end
for _, base in ipairs(ROOTS) do
    candidates[#candidates + 1] = base .. "/build/liblite_codesearch.so"
    candidates[#candidates + 1] = base .. "/lib/liblite_codesearch.so"
end
candidates[#candidates + 1] = "liblite_codesearch.so"

local path = first_file(candidates)
if path then
    local ok, h = pcall(ffi.load, path)
    if ok then LIB = h else load_err = h end
end

local M = { available = LIB ~= nil, lib = LIB, path = path }

local function decode(p)
    if p == nil then return nil, "null result" end
    local s = ffi.string(p)
    LIB.lite_cs_free(p)
    local ok, v = pcall(cjson.decode, s)
    if not ok then return nil, "bad json: " .. tostring(v) .. ": " .. s:sub(1, 200) end
    return v
end

local function call(name, ...)
    if not LIB then return nil, "liblite_codesearch.so not found: " .. tostring(load_err) end
    local p = LIB[name](...)
    local v, err = decode(p)
    if not v then return nil, err end
    if v.ok == false then return nil, v.error or "codesearch failed" end
    return v
end

function M.index(opts)
    opts = opts or {}
    local fork = -1
    if opts.fork == true then fork = 1 elseif opts.fork == false then fork = 0 end
    local skip = opts.skip_kinds or env("LITE_CS_SKIP_KINDS") or ""
    if LIB.lite_cs_index_ext ~= nil then
        return call("lite_cs_index_ext", opts.repo, opts.analysis_dir,
                    opts.workers or 1, opts.excludes or "", opts.plugins or "", fork, skip)
    end
    if LIB.lite_cs_index_ex ~= nil then
        return call("lite_cs_index_ex", opts.repo, opts.analysis_dir,
                    opts.workers or 1, opts.excludes or "", opts.plugins or "", fork)
    end
    return call("lite_cs_index", opts.repo, opts.analysis_dir,
                opts.workers or 1, opts.excludes or "", opts.plugins or "")
end

function M.word_freq(dir) return call("lite_cs_word_freq", dir) end
function M.vectorize(dir, model, name, opts)
    opts = opts or {}
    if LIB.lite_cs_vectorize_ex ~= nil then
        local fp16 = -1
        if opts.fp16 == true then fp16 = 1 elseif opts.fp16 == false then fp16 = 0 end
        return call("lite_cs_vectorize_ex", dir, model or "jina", name or "",
                    opts.batch or 0, fp16)
    end
    return call("lite_cs_vectorize", dir, model or "jina", name or "")
end
function M.callgraph(dir) return call("lite_cs_callgraph", dir) end
function M.dataflow(dir) return call("lite_cs_dataflow", dir) end
function M.import(dir, ns, kv_dir, only_dataflow)
    return call("lite_cs_import", dir, ns, kv_dir, only_dataflow and 1 or 0)
end

function M.query(opts)
    opts = opts or {}
    return call("lite_cs_query", opts.query, opts.repo or "", opts.type or "auto",
                opts.kv_dir, opts.analysis_dir or "", opts.model or "jina",
                opts.max_results or 10, opts.depth or 0, opts.no_boost and 1 or 0,
                opts.kind or "", opts.lang or "", opts.file or "")
end

function M.check(dir) return call("lite_cs_check", dir) end
function M.capabilities() return call("lite_cs_capabilities") end

return M
