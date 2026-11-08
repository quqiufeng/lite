local cjson = require("cjson")

local function fmt(args)
    local req = {
        pattern = args.pattern,
        path = args.path or ".",
        ext = args.ext,
        ignore_case = (args.ignore_case ~= false),
        fixed = (args.fixed == true),
        max_hits = args.max_hits or 200,
        per_file = args.per_file or 20,
        threads = args.threads or 4,
    }
    return cjson.encode(req)
end

local function render(res)
    local ok, d = pcall(cjson.decode, res)
    if not ok or type(d) ~= "table" then return "cgrep: bad helper output: " .. tostring(res):sub(1, 300) end
    if not d.ok then
        return string.format("cgrep: %s\nrequired: pattern (string)\n", tostring(d.error))
    end
    local out = { string.format("%d hit(s) in %d file(s), scanned %d, %d ms%s",
        d.hits and #d.hits or 0, d.files or 0, d.scanned or 0, d.ms or 0,
        d.truncated and " (truncated, raise max_hits)" or "") }
    local seen, n, total = {}, 0, 0
    for _, h in ipairs(d.hits or {}) do
        local key = h.file .. ":" .. h.line
        if not seen[key] then          -- C 端一行多命中会重复，这里按 file:line 去重
            seen[key] = true
            local line = string.format("%s:%d: %s", h.file, h.line, (h.text or ""):gsub("^%s+", ""))
            total = total + #line + 1
            if total > 8000 then out[#out + 1] = "... (output capped)"; break end
            out[#out + 1] = line
            n = n + 1
        end
    end
    if n == 0 then out[#out + 1] = "(no match)" end
    return table.concat(out, "\n")
end

return {
    run = function(args, env)
        local res, err = env.call("cgrep", fmt(args))
        if not res then error("cgrep: native helper failed: " .. tostring(err), 0) end
        return render(res)
    end,
}
