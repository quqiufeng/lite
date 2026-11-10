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
    -- 用绝对游标切行，只在末尾留未完成的一行；避免每行都 sub 一次导致的
    -- O(lines²) 拷贝（一个 chunk 里塞几十行时非常明显）。
    local data = p.buf .. chunk
    local start = 1

    while true do
        local nl = data:find("\n", start, true)
        if not nl then break end
        local line = data:sub(start, nl - 1)
        start = nl + 1
        line = line:gsub("\r$", "")

        if line == "data: [DONE]" then
            p.done = true
            start = #data + 1
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
    p.buf = data:sub(start)
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
    -- finish 是本地诊断信息（判断输出是否被 max_tokens 截断），build_request
    -- 的 strip_local_fields 会把它剔掉，不会发给 provider。
    if type(p.finish) == "string" and p.finish ~= "" then msg.finish = p.finish end
    return msg
end

-- 合法历史（绝大多数）直接复用原表，不做逐条深拷贝；只有确实发现非法
-- 字节时才走完整清洗。合法性检查用 Text.sanitize 的零分配快速路径。
local function clean_messages(messages)
    messages = messages or {}
    local fixed, any = 0, false
    for _, m in ipairs(messages) do
        local content = m.content
        if type(content) == "string" then
            local _, f = Text.sanitize(content)
            if f > 0 then fixed = fixed + f; any = true end
        elseif type(content) == "table" then
            for _, part in ipairs(content) do
                if type(part) == "table" then
                    if part.type == "text" and type(part.text) == "string" then
                        local _, f = Text.sanitize(part.text)
                        if f > 0 then fixed = fixed + f; any = true end
                    end
                    if part.type == "image_url" and type(part.image_url) == "table"
                        and type(part.image_url.url) == "string" then
                        local s = Text.sanitize(part.image_url.url)
                        if s ~= part.image_url.url then any = true end
                    end
                end
            end
        end
        local tcs = m.tool_calls
        if type(tcs) == "table" then
            for _, tc in ipairs(tcs) do
                local fn = type(tc) == "table" and tc["function"] or nil
                if type(fn) == "table" then
                    if type(fn.name) == "string" then
                        local _, f = Text.sanitize(fn.name)
                        if f > 0 then fixed = fixed + f; any = true end
                    end
                    if type(fn.arguments) == "string" then
                        local _, f = Text.sanitize(fn.arguments)
                        if f > 0 then fixed = fixed + f; any = true end
                    end
                end
            end
        end
    end
    if not any then return messages, 0 end

    local out = {}
    for i, m in ipairs(messages) do
        local c = {}
        for k, v in pairs(m) do c[k] = v end
        if type(c.content) == "string" then
            c.content = (Text.sanitize(c.content))
        elseif type(c.content) == "table" then
            local parts = {}
            for k, part in ipairs(c.content) do
                if type(part) == "table" then
                    local p = {}
                    for kk, vv in pairs(part) do p[kk] = vv end
                    if p.type == "text" and type(p.text) == "string" then
                        p.text = (Text.sanitize(p.text))
                    end
                    if p.type == "image_url" and type(p.image_url) == "table" then
                        local u = {}
                        for kk, vv in pairs(p.image_url) do u[kk] = vv end
                        if type(u.url) == "string" then u.url = (Text.sanitize(u.url)) end
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
                    if type(f2.name) == "string" then f2.name = (Text.sanitize(f2.name)) end
                    if type(f2.arguments) == "string" then
                        f2.arguments = (Text.sanitize(f2.arguments))
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

-- provider 的 usage 是"它给才有"：include_usage 是对的，但网关改写、流被中断、
-- 有些兼容端点根本不返回最后一个 usage chunk，账本就会开天窗。本地其实一直握着
-- [埋点] usage 采集总入口：provider 是唯一同时看得到「发出去的 payload」和
-- 「收回来的回复」的地方，插件拿不到，所以 token 估算只能落在这里。
-- 下游链路：estimate_usage → opts.on_usage → agent.track_usage_day
--          → memory:add_usage_day（/agent/usage/day/<date>）→ helper/tokens.lua 读。
--
-- 两个便宜的数 —— 发出去的 payload 字节数、收回来的回复字节数 —— 按 DeepSeek 的
-- 口径（英文 ~0.3 token/字节，中文 ~0.6 token/字 ≈ 0.2 token/字节）折一下即可兜底。
-- 标记 estimated=true，别跟真实值混着当准确账看。
local function count_nonascii(s)
    local _, n = tostring(s or ""):gsub("[\128-\255]", "")
    return n
end

