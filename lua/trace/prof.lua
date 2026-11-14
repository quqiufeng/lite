-- 进程内追踪账本（零依赖、零子进程）：lite 自己的每个功能做了多少、慢在哪、错几次。
-- 与 lua/trace/engine.lua 分工明确：
--   engine = 内核/机器侧（perf_event_open + 探针 + 火焰图），看「CPU/系统在干什么」
--   prof   = 进程内功能侧（工具/API/记忆/serve/插件 hook），看「lite 的哪块慢」
-- 两者都不需要 root 才能读（prof 甚至不需要 root 才能采）。
--
-- 设计纪律：
--   * O(1) 记账，任何异常都静默：追踪不能反过来把功能搞坏。
--   * 默认开启，`LITE_PROF=0` 或 prof.enable(false) 关闭；关闭时几乎零成本。
--   * 只存聚合（count/err/total/max/min/bytes）+ 有界 ring + 有界 reservoir 样本，
--     不无限增长，长跑也不会吃内存。
--
-- 用法：
--   local prof = require("trace.prof")
--   local out = prof.span("memory.recall", function() return self:recall(q) end)
--   prof.count("api.retry")
--   prof.hist("api.ttfb_ms", 183)
--   prof.report()         -- 文本（按 total 降序）
--   prof.report_json()    -- 表，便于 /prompt 返回或落盘
--   prof.reset()
--
-- 读的地方：helper/trace.lua action=prof（同进程直接拿表）；
-- 手工：`./tools/run.sh --once --json "..."` 够不着进程内状态，需走 helper。

local M = {}

-- ── 单调时钟：优先 clock_gettime(CLOCK_MONOTONIC)，退化到 os.time()*1000 ──
local now_ms
do
    local ok, ffi = pcall(require, "ffi")
    if ok then
        pcall(ffi.cdef, [[
            typedef long time_t;
            struct lite_prof_ts { time_t tv_sec; long tv_nsec; };
            int clock_gettime(int clk_id, struct lite_prof_ts *tp);
        ]])
        local ts = ffi.new("struct lite_prof_ts")
        local fn = pcall(function() return ffi.C.clock_gettime end) and ffi.C.clock_gettime or nil
        if fn then
            now_ms = function()
                if fn(1, ts) == 0 then           -- CLOCK_MONOTONIC
                    return tonumber(ts.tv_sec) * 1000 + tonumber(ts.tv_nsec) / 1e6
                end
                return os.time() * 1000
            end
        end
    end
    if not now_ms then
        now_ms = function() return os.time() * 1000 end
    end
end
M.now_ms = now_ms

-- ── 开关 ──
local disabled = os.getenv("LITE_PROF") == "0"
function M.enabled() return not disabled end
function M.enable(on) disabled = not on end

-- ── 账本 ──
-- 上限按「能不能据此下结论」定，不是随手拍的：
--   avg/min/max/count 走 total/count 累加，**不经 reservoir，永远精确**——
--   别指望调 SAMPLE_MAX 改善均值（容易反着猜，实测 4 轮误差恒为 0.00%）。
--   SAMPLE_MAX 只决定 p50/p99 的精度。实测（n=21000，5% 巨尾 + 25% 慢 + 70% 快的三峰负载,
--   60 次重复，与全量排序算的真 p99 比）：256 → 中位 1.31% / p95 3.06% / max 5.06%；
--   1024 → 中位 0.66% / p95 1.39% / max 1.48%。即 1024 把 p99 误差砍半——
--   要判「p99 有没有变」得 ≥1024，256 在 ±5% 里分不清 3% 的改善。
--   代价：每个 span 名最多多 768 个 number，几十个名字合计数万，可忽略。
--   RING_MAX 是 ring 容量，dump 的 recent 全量导出（以前只导 20 条，492 条白存）。
local RING_MAX = 512
local SAMPLE_MAX = 1024

local agg = {}        -- name -> { count, err, total, max, min, bytes, samples[], nsamp }
local counters = {}   -- name -> number
local hists = {}      -- name -> { samples[], n, max }
local ring = {}       -- 最近事件
local ring_n = 0

local function ensure(name)
    local e = agg[name]
    if not e then
        e = { count = 0, err = 0, total = 0, max = 0, min = math.huge, bytes = 0,
              samples = {}, nsamp = 0 }
        agg[name] = e
    end
    return e
end

