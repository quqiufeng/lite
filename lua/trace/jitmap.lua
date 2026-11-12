-- jitmap：把 LuaJIT 的 JIT trace 写成 Linux 的 /tmp/perf-<pid>.map。
--
-- 为什么需要它：JIT 出来的机器码在 /proc/pid/maps 里是**匿名可执行页**（没有模块名），
-- perf 只能显示 `[unknown]`/`0x7f..`。perf 认的旁路就是 perf map：
--     <起始地址(hex)> <长度(hex)> <名字>
-- lua/trace/engine.lua 的 perf_map()/sym_lookup() 早就读这份文件了（见 engine.lua:sym_lookup），
-- 一直缺的是**写**的一方 —— 这个模块补的就是那一半：于是 JIT 帧能落到 `xxx.lua:123 [tr7]`，
-- 和 C 帧（.symtab/dynsym）一起出现在同一张火焰图里。
--
-- 取址不靠猜：jit.util.tracemc(tr) 直接给 (mcode 字节串, 起始地址, loop 偏移)，
-- #mcode 就是长度；源码位置靠 jit.attach(…, "trace") 的 start 事件
-- （回调参数就是 func + pc，和 `luajit -jv` 打 "TRACE 1 start file:line" 同源）。
--
-- 已知边界：
--   * 只认 **JIT 编译过的** trace。纯解释执行的 Lua 帧在 native 栈上根本不存在
--     （解释器是一个 C 帧），perf 采到的只会是 libluajit 的 lj_* 符号 —— 那是「VM 在跑」，
--     不是「哪个函数在跑」。要 Lua 级归因用 jit.profile，不是 perf map 能解决的。
--   * start() 之后**新建**的 trace 才有源码行；之前已存在的 trace 只有 `[trN]` 兜底
--     （要全带行号就在进程启动最早期 start，或 main.lua 里用 LITE_TRACE_PERFMAP=1）。
--   * trace 被 flush 后 mcode 会被复用，所以 flush/start 事件都会整表重写。
--
-- 开销：只有 trace 事件发生时重写（一次几 KB 写 + 一次 ≤ maxtrace 的扫描），
-- 正常业务路径零成本；不 start 则连 jit.attach 都不挂。

local ffi = require("ffi")
local bit = require("bit")
local util = require("jit.util")

local ok_jit, jit = pcall(require, "jit")

local M = {}

-- ── 状态 ────────────────────────────────────────────────────────────────
local st = {
    on = false,
    pid = nil,
    path = nil,
    names = {},        -- trno -> "file.lua:123"（jit.attach start 事件填）
    writes = 0,
    errors = {},
    last_traces = 0,
    last_bytes = 0,
}

local SCAN_MAX = 8192      -- maxtrace 默认 1000/4096，给到 8192 够用且扫描仍很快
local SCAN_GAP = 512       -- 连续这么多个空槽且已越过最后一个活 trace 就收工

if not pcall(function() return ffi.C.getpid end) then
    pcall(ffi.cdef, "int getpid(void);")
end

local function getpid()
    local ok, v = pcall(function() return ffi.C.getpid() end)
    return ok and tonumber(v) or nil
end

local function default_path(pid)
    local env = os.getenv("LITE_PERFMAP_PATH")   -- 单测/容器里改路径用
    if env and env ~= "" then return (env:gsub("%%p", tostring(pid))) end
    return ("/tmp/perf-%d.map"):format(pid)
end

M.path = function(pid) return (st.on and st.path) or default_path(pid or getpid() or 0) end

