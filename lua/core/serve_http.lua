-- serve 的 HTTP 前端：两个端点，够任何客户端直接用。
--   GET  /health           探活（不鉴权，不回工作区信息）
--   POST /prompt           {"prompt":"..."} 直接发给 lite 执行，跑完回 {"ok":true,"text":"..."}
-- 纯函数模块（解析/构造响应），网络读写留在 core/serve.lua。
local cjson = require("cjson")

local M = {}

M.VERSION = "0.1.0"

local METHODS = {
    GET = true, HEAD = true, POST = true, PUT = true,
    PATCH = true, DELETE = true, OPTIONS = true,
}

local function is_method(s)
    return METHODS[s] == true
end

-- 首包分流：attach 客户端发的是 JSONL（`{"type":...}`），HTTP 客户端发 `GET / HTTP/1.1`。
-- 只认「方法名 + 空格」，所以 `{` 开头的帧永远走 JSONL，两边不会误判。
function M.looks_like_http(s)
    if not s or s == "" then return false end
    local m = s:match("^(%u+)%s")
    return m ~= nil and is_method(m)
end

-- 解析一个 HTTP 请求。返回 req；未收全返回 nil,"more"；非法返回 nil,"bad: ..."。
function M.parse(buf)
    if not buf or buf == "" then return nil, "more" end
    local head_end, sep = buf:find("\r\n\r\n", 1, true), 4
    if not head_end then
        head_end, sep = buf:find("\n\n", 1, true), 2
    end
    if not head_end then
        if #buf > 65536 then return nil, "bad: header too large" end
        return nil, "more"
    end
    local head = buf:sub(1, head_end - 1)
    local rest = buf:sub(head_end + sep)

    local lines = {}
    for line in (head .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("\r$", ""))
    end
    local method, target, ver = lines[1]:match("^(%u+)%s+(%S+)%s+HTTP/(%d%.%d)$")
    if not method then return nil, "bad: malformed request line" end

    local headers = {}
    for i = 2, #lines do
        local k, v = lines[i]:match("^([^:]+):%s*(.-)%s*$")
        if k then headers[k:lower()] = v end
    end

    local te = (headers["transfer-encoding"] or ""):lower()
    if te:find("chunked", 1, true) then
        return nil, "bad: chunked request body unsupported"
    end
    local len = tonumber(headers["content-length"] or "0") or 0
    if len > 8 * 1024 * 1024 then return nil, "bad: body too large" end
    if #rest < len then return nil, "more" end

    local path, query = target:match("^([^?]*)%??(.*)$")
    if not path or path == "" then path = "/" end
    -- 只解码 path 里的百分号，够用（路由全是 ASCII）。
    path = path:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)

    return {
        method = method,
        path = path,
        query = query or "",
        version = ver,
        headers = headers,
        body = rest:sub(1, len),
    }
end

function M.status_text(code)
    local t = {
        [200] = "OK", [201] = "Created", [204] = "No Content",
        [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden",
        [404] = "Not Found", [405] = "Method Not Allowed",
        [408] = "Request Timeout", [411] = "Length Required",
        [413] = "Payload Too Large", [429] = "Too Many Requests",
        [500] = "Internal Server Error", [502] = "Bad Gateway",
        [503] = "Service Unavailable", [504] = "Gateway Timeout",
    }
    return t[code] or "OK"
end

local CORS = {
    ["Access-Control-Allow-Origin"] = "*",
    ["Access-Control-Allow-Headers"] = "content-type",
    ["Access-Control-Allow-Methods"] = "GET,POST,OPTIONS",
    ["Access-Control-Max-Age"] = "86400",
}

local function header_block(headers)
    local order = {}
    for k in pairs(headers) do order[#order + 1] = k end
    table.sort(order)
    local out = {}
    for _, k in ipairs(order) do
        out[#out + 1] = k .. ": " .. tostring(headers[k]) .. "\r\n"
    end
    return table.concat(out)
end

-- 一律 Connection: close：客户端拿到就关，省掉 keep-alive 状态机。
function M.response(status, headers, body)
    body = body or ""
    local h = {
        ["Content-Type"] = "application/json; charset=utf-8",
        ["Connection"] = "close",
        ["Content-Length"] = #body,
        ["Cache-Control"] = "no-store",
    }
    for k, v in pairs(CORS) do h[k] = v end
    for k, v in pairs(headers or {}) do h[k] = v end
    h["Content-Length"] = #body
    return string.format("HTTP/1.1 %d %s\r\n", status, M.status_text(status))
        .. header_block(h) .. "\r\n" .. body
end

function M.json(status, obj)
    local ok, s = pcall(cjson.encode, obj)
    if not ok then s = '{"ok":false,"error":"encode failed"}' end
    return M.response(status, { ["Content-Type"] = "application/json; charset=utf-8" }, s)
end

function M.error(status, message, code)
    return M.json(status, {
        ok = false,
        error = { message = tostring(message), code = code or "error" },
    })
end

function M.not_found(path)
    return M.error(404, "no such endpoint: " .. tostring(path)
        .. " (only GET /health and POST /prompt)", "not_found")
end

-- 请求体 → 要办的事。JSON `{"prompt":"..."}` 优先，也收 `{"text":...}`；
-- 裸文本（非 JSON 对象）原样当指令，方便 `curl -d '看下磁盘'`。
function M.prompt_of(body)
    body = tostring(body or "")
    if body == "" then return nil, "empty body (send {\"prompt\":\"...\"})" end
    local ok, obj = pcall(cjson.decode, body)
    if ok and type(obj) == "table" then
        for _, k in ipairs({ "prompt", "text", "input", "query" }) do
            local v = obj[k]
            if type(v) == "string" and v:match("%S") then return v end
        end
        return nil, "prompt must be a non-empty string"
    end
    if body:match("%S") then return body end
    return nil, "empty body (send {\"prompt\":\"...\"})"
end

return M