function M.record(name, ms, ok, bytes)
    if disabled then return end
    name = tostring(name)
    ms = tonumber(ms) or 0
    if ms < 0 then ms = 0 end
    local e = ensure(name)
    e.count = e.count + 1
    e.total = e.total + ms
    if ms > e.max then e.max = ms end
    if ms < e.min then e.min = ms end
    if bytes then e.bytes = e.bytes + (tonumber(bytes) or 0) end
    if not ok then e.err = e.err + 1 end
    if e.nsamp < SAMPLE_MAX then
        e.nsamp = e.nsamp + 1
        e.samples[e.nsamp] = ms
    else
        local i = math.random(e.nsamp)
        if i <= SAMPLE_MAX then e.samples[i] = ms end
    end
    ring_n = ring_n + 1
    local slot = (ring_n - 1) % RING_MAX + 1
    ring[slot] = { ts = os.time(), name = name, ms = ms, ok = ok and true or false,
                   bytes = bytes }
end

function M.count(name, n)
    if disabled then return end
    name = tostring(name)
    counters[name] = (counters[name] or 0) + (tonumber(n) or 1)
end

function M.hist(name, v)
    if disabled then return end
    name = tostring(name)
    v = tonumber(v) or 0
    local h = hists[name]
    if not h then h = { samples = {}, n = 0, max = 0 }; hists[name] = h end
    h.n = h.n + 1
    if v > h.max then h.max = v end
    if h.n <= SAMPLE_MAX then
        h.samples[h.n] = v
    else
        local i = math.random(h.n)
        if i <= SAMPLE_MAX then h.samples[i] = v end
    end
end

-- 包一段执行：计时 + ok/err + 输出字节，异常照原样抛（不吞）。
-- opts.bytes 可以是 number，也可以是 fn(result) -> number（按结果算字节）。
function M.span(name, fn, opts)
    if disabled then return fn() end
    local t0 = now_ms()
    local ok, a, b = pcall(fn)
    local dt = now_ms() - t0
    local nb
    if ok and opts then
        if type(opts.bytes) == "function" then
            local bok, v = pcall(opts.bytes, a)
            if bok then nb = v end
        elseif opts.bytes then
            nb = opts.bytes
        end
    end
    M.record(name, dt, ok, nb)
    if not ok then error(a, 0) end
    return a, b
end

local function pct(samples, n, p)
    if n == 0 then return 0 end
    local t = {}
    for i = 1, n do t[i] = samples[i] end
    table.sort(t)
    local i = math.max(1, math.min(n, math.ceil(p * n)))
    return t[i]
end

local function fmt_ms(ms)
    if ms >= 1000 then return string.format("%.2fs", ms / 1000) end
    if ms >= 10 then return string.format("%.0fms", ms) end
    if ms >= 1 then return string.format("%.1fms", ms) end
    return string.format("%.0fµs", ms * 1000)
end
M.fmt_ms = fmt_ms

