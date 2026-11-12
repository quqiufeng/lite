-- trace（动态追踪）：perf_event_open + tracefs 探针，纯 LuaJIT，零 perf/bcc 依赖。
-- 实现 = lua/trace/{engine,render,svgpng}.lua —— 与 codesearch 同级：
-- 源码在仓库里、有单测、有文档（lua/trace/README.md），不是用完即弃的 helper 临时工。
--
-- ════════ 用法纪律（都是踩出来的，别当成可随手改的注释） ════════
--
-- [1] 权限是硬前提：engine 要 root 或 cap_perfmon（perf_event_open），
--     非 root 时本插件自动加 `sudo -n`；sudo 要密码就直接报错让你去配
--     NOPASSWD，不会卡住等你敲密码。
--
-- [2] 模式先选对，别拿 count 当采样：
--     count   只数次数（最便宜，先确认探针能触发 → events>0）
--     samples 打印原始字段（看参数取没取到，比如 file= 字符串）
--     latency entry→exit 配对求时延分布（p50/p99/max + 按 key 排名）
--     folded  折叠栈（callchain）→ 火焰图/热力图/排行的输入
--     oncpu   周期性 on-CPU 采样（--freq，默认 99Hz）+ callchain
--     offcpu  调度阻塞时长（sched_switch 配对），卡点排行首选
--     顺序建议：count 验探针 → samples 验字段 → 再上 folded/oncpu/offcpu 出图。
--
-- [3] events=0 不是插件坏了，是**内核侧**某一环没开/不可见：
--     FTRACE/TRACEPOINTS/PERF_EVENTS/KPROBE_EVENTS/UPROBES + tracefs 挂载。
--     先 action=status 看五环，别在 Lua 侧乱改。stderr 里 ring 溢出
--     （丢事件 lost / throttle）说明统计偏小 → 调大 ring_size 或收窄探针。
--
-- [4] 出图三件套（flame/heat/rank）只吃 oncpu/offcpu/folded 的 result；
--     写 .png 走 cairo+librsvg，缺库就给 .svg（浏览器打开可交互），不要报「做不到」。
--
-- [5] duration 会被夹到 [0.1, 120] 秒：采样是**阻塞**的，别拿 60s 探路；
--     count 用 1~2s，出图 3~5s 足够看清形状。
--
-- [6] --pid 跟的是**进程的全部线程**（展开 /proc/PID/task 每 tid 一条 per-task 事件），
--     内核里 common_pid 是 tid 不是 tgid，别看错。
--
-- [7] 高价值探针：kprobe:do_sys_openat2（file=+0(%si):string）、
--     tracepoint:sched:sched_switch（offcpu 基座）、raw_syscalls:sys_enter/exit（latency）。

local cjson = require("cjson")

-- 摘要格式化放 lua/trace/summary.lua（纯函数，auto_unit 直接测）
local ok_sum, summary = pcall(require, "trace.summary")
if not ok_sum then summary = nil end

local M = {}

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- 读一行命令的 stdout，返回 out, rc（popen:close() 拿不到退出码，让 shell 回显）
local function capture(cmd, timeout)
    local full = "timeout " .. tostring(timeout or 30) .. " " .. cmd .. '; echo "__lite_rc=$?"'
    local p = io.popen("sh -c " .. shq(full) .. " 2>&1")
    if not p then return nil, -1, "cannot spawn sh" end
    local out = p:read("*a") or ""
    p:close()
    local rc = tonumber(out:match("__lite_rc=(%-?%d+)%s*$") or "")
    out = out:gsub("__lite_rc=%-?%d+%s*$", "")
    return out, rc or -1
end

