-- my_db KV cache FFI：零拷贝 mmap + 前缀/范围/正则/模糊/标签搜索。
local ffi = require("ffi")

ffi.cdef[[
typedef struct cache cache_t;
typedef struct {
    const char* key;
    const char* value;
    double score;
} cache_result_t;
typedef struct {
    int max_results;
    int case_sensitive;
    const char* ns_filter;
    const char* query_text;
} cache_search_options_t;

cache_t* cache_open(const char* db_dir, size_t max_memory);
void cache_close(cache_t* cache);
int cache_sync(cache_t* cache);
int cache_set(cache_t* cache, const char* key, const char* value, uint64_t ttl_ms);
const char* cache_get(cache_t* cache, const char* key);
int cache_del(cache_t* cache, const char* key);
int cache_exists(cache_t* cache, const char* key);
int cache_set_ns(cache_t* cache, const char* ns, const char* key, const char* value, uint64_t ttl_ms);
const char* cache_get_ns(cache_t* cache, const char* ns, const char* key);
int cache_del_ns(cache_t* cache, const char* ns, const char* key);
int cache_del_namespace(cache_t* cache, const char* ns);
size_t cache_count(cache_t* cache);
size_t cache_memory_used(cache_t* cache);
size_t cache_memory_max(cache_t* cache);
size_t cache_pool_used(cache_t* cache);
int cache_search_prefix(cache_t* cache, const char* prefix,
    const cache_search_options_t* options, cache_result_t** out_results, size_t* out_count);
int cache_search_range(cache_t* cache, const char* start_key, const char* end_key,
    const cache_search_options_t* options, cache_result_t** out_results, size_t* out_count);
int cache_search_regex(cache_t* cache, const char* pattern,
    const cache_search_options_t* options, cache_result_t** out_results, size_t* out_count);
int cache_search_fuzzy(cache_t* cache, const char* query,
    const cache_search_options_t* options, cache_result_t** out_results, size_t* out_count);
int cache_search_tag(cache_t* cache, const char* tag,
    const cache_search_options_t* options, cache_result_t** out_results, size_t* out_count);
void cache_results_free(cache_result_t* results);
int cache_expire(cache_t* cache, const char* key);
int cache_touch(cache_t* cache, const char* key);
size_t cache_compact(cache_t* cache);
size_t cache_purge_expired(cache_t* cache);
int cache_check(const char* db_dir);
]]

local root = os.getenv("LITE_ROOT") or "."
local candidates = {
    root .. "/build/liblite_cache.so",
    "./build/liblite_cache.so",
    "liblite_cache.so",
}
local lib, load_err
for _, p in ipairs(candidates) do
    local ok, h = pcall(ffi.load, p)
    if ok then lib = h; break end
    load_err = h
end
if not lib then
    error("cannot load liblite_cache.so: " .. tostring(load_err))
end

local M = {}

function M.open(dir, max_memory)
    local h = lib.cache_open(dir, max_memory or 100 * 1024 * 1024)
    if h == nil then return nil, "cache_open failed" end
    return h
end

function M.close(h)
    if h then lib.cache_close(h) end
end

function M.sync(h) return tonumber(lib.cache_sync(h)) end
function M.set(h, key, value, ttl) return tonumber(lib.cache_set(h, key, value, ttl or 0)) end
function M.del(h, key) return tonumber(lib.cache_del(h, key)) end
function M.exists(h, key) return tonumber(lib.cache_exists(h, key)) ~= 0 end

function M.get(h, key)
    local p = lib.cache_get(h, key)
    if p == nil then return nil end
    return ffi.string(p)
end

function M.set_ns(h, ns, key, value, ttl)
    return tonumber(lib.cache_set_ns(h, ns, key, value, ttl or 0))
end
function M.get_ns(h, ns, key)
    local p = lib.cache_get_ns(h, ns, key)
    if p == nil then return nil end
    return ffi.string(p)
end
function M.del_ns(h, ns, key) return tonumber(lib.cache_del_ns(h, ns, key)) end
function M.del_namespace(h, ns) return tonumber(lib.cache_del_namespace(h, ns)) end

function M.count(h) return tonumber(lib.cache_count(h)) end
function M.memory_used(h) return tonumber(lib.cache_memory_used(h)) end
function M.memory_max(h) return tonumber(lib.cache_memory_max(h)) end
function M.pool_used(h) return tonumber(lib.cache_pool_used(h)) end
function M.expire(h, key) return tonumber(lib.cache_expire(h, key)) end
function M.touch(h, key) return tonumber(lib.cache_touch(h, key)) end
function M.compact(h) return tonumber(lib.cache_compact(h)) end
function M.purge_expired(h) return tonumber(lib.cache_purge_expired(h)) end
function M.check(dir) return tonumber(lib.cache_check(dir)) end

local function options(o)
    o = o or {}
    local out = ffi.new("cache_search_options_t")
    out.max_results = tonumber(o.max_results) or 100
    out.case_sensitive = o.case_sensitive and 1 or 0
    out.ns_filter = o.ns_filter and ffi.cast("const char*", o.ns_filter) or nil
    out.query_text = o.query_text and ffi.cast("const char*", o.query_text) or nil
    return out
end

local function collect(out, n)
    local res = {}
    if n[0] > 0 and out[0] ~= nil then
        for i = 0, tonumber(n[0]) - 1 do
            local r = out[0][i]
            res[#res + 1] = {
                key = ffi.string(r.key),
                value = ffi.string(r.value),
                score = tonumber(r.score),
            }
        end
        lib.cache_results_free(out[0])
    end
    return res
end

local function search(fn, h, a, b, o)
    local out = ffi.new("cache_result_t*[1]")
    local n = ffi.new("size_t[1]")
    local oo = options(o)
    local rc
    if b then
        rc = fn(h, a, b, oo, out, n)
    else
        rc = fn(h, a, oo, out, n)
    end
    if rc ~= 0 then return {} end
    return collect(out, n)
end

function M.search_prefix(h, prefix, o)
    return search(lib.cache_search_prefix, h, prefix, nil, o)
end
function M.search_range(h, start_key, end_key, o)
    return search(lib.cache_search_range, h, start_key, end_key, o)
end
function M.search_regex(h, pattern, o)
    return search(lib.cache_search_regex, h, pattern, nil, o)
end
function M.search_fuzzy(h, query, o)
    return search(lib.cache_search_fuzzy, h, query, nil, o)
end
function M.search_tag(h, tag, o)
    return search(lib.cache_search_tag, h, tag, nil, o)
end

return M
