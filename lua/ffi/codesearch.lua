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
char* lite_cs_index_full(const char* repo, const char* out_dir, int workers,
                         const char* excludes, const char* plugins, int use_fork,
                         const char* skip_kinds, const char* include_dirs);
char* lite_cs_word_freq(const char* analysis_dir);
char* lite_cs_vectorize(const char* analysis_dir, const char* model, const char* name);
char* lite_cs_vectorize_ex(const char* analysis_dir, const char* model, const char* name,
                           int batch, int fp16);
char* lite_cs_callgraph(const char* analysis_dir);
char* lite_cs_dataflow(const char* analysis_dir);
char* lite_cs_dataflow_query(const char* query, const char* kv_dir, const char* ns,
                             int max_results);
char* lite_cs_import(const char* analysis_dir, const char* ns,
                     const char* kv_dir, int only_dataflow);
char* lite_cs_query(const char* query, const char* repo, const char* type,
                    const char* kv_dir, const char* analysis_dir, const char* model,
                    int max_results, int depth, int no_boost,
                    const char* kind, const char* lang, const char* file,
                    const char* path_prefix);
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

-- 候选顺序统一在 ffi/libfind.lua：$LITE_ROOT/build → $LITE_ROOT/lib → 源码树 → ./build → 裸名。
-- LITE_CS_LIB 显式指定仍然排第一（调试单个 .so 用）。
-- 顺序统一后要留心：只跑 ./tools/build.sh 没跑 release.sh 时，源码树的新库会被
-- 安装目录的旧副本遮蔽——libfind 会在长度不一致时往 stderr 打一行警告。
local LIB, path, load_err = require("ffi.libfind").load("liblite_codesearch.so", {
    explicit = env("LITE_CS_LIB"),
})

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

-- 日志：C 侧只把进度/错误 printf 到 stdout/stderr，返回 JSON 只有 ok+exit，
-- 失败时原因全丢（TUI 里连 stdout 都看不见）。所以每次阶段调用把 fd 1/2 临时指到
-- <analysis>/build.log（append），跑完 fflush 再还原 —— 事后可在盘上翻完整上下文。
-- 注意：open 必须写成固定三参（与 core/memory.lua、ffi/ocr.lua 一致）。写成变参
-- `...` 的话，别处那份 pcall(ffi.cdef) 的固定版静默失败、调用落到变参版，mode 被当
-- vararg 传成垃圾 → 建出 0000 权限的文件（实测：mem.lock 第二次打开 errno 13）。
ffi.cdef[[
int fflush(void* stream);
int open(const char *pathname, int flags, unsigned int mode);
int dup(int fd);
int dup2(int oldfd, int newfd);
int close(int fd);
]]
local O_WRONLY, O_CREAT, O_APPEND = 1, 0x40, 0x400

function M.log_path(dir) return (dir or ".") .. "/build.log" end

local function log_line(path, fmt, ...)
    local f = io.open(path, "a")
    if not f then return end
    f:write(string.format("[%s] " .. fmt .. "\n", os.date("%Y-%m-%d %H:%M:%S"), ...))
    f:close()
end

-- 在 fd 1/2 指向 path 的情况下跑 fn(...)，把起止/退出码/异常记进日志。
function M.logged(name, path, fn, ...)
    path = path or "codesearch.log"
    -- 先让 Lua 按 umask 建好文件（固定三参 open 建出来的权限才是对的），再拿 fd 追加
    do
        local f = io.open(path, "a")
        if not f then                       -- 目录还没被 C 建出来时先补一次
            local d = path:match("^(.*)/[^/]+$")
            if d and d ~= "" then
                os.execute("mkdir -p '" .. d:gsub("'", "'\\''") .. "'")
            end
            f = io.open(path, "a")
        end
        if f then f:close() end
    end
    local fd = ffi.C.open(path, O_WRONLY + O_APPEND, 420)
    if fd < 0 then return fn(...) end          -- 打不开日志也不能拖垮构建
    log_line(path, ">> %s start", name)
    io.stdout:flush(); io.stderr:flush()
    local s1, s2 = ffi.C.dup(1), ffi.C.dup(2)
    local t0 = os.time()
    ffi.C.dup2(fd, 1); ffi.C.dup2(fd, 2)
    local res = { pcall(fn, ...) }
    ffi.C.fflush(nil)                          -- 关键：C 的缓冲还属于日志 fd，先刷出去
    ffi.C.dup2(s1, 1); ffi.C.dup2(s2, 2)
    ffi.C.close(s1); ffi.C.close(s2); ffi.C.close(fd)
    local el = os.time() - t0
    if not res[1] then
        log_line(path, "!! %s raised after %ds: %s", name, el, tostring(res[2]))
        error(res[2], 0)
    end
    local r, e = res[2], res[3]
    if type(r) == "table" then
        log_line(path, "<< %s %s in %ds (exit=%s)", name,
                 (r.ok == false and "FAILED" or "ok"), el, tostring(r.exit))
    else
        log_line(path, "<< %s %s in %ds %s", name, r and "ok" or "FAILED", el,
                 tostring(e or r))
    end
    if not r then return nil, e end
    return r, e
end

function M.index(opts)
    opts = opts or {}
    local fork = -1
    if opts.fork == true then fork = 1 elseif opts.fork == false then fork = 0 end
    local skip = opts.skip_kinds or env("LITE_CS_SKIP_KINDS") or ""
    local incl = opts.include_dirs or env("LITE_CS_INCLUDE_DIRS") or ""
    if LIB.lite_cs_index_full ~= nil then
        return call("lite_cs_index_full", opts.repo, opts.analysis_dir,
                    opts.workers or 1, opts.excludes or "", opts.plugins or "", fork, skip, incl)
    end
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
function M.dataflow_query(query, kv_dir, ns, max_results)
    return call("lite_cs_dataflow_query", query, kv_dir, ns, max_results or 10)
end
function M.import(dir, ns, kv_dir, only_dataflow)
    return call("lite_cs_import", dir, ns, kv_dir, only_dataflow and 1 or 0)
end

function M.query(opts)
    opts = opts or {}
    return call("lite_cs_query", opts.query, opts.repo or "", opts.type or "auto",
                opts.kv_dir, opts.analysis_dir or "", opts.model or "jina",
                opts.max_results or 10, opts.depth or 0, opts.no_boost and 1 or 0,
                opts.kind or "", opts.lang or "", opts.file or "", opts.path_prefix or "")
end

function M.check(dir) return call("lite_cs_check", dir) end
function M.capabilities() return call("lite_cs_capabilities") end

return M
