-- DeepSeek Fetch 插件：POST /v1/tools/fetch，把一个 URL 变成 Markdown 正文。
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

local MAX_CONTENT = 20000  -- 回给模型的正文上限，超出截断并说明

return {
    schema = {
        name = "fetch",
        description = "Fetch a web page through the DeepSeek Fetch API and get its readable body "
            .. "as Markdown (title + content). Use it instead of raw HTTP when you need page "
            .. "content for a URL found by `search`.",
        parameters = {
            type = "object",
            properties = {
                url = {
                    type = "string",
                    description = "Absolute http(s) URL including host, max 8192 chars. "
                        .. "Credentials in the URL are rejected.",
                },
            },
            required = { "url" },
        },
    },

    run = function(args, env)
        args = args or {}
        local url = args.url
        if type(url) ~= "string" or url == "" then
            return "error: fetch needs a `url` string (absolute http/https, max 8192 chars). required: url"
        end
        if #url > 8192 then
            return string.format("error: `url` is %d chars; the API caps it at 8192.", #url)
        end
        local scheme, host = url:match("^(https?)://([^/]+)")
        if not scheme or not host or host == "" then
            return string.format("error: `%s` is not an absolute http(s) URL with a host "
                .. "(example: https://example.com/a/b). required: url", url:sub(1, 120))
        end
        if host:find("@", 1, true) then
            return "error: the API rejects URLs that carry credentials (user:pass@host). "
                .. "Strip them; required: url"
        end

        local ok, data_or_err, err = pcall(function()
            return lib(env).request("/v1/tools/fetch", { url = url })
        end)
        if not ok then
            return "error: fetch plugin crashed: " .. tostring(data_or_err)
        end
        if not data_or_err then return err end

        local title = data_or_err.title
        local content = data_or_err.content
        if type(content) ~= "string" or content == "" then
            return string.format("error: Fetch returned no body for %s (HTTP 200 but empty; "
                .. "the page is probably JS-only or blocked). Try another source.", url)
        end

        local out = {
            string.format("# %s", (type(title) == "string" and title ~= "") and title or url),
            "url: " .. url,
            string.format("chars: %d", #content),
            "",
            content,
        }
        local body = table.concat(out, "\n")
        if #body > MAX_CONTENT then
            body = body:sub(1, MAX_CONTENT)
                .. string.format("\n... [truncated; page had %d chars. Ask for a section instead of the whole page]", #content)
        end
        return body
    end,
}
