-- libcurl FFI：阻塞 POST（--once）+ curl_multi 非阻塞（TUI）。
local ffi = require("ffi")
local curl = ffi.load("curl")

ffi.cdef[[
typedef struct CURL CURL;
typedef struct CURLM CURLM;
typedef struct curl_slist curl_slist;

typedef struct CURLMsg {
    int msg;
    CURL *easy_handle;
    union { void *whatever; int result; } data;
} CURLMsg;

CURL *curl_easy_init(void);
void curl_easy_cleanup(CURL *);
int curl_easy_perform(CURL *);
int curl_easy_setopt(CURL *, int, ...);
int curl_easy_getinfo(CURL *, int, ...);
const char *curl_easy_strerror(int);
struct curl_slist *curl_slist_append(struct curl_slist *, const char *);
void curl_slist_free_all(struct curl_slist *);
int curl_global_init(long);

typedef struct FILE FILE;
FILE *tmpfile(void);
int fclose(FILE *);
int fflush(FILE *);
long ftell(FILE *);
int fseek(FILE *, long, int);
size_t fread(void *, size_t, size_t, FILE *);

CURLM *curl_multi_init(void);
int curl_multi_cleanup(CURLM *);
int curl_multi_add_handle(CURLM *, CURL *);
int curl_multi_remove_handle(CURLM *, CURL *);
int curl_multi_perform(CURLM *, int *);
CURLMsg *curl_multi_info_read(CURLM *, int *);
int curl_multi_poll(CURLM *, void *extra_fds, unsigned int extra_nfds,
                    int timeout_ms, int *numfds);
const char *curl_multi_strerror(int);
]]

local M = {}

local CURLOPT_URL = 10002
local CURLOPT_POST = 47
local CURLOPT_POSTFIELDS = 10015
local CURLOPT_POSTFIELDSIZE = 60
local CURLOPT_HTTPHEADER = 10023
local CURLOPT_WRITEDATA = 10001
local CURLOPT_WRITEFUNCTION = 20011
local CURLOPT_NOSIGNAL = 99
local CURLOPT_SSL_VERIFYPEER = 64
local CURLOPT_CONNECTTIMEOUT = 78
local CURLOPT_TIMEOUT = 13
local CURLOPT_ACCEPT_ENCODING = 10102
local CURLOPT_HTTPGET = 80
local CURLOPT_FOLLOWLOCATION = 52
local CURLOPT_MAXREDIRS = 68
local CURLOPT_USERAGENT = 10018
local CURLINFO_RESPONSE_CODE = 0x200002

local CURLMSG_DONE = 1

local inited = false

local function global_init()
    if not inited then
        curl.curl_global_init(3)
        inited = true
    end
end

local write_cb_t = ffi.typeof("size_t (*)(char*, size_t, size_t, void *)")

-- 单活动请求；多路复用期间用 tmpfile 缓冲，poll 后再读增量，
-- 避免从 C 回调进入 Lua（LuaJIT JIT 下偶发 bad callback）。
local active_req = nil

local function setup_easy(h, url, headers, payload, cb, writedata)
    local list = nil
    for _, v in ipairs(headers) do
        list = curl.curl_slist_append(list, v)
    end
    curl.curl_easy_setopt(h, CURLOPT_URL, ffi.cast("const char *", url))
    curl.curl_easy_setopt(h, CURLOPT_POST, ffi.cast("long", 1))
    curl.curl_easy_setopt(h, CURLOPT_POSTFIELDS, ffi.cast("const char *", payload))
    curl.curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE, ffi.cast("long", #payload))
    curl.curl_easy_setopt(h, CURLOPT_HTTPHEADER, list)
    if cb then
        curl.curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, cb)
    else
        curl.curl_easy_setopt(h, CURLOPT_WRITEDATA, writedata)
    end
    curl.curl_easy_setopt(h, CURLOPT_NOSIGNAL, ffi.cast("long", 1))
    curl.curl_easy_setopt(h, CURLOPT_SSL_VERIFYPEER, ffi.cast("long", 1))
    curl.curl_easy_setopt(h, CURLOPT_ACCEPT_ENCODING, ffi.cast("const char *", ""))
    curl.curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT, ffi.cast("long", 20))
    curl.curl_easy_setopt(h, CURLOPT_TIMEOUT, ffi.cast("long", 300))
    return list
