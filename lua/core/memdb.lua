-- 群体记忆：所有 agent 往同一个目录里追加，读取时自己挑。
--
-- 为什么不是"一个 mem.bin + 多写者"：
--   mem.bin 是 mmap 二进制 + mem.lock 独占写锁，第二个进程只能降级只读（memory.lua）。
--   要让 N 个 agent 同时写同一份 mmap，得自己做跨进程写锁和扩容重映射，
--   那是给"每次写都要改同一块内存"付的代价，而记忆写入本来就是追加语义。
--
-- 为什么是"每个 agent 一个 jsonl、只 append"：
--   1) O_APPEND 下单行 < PIPE_BUF 的 write 是原子的，不用锁、不用协调；
--   2) 一行坏了（写一半、进程被杀）只丢那一行，scan 跳过即可；
--   3) 放在同一个 NFS/WebDAV 目录里就是分布式——不需要谁来当 master；
--   4) 可 grep、可 git diff、可人工改。
--
-- 冗余是设计选择，不是缺陷：同一条事实被三个 agent 各写一遍很正常，
-- 人类的知识库本来也充满重复。去重、加权、判断可信度是**读的人**的事，
-- 这里只在读取时做两件不花钱的事：完全相同的 (key,text) 只出一条、按查询词打分排序。
local cjson = require("cjson")

local M = {}

-- 所有 key 都从这走，读的时候一眼能认出"这不是本机亲眼所见"
M.NS = "/shared/"

local function default_dir()
    local env = os.getenv("LITE_MEMDB_DIR")
    if env and env ~= "" then return env end
    local mem = os.getenv("LITE_MEMORY_DIR")
    if mem and mem ~= "" then return mem .. "/../memdb" end
    local home = os.getenv("HOME") or "."
    -- 放在 memory_dir 旁边：mem.bin 是私有脑，memdb/ 是公共告示板
    return home .. "/.local/share/lite/memdb"
end

M.dir = default_dir

-- 身份只用来分文件，不做权限也不参与合并：即使两个 agent 撞名，
-- 也只是共用一个文件继续 append，仍然不会互相覆盖。
function M.origin()
    local env = os.getenv("LITE_AGENT_NAME")
    if env and env ~= "" then return (env:gsub("[^%w%._%-]", "_")) end
    local host = os.getenv("HOSTNAME") or ""
    if host == "" then
        local f = io.open("/etc/hostname")
        if f then host = (f:read("*l") or ""):gsub("%s+", "") f:close() end
    end
    if host == "" then host = "agent" end
    local cwd = (os.getenv("LITE_CWD") or os.getenv("PWD") or "."):gsub("/+$", "")
    local base = cwd:match("([^/]+)$") or "root"
    return ((host .. "-" .. base):gsub("[^%w%._%-]", "_"))
end

local function ensure_dir(dir)
    os.execute(string.format("mkdir -p '%s'", (dir:gsub("'", "'\\''"))))
end

-- 写一条。失败只返回 nil, err，调用方决定要不要吵——记忆写丢了不该中断主流程。
-- rec: { key=, text=, tags=, cwd=, ts= }
function M.append(rec, opts)
    opts = opts or {}
    rec = rec or {}
    local text = rec.text
    if type(text) ~= "string" or text == "" then return nil, "empty text" end
    local key = tostring(rec.key or "")
    if key == "" then return nil, "empty key" end
    local dir = opts.dir or M.dir()
    ensure_dir(dir)
    local origin = (opts.origin or M.origin()):gsub("[^%w%._%-]", "_")
    local path = dir .. "/" .. origin .. ".jsonl"

    -- ts 允许写在 rec 里，也允许写在 opts 里（导入历史条目时方便）
    local row = { k = key, o = origin, ts = tonumber(rec.ts) or tonumber(opts.ts) or os.time(), v = text }
    if rec.tags and #rec.tags > 0 then row.tags = rec.tags end
    if rec.cwd then row.cwd = rec.cwd end
    local line = (cjson.encode(row):gsub("\\/", "/")) .. "\n"

    local f, err = io.open(path, "a")
    if not f then return nil, tostring(err) end
    local ok, werr = f:write(line)   -- 单次 write，O_APPEND 下不会和别的进程交织
    f:close()
    if not ok then return nil, tostring(werr) end
    return true, path