function M.report()
    if disabled then return "prof disabled (LITE_PROF=0)" end
    local rows = {}
    for name, e in pairs(agg) do
        rows[#rows + 1] = { name = name, e = e }
    end
    table.sort(rows, function(a, b)
        if a.e.total ~= b.e.total then return a.e.total > b.e.total end
        return a.name < b.name
    end)
    local lines = {}
    local total_ms, total_err = 0, 0
    for _, r in ipairs(rows) do
        total_ms = total_ms + r.e.total
        total_err = total_err + r.e.err
    end
    lines[#lines + 1] = string.format("prof: %d span kinds, %d calls, %d errors, %s total",
        #rows, ring_n, total_err, fmt_ms(total_ms))
    lines[#lines + 1] = string.format("%-28s %8s %5s %9s %9s %9s %9s %9s",
        "name", "count", "err", "total", "avg", "p50", "p99", "max")
    for _, r in ipairs(rows) do
        local e = r.e
        lines[#lines + 1] = string.format("%-28s %8d %5d %9s %9s %9s %9s %9s",
            r.name, e.count, e.err, fmt_ms(e.total), fmt_ms(e.total / math.max(e.count, 1)),
            fmt_ms(pct(e.samples, e.nsamp, 0.50)), fmt_ms(pct(e.samples, e.nsamp, 0.99)),
            fmt_ms(e.max))
    end
    local cn = {}
    for name in pairs(counters) do cn[#cn + 1] = name end
    if #cn > 0 then
        table.sort(cn)
        lines[#lines + 1] = "counters:"
        for _, name in ipairs(cn) do
            lines[#lines + 1] = string.format("  %-24s %d", name, counters[name])
        end
    end
    local hn = {}
    for name in pairs(hists) do hn[#hn + 1] = name end
    if #hn > 0 then
        table.sort(hn)
        lines[#lines + 1] = "histograms:"
        for _, name in ipairs(hn) do
            local h = hists[name]
            lines[#lines + 1] = string.format("  %-24s n=%d p50=%s p99=%s max=%s",
                name, h.n, fmt_ms(pct(h.samples, math.min(h.n, SAMPLE_MAX), 0.50)),
                fmt_ms(pct(h.samples, math.min(h.n, SAMPLE_MAX), 0.99)), fmt_ms(h.max))
        end
    end
    return table.concat(lines, "\n")
end

function M.report_json()
    local spans = {}
    for name, e in pairs(agg) do
        spans[#spans + 1] = {
            name = name, count = e.count, err = e.err,
            total_ms = e.total, avg_ms = e.total / math.max(e.count, 1),
            min_ms = (e.min == math.huge) and 0 or e.min, max_ms = e.max,
            p50_ms = pct(e.samples, e.nsamp, 0.50),
            p99_ms = pct(e.samples, e.nsamp, 0.99),
            bytes = e.bytes,
        }
    end
    table.sort(spans, function(a, b) return a.total_ms > b.total_ms end)
    local c = {}
    for k, v in pairs(counters) do c[k] = v end
    local h = {}
    for k, v in pairs(hists) do
        h[k] = { n = v.n, max = v.max, p50 = pct(v.samples, math.min(v.n, SAMPLE_MAX), 0.50),
                 p99 = pct(v.samples, math.min(v.n, SAMPLE_MAX), 0.99) }
    end
    -- recent 是「最近发生了什么」的原始序列：ring 里存满了 RING_MAX 条，就全部导出。
    -- 以前硬编码 ring_n-19 只给 20 条，采样不足，看 dump 会把「窗口里没发生」误读成「没埋点」。
    local recent = {}
    for i = math.max(1, ring_n - RING_MAX + 1), ring_n do
        local e = ring[(i - 1) % RING_MAX + 1]
        if e then recent[#recent + 1] = e end
    end
    return { spans = spans, counters = c, histograms = h, recent = recent, events = ring_n }
end

function M.reset()
    agg, counters, hists, ring = {}, {}, {}, {}
    ring_n = 0
end

-- ── 落盘 / 读回 ─────────────────────────────────────────────────────────
-- 为什么需要：`--once`/serve 的进程一退，进程内账本就没了，事后只能看
-- 会话 JSONL 里零散的 usage。落一份快照到 <memory_dir>/prof.json，
-- 让「上次那一轮到底慢在哪」在进程外也能查（helper/trace action=prof 会读它）。
-- 写法：tmp + rename，写坏了也不会留下半个 JSON。
function M.dump(path)
    if disabled then return false, "prof disabled" end
    if ring_n == 0 then return false, "nothing recorded" end
    local ok, cjson = pcall(require, "cjson")
    if not ok then return false, "no cjson" end
    local snap = M.report_json()
    snap.ts = os.time()
    snap.pid = tonumber(os.getenv("LITE_PID")) or nil
    local body_ok, body = pcall(cjson.encode, snap)
    if not body_ok then return false, body end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false, "cannot write " .. tmp end
    f:write(body)
    f:close()
    local rok, rerr = os.rename(tmp, path)
    if not rok then return false, tostring(rerr) end
    return true, #body
end

function M.load(path)
    local ok, cjson = pcall(require, "cjson")
    if not ok then return nil, "no cjson" end
    local f = io.open(path, "r")
    if not f then return nil, "no such file: " .. tostring(path) end
    local body = f:read("*a")
    f:close()
    if not body or body == "" then return nil, "empty file" end
    local dok, data = pcall(cjson.decode, body)
    if not dok then return nil, "bad json: " .. tostring(data) end
    return data
end

-- 一行摘要：塞进状态栏/日志用，不打印整张表。
function M.summary_line()
    if disabled then return "prof disabled" end
    local calls, errs, total = ring_n, 0, 0
    local worst, worst_ms = nil, -1
    for name, e in pairs(agg) do
        errs = errs + e.err
        total = total + e.total
        if e.total > worst_ms then worst, worst_ms = name, e.total end
    end
    return string.format("prof: %d calls, %d err, %s total, top=%s %s",
        calls, errs, fmt_ms(total), tostring(worst), fmt_ms(math.max(worst_ms, 0)))
end

return M
