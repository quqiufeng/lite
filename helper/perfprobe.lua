local cjson = require("cjson")

local function req_of(args)
    local argv = args.argv
    if (type(argv) ~= "table" or #argv == 0) and args.command and args.command ~= "" then
        argv = {}
        for w in tostring(args.command):gmatch("%S+") do argv[#argv + 1] = w end
    end
    if type(argv) ~= "table" or #argv == 0 then
        return nil, "need argv (array) or command (string), e.g. argv={\"/bin/prog\",\"arg\"}"
    end
    return {
        argv = argv,
        freq = args.freq or 99,
        seconds = args.seconds or 600,
        top = args.top or 20,
        show_output = args.show_output == true,
    }
end

local function bar(pct)                     -- 0..100 -> 20 格
    local n = math.floor((pct or 0) / 5 + 0.5)
    if n < 0 then n = 0 end
    if n > 20 then n = 20 end
    return string.rep("#", n) .. string.rep(".", 20 - n)
end

local function render(res)
    local ok, d = pcall(cjson.decode, res)
    if not ok or type(d) ~= "table" then
        return "perfprobe: bad helper output: " .. tostring(res):sub(1, 300)
    end
    -- cjson 把 0 解成 Lua 的 0（真值），所以不能写 `if not d.ok`
    if d.ok ~= 1 then
        local tag = d.stage and (" [" .. tostring(d.stage) .. "]") or ""
        return string.format("perfprobe:%s %s\n  required: argv=[\"prog\",\"arg1\"] | command=\"prog arg1\"", tag, tostring(d.error))
    end
    local out = {}
    local head = string.format(
        "%d samples (%.0f Hz, lost %d) | target exit %d | wall %.2fs | %d mappings",
        d.samples or 0, d.freq or 0, d.lost or 0, d.exit or 0, d.seconds or 0, d.maps or 0)
    if (d.signal or 0) ~= 0 then head = head .. string.format(" | killed by signal %d", d.signal) end
    if (d.dropped or 0) > 0 then head = head .. string.format(" | %d records unusable", d.dropped) end
    out[#out + 1] = head
    if d.timed_out == 1 then
        out[#out + 1] = "  note: seconds budget hit -> target killed, profile covers the window only"
    end
    if (d.samples or 0) == 0 then
        if d.hint and d.hint ~= cjson.null then
            out[#out + 1] = "  no samples: " .. tostring(d.hint)
        else
            out[#out + 1] = "  no samples: target too short or perf blocked (paranoid > 2 needs root)"
        end
        return table.concat(out, "\n")
    end
    if (d.maps_truncated or 0) == 1 then
        out[#out + 1] = "  note: mapping table hit its cap -> symbol attribution is partial"
    end
    if (d.truncated or 0) == 1 then
        out[#out + 1] = "  note: sample pool hit its cap -> later samples were dropped"
    end
    out[#out + 1] = "  -- by object --"
    for _, o in ipairs(d.objects or {}) do
        out[#out + 1] = string.format("  %-28s %5.1f%% %s", (o.name or "?"):sub(1, 28), o.pct or 0, bar(o.pct))
    end
    out[#out + 1] = "  -- leaf symbols --"
    for _, s in ipairs(d.symbols or {}) do
        out[#out + 1] = string.format("  %6.2f%%  %-34s %s", s.pct or 0, (s.symbol or "?"):sub(1, 34), (s.object or ""):sub(1, 24))
    end
    if (d.jit_pct or 0) > 0 then
        out[#out + 1] = string.format("  note: %.1f%% in /tmp/perf-<pid>.map (JIT frames, named by that table)", d.jit_pct)
    end
    if (d.anon_pct or 0) > 0 then
        out[#out + 1] = string.format("  note: %.1f%% in anonymous exec memory (JIT/AOT code has no ELF symbols)", d.anon_pct)
    end
    if (d.kernel_excluded or 0) == 1 then
        out[#out + 1] = "  note: kernel samples excluded (perf_event_paranoid)"
    end
    return table.concat(out, "\n")
end

return {
    run = function(args, env)
        local req, err = req_of(args or {})
        if not req then return "perfprobe: " .. err end
        local res, cerr = env.call("perfprobe", cjson.encode(req))
        if not res then error("perfprobe: native helper failed: " .. tostring(cerr), 0) end
        return render(res)
    end,
}
