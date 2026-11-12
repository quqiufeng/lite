-- 记忆导入/导出：JSONL 每行一条 KV，`{"k":..., "v":..., "ttl":0}`。
--
-- 为什么是 JSONL 而不是直接搬 mem.bin：
--   1) 二进制里带指针/偏移（MYCA 布局），跨机器、跨版本都不保证能读；
--   2) 需求本身是"只挑想要的记忆"，整份复制做不到，JSONL 删行就行；
--   3) 纯文本可 grep、可 git diff、可人工审阅改内容。
-- 注意别写进 sessions/*.jsonl：那里是会话回放（{role,content}），
-- session.for_cwd 会 ls 该目录并把每一行当消息读（见 session.lua:71）。
--
-- ttl 一律导出 0（永久）：cache.h 只有 set/expire/touch，没有"剩余寿命"查询接口，
-- 真实 TTL 读不回来；而值得搬的 fact 本来就是永久，working/short 跨机早已过期。
local cjson = require("cjson")
local cache = require("ffi.cache")

local M = {}

-- 默认只导知识层。会话 msg/* 属于回放（有 sessions/*.jsonl 兜底），
-- /agent/working 是 5 分钟的运行态，两者搬过去都没意义。
M.DEFAULT_PREFIXES = { "/agent/knowledge/" }

-- 把 KV 里的原始 JSON 文本嵌进外层对象，保持一行合法 JSON。
local function embed(raw)
    if type(raw) ~= "string" then return cjson.encode(raw) end
    local ok = pcall(cjson.decode, raw)
    if ok then return raw end
    return cjson.encode(raw)
end

-- 导出为行数组（已按 key 排序，便于 diff）。
-- opts.prefixes    前缀列表，默认 DEFAULT_PREFIXES
-- opts.max_results 单前缀扫描上限，默认 100000
function M.export_lines(memory, opts)
    opts = opts or {}
    local prefixes = opts.prefixes
    if not prefixes or #prefixes == 0 then prefixes = M.DEFAULT_PREFIXES end
    local limit = opts.max_results or 100000

    local rows, seen = {}, {}
    for _, prefix in ipairs(prefixes) do
        for _, r in ipairs(memory:search_prefix(prefix, { max_results = limit })) do
            local key = tostring(r.key)
            if not seen[key] then
                seen[key] = true
                rows[#rows + 1] = { k = key, raw = r.value }
            end
        end
    end
    table.sort(rows, function(a, b) return a.k < b.k end)

    local lines = {}
    for i, row in ipairs(rows) do
        local line = string.format('{"k":%s,"v":%s,"ttl":0}',
            cjson.encode(row.k), embed(row.raw))
        -- cjson 会把 "/" 转义成 "\\/"；去掉只为可读/可 grep（JSON 语义不变，
        -- 真反斜杠是 "\\\\"，替换后仍是合法转义，已用 roundtrip 验过）
        lines[i] = line:gsub("\\/", "/")
    end
    return lines, rows
end

-- 解析一行；非法行返回 nil, reason（导入时跳过并计数，不中断）。
function M.parse_line(line)
    line = (line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" or line:sub(1, 1) == "#" then return nil, "blank" end
    local ok, obj = pcall(cjson.decode, line)
    if not ok then return nil, "bad json" end
    if type(obj) ~= "table" then return nil, "not object" end
    -- 兼容旧写法：{"key":..,"value":..}
    local k = obj.k or obj.key
    if type(k) ~= "string" or k == "" then return nil, "no key" end
    local v = obj.v
    if v == nil then v = obj.value end
    if v == nil then return nil, "no value" end
    local text
    if type(v) == "string" then
        -- 值本身是一段 JSON 文本就原样写回，否则当普通字符串存（等价 put 的编码）
        local dok, dv = pcall(cjson.decode, v)
        text = dok and cjson.encode(dv) or cjson.encode(v)
    else
        text = cjson.encode(v)
    end
    -- 手写时不带命名空间（memorize 里写的是路径）→ 默认落到知识层，
    -- 否则裸 key 存在根命名空间，recall/导出都扫不到，等于导了个寂寞
    if k:sub(1, 1) ~= "/" then
        k = "/agent/knowledge/" .. k:gsub("^/+", "")
    end
    return { key = k, text = text, ttl = tonumber(obj.ttl) or 0 }
end

-- 导入。opts.dry_run 只统计不写；返回 report。
function M.import_file(memory, path, opts)
    opts = opts or {}
    local f, err = io.open(path, "r")
    if not f then return nil, tostring(err) end

    local rep = { total = 0, added = 0, updated = 0, skipped = 0, failed = 0,
                  dry_run = opts.dry_run and true or false, keys = {}, errors = {} }
    local n = 0
    for line in f:lines() do
        n = n + 1
        local item, why = M.parse_line(line)
        if not item then
            if why ~= "blank" then
                rep.skipped = rep.skipped + 1
                if #rep.errors < 10 then
                    rep.errors[#rep.errors + 1] = string.format("line %d: %s", n, why)
                end
            end
        else
            rep.total = rep.total + 1
            local exists = cache.get(memory.h, item.key) ~= nil
            if opts.dry_run then
                if exists then rep.updated = rep.updated + 1 else rep.added = rep.added + 1 end
            else
                local rc = cache.set(memory.h, item.key, item.text, item.ttl)
                if rc == 0 then
                    if exists then rep.updated = rep.updated + 1 else rep.added = rep.added + 1 end
                else
                    rep.failed = rep.failed + 1
                    if #rep.errors < 10 then
                        rep.errors[#rep.errors + 1] = string.format("line %d: set rc=%s", n, tostring(rc))
                    end
                end
            end
            if #rep.keys < 20 then rep.keys[#rep.keys + 1] = item.key end
        end
    end
    f:close()
    if not opts.dry_run then cache.sync(memory.h) end
    return rep
end

return M