end

-- 逐行扫全库。坏行（半行写入、手滑）直接跳过，不中断——
-- 公共目录里可能有别人正在写的文件，读到半行是常态。
function M.scan(opts)
    opts = opts or {}
    local dir = opts.dir or M.dir()
    local rows, files = {}, {}
    local p = io.popen(string.format("ls -1 '%s'/*.jsonl 2>/dev/null", (dir:gsub("'", "'\\''"))))
    if p then
        for name in p:lines() do files[#files + 1] = name end
        p:close()
    end

    for _, path in ipairs(files) do
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do
                if line ~= "" then
                    local ok, obj = pcall(cjson.decode, line)
                    if ok and type(obj) == "table" and type(obj.k) == "string"
                        and type(obj.v) == "string" then
                        rows[#rows + 1] = { key = obj.k, text = obj.v, origin = obj.o,
                                            ts = tonumber(obj.ts) or 0, tags = obj.tags }
                    end
                end
            end
            f:close()
        end
    end
    return rows
end

-- 打分只要"能排序"就够：ASCII 词命中 + CJK bigram 命中，长文本归一化。
-- 不做 IDF、不做时间衰减——真要去重和排序，读的时候自己按需要再筛。
local function terms_of(q)
    local s = tostring(q or "")
    local terms, seen = {}, {}
    for w in s:lower():gmatch("[%w_%-]+") do
        if #w >= 2 and not seen[w] then seen[w] = true terms[#terms + 1] = w end
    end
    local chars, i = {}, 1
    while i <= #s do
        local b = s:byte(i)
        local n = b < 0x80 and 1 or (b < 0xE0 and 2 or (b < 0xF0 and 3 or 4))
        chars[#chars + 1] = s:sub(i, i + n - 1)
        i = i + n
    end
    for j = 1, #chars - 1 do
        local a, b = chars[j], chars[j + 1]
        if #a > 1 and #b > 1 then
            local t = a .. b
            if not seen[t] then seen[t] = true terms[#terms + 1] = t end
        end
    end
    return terms
end

-- 读并筛：query 为空就按时间倒序给最近的。
-- 返回 hits, total_scanned。
function M.search(query, limit, opts)
    opts = opts or {}
    limit = tonumber(limit) or 5
    local terms = terms_of(query)
    local rows = M.scan(opts)
    local seen, scored = {}, {}
    for _, r in ipairs(rows) do
        -- 同一条事实被多个 agent 抄过（key 常常不一样，正文一样）：
        -- 按正文去重、只留最早的那份，否则 prompt 里同一句话会排三四遍
        local sig = r.text:gsub("%s+", " "):lower()
        local prev = seen[sig]
        if prev then
            if r.ts > 0 and (prev.ts == 0 or r.ts < prev.ts) then
                prev.ts = r.ts prev.origin = r.origin
            end
        else
            local hay = (r.key .. " " .. r.text):lower()
            local hit = 0
            for _, t in ipairs(terms) do
                if hay:find(t, 1, true) then hit = hit + 1 end
            end
            if #terms == 0 or hit > 0 then
                -- 命中率为主，短文本同分时靠前（一条 20 字的结论比 2000 字日志更该进 prompt）。
                -- 空 query 全给 0 分，让下面的 ts 决定顺序 = 最近写的先看。
                r.score = #terms > 0 and (hit / #terms + 1 / (1 + #r.text / 200)) or 0
                seen[sig] = r
                scored[#scored + 1] = r
            end
        end
    end
    table.sort(scored, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.ts > b.ts
    end)
    local out = {}
    for i = 1, math.min(limit, #scored) do out[i] = scored[i] end
    return out, #rows
end

function M.stats(opts)
    local rows = M.scan(opts)
    local by_origin = {}
    for _, r in ipairs(rows) do
        local o = r.origin or "?"
        by_origin[o] = (by_origin[o] or 0) + 1
    end
    return { dir = (opts and opts.dir) or M.dir(), entries = #rows, by_origin = by_origin }
end

return M
