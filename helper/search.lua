-- DeepSeek Search 插件：POST /v1/tools/search。
-- 返回按 rerank_score 排序的结果；summary 是给模型读的 600-800 字摘要，snippet 是短句。
local shared

local function lib(env)
    if shared then return shared end
    local dir = (env and env.helper_dir) or "helper"
    local path = dir:gsub("/+$", "") .. "/lib/deepseek.lua"
    local chunk, err = loadfile(path)
    if not chunk then error("cannot load " .. path .. ": " .. tostring(err)) end
    shared = chunk()
    return shared
end

local MAX_TOTAL = 12000   -- 一次搜索回给模型的字符上限
local MAX_SUMMARY = 700   -- 单条 summary 上限

local function fmt_num(v)
    if type(v) == "number" then return string.format("%.2f", v) end
    return "?"
end

local function render(query, results)
    local lines = {
        string.format("%d result(s) for: %s", #results, query),
    }
    local used = #lines[1]
    for i, r in ipairs(results) do
        local head = string.format("%d. %s", i, tostring(r.title or "(untitled)"))
        local meta = { "url: " .. tostring(r.url or "") }
        if r.rerank_score ~= nil then meta[#meta + 1] = "score " .. fmt_num(r.rerank_score) end
        if r.authority ~= nil then meta[#meta + 1] = "authority " .. tostring(r.authority) end
        if r.date then meta[#meta + 1] = "date " .. tostring(r.date) end
        if r.site_name then meta[#meta + 1] = "site " .. tostring(r.site_name) end
        local body = r.summary
        if type(body) ~= "string" or body == "" then body = r.snippet end
        if type(body) ~= "string" or body == "" then body = r.content end
        body = body and body:sub(1, MAX_SUMMARY) or ""
        local block = head .. "\n  " .. table.concat(meta, " · ") .. "\n  " .. body:gsub("\n+", " ")
        if used + #block > MAX_TOTAL then
            lines[#lines + 1] = string.format("... (%d more result(s) omitted; raise count later or ask for a narrower query)", #results - i + 1)
            break
        end
        used = used + #block
        lines[#lines + 1] = block
    end
    return table.concat(lines, "\n")
end

return {
    schema = {
        name = "search",
        description = "Search the web through the DeepSeek Search API: reranked results with url, "
            .. "snippet, and a model-ready summary per hit. Use it for any outside-world facts, "
            .. "docs, or news; follow up with `fetch` when you need a full page.",
        parameters = {
            type = "object",
            properties = {
                query = {
                    type = "string",
                    description = "Search query, 1-128 chars. Supports site:example.com, -site:, "
                        .. "-word, \"exact phrase\", lang:zh,en, after:2025-01-01, before:2026-01-01.",
                },
                count = {
                    type = "integer",
                    description = "How many results to return (default 10, range 1-50).",
                },
                ori_question = {
                    type = "string",
                    description = "The original user question; helps reranking when `query` is a "
                        .. "rewritten or follow-up search.",
                },
                localization = {
                    type = "string",
                    description = "Two-letter market/region for results (e.g. CN, US). "
                        .. "Default: inferred from the server IP.",
                },
                need_content = {
                    type = "boolean",
                    description = "Also return each page's full content (slower, larger). "
                        .. "Default false; prefer `fetch` on the one URL you need.",
                },
            },
            required = { "query" },
        },
    },

    run = function(args, env)
        args = args or {}
        local query = args.query
        if type(query) ~= "string" or query:gsub("%s", "") == "" then
            return "error: search needs a non-empty `query` string (1-128 chars). "
                .. "required: query; optional: count, ori_question, localization, need_content"
        end
        if #query > 128 then
            return string.format("error: `query` is %d chars; the API caps it at 128. "
                .. "Shorten it (drop stopwords, keep site:/lang: filters).", #query)
        end
        local count = tonumber(args.count) or 10
        if count < 1 or count > 50 then
            return string.format("error: `count` is %d; the API allows 1-50 (default 10).", count)
        end

        local payload = { query = query, count = math.floor(count) }
        if type(args.ori_question) == "string" and args.ori_question ~= "" then
            payload.ori_question = args.ori_question
        end
        if type(args.localization) == "string" and args.localization ~= "" then
            payload.localization = args.localization
        end
        if args.need_content == true then payload.need_content = true end

        local ok, data_or_err, err = pcall(function() return lib(env).request("/v1/tools/search", payload) end)
        if not ok then
            return "error: search plugin crashed: " .. tostring(data_or_err)
        end
        if not data_or_err then return err end

        local results = data_or_err.results
        if type(results) ~= "table" and type(data_or_err) == "table" and data_or_err[1] then
            results = data_or_err
        end
        if type(results) ~= "table" or #results == 0 then
            return string.format("no results for: %s\n"
                .. "hint: broaden the query, drop site:/after: filters, or try English keywords.", query)
        end
        return render(query, results)
    end,
}