-- ── 活 trace 枚举 ───────────────────────────────────────────────────────
-- 返回 { {tr=, addr=, size=, loop=}, ... }（addr 是 double，< 2^53 精确）
local function live_traces()
    local out, last, miss = {}, 0, 0
    for tr = 1, SCAN_MAX do
        local mc, addr, loop = util.tracemc(tr)
        if mc then
            if addr < 0 then addr = addr + 4294967296 end     -- 32 位系统上会返回负数
            out[#out + 1] = { tr = tr, addr = addr, size = #mc, loop = loop }
            last, miss = tr, 0
        elseif tr > last then
            miss = miss + 1
            if miss > SCAN_GAP then break end
        end
    end
    return out
end
M.live_traces = live_traces

local function label(tr)
    local loc = st.names[tr]
    if loc then return ("%s [tr%d]"):format(loc, tr) end
    return ("[tr%d]"):format(tr)
end

-- ── 写文件（整表重写 + 原子 rename）────────────────────────────────────
function M.write()
    if not st.on then return false, "jitmap 未启动" end
    local traces = live_traces()
    local lines, bytes = {}, 0
    for _, t in ipairs(traces) do
        local line = ("%x %x %s\n"):format(t.addr, t.size, label(t.tr))
        lines[#lines + 1] = line
        bytes = bytes + #line
    end
    local tmp = st.path .. ".tmp." .. tostring(getpid() or 0)
    local f, err = io.open(tmp, "wb")
    if not f then
        st.errors[#st.errors + 1] = ("open %s: %s"):format(tmp, tostring(err))
        return false, err
    end
    f:write(table.concat(lines))
    f:close()
    local okr, rerr = os.rename(tmp, st.path)
    if not okr then
        os.remove(tmp)
        st.errors[#st.errors + 1] = ("rename %s: %s"):format(st.path, tostring(rerr))
        return false, rerr
    end
    st.writes = st.writes + 1
    st.last_traces = #traces
    st.last_bytes = bytes
    return true, { traces = #traces, bytes = bytes }
end

-- ── 事件回调 ────────────────────────────────────────────────────────────
local function on_trace(what, tr, func, pc)
    if not st.on then return end
    if what == "start" then
        local loc
        if func then
            local ok, fi = pcall(util.funcinfo, func, pc)
            if ok and fi then loc = fi.loc or fi.short_src end
        end
        if tr then st.names[tr] = loc end
    elseif what == "flush" or what == "stop" or what == "abort" then
        -- flush 后 mcode 会被复用；stop/abort 不影响地址但顺手重写也无妨
        if what ~= "stop" then M.write() end
        return
    end
    -- start 事件：一个新 trace 刚落地，重写一次（几 KB，trace 创建是低频事件）
    pcall(M.write)
end

-- ── 对外接口 ────────────────────────────────────────────────────────────
-- opts = { path=..., quiet=true }
function M.start(opts)
    opts = opts or {}
    if st.on then
        if opts.path and opts.path ~= st.path then
            st.path = opts.path
            M.write()
        end
        return st
    end
    local pid = getpid()
    st.pid = pid
    st.path = opts.path or default_path(pid or 0)
    st.names = {}
    st.on = true
    local ok, err = pcall(function() jit.attach(on_trace, "trace") end)
    if not ok then
        st.on = false
        st.errors[#st.errors + 1] = ("jit.attach: %s"):format(tostring(err))
        return nil, "jit.attach 失败：" .. tostring(err)
    end
    local wok, werr = M.write()   -- 先把**已有** trace 落盘（它们的源码行拿不到，留 [trN]）
    if not wok and not opts.quiet then
        -- 写不了（比如 /tmp 只读）也要让调用方知道为什么图里还是 [unknown]
        st.errors[#st.errors + 1] = ("首次写盘失败：%s"):format(tostring(werr))
    end
    return st
end

function M.stop(remove_file)
    if not st.on then return st end
    st.on = false
    pcall(function() jit.attach(nil, "trace") end)   -- 老版本会报错，靠 st.on 兜底
    if remove_file ~= false then pcall(os.remove, st.path) end
    return st
end

function M.status()
    local s = {
        on = st.on, pid = st.pid or getpid(), path = st.path or default_path(getpid() or 0),
        traces = st.last_traces, bytes = st.last_bytes, writes = st.writes,
        named = 0, errors = st.errors,
    }
    for _ in pairs(st.names) do s.named = s.named + 1 end
    return s
end

function M.enabled() return st.on end

return M
