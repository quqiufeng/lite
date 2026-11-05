-- DeepSeek（OpenAI 兼容）流式 provider + SSE 解析。
local cjson = require("cjson")
local http = require("core.http")

local M = {}

function M.new_parser()
    return {
        buf = "",
        content = {},
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
                if d.content and d.content ~= "" then
                    p.content[#p.content + 1] = d.content
                    events[#events + 1] = { type = "content", text = d.content }
                end
                if d.tool_calls then
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
                        if tc.id then acc.id = tc.id end
                        if tc.type then acc.type = tc.type end
                        local fn = tc["function"]
                        if fn then
                            if fn.name then
                                acc["function"].name = acc["function"].name .. fn.name
                            end
                            if fn.arguments then
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

function M.stream(messages, tools, opts, on_delta)
    if not opts.api_key or opts.api_key == "" then
        return nil, "missing DEEPSEEK_API_KEY"
    end

    local body = {
        model = opts.model or "deepseek-chat",
        messages = messages,
        stream = true,
        temperature = opts.temperature or 0,
    }
    if tools and #tools > 0 then body.tools = tools end

    local ok, payload = pcall(cjson.encode, body)
    if not ok then return nil, "encode request failed: " .. tostring(payload) end

    local base = (opts.base_url or "https://api.deepseek.com"):gsub("/+$", "")
    local headers = {
        "Content-Type: application/json",
        "Authorization: Bearer " .. opts.api_key,
        "Accept: text/event-stream",
    }

    local parser = M.new_parser()
    local rc, status, raw = http.post_stream(base .. "/chat/completions",
        headers, payload, function(chunk)
            local events = M.feed(parser, chunk)
            for _, ev in ipairs(events) do
                if ev.type == "content" and on_delta then on_delta(ev.text) end
            end
        end)

    if rc ~= 0 then
        return nil, "http error: " .. tostring(raw)
    end
    if status ~= 200 then
        return nil, string.format("HTTP %d: %s", status, tostring(raw):sub(1, 800))
    end
    return M.finish(parser)
end

return M
