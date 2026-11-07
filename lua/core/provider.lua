-- DeepSeek（OpenAI 兼容）流式 provider + SSE 解析。
local cjson = require("cjson")
local http = require("core.http")
local Text = require("core.text")

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
        usage = nil,
    }
end

-- DeepSeek 在 stream_options.include_usage 下把用量放在**最后一个** chunk 里，
-- 那个 chunk 的 choices 是空数组，所以必须先于 choices 判断处理，否则整条被丢掉。
-- 三家参考实现都靠 usage 反推 chars→tokens 比例（Reasonix tokPerChar），没有本地
-- tokenizer 时这是唯一可靠的校准来源。
local function read_usage(obj)
    local u = obj and obj.usage
    if type(u) ~= "table" then return nil end
    local prompt = tonumber(u.prompt_tokens) or 0
    local details = u.prompt_tokens_details
    local hit = tonumber(u.prompt_cache_hit_tokens)
    if not hit and type(details) == "table" then
        hit = tonumber(details.cached_tokens)
    end
    hit = hit or 0
    if hit > prompt then hit = prompt end
    local miss = tonumber(u.prompt_cache_miss_tokens)
    if not miss then miss = prompt - hit end
    return {
        prompt = prompt,
        completion = tonumber(u.completion_tokens) or 0,
        total = tonumber(u.total_tokens) or prompt,
        cache_hit = hit,
        cache_miss = miss > 0 and miss or 0,
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
            if ok and type(obj) == "table" then
                local usage = read_usage(obj)
                if usage then
                    p.usage = usage
                    events[#events + 1] = { type = "usage", usage = usage }
                end
            end
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

local function clean_messages(messages)
    local out, fixed = {}, 0
    for i, m in ipairs(messages or {}) do
        local c = {}
        for k, v in pairs(m) do c[k] = v end
        if type(c.content) == "string" then
            local s, f = Text.sanitize(c.content)
            c.content = s
            fixed = fixed + f
        elseif type(c.content) == "table" then
            local parts = {}
            for k, part in ipairs(c.content) do
                if type(part) == "table" then
                    local p = {}
                    for kk, vv in pairs(part) do p[kk] = vv end
                    if p.type == "text" and type(p.text) == "string" then
                        local s, f = Text.sanitize(p.text)
                        p.text = s
                        fixed = fixed + f
                    end
                    if p.type == "image_url" and type(p.image_url) == "table" then
                        local u = {}
                        for kk, vv in pairs(p.image_url) do u[kk] = vv end
                        if type(u.url) == "string" then u.url = Text.sanitize(u.url) end
                        p.image_url = u
                    end
                    parts[k] = p
                else
                    parts[k] = part
                end
            end
            c.content = parts
        end
        if type(c.tool_calls) == "table" then
            local tcs = {}
            for j, tc in ipairs(c.tool_calls) do
                local t = {}
                for k, v in pairs(tc) do t[k] = v end
                local fn = tc["function"]
                if type(fn) == "table" then
                    local f2 = {}
                    for k, v in pairs(fn) do f2[k] = v end
                    if type(f2.name) == "string" then
                        local s, f = Text.sanitize(f2.name); f2.name = s; fixed = fixed + f
                    end
                    if type(f2.arguments) == "string" then
                        local s, f = Text.sanitize(f2.arguments); f2.arguments = s; fixed = fixed + f
                    end
                    t["function"] = f2
                end
                tcs[j] = t
            end
            c.tool_calls = tcs
        end
        out[i] = c
    end
    return out, fixed
end

-- OpenCode 的 outputLimit 思路：输出不能把剩余窗口吃穿。
function M.output_limit(opts)
    local max_out = tonumber(opts.max_output_tokens) or 0
    if max_out <= 0 then return nil end
    local window = tonumber(opts.context_window) or 0
    local input = tonumber(opts.input_tokens) or 0
    local reserve = tonumber(opts.reserve_tokens) or 0
    if window > 0 and input > 0 then
        local room = window - input - reserve
        if room < 1024 then room = 1024 end
        if room < max_out then max_out = room end
    end
    return math.floor(max_out)
end

function M.context_overflow(err)
    local s = tostring(err or ""):lower()
    return s:find("context length", 1, true) ~= nil
        or s:find("context_length", 1, true) ~= nil
        or s:find("maximum context", 1, true) ~= nil
        or s:find("too many tokens", 1, true) ~= nil
        or s:find("input is too long", 1, true) ~= nil
        or s:find("request too large", 1, true) ~= nil
        or (s:find("http 400", 1, true) ~= nil and s:find("token", 1, true) ~= nil)
        or (s:find("http 400", 1, true) ~= nil and s:find("context", 1, true) ~= nil)
end

local function build_request(messages, tools, opts)
    if not opts.api_key or opts.api_key == "" then
        return nil, nil, nil, "missing DEEPSEEK_API_KEY"
    end

    local cleaned, fixed = clean_messages(messages)
    local body = {
        model = opts.model or "deepseek-flash",
        messages = cleaned,
        stream = true,
        temperature = opts.temperature or 0,
    }
    if tools and #tools > 0 then body.tools = tools end
    -- 不带上 include_usage，DeepSeek 不会在流末尾返回 usage，命中率就无从观测。
    body.stream_options = { include_usage = true }
    local max_out = M.output_limit(opts)
    if max_out then body.max_tokens = max_out end
    if opts.thinking then body.thinking = { type = "enabled" } end
    if opts.reasoning_effort and opts.reasoning_effort ~= "" then
        body.reasoning_effort = opts.reasoning_effort
    end

    local ok, payload = pcall(cjson.encode, body)
    if not ok then return nil, nil, nil, "encode request failed: " .. tostring(payload) end

    if opts.debug then
        local images, image_bytes = 0, 0
        for _, m in ipairs(cleaned) do
            if type(m.content) == "table" then
                for _, p in ipairs(m.content) do
                    if type(p) == "table" and p.type == "image_url"
                        and type(p.image_url) == "table" then
                        images = images + 1
                        image_bytes = image_bytes + #tostring(p.image_url.url or "")
                    end
                end
            end
        end
        local system_prompt = ""
        for _, m in ipairs(cleaned) do
            if m.role == "system" then
                system_prompt = tostring(m.content or "")
                break
            end
        end
        opts.debug:log("request", {
            model = body.model,
            messages = #cleaned,
            system_prompt = system_prompt,
            system_prompt_bytes = #system_prompt,
            bytes = #payload,
            images = images,
            image_bytes = image_bytes,
            utf8_repaired = fixed,
        })
    end

    local base = (opts.base_url or "https://api.deepseek.com"):gsub("/+$", "")
    local headers = {
        "Content-Type: application/json",
        "Authorization: Bearer " .. opts.api_key,
        "Accept: text/event-stream",
    }
    return base .. "/chat/completions", headers, payload
end

local function feed_parser(parser, chunk, on_delta, on_reasoning, on_usage)
    local events = M.feed(parser, chunk)
    for _, ev in ipairs(events) do
        if ev.type == "content" and on_delta then
            on_delta(ev.text)
        elseif ev.type == "reasoning" and on_reasoning then
            on_reasoning(ev.text)
        elseif ev.type == "usage" and on_usage then
            on_usage(ev.usage)
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
            feed_parser(parser, chunk, d, r, opts.on_usage)
        end)

        if opts.debug then
            opts.debug:log("response", {
                attempt = attempt,
                status = status,
                rc = rc,
                body = tostring(raw or ""),
                body_bytes = #tostring(raw or ""),
                error = rc ~= 0 and tostring(raw) or nil,
            })
        end

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
        feed_parser(parser, chunk, on_delta, on_reasoning, opts.on_usage)
    end)
    if not req then return nil, rerr end
    req.parser = parser
    req.debug = opts.debug
    return req
end

function M.finish_request(req)
    if req.debug then
        req.debug:log("response", {
            status = req.status,
            rc = req.rc,
            body = tostring(req.body or ""),
            body_bytes = #tostring(req.body or ""),
            error = req.err,
        })
    end
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
