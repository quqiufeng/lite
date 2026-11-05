-- libcurl FFI：流式 POST（DeepSeek SSE）。
local ffi = require("ffi")
local curl = ffi.load("curl")

ffi.cdef[[
typedef struct CURL CURL;
typedef struct curl_slist curl_slist;
CURL *curl_easy_init(void);
void curl_easy_cleanup(CURL *);
int curl_easy_perform(CURL *);
int curl_easy_setopt(CURL *, int, ...);
int curl_easy_getinfo(CURL *, int, ...);
const char *curl_easy_strerror(int);
struct curl_slist *curl_slist_append(struct curl_slist *, const char *);
void curl_slist_free_all(struct curl_slist *);
int curl_global_init(long);
]]

local M = {}

local CURLOPT_URL = 10002
local CURLOPT_POST = 47
local CURLOPT_POSTFIELDS = 10015
local CURLOPT_POSTFIELDSIZE = 60
local CURLOPT_HTTPHEADER = 10023
local CURLOPT_WRITEFUNCTION = 20011
local CURLOPT_NOSIGNAL = 99
local CURLOPT_SSL_VERIFYPEER = 64
local CURLOPT_CONNECTTIMEOUT = 78
local CURLOPT_TIMEOUT = 13
local CURLOPT_ACCEPT_ENCODING = 10102
local CURLINFO_RESPONSE_CODE = 0x200002

local inited = false
local current = nil
local chunks = {}

local function write_cb(ptr, size, nmemb, data)
    local n = tonumber(size) * tonumber(nmemb)
    if n <= 0 then return 0 end
    local s = ffi.string(ptr, n)
    chunks[#chunks + 1] = s
    if current then current(s) end
    return n
end
local write_cb_t = ffi.typeof("size_t (*)(char*, size_t, size_t, void *)")
local write_cb_ptr = ffi.cast(write_cb_t, write_cb)

-- 返回 rc, status, body_or_error；on_data 收到流式片段。
function M.post_stream(url, headers, payload, on_data)
    if not inited then
        curl.curl_global_init(3)
        inited = true
    end
    local h = curl.curl_easy_init()
    if h == nil then return -1, 0, "curl_easy_init failed" end

    local list = nil
    for _, v in ipairs(headers) do
        list = curl.curl_slist_append(list, v)
    end

    chunks = {}
    current = on_data
    curl.curl_easy_setopt(h, CURLOPT_URL, ffi.cast("const char *", url))
    curl.curl_easy_setopt(h, CURLOPT_POST, ffi.cast("long", 1))
    curl.curl_easy_setopt(h, CURLOPT_POSTFIELDS, ffi.cast("const char *", payload))
    curl.curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE, ffi.cast("long", #payload))
    curl.curl_easy_setopt(h, CURLOPT_HTTPHEADER, list)
    curl.curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, write_cb_ptr)
    curl.curl_easy_setopt(h, CURLOPT_NOSIGNAL, ffi.cast("long", 1))
    curl.curl_easy_setopt(h, CURLOPT_SSL_VERIFYPEER, ffi.cast("long", 1))
    curl.curl_easy_setopt(h, CURLOPT_ACCEPT_ENCODING, ffi.cast("const char *", ""))
    curl.curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT, ffi.cast("long", 20))
    curl.curl_easy_setopt(h, CURLOPT_TIMEOUT, ffi.cast("long", 300))

    local rc = curl.curl_easy_perform(h)
    local code = ffi.new("long[1]")
    curl.curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, code)

    current = nil
    if list then curl.curl_slist_free_all(list) end
    curl.curl_easy_cleanup(h)

    local body = table.concat(chunks)
    chunks = {}
    if rc ~= 0 then
        return tonumber(rc), 0, ffi.string(curl.curl_easy_strerror(rc))
    end
    return 0, tonumber(code[0]), body
end

return M
