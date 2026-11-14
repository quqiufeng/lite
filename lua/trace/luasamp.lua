-- luasamp.lua — Lua 侧栈采样（debug.sethook count 钩子），输出标准 folded（root-first）
--
-- 为什么需要它：engine.lua 的 perf 路（oncpu）只看得见 **JIT 编译后的帧 + C 帧**。
-- 热点落在 C 里（md4c/litehtml/gumbo 这类）时 Lua 侧几乎空白，火焰图上只有
-- `htmlParseDocument` 这类块。hook 路在**同进程内**用 debug 钩子取 file:line，
-- 解释执行的帧全在，正好补这半边。
--
-- 分工（别混用）：
--   perf 路  engine --mode oncpu --pid $PID   跨进程、带 C 帧、要 root、只见 JIT
--   hook 路  luasamp.lua target.lua           同进程、解释帧全、不要 root、慢 4~7%
-- 两条路的 folded 都能喂 `engine --folded-in` 出图，第 3 层不分叉。
--
-- [坑 1] **JIT 开着 count 钩子一次都不触发**（LuaJIT 的 count 钩子只在解释器里计数，
--   热循环编成 trace 后就不再回调）。所以本文件默认 `jit.off()+flush()`；否则纯 Lua
--   负载会和微基准一样 `samples=0`，最后出一张空图当结论。要不要关由 opts.keep_jit 决定。
--   关 JIT 的代价：采样期间的**绝对耗时**不代表生产环境（解释器比 trace 慢），
--   但**热点形状**是对的——要看真实耗时就用 perf 路对比。
--
-- [坑 2] n 别调小：钩子本身比被采代码贵，n=200 时采样器自己会变热点。4000 是实测甜点
--   （8s 负载 → 3000+ 样本、110+ 唯一行）。
--
-- 用法（进程外跑，别在 agent 里 inline 起长任务）：
--   ./tools/lite-lua lua/trace/luasamp.lua target.lua [--n 4000] [--out /tmp/x.folded]
--                                             [--depth 32] [--keep-jit] [--quiet]
--   ./tools/lite-lua lua/trace/engine.lua --mode folded --folded-in /tmp/x.folded \
--                                        --flame /tmp/flame.svg        # 出图
--
-- 作为库：
--   local s = require("trace.luasamp").start{ out = "/tmp/x.folded", n = 4000 }
--   ... 被测代码 ...
--   s:report()          -- stop 后：samples / unique_lines / stacks / out
--
-- 落盘 = Brendan Gregg 标准 folded：`root;...;leaf 次数`，一行一栈。
-- speedscope / flamegraph.pl / 本仓 engine --folded-in 都能直接吃。

local M = {}

local function getpid_num()
    local ok, ffi = pcall(require, "ffi")
    if ok then
        pcall(ffi.cdef, "int getpid(void);")
        return ffi.C.getpid()
    end
    return 0
end

local function selfsrc(s)
    -- 采样器自己的帧不能进栈（否则第一名永远是 luasamp.lua:N）
    return s == nil or s:find("luasamp.lua", 1, true) ~= nil
end

local function name_of(info)
    if info.what == "C" then return "[C] " .. (info.name or "?") end
    local src = (info.short_src or info.source or "?"):gsub("^@", "")
    return ("%s:%d"):format(src:gsub("^.*/([^/]+)$", "%1"), info.currentline or 0)
end