end

-- 返回 rc, status, body_or_error；on_data 收到流式片段。
function M.post_stream(url, headers, payload, on_data)
    global_init()
    local h = curl.curl_easy_init()
    if h == nil then return -1, 0, "curl_easy_init failed" end

    local chunks = {}
    local cb = ffi.cast(write_cb_t, function(ptr, size, nmemb)
        local n = tonumber(size) * tonumber(nmemb)
        if n <= 0 then return 0 end
        local s = ffi.string(ptr, n)
        chunks[#chunks + 1] = s
        if on_data then on_data(s) end
        return n
    end)

    local list = setup_easy(h, url, headers, payload, cb)
    local rc = curl.curl_easy_perform(h)
    local code = ffi.new("long[1]")
    curl.curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, code)

    if list then curl.curl_slist_free_all(list) end
    curl.curl_easy_cleanup(h)

    local body = table.concat(chunks)
    if rc ~= 0 then
        return tonumber(rc), 0, ffi.string(curl.curl_easy_strerror(rc))
    end
    return 0, tonumber(code[0]), body
end

-- 阻塞 GET（web 工具）；max_bytes 防大页面吃内存。
function M.get(url, headers, max_bytes)
    global_init()
    max_bytes = tonumber(max_bytes) or (1024 * 1024)
    local h = curl.curl_easy_init()
    if h == nil then return -1, 0, "curl_easy_init failed" end

    local chunks, total = {}, 0
    local cb = ffi.cast(write_cb_t, function(ptr, size, nmemb)
        local n = tonumber(size) * tonumber(nmemb)
        if n <= 0 then return 0 end
        if total < max_bytes then
            local take = math.min(n, max_bytes - total)
            chunks[#chunks + 1] = ffi.string(ptr, take)
            total = total + take
        end
        return n
    end)

    local list = nil
    for _, v in ipairs(headers or {}) do
        list = curl.curl_slist_append(list, v)
    end
    curl.curl_easy_setopt(h, CURLOPT_URL, ffi.cast("const char *", url))
    curl.curl_easy_setopt(h, CURLOPT_HTTPGET, ffi.cast("long", 1))
    curl.curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, ffi.cast("long", 1))
    curl.curl_easy_setopt(h, CURLOPT_MAXREDIRS, ffi.cast("long", 5))
    curl.curl_easy_setopt(h, CURLOPT_USERAGENT, ffi.cast("const char *", "lite-agent/0.1"))
    if list then curl.curl_easy_setopt(h, CURLOPT_HTTPHEADER, list) end
    curl.curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, cb)
    curl.curl_easy_setopt(h, CURLOPT_NOSIGNAL, ffi.cast("long", 1))
    curl.curl_easy_setopt(h, CURLOPT_SSL_VERIFYPEER, ffi.cast("long", 1))
    curl.curl_easy_setopt(h, CURLOPT_ACCEPT_ENCODING, ffi.cast("const char *", ""))
    curl.curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT, ffi.cast("long", 20))
    curl.curl_easy_setopt(h, CURLOPT_TIMEOUT, ffi.cast("long", 60))

    local rc = curl.curl_easy_perform(h)
    local code = ffi.new("long[1]")
    curl.curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, code)
    if list then curl.curl_slist_free_all(list) end
    curl.curl_easy_cleanup(h)

    if rc ~= 0 then return tonumber(rc), 0, ffi.string(curl.curl_easy_strerror(rc)) end
    return 0, tonumber(code[0]), table.concat(chunks)
end

-- 非阻塞请求组。当前 agent 一次只有一个请求，但接口支持多个。
function M.multi_new()
    global_init()
    local h = curl.curl_multi_init()
    if h == nil then return nil, "curl_multi_init failed" end
    return { handle = h, by_handle = {}, reqs = {} }
end

