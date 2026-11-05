-- DeepSeek（OpenAI 兼容）流式 provider + SSE 解析。
local cjson = require("cjson")
local http = require("core.http")

local M = {}

function M.new_parser()
    return {
        buf = "",
        content = {},
        reasoning = {},
        tool_calls = {},
        tool_max = 0,
        finish = nil,
        done = false,
    }
end

-- 喂入任意片段，返回事件列表：{type="content", text=...}
function M.feed(p, chunk)
    local events = {}
    p.buf = p.buf .. chunk

    while true do
        local nl = p.buf:find("\n", 1, true)
        if not nl then break end
        local line = p.buf:sub(1, nl - 1)
        p.buf = p.buf:sub(nl + 1)
        line = line:gsub("\r$", "")

        if line == "data: [DONE]" then
            p.done = true
            break
        end

        local payload = line:match("^data:%s*(.*)$")
        if payload and payload ~= "" then
            local ok, obj = pcall(cjson.decode, payload)
            if ok and type(obj) == "table" and obj.choices and obj.choices[1] then
                local ch = obj.choices[1]
                local d = ch.delta or {}
                if type(d.reasoning_content) == "string" and d.reasoning_content ~= "" then
                    p.reasoning[#p.reasoning + 1] = d.reasoning_content
                    events[#events + 1] = { type = "reasoning", text = d.reasoning_content }
                end
                -- 思考阶段 content 可能为 JSON null（cjson 解成 lightuserdata）。
                if type(d.content) == "string" and d.content ~= "" then
                    p.content[#p.content + 1] = d.content
                    events[#events + 1] = { type = "content", text = d.content }
                end
                if type(d.tool_calls) == "table" then
                    for _, tc in ipairs(d.tool_calls) do
                        local idx = (tonumber(tc.index) or p.tool_max) + 1
                        if idx > p.tool_max then p.tool_max = idx end
                        local acc = p.tool_calls[idx]
                        if not acc then
                            acc = {
                                id = "",
                                type = "function",
                                ["function"] = { name = "", arguments = "" },
                            }
                            p.tool_calls[idx] = acc
                        end
                        if type(tc.id) == "string" then acc.id = tc.id end
                        if type(tc.type) == "string" then acc.type = tc.type end
                        local fn = tc["function"]
                        if type(fn) == "table" then
                            if type(fn.name) == "string" then
                                acc["function"].name = acc["function"].name .. fn.name
                            end
                            if type(fn.arguments) == "string" then
                                acc["function"].arguments =
                                    acc["function"].arguments .. fn.arguments
                            end
                        end
                    end
                end
                if ch.finish_reason then p.finish = ch.finish_reason end
            end
        end
    end
    return events
end

function M.finish(p)
    local msg = { role = "assistant", content = table.concat(p.content) }
    if p.tool_max > 0 then
        local tcs = {}
        for i = 1, p.tool_max do
            if p.tool_calls[i] then tcs[#tcs + 1] = p.tool_calls[i] end
        end
        if #tcs > 0 then msg.tool_calls = tcs end
    end
    return msg
end

local function build_request(messages, tools, opts)
    if not opts.api_key or opts.api_key == "" then
        return nil, nil, nil, "missing DEEPSEEK_API_KEY"
    end

    local body = {
        model = opts.model or "deepseek-flash",
        messages = messages,
        stream = true,
        temperature = opts.temperature or 0,
    }
    if tools and #tools > 0 then body.tools = tools end
    if opts.thinking then body.thinking = { type = "enabled" } end
    if opts.reasoning_effort and opts.reasoning_effort ~= "" then
        body.reasoning_effort = opts.reasoning_effort
    end

    local ok, payload = pcall(cjson.encode, body)
    if not ok then return nil, nil, nil, "encode request failed: " .. tostring(payload) end

    local base = (opts.base_url or "https://api.deepseek.com"):gsub("/+$", "")
    local headers = {
        "Content-Type: application/json",
        "Authorization: Bearer " .. opts.api_key,
        "Accept: text/event-stream",
    }
    return base .. "/chat/completions", headers, payload
end

local function feed_parser(parser, chunk, on_delta, on_reasoning)
    local events = M.feed(parser, chunk)
    for _, ev in ipairs(events) do
        if ev.type == "content" and on_delta then
            on_delta(ev.text)
        elseif ev.type == "reasoning" and on_reasoning then
            on_reasoning(ev.text)
        end
    end
end

function M.retryable(err)
    if not err then return false end
    err = tostring(err)
    if err:find("HTTP 429", 1, true) then return true end
    if err:match("^HTTP 5%d%d") then return true end
    if err:find("http error", 1, true) then return true end
    return false
end

-- 阻塞请求（--once / 单测）；429/5xx/网络错误重试。
function M.stream(messages, tools, opts, on_delta, on_reasoning)
    local max_retries = tonumber(opts.max_retries) or 2
    local emitted = false
    local function d(t)
        emitted = true
        if on_delta then on_delta(t) end
    end
    local function r(t)
        emitted = true
        if on_reasoning then on_reasoning(t) end
    end

    local last_err
    for attempt = 0, max_retries do
        local url, headers, payload, err = build_request(messages, tools, opts)
        if not url then return nil, err end

        local parser = M.new_parser()
        local rc, status, raw = http.post_stream(url, headers, payload, function(chunk)
            feed_parser(parser, chunk, d, r)
        end)

        if rc == 0 and status == 200 then return M.finish(parser) end
        if rc ~= 0 then
            last_err = "http error: " .. tostring(raw)
        else
            last_err = string.format("HTTP %d: %s", status, tostring(raw):sub(1, 800))
        end

        if emitted or attempt >= max_retries or not M.retryable(last_err) then
            return nil, last_err
        end
        os.execute("sleep " .. tostring(0.5 * (attempt + 1)))
    end
    return nil, last_err
end

-- 非阻塞请求（TUI）：返回 req，完成后用 finish_request(req) 取结果。
function M.start(multi, messages, tools, opts, on_delta, on_reasoning)
    if not multi then return nil, "missing multi handle" end
    local url, headers, payload, err = build_request(messages, tools, opts)
    if not url then return nil, err end

    local parser = M.new_parser()
    local req, rerr = http.request(multi, url, headers, payload, function(chunk)
        feed_parser(parser, chunk, on_delta, on_reasoning)
    end)
    if not req then return nil, rerr end
    req.parser = parser
    return req
end

function M.finish_request(req)
    if req.rc ~= 0 then
        return nil, "http error: " .. tostring(req.err or req.rc)
    end
    if req.status ~= 200 then
        return nil, string.format("HTTP %d: %s", req.status, tostring(req.body or ""):sub(1, 800))
    end
    return M.finish(req.parser)
end

-- 协程入口：yield {kind="http", req=...}；可重试时重新发起请求。
function M.stream_async(messages, tools, opts, on_delta, on_reasoning)
    local max_retries = tonumber(opts.max_retries) or 2
    local emitted = false
    local function d(t)
        emitted = true
        if on_delta then on_delta(t) end
    end
    local function r(t)
        emitted = true
        if on_reasoning then on_reasoning(t) end
    end

    local last_err
    for attempt = 0, max_retries do
        local req, err = M.start(opts.multi, messages, tools, opts, d, r)
        if not req then return nil, err end
        local assistant, err2 = coroutine.yield({ kind = "http", req = req })
        if assistant then return assistant end
        last_err = err2
        if emitted or attempt >= max_retries or not M.retryable(err2) then
            return nil, err2
        end
    end
    return nil, last_err
end

return M