local function file_size(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local n = f:seek("end")
    f:close()
    return n
end

local function read_first_line(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    return s
end

local CACHE = {}
-- 只加载一次的 Lua 模块（svgpng 有 ffi.cdef，重复 dofile 会 redefine 报错）
local MODCACHE = {}

local function euid()
    if CACHE.euid then return CACHE.euid end
    local out = capture("id -u", 5) or ""
    CACHE.euid = tonumber(out:match("(%d+)")) or 1000
    return CACHE.euid
end

-- sudo -n：只走 NOPASSWD。要密码就是不可用 —— 绝不弹 tty 问密码（那是 TUI 里卡死）
local function sudo_ok()
    if CACHE.sudo ~= nil then return CACHE.sudo end
    if euid() == 0 then CACHE.sudo = false return false end
    local _, rc = capture("sudo -n true", 8)
    CACHE.sudo = (rc == 0)
    return CACHE.sudo
end

-- LITE_ROOT 优先；插件被别处加载时退到 helper_dir/..，最后试安装路径
local function lite_root(env)
    local cands = {}
    if os.getenv("LITE_ROOT") then cands[#cands + 1] = os.getenv("LITE_ROOT") end
    if env and env.helper_dir and env.helper_dir ~= "" then
        cands[#cands + 1] = env.helper_dir:gsub("/helper$", "")
    end
    cands[#cands + 1] = "/usr/local/share/lite"
    for _, c in ipairs(cands) do
        if file_size(c .. "/lua/trace/engine.lua") then return (c:gsub("/+$", "")) end
    end
    return nil
end

local function engine_path(root)
    if not root then return nil end
    local p = root .. "/lua/trace/engine.lua"
    if file_size(p) then return p end
    return nil
end

local function render_path(root)
    if not root then return nil end
    local p = root .. "/lua/trace/render.lua"
    if file_size(p) then return p end
    return nil
end

-- 子进程解释器：优先仓库/安装目录的 tools/lua.sh（自带 LUA_PATH/LUA_CPATH + 预加载），
-- 退到裸 luajit（自己拼 LUA_PATH）。sudo 下 lua.sh 按自身路径重算 ROOT，照样成立。
local function lua_bin(root)
    if root then
        local p = root .. "/tools/lua.sh"
        if file_size(p) then return shq(p) end
    end
    local ok = os.execute("command -v luajit >/dev/null 2>&1")
    if ok == 0 or ok == true then
        local path = (root and (root .. "/lua/?.lua")) or "./lua/?.lua"
        return "env LUA_PATH=" .. shq(path .. ";" .. path:gsub("%?%.lua$", "?/init.lua") .. ";;")
            .. " luajit"
    end
    return nil
end

local function need_root_prefix()
    if euid() == 0 then return "" end
    if sudo_ok() then return "sudo -n " end
    return nil
end

-- ── 探针参数归一：string / array 都收；空串丢掉 ──────────────────────
local function as_list(v)
    local l = {}
    if type(v) == "table" then
        for _, x in ipairs(v) do
            x = tostring(x or "")
            if x ~= "" then l[#l + 1] = x end
        end
    elseif v ~= nil then
        local s = tostring(v)
        if s ~= "" then l[1] = s end
    end
    return l
end

local MODES = {
    count = true, samples = true, latency = true,
    folded = true, oncpu = true, offcpu = true,
}

local RENDER_MODES = { oncpu = true, offcpu = true, folded = true }

local function num(v) return tonumber(v) end

-- 组装 engine 命令行（不含解释器/前缀）。返回 argv 数组 或 nil, err
function M.build_argv(args)
    local mode = tostring(args.mode or "count")
    if not MODES[mode] then
        error(("trace: 未知 mode %q（可选 %s）；参数 mode=%s"):format(
            mode, "count/samples/latency/folded/oncpu/offcpu", cjson.encode(mode)), 0)
    end
    local a = { "--mode", mode }
    local probes = as_list(args.probe)
    if mode == "latency" then
        if not args.entry or not args.exit then
            error("trace: latency 模式需要 entry 和 exit（如 tracepoint:syscalls:sys_enter_openat / "
                .. "tracepoint:syscalls:sys_exit_openat）；收到 entry="
                .. tostring(args.entry) .. " exit=" .. tostring(args.exit), 0)
        end
        a[#a + 1] = "--entry"; a[#a + 1] = tostring(args.entry)
        a[#a + 1] = "--exit";  a[#a + 1] = tostring(args.exit)
    else
        if #probes == 0 then
            error("trace: " .. mode .. " 模式需要 probe（如 kprobe:do_sys_openat2 / "
                .. "tracepoint:sched:sched_switch），可给数组；当前 probe 为空", 0)
        end
        for _, p in ipairs(probes) do a[#a + 1] = "--probe"; a[#a + 1] = p end
    end
    local dur = num(args.duration) or 2
    if dur < 0.1 then dur = 0.1 end
    if dur > 120 then dur = 120 end
    a[#a + 1] = "--duration"; a[#a + 1] = tostring(dur)
    for _, f in ipairs(as_list(args.arg)) do a[#a + 1] = "--arg"; a[#a + 1] = f end
    local map = {
        key = "--key", str = "--str", pid = "--pid", limit = "--limit",
        freq = "--freq", event = "--event", ring_size = "--ring-size",
    }
    -- offcpu/oncpu/folded 是全机高频事件（sched_switch 每秒上万），默认 8 页(32KB/CPU)
    -- 一定溢丢；这三档默认给 64 页，显式 ring_size 仍然覆盖它。
    if args.ring_size == nil and RENDER_MODES[mode] then
        a[#a + 1] = "--ring-size"; a[#a + 1] = "64"
    end
    for k, flag in pairs(map) do
        if args[k] ~= nil and args[k] ~= "" then
            a[#a + 1] = flag; a[#a + 1] = tostring(args[k])
        end
    end
    if args.sym then a[#a + 1] = "--sym" end
    -- 出图：只对 oncpu/offcpu/folded 有意义，其余模式 engine 会自己跳过并打 stderr
    for _, kind in ipairs({ "flame", "heat", "rank" }) do
        if args[kind] and args[kind] ~= "" then
            a[#a + 1] = "--" .. kind; a[#a + 1] = tostring(args[kind])
        end
    end
    for _, k in ipairs({ "heat_top", "rank_top", "rank_by" }) do
        if args[k] ~= nil and args[k] ~= "" then
            a[#a + 1] = "--" .. k:gsub("_", "-"); a[#a + 1] = tostring(args[k])
        end
    end
    if args.json then a[#a + 1] = "--json" end
    return a, mode, dur
end

local function join_argv(argv)
    local out = {}
    for i, v in ipairs(argv) do out[i] = shq(v) end
    return table.concat(out, " ")
end

-- ── action=status ────────────────────────────────────────────────────────
local function do_status(root)
    local L = {}
    local function add(fmt, ...) L[#L + 1] = fmt:format(...) end
    add("engine: %s", engine_path(root) or ("未找到（LITE_ROOT=" .. tostring(os.getenv("LITE_ROOT")) .. "）"))
    add("render: %s", render_path(root) or "未找到")
    add("euid: %d%s", euid(), euid() == 0 and "（root，直接跑）" or "")
    if euid() ~= 0 then
        add("sudo -n: %s", sudo_ok() and "可用" or "不可用 → 配 visudo NOPASSWD，或以 root 启动 lite")
    end
    -- 内核五环。tracefs 目录是 0700 root，非 root 一定读不到内容：
    -- 这时候要区分「没挂载」和「挂了但没权限」，否则会被误判成内核没开 FTRACE。
    local mounted = false
    local mf = io.open("/proc/mounts", "r")
    if mf then
        for line in mf:lines() do
            if line:match("^tracefs%s") then mounted = true break end
        end
        mf:close()
    end
    add("tracefs: %s", mounted and "已挂载 /sys/kernel/tracing"
        or "未挂载 → mount -t tracefs tracefs /sys/kernel/tracing")
    local afr = read_first_line("/sys/kernel/tracing/available_filter_functions")
    add("tracefs 内容: %s", afr and "可读"
        or (mounted and "读不到（目录 0700 root；跑起来时靠 sudo -n/root 访问）" or "未知"))
    local fmtok = read_first_line("/sys/kernel/tracing/events/sched/sched_switch/format") ~= nil
    add("tracepoint format: %s", fmtok and "ok（sched_switch）" or "缺失/不可读")
    local kb = io.open("/sys/kernel/tracing/kprobe_events", "r")
    add("kprobe_events: %s", kb and "可读（kprobe 探针装得动）" or "不可读（要 root/cap_perfmon）")
    if kb then kb:close() end
    local krel = read_first_line("/proc/sys/kernel/kptr_restrict")
    add("kptr_restrict: %s%s", tostring(krel or "?"),
        (tonumber(krel) == 0) and "" or "（非 0 时符号化会糊，--sym 可能给不出名字）")
    -- 渲染依赖：cairo/librsvg 走 dlopen，缺就只出 SVG
    local libs = {}
    for _, pat in ipairs({ "libcairo.so.2", "librsvg-2.so.2" }) do
        local _, rc = capture("ldconfig -p 2>/dev/null | grep -m1 " .. shq(pat), 8)
        libs[#libs + 1] = pat .. (rc == 0 and " ok" or " 缺失")
    end
    add("渲染依赖: %s", table.concat(libs, " / "))
    return table.concat(L, "\n")
end

-- ── action=run ───────────────────────────────────────────────────────────
local function do_run(args, env)
    local root = lite_root(env)
    local engine = engine_path(root)
    if not engine then
        error("trace: 找不到 lua/trace/engine.lua（LITE_ROOT="
            .. tostring(os.getenv("LITE_ROOT")) .. "）；源码树先 ./tools/build.sh，安装版用 release.sh", 0)
    end
    local prefix = need_root_prefix()
    if not prefix then
        error("trace: 需要 root 或 cap_perfmon 才能 perf_event_open；当前 euid≠0 且 `sudo -n` 不可用。"
            .. " 配 NOPASSWD 或用 root 跑 lite 后重试（action=status 可自检）", 0)
    end
    local bin = lua_bin(root)
    if not bin then error("trace: 找不到 luajit（tools/lua.sh 缺失且 PATH 里没有）", 0) end

    local argv, mode, dur = M.build_argv(args)
    -- json_out 也要走 --json（engine 一次只出一种格式），落盘后由插件自己给摘要
    local save_json = args.json_out and args.json_out ~= ""
    local want_json = (args.json and true) or save_json or false
    if want_json and not args.json then
        local has = false
        for _, v in ipairs(argv) do if v == "--json" then has = true break end end
        if not has then argv[#argv + 1] = "--json" end
    end
    local cmd = prefix .. bin .. " " .. shq(engine) .. " " .. join_argv(argv)
    -- 采样是阻塞的：给它 duration + 收尾余量；渲染大图再宽一点
    local timeout = math.ceil(dur) + ((args.flame or args.heat or args.rank) and 60 or 30)
    local out, rc = capture(cmd, timeout)

    if rc == 124 then
        error(("trace: 超时 %ds 被 kill（mode=%s duration=%.1f）。缩小 duration/ring_size 后重试；"
            .. "命令：%s"):format(timeout, mode, dur, cmd), 0)
    end
    if rc ~= 0 and (out == nil or out == "") then
        error(("trace: engine 退出码 %d 无输出；命令：%s"):format(rc, cmd), 0)
    end

    -- JSON 模式要纯 JSON：engine 的 stderr 进度/告警会混进来，先剥掉已知的进度行
    local body = out or ""
    if want_json then
        local lines = {}
        for line in body:gmatch("[^\n]*") do
            if not line:match("^%[trace_engine%]") and not line:match("^%[render%]") then
                lines[#lines + 1] = line
            end
        end
        body = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
        local okj = pcall(cjson.decode, body)
        if not okj and body ~= "" then
            error("trace: engine --json 输出无法解析（前 200 字：" .. body:sub(1, 200) .. "）；命令：" .. cmd, 0)
        end
    end

    -- 产物：PNG/SVG 落地了就把路径+大小顶到最前面（模型下一步就是 read 它）
    local arts = {}
    for _, kind in ipairs({ "flame", "heat", "rank" }) do
        local p = args[kind]
        if p and p ~= "" then
            local n = file_size(p)
            arts[#arts + 1] = n and ("%s: %s（%d 字节）"):format(kind, p, n)
                or ("%s: %s（**没生成**，看下面 stderr 里的渲染失败原因）"):format(kind, p)
        end
    end
    local head = #arts > 0 and (table.concat(arts, "\n") .. "\n---\n") or ""
    if want_json then
        local j
        local okj, dec = pcall(cjson.decode, body)
        if okj then j = dec end
        if save_json then
            local f = io.open(args.json_out, "wb")
            if f then
                f:write(body) f:close()
                head = head .. ("json → %s（%d 字节）\n"):format(args.json_out, #body)
            end
        end
        if args.json then return head .. body end
        return head .. (summary and summary.render(mode, j) or body)
    end
    return head .. (body:gsub("%s+$", "") == "" and "(engine 无 stdout 输出)" or body)
end

-- ── action=render：从上次的 JSON 重出图（不采样，毫秒级） ────────────────
local function do_render(args, env)
    local root = lite_root(env)
    local render = render_path(root)
    if not render then error("trace: 找不到 lua/trace/render.lua", 0) end
    local json_in = args.json_in
    if not json_in or json_in == "" then
        error("trace: render 需要 json_in（先跑 action=run json=true json_out=xxx.json 存一份）", 0)
    end
    if not file_size(json_in) then error("trace: 读不到 json_in " .. tostring(json_in), 0) end
    local kind = tostring(args.kind or "flame")
    if not ({ flame = true, heat = true, rank = true })[kind] then
        error("trace: render 的 kind 只能是 flame/heat/rank，收到 " .. kind, 0)
    end
    local out = args.out
    if not out or out == "" then error("trace: render 需要 out（.svg 或 .png 路径）", 0) end
    local bin = lua_bin(root)
    if not bin then error("trace: 找不到 luajit", 0) end

    local want_png = out:lower():match("%.png$") ~= nil
    local svg = want_png and (os.tmpname() .. ".svg") or out
    local timeouts = math.ceil(tonumber(args.duration) or 2) + 60
    local cmd = bin .. " " .. shq(render) .. " " .. shq(kind) .. " " .. shq(json_in)
        .. " " .. shq(svg) .. " " .. shq(tostring(args.out_title or "trace"))
    if args.heat_top or args.rank_top or args.rank_by then
        cmd = cmd .. " " .. shq(tostring(args.heat_top or args.rank_top or 0))
            .. " " .. shq(tostring(args.rank_by or ""))
    end
    local out_txt, rc = capture(cmd, timeouts)
    if rc ~= 0 then
        error(("trace: %s 渲染失败（rc=%d）：%s"):format(kind, rc, (out_txt or ""):sub(-500)), 0)
    end
    local note = ""
    if want_png then
        local png_lua = render:gsub("[^/]*$", "") .. "svgpng.lua"
        local okp, err = pcall(function()
            local f = assert(io.open(svg, "rb"), "读不到临时 SVG " .. svg)
            local body = f:read("*a") f:close()
            -- svgpng 里 ffi.cdef 了 cairo/GError：一个进程只加载一次，
            -- 第二次 cdef 会 "attempt to redefine '_GError'"（engine 里也是这么缓的）
            local mod = MODCACHE[png_lua]
            if not mod then
                mod = assert(loadfile(png_lua))()
                MODCACHE[png_lua] = mod
            end
            local done, why = mod.render(body, out, 2)
            if not done then error(why or "svgpng 失败", 0) end
        end)
        if okp then
            os.remove(svg)
        else
            note = ("\nPNG 转换失败（%s），SVG 留在 %s —— 装 libcairo2/librsvg2-2 或直接用 .svg"
                ):format(tostring(err), svg)
        end
    end
    local n = file_size(out) or 0
    return ("%s → %s（%d 字节）%s%s"):format(kind, out, n, note,
        (out_txt or ""):gsub("%s+$", "") ~= "" and ("\n" .. out_txt:gsub("%s+$", "")) or "")
end

local schema = {
    name = "trace",
    description = "动态追踪（Linux 内核，纯 LuaJIT）：perf_event_open + tracefs 探针采样，"
        .. "出火焰图/热力图/卡点排行。action=status 自检权限与内核五环；"
        .. "run 按 mode（count 数次数 / samples 看字段 / latency 配对时延 / folded 折叠栈 / "
        .. "oncpu on-CPU 采样 / offcpu 阻塞时长）采一次；render 拿之前的 JSON 重出图。"
        .. "需要 root 或 cap_perfmon（非 root 自动 sudo -n）。",
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                enum = { "status", "run", "render" },
                description = "status=环境自检（权限/tracefs/渲染依赖）；run=采样（默认）；render=从 json_in 重出图",
            },
            mode = {
                type = "string",
                enum = { "count", "samples", "latency", "folded", "oncpu", "offcpu" },
                description = "count 最便宜先验探针；latency 需 entry+exit；folded/oncpu/offcpu 可出图",
            },
            probe = {
                type = "array", items = { type = "string" },
                description = "探针，可多个：tracepoint:sched:sched_switch / kprobe:do_sys_openat2 / uprobe:/path:func",
            },
            arg = {
                type = "array", items = { type = "string" },
                description = "附加 fetchargs，如 'file=+0(%si):string'（kprobe 取寄存器指向的字符串）",
            },
            entry = { type = "string", description = "latency 模式的进入探针" },
            exit = { type = "string", description = "latency 模式的退出探针" },
            key = { type = "string", description = "latency/聚合键，默认 comm" },
            str = { type = "string", description = "按字符串解的字段名" },
            pid = { type = "integer", description = "只跟这个进程（覆盖其全部线程 + 之后 fork 的）" },
            duration = { type = "number", description = "采样秒数，默认 2，夹到 [0.1,120]" },
            limit = { type = "integer", description = "samples/folded 输出条数" },
            freq = { type = "integer", description = "oncpu 采样频率 Hz，默认 99" },
            event = { type = "string", description = "自定义 perf 事件（软件时钟/硬件周期）" },
            ring_size = { type = "integer", description = "ring data 页数，默认 8（32KB/CPU）；高频探针调大" },
            sym = { type = "boolean", description = "用 kallsyms 把栈地址符号化" },
            flame = { type = "string", description = "火焰图输出路径（.svg 或 .png）；mode 需 folded/oncpu/offcpu" },
            heat  = { type = "string", description = "热力图输出路径（.svg/.png）" },
            rank  = { type = "string", description = "卡点排行输出路径（.svg/.png）" },
            heat_top = { type = "integer", description = "热力图保留前 N 个函数" },
            rank_top = { type = "integer", description = "排行保留前 N 行" },
            rank_by  = { type = "string", description = "排行排序键 self/incl/count" },
            json = { type = "boolean", description = "返回原始 JSON（可配合 json_out 落盘供 render 复用）" },
            json_out = { type = "string", description = "把 JSON 结果另存到这个路径" },
            json_in = { type = "string", description = "render：上一次 run 存的 JSON 路径" },
            kind = { type = "string", enum = { "flame", "heat", "rank" }, description = "render：出哪种图" },
            out = { type = "string", description = "render：输出路径（.svg/.png）" },
            out_title = { type = "string", description = "render：图标题" },
        },
    },
}

M.schema = schema

function M.run(args, env)
    args = args or {}
    env = env or {}
    local action = tostring(args.action or "")
    if action == "" then
        action = (args.kind and args.json_in) and "render"
            or (args.mode or args.probe or args.entry) and "run" or "status"
    end
    if action == "status" then return do_status(lite_root(env)) end
    if action == "run" then return do_run(args, env) end
    if action == "render" then return do_render(args, env) end
    error("trace: 未知 action " .. action .. "（status/run/render）", 0)
end

return M