function M.request(m, url, headers, payload, on_data)
    if not m then return nil, "nil multi handle" end
    if active_req and not active_req.done then
        return nil, "another request is active"
    end
    local h = curl.curl_easy_init()
    if h == nil then return nil, "curl_easy_init failed" end

    local stream = curl.tmpfile()
    if stream == nil then
        curl.curl_easy_cleanup(h)
        return nil, "tmpfile failed"
    end

    local req = {
        multi = m,
        handle = h,
        payload = payload, -- 保持引用
        stream = stream,
        read_pos = 0,
        chunks = {},
        on_data = on_data,
        done = false,
    }

    req.list = setup_easy(h, url, headers, payload, nil, stream)
    local rc = curl.curl_multi_add_handle(m.handle, h)
    if rc ~= 0 then
        if req.list then curl.curl_slist_free_all(req.list) end
        curl.fclose(stream)
        curl.curl_easy_cleanup(h)
        return nil, ffi.string(curl.curl_multi_strerror(rc))
    end

    local key = tostring(h)
    m.by_handle[key] = req
    m.reqs[#m.reqs + 1] = req
    active_req = req
    return req
end

local function finish_req(m, req)
    if active_req == req then active_req = nil end
    local key = tostring(req.handle)
    curl.curl_multi_remove_handle(m.handle, req.handle)
    if req.list then curl.curl_slist_free_all(req.list); req.list = nil end
    curl.curl_easy_cleanup(req.handle)
    m.by_handle[key] = nil
    req.handle = nil
    req.done = true
    req.body = table.concat(req.chunks)
    req.chunks = {}
    if req.stream then
        curl.fclose(req.stream)
        req.stream = nil
    end
end

-- 从 tmpfile 读取自上次以来的新增字节，再回调 Lua（不在 C 回调栈内）。
local function drain(req)
    local f = req.stream
    if not f then return end
    curl.fflush(f)
    local size = tonumber(curl.ftell(f))
    if not size or size <= req.read_pos then return end
    curl.fseek(f, req.read_pos, 0)
    local buf = ffi.new("char[8192]")
    while req.read_pos < size do
        local want = math.min(8192, size - req.read_pos)
        local n = tonumber(curl.fread(buf, 1, want, f))
        if n <= 0 then break end
        req.read_pos = req.read_pos + n
        local s = ffi.string(buf, n)
        req.chunks[#req.chunks + 1] = s
        if req.on_data then req.on_data(s) end
    end
end

-- 推进所有请求；返回本轮完成的 req 列表（已填 rc/status/body/err）。
function M.poll(m, timeout_ms)
    if not m or not m.handle then return {} end
    curl.curl_multi_poll(m.handle, nil, 0, timeout_ms or 20, nil)
    local running = ffi.new("int[1]")
    curl.curl_multi_perform(m.handle, running)
    if active_req then drain(active_req) end

    local out = {}
    while true do
        local q = ffi.new("int[1]")
        local msg = curl.curl_multi_info_read(m.handle, q)
        if msg == nil then break end
        if msg.msg == CURLMSG_DONE then
            local req = m.by_handle[tostring(msg.easy_handle)]
            if req then
                local rc = tonumber(msg.data.result)
                local code = ffi.new("long[1]")
                curl.curl_easy_getinfo(req.handle, CURLINFO_RESPONSE_CODE, code)
                req.rc = rc
                req.status = tonumber(code[0])
                if rc ~= 0 then
                    req.err = ffi.string(curl.curl_easy_strerror(rc))
                end
                drain(req)
                finish_req(m, req)
                out[#out + 1] = req
            end
        end
    end
    return out
end

function M.cancel(m, req)
    if not m or not req or req.done then return end
    finish_req(m, req)
    req.rc = -1
    req.status = 0
    req.err = "cancelled"
end

function M.multi_free(m)
    if not m or not m.handle then return end
    for _, req in ipairs(m.reqs) do
        if not req.done and req.handle then
            finish_req(m, req)
        end
    end
    curl.curl_multi_cleanup(m.handle)
    m.handle = nil
end

return M