function M.estimate_tokens(bytes, nonascii)
    bytes = tonumber(bytes) or 0
    nonascii = tonumber(nonascii) or 0
    if nonascii > bytes then nonascii = bytes end
    -- DeepSeek 官方口径：1 个英文字符 ≈ 0.3 token，1 个中文字符 ≈ 0.6 token
    -- （https://api-docs.deepseek.com/zh-cn/quick_start/token_usage）。
    -- 中文 UTF-8 占 3 字节：3*0.3 - 3*0.1 = 0.6 token/字，正好对上；
    -- 纯 ASCII 时退化为 0.3/字符。实际用量以接口返回的 usage 为准，这里只是兜底。
    local t = 0.3 * bytes - 0.1 * nonascii
    if t < 1 and bytes > 0 then t = 1 end
    return math.floor(t + 0.5)
end

local function result_text(res)
    if type(res) ~= "table" then return "" end
    local parts = { tostring(res.content or "") }
    for _, t in ipairs(res.tool_calls or {}) do
        local f = type(t) == "table" and t["function"] or nil
        if type(f) == "table" then
            parts[#parts + 1] = tostring(f.name or "")
            parts[#parts + 1] = tostring(f.arguments or "")
        end
    end
    return table.concat(parts)
end

-- [埋点] usage 兜底估值：接口没回 usage 时用它，结果带 estimated=true。
function M.estimate_usage(payload, res)
    local pin = tostring(payload or "")
    local out = result_text(res)
    return {
        prompt = M.estimate_tokens(#pin, count_nonascii(pin)),
        completion = M.estimate_tokens(#out, count_nonascii(out)),
        prompt_bytes = #pin,
        completion_bytes = #out,
        estimated = true,
    }
end

-- 本地诊断字段（finish / 以下划线开头的键）不能出现在请求体里。只有极少数
-- 助手消息带它们，按需浅拷贝，其余历史原样复用，长会话不会因此变慢。
local function strip_local_fields(messages)
    local out, dirty = nil, false
    for i = 1, #messages do
        local m = messages[i]
        local extra = false
        for k in pairs(m) do
            if k == "finish" or (type(k) == "string" and k:sub(1, 1) == "_") then
                extra = true
                break
            end
        end
        if extra then
            if not dirty then
                out = {}
                for j = 1, i - 1 do out[j] = messages[j] end
                dirty = true
            end
            local c = {}
            for k, v in pairs(m) do
                if k ~= "finish" and not (type(k) == "string" and k:sub(1, 1) == "_") then
                    c[k] = v
                end
            end
            out[i] = c
        elseif dirty then
            out[i] = m
        end
    end
    return out or messages
end

local function build_request(messages, tools, opts)
    if not opts.api_key or opts.api_key == "" then
        return nil, nil, nil, "missing DEEPSEEK_API_KEY"
    end

    local cleaned, fixed = clean_messages(strip_local_fields(messages))
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
        -- [埋点] 流式：真 usage 与兜底估值都从这一个上报口出去（且只出去一次）。
        local usage_seen = false
        local function u(usage)
            if type(usage) == "table" then usage_seen = true end
            if opts.on_usage then opts.on_usage(usage) end
        end
        local rc, status, raw = http.post_stream(url, headers, payload, function(chunk)
            feed_parser(parser, chunk, d, r, u)
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

        if rc == 0 and status == 200 then
            local res = M.finish(parser)
            if not usage_seen then
                -- [埋点] 流式兜底：接口没给 usage，用 payload/回复字节数估一份补上。
                if opts.debug then opts.debug:log("usage_estimated", M.estimate_usage(payload, res)) end
                u(M.estimate_usage(payload, res))
            end
            return res
        end
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
    local seen = { hit = false }
    local req, rerr = http.request(multi, url, headers, payload, function(chunk)
        feed_parser(parser, chunk, on_delta, on_reasoning, function(usage)
            if type(usage) == "table" then seen.hit = true end
            if opts.on_usage then opts.on_usage(usage) end
        end)
    end)
    if not req then return nil, rerr end
    req.parser = parser
    req.debug = opts.debug
    req.payload = payload
    req.opts = opts
    req.seen = seen
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
    local res = M.finish(req.parser)
    if not (req.seen and req.seen.hit) then
        -- [埋点] 非流式（TUI multi 路径）兜底：同上，没有 usage 就估一份。
        local est = M.estimate_usage(req.payload, res)
        if req.debug then req.debug:log("usage_estimated", est) end
        if req.opts and type(req.opts.on_usage) == "function" then req.opts.on_usage(est) end
    end
    return res
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
