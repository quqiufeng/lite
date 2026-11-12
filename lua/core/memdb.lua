-- 群体记忆：一个目录、一个文件，所有 agent 都往同一个文件里 append。
--
-- 为什么不是"一个 mem.bin + 多写者"：
--   mem.bin 是 mmap 二进制 + mem.lock 独占写锁，第二个进程只能降级只读（memory.lua）。
--   要让 N 个 agent 同时写同一份 mmap，得自己做跨进程写锁和扩容重映射，
--   那是给"每次写都要改同一块内存"付的代价，而记忆写入本来就是追加语义。
--
-- 为什么是"单文件 + 只 append"：
--   1) O_APPEND 下 seek+write 不可分割，单行 < PIPE_BUF 的写入不会交织，不用锁；
--   2) 每行自带 o（origin）字段，谁写的写在行里，不需要靠文件名区分；
--   3) 一行坏了（写一半、进程被杀）只丢那一行，scan 跳过即可；
--   4) 放在同一个 NFS/WebDAV 目录里就是跨机共享——不需要谁来当 master；
--   5) 可 grep、可 git diff、可人工改。
--
-- NFS 例外：跨网络文件系统的 O_APPEND 不保证原子。真跑在多机 NFS 上时设
-- LITE_MEMDB_SPLIT=1，退回"每 agent 一个 <origin>.jsonl"（单机写本地盘不需要）。
--
-- 冗余是设计选择，不是缺陷：同一条事实被三个 agent 各写一遍很正常，
-- 人类的知识库本来也充满重复。去重、加权、判断可信度是**读的人**的事，
-- 这里只在读取时做两件不花钱的事：完全相同的 (key,text) 只出一条、按查询词打分排序。
local cjson = require("cjson")

local M = {}

-- 所有 key 都从这走，读的时候一眼能认出"这不是本机亲眼所见"
M.NS = "/shared/"

-- 老版本默认放在 <prefix>/share/lite/memdb，也就是**安装目录内部**。
-- tools/install.sh 升级时 rm -rf "$APP"，于是每次 release 都把共享库清空一次
-- （本机实测：09:08 写入的 7 条，09:09 装完就没了）。数据目录必须在安装目录之外。
local LEGACY_DIR = "/.local/share/lite/memdb"

-- 老路径有东西、新路径还没有时，搬一次；失败不影响使用（只是读不到旧条目）。
-- 注意优先整目录 rename，只有目标已存在才退化成逐文件搬 —— 直接 `mv from to`
-- 在 to 已存在时会搬成 to/memdb/，多套一层目录（踩过）。
local function migrate(from, to)
    local f = io.open(from .. "/mem.shared.jsonl", "r")
    if not f then return end
    f:close()
    local to_f = io.open(to .. "/mem.shared.jsonl", "r")
    if to_f then to_f:close() return end   -- 新路径已有数据，不覆盖

    local parent = to:match("^(.*)/[^/]+$")
    if parent then os.execute(string.format("mkdir -p %q", parent)) end
    if os.rename(from, to) then return end -- 目录整体搬走
    os.execute(string.format("mkdir -p %q && mv -f %q/*.jsonl %q/ 2>/dev/null; rmdir %q 2>/dev/null",
        to, from, to, from))
end

local function default_dir()
    local env = os.getenv("LITE_MEMDB_DIR")
    if env and env ~= "" then return env end
    local mem = os.getenv("LITE_MEMORY_DIR")
    if mem and mem ~= "" then return mem .. "/../memdb" end
    local home = os.getenv("HOME") or "."
    -- 与安装目录（share/lite）平级，升级 rm -rf 不会碰到它
    local dir = home .. "/.local/share/lite-memdb"
    migrate(home .. LEGACY_DIR, dir)
    return dir
end

M.dir = default_dir

-- 共享库就一个文件。所有 agent 都 append 它——这才叫共享。
function M.file(opts)
    opts = opts or {}
    if opts.file and opts.file ~= "" then return opts.file end
    local env = os.getenv("LITE_MEMDB_FILE")
    if env and env ~= "" then return env end
    return (opts.dir or M.dir()) .. "/mem.shared.jsonl"
end

-- NFS 上 O_APPEND 不原子，允许退回每 agent 一个文件（默认关）。
local function split_mode()
    local v = os.getenv("LITE_MEMDB_SPLIT")
    return v == "1" or v == "true" or v == "yes"
end

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
    -- 默认所有人写同一个文件；split 模式（NFS）才各写各的
    local path = split_mode() and (dir .. "/" .. origin .. ".jsonl") or M.file(opts)

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
    local rows, files, seen_path = {}, {}, {}
    -- 主文件排第一（绝大多数内容都在这），再捞目录里其余的 jsonl
    -- （split 模式的 <origin>.jsonl、以及旧版本留下的按 agent 分文件，都能继续读）
    local main = M.file(opts)
    local function add(path)
        if path and not seen_path[path] then seen_path[path] = true files[#files + 1] = path end
    end
    add(main)
    local p = io.popen(string.format("ls -1 '%s'/*.jsonl 2>/dev/null", (dir:gsub("'", "'\\''"))))
    if p then
        for name in p:lines() do add(name) end
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
    return { dir = (opts and opts.dir) or M.dir(), file = M.file(opts),
             entries = #rows, by_origin = by_origin }
end

return M