-- opts: n=指令数/采样(4000) depth=最大层数(32) out=输出路径 keep_jit=不关 JIT
function M.start(opts)
    opts = opts or {}
    local n = math.max(500, tonumber(opts.n) or 4000)
    local depth = math.max(2, tonumber(opts.depth) or 32)
    local out = opts.out or ("/tmp/lua-" .. getpid_num() .. ".folded")
    local acc, lines = {}, {}
    local samples, truncated = 0, 0

    local jit_off = false
    if not opts.keep_jit then
        local ok, jit = pcall(require, "jit")
        if ok then jit.off() jit.flush() jit_off = true end
    end

    local function hook()
        local frames, leaf = {}, nil
        for lvl = 2, depth + 1 do
            local ok, info = pcall(debug.getinfo, lvl, "Snl")
            if not ok or not info then break end          -- 到底了
            if lvl == depth + 1 then truncated = truncated + 1 break end
            if not selfsrc(info.short_src or info.source) then
                local nm = name_of(info)
                frames[#frames + 1] = nm                   -- leaf → root
                leaf = leaf or nm
            end
        end
        if #frames == 0 then return end                     -- 钩子落在采样器自己身上
        local rev = {}
        for i = #frames, 1, -1 do rev[#rev + 1] = frames[i] end   -- 反成 root;...;leaf
        -- [坑 3] run_file 用 pcall(chunk) 起目标，钩子栈的**根**因此永远带两层
        -- harness 帧：`[C] ?`（luajit main）+ `[C] pcall`（run_file 自己的 pcall）。
        -- 它们不是被测代码，会把火焰图最底层两根柱子变成噪声，还会让「最深 N 层」
        -- 平白多 2。目标自己调 pcall 时这两帧出现在**中间**（下面还有目标文件帧），
        -- 所以只剥根部的连续段是安全的。
        if not opts.keep_root then
            while #rev > 1 and (rev[1] == "[C] ?" or rev[1] == "[C] pcall") do
                table.remove(rev, 1)
            end
        end
        acc[table.concat(rev, ";")] = (acc[table.concat(rev, ";")] or 0) + 1
        lines[leaf] = true
        samples = samples + 1
    end

    debug.sethook(hook, "", n)

    local rec = { out = out, jit_off = jit_off, n = n, depth = depth }

    -- 停止采样并写盘；返回 rec 或 (nil, err)
    function rec.stop()
        debug.sethook()
        local arr = {}
        for k, v in pairs(acc) do arr[#arr + 1] = { stack = k, count = v } end
        table.sort(arr, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return a.stack < b.stack
        end)
        local f, err = io.open(out, "w")
        if not f then return nil, ("写不了 folded %s: %s"):format(tostring(out), tostring(err)) end
        for _, e in ipairs(arr) do f:write(e.stack, " ", e.count, "\n") end
        f:close()
        local nl = 0
        for _ in pairs(lines) do nl = nl + 1 end
        rec.samples, rec.unique_lines, rec.stacks = samples, nl, #arr
        rec.truncated, rec.folded = truncated, arr
        return rec
    end

    function rec:report()
        return ("hook  samples=%d 唯一行=%d 栈种类=%d 截断=%d jit=%s folded=%s")
            :format(self.samples or 0, self.unique_lines or 0, self.stacks or 0,
                    self.truncated or 0, self.jit_off and "off" or "on", self.out)
    end

    return rec
end

-- 在采样下跑一个脚本文件（目标脚本自己退出；要限时就外层 `timeout N`）
function M.run_file(path, opts)
    opts = opts or {}
    local rec, err = M.start(opts)
    if not rec then return nil, err end
    local chunk, why = loadfile(path)
    if not chunk then
        rec.stop()
        return nil, "loadfile 失败: " .. tostring(why)
    end
    local ok, e2 = pcall(chunk, unpack(opts.argv or {}))   -- LuaJIT 5.1：table.unpack 是 nil
    local r, werr = rec.stop()
    if not r then return nil, werr end
    r.ok, r.script_err = ok, (not ok) and tostring(e2) or nil
    r.path = path
    return r
end

-- ── CLI：luajit lua/trace/luasamp.lua target.lua [flags] ─────────────────────
local function cli(argv)
    local script, opts, rest = nil, {}, {}
    local i = 1
    while argv and argv[i] do
        local a = argv[i]
        local function val() i = i + 1 return argv[i] end
        if a == "--n" then opts.n = tonumber(val())
        elseif a == "--out" then opts.out = val()
        elseif a == "--depth" then opts.depth = tonumber(val())
        elseif a == "--keep-jit" then opts.keep_jit = true
        elseif a == "--quiet" then opts.quiet = true
        elseif a == "--" then
            for j = i + 1, #argv do rest[#rest + 1] = argv[j] end
            break
        elseif a:sub(1, 2) == "--" then
            io.stderr:write("[luasamp] 未知参数: " .. a .. "\n") os.exit(2)
        elseif not script then script = a
        else rest[#rest + 1] = a end
        i = i + 1
    end
    if not script then
        io.stderr:write("用法: luajit lua/trace/luasamp.lua <目标.lua> [--n 4000] " ..
                        "[--out /tmp/x.folded] [--depth 32] [--keep-jit] [--quiet]\n")
        os.exit(2)
    end
    opts.argv = rest
    local r, err = M.run_file(script, opts)
    if not r then io.stderr:write("[luasamp] " .. tostring(err) .. "\n") os.exit(3) end
    if not opts.quiet then
        io.stderr:write("[luasamp] " .. r:report() ..
            (r.script_err and ("  目标脚本报错: " .. r.script_err) or "") .. "\n")
    end
    if (r.samples or 0) == 0 then
        -- 契约：0 样本不算成功（空图当结论是踩过的坑）
        io.stderr:write("[luasamp] samples=0：钩子没挂上，或目标全是 JIT trace（试 --keep-jit 关掉看看）\n")
        os.exit(4)
    end
    print(r.out)
end

local self_path = arg and arg[0] or ""
if self_path:match("luasamp%.lua$") and arg[1] then cli(arg) end

return M
