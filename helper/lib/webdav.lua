-- helper/lib/webdav.lua — WebDAV 无损曲库：PROPFIND 列目录 + 按需下载缓存
-- 凭据只从环境变量读，只走 libcurl CURLOPT_USERPWD：不进 URL、不进 argv(ps)、
-- 不进 m3u / 队列日志 / 磁盘。播放列表只写本地缓存 file:// 路径。
local ffi = require("ffi")
local curl = ffi.load("curl")

ffi.cdef[[
typedef struct CURL CURL;
typedef struct curl_slist curl_slist;
typedef struct FILE FILE;
CURL *curl_easy_init(void);
void curl_easy_cleanup(CURL *);
int curl_easy_perform(CURL *);
int curl_easy_setopt(CURL *, int, ...);
int curl_easy_getinfo(CURL *, int, ...);
const char *curl_easy_strerror(int);
struct curl_slist *curl_slist_append(struct curl_slist *, const char *);
void curl_slist_free_all(struct curl_slist *);
int curl_global_init(long);
FILE *tmpfile(void);
FILE *fopen(const char *, const char *);
int fclose(FILE *);
size_t fread(void *, size_t, size_t, FILE *);
int fseek(FILE *, long, int);
]]

local M = {}

local CACHE = os.getenv("LITE_MUSIC_CACHE") or "/tmp/lite-music-cache"
local LIST_TTL = 600 -- 列目录缓存秒数
M.cache_dir = CACHE

local CURLOPT_URL = 10002
local CURLOPT_WRITEDATA = 10001
local CURLOPT_HTTPHEADER = 10023
local CURLOPT_CUSTOMREQUEST = 10036
local CURLOPT_USERPWD = 10005
local CURLOPT_NOSIGNAL = 99
local CURLOPT_TIMEOUT = 13
local CURLOPT_CONNECTTIMEOUT = 78
local CURLOPT_FOLLOWLOCATION = 52
local CURLOPT_MAXREDIRS = 68
local CURLOPT_USERAGENT = 10018

local EXT = {
    mp3 = 1, flac = 1, wav = 1, ogg = 1, oga = 1, opus = 1, m4a = 1, aac = 1,
    wma = 1, ape = 1, wv = 1, aiff = 1, mka = 1,
}

local inited = false
local function global_init()
    if not inited then
        curl.curl_global_init(3)
        inited = true
    end
end

local function shell(cmd)
    local f = io.popen(cmd .. " 2>&1", "r")
    if not f then return "" end
    local out = f:read("*a") or ""
    f:close()
    return out
end

-- 进程环境缺变量时回退读 dotenv（进程环境优先，与 tools/lua.sh 顺序一致）
local dotenv
local function env(key)
    local v = os.getenv(key)
    if v and v ~= "" then return v end
    if dotenv == nil then
        dotenv = {}
        local home = os.getenv("HOME") or ""
        for _, p in ipairs({ home .. "/.env", home .. "/.config/lite/.env" }) do
            local f = io.open(p, "r")
            if f then
                for line in f:lines() do
                    local k, val = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
                    if k and dotenv[k] == nil then
                        dotenv[k] = val:gsub("^['\"]", ""):gsub("['\"]$", "")
                    end
                end
                f:close()
            end
        end
    end
    return dotenv[key]
end

-- dav://host:port/path → http://host:port + /path（davs:// → https）
local function split_dav(u)
    local scheme, rest = tostring(u or ""):match("^(dav%a*)://(.+)$")
    if not scheme then return nil end
    local proto = (scheme == "davs") and "https" or "http"
    local host, path = rest:match("^([^/]+)(/.*)$")
    if not host then return proto .. "://" .. rest end
    return proto .. "://" .. host, (path:gsub("/+$", ""))
end

-- 任意 URL 里的 dav:// 转 http(s)://
function M.http(u)
    local b, p = split_dav(u)
    if not b then return u end
    return p and (b .. p) or b
end

