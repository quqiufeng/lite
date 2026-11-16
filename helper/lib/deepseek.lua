-- DeepSeek Search/Fetch 共用底座：鉴权、POST、重试、错误码翻译、JSON。
-- 放在 helper/lib/ 下（插件扫描只平铺看 helper/*.lua，不看子目录）。
local http = require("core.http")
local cjson = require("cjson")

local M = {}

-- 只有成功（HTTP 200 且有结果）才计费，所以重试是安全的：
-- 408 / 429 / 5xx 与 curl 自身失败都重试，4xx 不改请求、不重试。
local RETRY_STATUS = { [408] = true, [429] = true }

local ffi = require("ffi")
pcall(ffi.cdef, "int usleep(unsigned int usec);")
local function sleep_ms(ms)
    if ms > 0 then pcall(function() ffi.C.usleep(ms * 1000) end) end
end

-- key 只在环境变量或 .env 里，不能进仓库/命令行。os.getenv 看不到 .env（lite 不 setenv，
-- key 进了 environ 就等于 `ps e` 可见），所以缺失时回退 core.config.env（按 cwd 向上 +
-- LITE_ENV_FILE + ~/.config/lite/.env 合并）。
-- getter 是插件桥（env.getenv）注入的权威读取器：只要装了它，就完全走它——测试夹具
-- 靠这个能表达「这个键就是没有」，否则真 .env 里的 key 会把夹具盖掉。
local getter
function M.set_getenv(fn) getter = fn end

local function getenv(k)
    if getter then return getter(k) end
    local v = os.getenv(k)
    if v and v ~= "" then return v end
    local ok, cfg = pcall(require, "core.config")
    if ok and cfg and cfg.env then return cfg.env(k) end
    return v
end

function M.base()
    local b = getenv("LITE_DEEPSEEK_BASE")
    if b and b ~= "" then return (b:gsub("/+$", "")) end
    return "https://api.deepseek.com"
end

function M.key()
    local key = getenv("DEEPSEEK_API_KEY")
    if not key or key == "" then key = getenv("LITE_DEEPSEEK_API_KEY") end
    if not key or key == "" then
        return nil, "error: DeepSeek Search/Fetch need DEEPSEEK_API_KEY "
            .. "(put DEEPSEEK_API_KEY=sk-... in ~/.config/lite/.env or the "
            .. "workspace .env, or export it / LITE_DEEPSEEK_API_KEY in the "
            .. "shell that starts lite). Nothing else is required."
    end
    return key
end

local function status_error(status, body)
    local hint = {
        [400] = "the request was rejected; check the arguments (query is 1-128 chars; url must be http(s) with a host).",
        [401] = "your API key is invalid; re-export DEEPSEEK_API_KEY.",
        [402] = "account balance is insufficient; top up before retrying.",
        [403] = "fetch was refused by a safety policy for that URL; try another page or domain.",
        [404] = "that URL has no usable body (empty, blocked, or JS-only); try another page.",
        [408] = "reading the body timed out; retry, or pick a lighter page.",
        [413] = "the page is too large for Fetch; try another source.",
        [429] = "rate limit exceeded (Search 100 QPS / Fetch 25 QPS per account); back off and retry.",
    }
    local why = hint[status]
    if not why and status >= 500 then why = "the service had a server-side error; retry later." end
    if not why then why = "unexpected status." end
    return string.format("error: DeepSeek API returned HTTP %d: %s", status, why)
end

-- POST /v1/tools/<path>；返回 decoded table 或 nil, errstring。
function M.request(path, payload)
    local key, kerr = M.key()
    if not key then return nil, kerr end

    local ok, body = pcall(cjson.encode, payload)
    if not ok then return nil, "error: cannot encode request payload as JSON" end

    local url = M.base() .. path
    local headers = {
        "Authorization: Bearer " .. key,
        "Content-Type: application/json",
        "Accept: application/json",
    }

    local last_err
    local delays = { 0, 400, 1000 }
    for attempt = 1, 3 do
        sleep_ms(delays[attempt])
        local rc, status, resp = http.post_stream(url, headers, body)
        if rc ~= 0 then
            last_err = string.format("error: curl failed (%s); POST %s; retrying does not change the request.",
                tostring(resp), url)
        elseif status == 200 then
            local dok, data = pcall(cjson.decode, resp or "")
            if not dok or type(data) ~= "table" then
                return nil, "error: DeepSeek API returned 200 with non-JSON body: "
                    .. tostring(resp):sub(1, 300)
            end
            return data
        elseif RETRY_STATUS[status] or status >= 500 then
            last_err = status_error(status, resp)
        else
            -- 400/401/402/403/404/413：请求或账号问题，重试无意义。
            return nil, status_error(status, resp)
        end
    end
    return nil, (last_err or "error: request failed") .. " [gave up after 3 attempts]"
end

function M.decode_ok() end

return M