-- 依赖环境变量（或 ~/.env、~/.config/lite/.env 回退）；WEBDAV_URL 也可写成 dav://
function M.cfg()
    local base = env("WEBDAV_URL")
    local user = env("WEBDAV_USER")
    local pass = env("WEBDAV_PASS")
    local root = env("WEBDAV_MUSIC")
    local hb, hp = split_dav(base)
    if hb then
        base = hb
        if not root or root == "" then root = hp end
    end
    local rb, rp = split_dav(root)
    if rb then
        base = rb
        root = rp
    end
    if not (base and user and pass and root) then
        return nil, "缺 WebDAV 配置：WEBDAV_URL / WEBDAV_USER / WEBDAV_PASS / WEBDAV_MUSIC"
            .. "（写进 ~/.env 或 ~/.config/lite/.env；也可直接给 dav://host:port/路径）"
    end
    return {
        base = base:gsub("/+$", ""),
        root = root,
        auth = user .. ":" .. pass,
    }
end

local function urlenc(s)
    -- 保留路径分隔符，只编码非 ASCII / 特殊字符
    return (tostring(s):gsub("[^%w%-%._~/]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function urldec(s)
    return (tostring(s):gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- 一次 curl easy 请求；out_file 给了就写文件，否则返回 body
local function request(url, auth, headers, method, timeout, out_file)
    global_init()
    local h = curl.curl_easy_init()
    if h == nil then return nil, "curl_easy_init 失败" end
    local list = nil
    for _, v in ipairs(headers or {}) do
        list = curl.curl_slist_append(list, v)
    end
    curl.curl_easy_setopt(h, CURLOPT_URL, url)
    curl.curl_easy_setopt(h, CURLOPT_USERPWD, auth)
    curl.curl_easy_setopt(h, CURLOPT_NOSIGNAL, ffi.cast("long", 1))
    curl.curl_easy_setopt(h, CURLOPT_TIMEOUT, ffi.cast("long", timeout or 30))
    curl.curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT, ffi.cast("long", 10))
    curl.curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, ffi.cast("long", 1))
    curl.curl_easy_setopt(h, CURLOPT_MAXREDIRS, ffi.cast("long", 5))
    curl.curl_easy_setopt(h, CURLOPT_USERAGENT, "lite-music/1")
    if method then curl.curl_easy_setopt(h, CURLOPT_CUSTOMREQUEST, method) end
    if list then curl.curl_easy_setopt(h, CURLOPT_HTTPHEADER, list) end

    local fp, body
    if out_file then
        fp = ffi.C.fopen(out_file, "wb")
        if fp == nil then
            curl.curl_easy_cleanup(h)
            if list then curl.curl_slist_free_all(list) end
            return nil, "打不开输出文件: " .. out_file
        end
    else
        fp = ffi.C.tmpfile()
    end
    curl.curl_easy_setopt(h, CURLOPT_WRITEDATA, fp)
    local rc = curl.curl_easy_perform(h)
    if rc ~= 0 then
        curl.curl_easy_cleanup(h)
        if list then curl.curl_slist_free_all(list) end
        ffi.C.fclose(fp)
        if out_file then os.remove(out_file) end
        return nil, string.format("HTTP 失败(%d): %s", rc, ffi.string(curl.curl_easy_strerror(rc)))
    end
    if not out_file then
        ffi.C.fseek(fp, 0, 0)
        local chunks, total = {}, 0
        local buf = ffi.new("char[65536]")
        while true do
            local n = tonumber(ffi.C.fread(buf, 1, 65536, fp))
            if n <= 0 then break end
            chunks[#chunks + 1] = ffi.string(buf, n)
            total = total + n
            if total > 16 * 1024 * 1024 then break end
        end
        body = table.concat(chunks)
    end
    ffi.C.fclose(fp)
    curl.curl_easy_cleanup(h)
    if list then curl.curl_slist_free_all(list) end
    return body or true
end

-- PROPFIND 单个目录（Depth: 1，平铺），只留音频；条目带绝对 url
local function propfind(c, target)
    local xml, err = request(target, c.auth,
        { "Depth: 1", "Content-Type: application/xml; charset=utf-8" },
        "PROPFIND", 30)
    if not xml then return nil, "PROPFIND 失败: " .. tostring(err) end
    local origin = target:match("^(%a+://[^/]+)") or c.base
    local entries, seen = {}, {}
    for href in xml:gmatch("<[%a]*:?[Hh][Rr][Ee][Ff]>([^<]+)<") do
        local dec = urldec(href)
        local name = dec:match("([^/]+)/?$") or dec
        local ext = name:match("%.([%w]+)$")
        if ext and EXT[ext:lower()] and not seen[dec] then
            seen[dec] = true
            local url = href:match("^%a+://") and href or (origin .. href)
            entries[#entries + 1] = { href = href, name = name, url = url }
        end
    end
    table.sort(entries, function(a, b) return a.name < b.name end)
    return entries
end

-- 列任意 dav:// 目录（不缓存）
function M.list_at(url)
    local c, err = M.cfg()
    if not c then return nil, err end
    local target = M.http(tostring(url):gsub("/+$", "")) .. "/"
    local entries, perr = propfind(c, target)
    if not entries then return nil, perr end
    if #entries == 0 then return nil, "目录里没有音频文件：" .. target end
    return entries
end

-- 列根目录（Depth: 1，平铺）；结果缓存到磁盘，LIST_TTL 秒内复用
local list_cache = nil

function M.list(force)
    local c = M.cfg()
    if not c then return nil, "缺 WebDAV 配置" end
    if list_cache and not force then return list_cache end
    local path = CACHE .. "/list.txt"
    if not force then
        local st = shell("stat -c %Y " .. path .. " 2>/dev/null")
        local mtime = tonumber((st:gsub("%s+$", "")))
        if mtime and (os.time() - mtime) < LIST_TTL then
            local f = io.open(path, "r")
            if f then
                local entries = {}
                for line in f:lines() do
                    local href, name = line:match("^(%S+)\t(.+)$")
                    if href then entries[#entries + 1] = { href = href, name = name } end
                end
                f:close()
                if #entries > 0 then
                    list_cache = entries
                    return entries
                end
            end
        end
    end
    local entries, perr = propfind(c, c.base .. urlenc(c.root) .. "/")
    if not entries then return nil, perr end
    if #entries == 0 then
        return nil, "曲库为空或 PROPFIND 没解析出音频（检查 WEBDAV_MUSIC）"
    end
    os.execute("mkdir -p " .. CACHE)
    local f = io.open(path, "w")
    if f then
        for _, e in ipairs(entries) do f:write(e.href, "\t", e.name, "\n") end
        f:close()
    end
    list_cache = entries
    return entries
end

local function norm(s)
    s = tostring(s):lower()
    s = s:gsub("[%s%-_%(%)%[%]%.·,，、]", "")
    return s
end

-- 关键词匹配曲名（多关键词用空格分隔，全部命中才算）
function M.search(kw)
    local entries, err = M.list()
    if not entries then return nil, err end
    local words = {}
    for w in tostring(kw or ""):gmatch("%S+") do words[#words + 1] = norm(w) end
    if #words == 0 then return entries end
    local hits = {}
    for _, e in ipairs(entries) do
        local n = norm((e.name:gsub("%.[%w]+$", "")))
        local ok = true
        for _, w in ipairs(words) do
            if not n:find(w, 1, true) then ok = false break end
        end
        if ok then hits[#hits + 1] = e end
    end
    return hits
end

local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

-- 按需下载到本地缓存；href 可为绝对 URL 或相对 base 的路径
function M.fetch(href)
    local c = M.cfg()
    if not c then return nil, "缺 WebDAV 配置" end
    local url = tostring(href)
    if not url:match("^%a+://") then url = c.base .. url end
    return M.fetch_url(url)
end

-- 下载任意（已 http(s) 化的）URL 到本地缓存；已存在则复用
function M.fetch_url(url)
    local c, cerr = M.cfg()
    if not c then return nil, cerr end
    url = M.http(tostring(url))
    local ext = (url:match("%.([%w]+)$") or "bin"):lower()
    os.execute("mkdir -p " .. CACHE)
    local dest = string.format("%s/%s.%s", CACHE, hash(url), ext)
    local f = io.open(dest, "rb")
    if f then
        local size = f:seek("end")
        f:close()
        if size and size > 4096 then return dest end
    end
    local tmp = dest .. ".part"
    local ok, err = request(url, c.auth, { "Accept: */*" }, nil, 600, tmp)
    if not ok then return nil, "下载失败: " .. tostring(err) end
    os.rename(tmp, dest)
    return dest
end

return M
