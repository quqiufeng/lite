-- trace_engine.lua —— 纯 LuaJIT FFI 的 tracing 引擎（需要 root / cap_perfmon）
-- tracefs 动态探针注册 + perf_event_open(298) ring buffer + format 驱动解码
local ffi = require "ffi"
local bit = require "bit"

ffi.cdef[[
typedef long ssize_t;
int ioctl(int fd, unsigned long request, ...);
long syscall(long number, ...);
ssize_t read(int fd, void *buf, size_t n);
void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset);
int close(int fd);
int munmap(void *addr, size_t length);
struct timespec { long tv_sec; long tv_nsec; };
int clock_gettime(int clk_id, struct timespec *tp);
struct pollfd { int fd; short events; short revents; };
int poll(struct pollfd *fds, unsigned long nfds, int timeout);
]]
local SYS_perf_event_open, SYS_process_vm_readv = 298, 310
local T = "/sys/kernel/tracing"
ffi.cdef[[ typedef void (*sighandler_t)(int); sighandler_t signal(int, sighandler_t); ]]
local _stop = ffi.new("volatile int[1]", 0)
local function _onsig(sig) _stop[0] = 1 end
local _sigcb = ffi.cast("sighandler_t", function(sig) _stop[0] = 1 end)
ffi.C.signal(15, _sigcb)   -- SIGTERM
ffi.C.signal(2,  _sigcb)   -- SIGINT

local PAGE = 4096
local RING_PAGES = 8      -- ring data 页数，--ring-size 可调；高频探针要大
local SAMPLE_TID, SAMPLE_TIME, SAMPLE_CALLCHAIN, SAMPLE_CPU, SAMPLE_RAW = 2, 4, 32, 128, 1024
-- 攒够多少个样本才唤醒一次 poll：1=每个样本都唤醒，开销最大
local WAKEUP_BATCH = 64

local TS = ffi.typeof("struct timespec")
local function now_s()
  local ts = TS()
  ffi.C.clock_gettime(1, ts)                     -- CLOCK_MONOTONIC
  return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
end

-- 睡 sec 秒：poll(nil,0,ms) 当 sleep，可被信号打断，无 os.execute 的子进程开销
local function sleep_seconds(sec)
  local deadline = now_s() + sec
  while _stop[0] == 0 do
    local rem = deadline - now_s()
    if rem <= 0 then return end
    local ms = math.floor(rem * 1000)
    if ms > 50 then ms = 50 end
    if ms < 1 then ms = 1 end
    ffi.C.poll(nil, ffi.cast("unsigned long", 0), ms)
  end
end

local function rf(p) local f=io.open(p) if not f then return nil end local s=f:read("*a") f:close() return s end
local function wf(p,s) local f=io.open(p,"w") if not f then return nil end local ok,e=f:write(s) f:close() return ok,e end

------------------------------------------------------------------------
-- 事件源：tracepoint / kprobe / uprobe 统一成 tracefs event id
------------------------------------------------------------------------
local probes, probe_seq, kprobe_added = {}, 0, 0

local function parse_format(txt)
  local f = {}
  for line in txt:gmatch("[^\n]+") do
    local decl = line:match("^%s*field:(.-);")
    if decl then
      -- 数组字段声明形如 "char prev_comm[16]" / "char[]"，末尾的 ']' 会让
      -- 直接取尾部标识符失败（name=nil → out[nil] 崩）。先剥掉维度再取名。
      local base = decl:gsub("%[%d*%]%s*$", "")
      f[#f+1] = { name = base:match("([%w_%.]+)%s*$"),
                  off  = tonumber(line:match("offset:(%d+)")),
                  size = tonumber(line:match("size:(%d+)")),
                  dyn  = decl:find("__data_loc") ~= nil,
                  arr  = decl:find("%[%]") ~= nil,
                  ptr  = decl:find("%*") ~= nil }
    end
  end
  return f
end

--------------------------------------------------------------------
-- ELF 符号解析：这台内核的 uprobe_events 只认文件偏移，不认符号名
-- （写 "libc.so.6:malloc" 直接 EIO），所以 uprobe:PATH:SYM 得自己算偏移
--------------------------------------------------------------------
local function elf_sym_offset(path, sym)
  if sym:match("^0x%x+$") or sym:match("^%d+$") then return tonumber(sym) end
  local base, extra = sym:match("^([%w_%.@]+)%+(0x%x+)$")
  if base then sym, extra = base, tonumber(extra) else extra = 0 end
  local f = io.open(path, "rb")
  if not f then return nil, "打不开 " .. path end
  local data = f:read("*a") f:close()
  if #data < 64 or data:sub(1, 4) ~= "\127ELF" then return nil, "不是 ELF 文件: " .. path end
  local buf = ffi.cast("const uint8_t*", data)      -- data 在作用域内，指针有效
  local function u16(o) return ffi.cast("const uint16_t*", buf+o)[0] end
  local function u32(o) return ffi.cast("const uint32_t*", buf+o)[0] end
  local function u64(o) return tonumber(ffi.cast("const uint64_t*", buf+o)[0]) end
  local shoff, shentsize, shnum = u64(40), u16(58), u16(60)
  local vaddr
  for i = 0, shnum - 1 do
    local o = shoff + i * shentsize
    local ty, link, off, size, ent = u32(o+4), u32(o+40), u64(o+24), u64(o+32), u64(o+56)
    if (ty == 2 or ty == 11) and ent > 0 then            -- symtab / dynsym
      local so = shoff + link * shentsize
      local stroff = u64(so+24)
      for j = 0, math.floor(size / ent) - 1 do
        local so2 = off + j * ent
        local nm = u32(so2)
        if nm ~= 0 then
          local e = stroff + nm
          local q = e
          while buf[q] ~= 0 do q = q + 1 end
          if q - e == #sym and ffi.string(buf+e, #sym) == sym then
            vaddr = u64(so2+8)
            break
          end
        end
      end
      if vaddr then break end
    end
  end
  if not vaddr then return nil, ("%s 里找不到符号 %s"):format(path, sym) end
  -- vaddr → 文件偏移（按 PT_LOAD 段换算；非 PIE 时两者相差 0x400000 这种量级）
  local phoff, phnum, phentsize = u64(32), u16(56), u16(54)
  for i = 0, phnum - 1 do
    local o = phoff + i * phentsize
    if u32(o) == 1 then                                   -- PT_LOAD
      local p_off, p_vaddr, p_filesz = u64(o+8), u64(o+16), u64(o+32)
      if vaddr >= p_vaddr and vaddr < p_vaddr + p_filesz then
        return p_off + (vaddr - p_vaddr) + extra
      end
    end
  end
  return vaddr + extra
end

local function reg_dynamic(kind, def, args)
  probe_seq = probe_seq + 1
  local name = ("lite_%d"):format(probe_seq)
  local file = (kind == "uprobe") and "/uprobe_events" or "/kprobe_events"
  local grp  = (kind == "uprobe") and "uprobes" or "kprobes"
  local line = "p:" .. name .. " " .. def
  if args and args ~= "" then line = line .. " " .. args end
  local ok, err = wf(T .. file, line .. "\n")
  -- 内核在 write 时只报 errno，io.write 仍可能返回成功；以事件目录是否出现为准
  local idtxt = rf(("%s/events/%s/%s/id"):format(T, grp, name))
  local fmt   = rf(("%s/events/%s/%s/format"):format(T, grp, name))
  if not idtxt or not fmt then
    return nil, ("%s 注册失败（%s；符号/偏移是否存在？errno=%s）"):format(
      kind, file:sub(2) .. ":" .. line, tostring(err))
  end
  kprobe_added = kprobe_added + 1
  return tonumber(idtxt:match("%d+")), parse_format(fmt), name, grp
end

function add_probe(spec, argstr)
  local kind, rest = spec:match("^(%w+):(.+)$")
  if not kind then return nil, "probe 语法应为 kind:... : " .. spec end
  local p = { spec = spec, kind = kind }
  if kind == "tracepoint" then
    local grp, ev = rest:match("^(.-):(.+)$")
    if not grp then return nil, "tracepoint 需要 group:event" end
    local idtxt = rf(("%s/events/%s/%s/id"):format(T, grp, ev))
    local fmt = rf(("%s/events/%s/%s/format"):format(T, grp, ev))
    if not idtxt or not fmt then return nil, "事件不存在: " .. grp .. ":" .. ev end
    p.id, p.fields, p.name = tonumber(idtxt:match("%d+")), parse_format(fmt), grp .. ":" .. ev
  elseif kind == "kprobe" or kind == "uprobe" then
    local def = rest
    if kind == "uprobe" then
      local path, sym = rest:match("^(.-):([^:]+)$")
      if not path then return nil, "uprobe 需要 文件:符号" end
      if not rf(path) then return nil, "文件不存在: " .. path end
      local off, e = elf_sym_offset(path, sym)
      if not off then return nil, "uprobe 解析失败: " .. tostring(e) end
      def = ("%s:0x%x"):format(path, off)
    end
    local id, fields, name, grp = reg_dynamic(kind, def, argstr)
    if not id then return nil, fields end
    p.id, p.fields, p.name, p.dynamic, p.grp = id, fields, kind .. ":" .. def, name, grp
  else
    return nil, "未知 probe 类型: " .. kind
  end
  probes[#probes + 1] = p
  return p
end

local all_rings = {}
local function cleanup()
  for _, r in ipairs(all_rings) do        -- 先放掉 ring 引用，否则删探针 EIO
    -- ring_close 已经收过的绝不能再 munmap：那段虚拟内存可能已被 malloc 复用，
    -- 二次 munmap 会连 LuaJIT 自己的堆一起卸掉，表现为退出时在 GC 里随机段错误。
    if not r.closed then
      r.closed = true
      pcall(function() ffi.C.close(r.fd) end)
      pcall(function() ffi.C.munmap(r.bp, r.mmap_len or PAGE*(1+RING_PAGES)) end)
    end
  end
  all_rings = {}
  for _, spec in ipairs({ {"/kprobe_events", "kprobes"}, {"/uprobe_events", "uprobes"} }) do
    local txt = rf(T .. spec[1]) or ""
    for line in txt:gmatch("[^\n]+") do
      local name = line:match("^p:" .. spec[2] .. "/(lite_%d+)")
      if name then wf(T .. spec[1], "-:" .. spec[2] .. "/" .. name .. "\n") end
    end
  end
end

------------------------------------------------------------------------
-- perf ring
------------------------------------------------------------------------
-- t 可省略：{ inherit = bool, wakeup = n }
-- flags(attr+40) 按 perf_event_attr 的位域：
--   bit0=disabled(1) bit1=inherit(2) bit2=pinned(4) bit3=exclusive(8)
--   bit7=exclude_idle(128) bit10=freq(1024)
--   注意 8 是 exclusive 不是 exclude_idle（早先写错过，采样率虚高就是这个）
--   freq 置位时 attr+16 解释为采样频率 Hz（不是 period）
-- wakeup_events(attr+48)：攒够 n 个样本才唤醒一次 poll
-- spec 两种写法：
--   number = tracefs 事件 id（type=PERF_TYPE_TRACEPOINT 2）
--   table  = 任意 perf 事件 { type, config, freq=bool, exclude_idle=bool }
--            软件时钟 {type=1,config=0}，硬件周期 {type=0,config=0}
local PERF_TYPE_HARDWARE, PERF_TYPE_SOFTWARE = 0, 1
local PERF_COUNT_HW_CPU_CYCLES, PERF_COUNT_SW_CPU_CLOCK = 0, 0
local function perf_open(spec, pid, cpu, sample_type, period, t)
  t = t or {}
  local attr = ffi.new("uint8_t[?]", 136)
  local etype, econfig, freq, idle = 2, spec, false, false
  if type(spec) == "table" then
    etype, econfig, freq, idle = spec.type, spec.config, spec.freq, spec.exclude_idle
  end
  ffi.cast("uint32_t*", attr)[0] = etype
  ffi.cast("uint32_t*", attr+4)[0] = 128
  ffi.cast("uint64_t*", attr+8)[0] = econfig
  ffi.cast("uint64_t*", attr+16)[0] = period or 1
  ffi.cast("uint64_t*", attr+24)[0] = sample_type
  ffi.cast("uint64_t*", attr+40)[0] = 1 + (t.inherit and 2 or 0) + (idle and 128 or 0) + (freq and 1024 or 0)
  ffi.cast("uint32_t*", attr+48)[0] = t.wakeup or 1
  local fd = tonumber(ffi.C.syscall(ffi.cast("long", SYS_perf_event_open), ffi.cast("void*", attr),
      ffi.cast("int", pid), ffi.cast("int", cpu), ffi.cast("int", -1), ffi.cast("unsigned long", 0)))
  if fd < 0 then return nil, ffi.errno() end
  return fd
end

local function online_cpus()
  local s = rf("/sys/devices/system/cpu/online") or "0"
  local l = {}
  for a, b in s:gmatch("(%d+)%-(%d+)") do for n = tonumber(a), tonumber(b) do l[#l+1] = n end end
  if #l == 0 then for n in s:gmatch("%d+") do l[#l+1] = tonumber(n) end end
  return l
end

------------------------------------------------------------------------
-- 采样目标枚举
------------------------------------------------------------------------
-- perf 的 pid 维度只有两种语义，不能混：
--   pid=P, cpu=-1    per-task：计数器属于该线程，fork 的子进程要 inherit 才跟
--   pid=-1, cpu=C    per-CPU ：该 CPU 上所有进程共享，噪声照样占 ring 槽
-- 所以「跟某个进程」= 展开 /proc/PID/task 的每个 tid 各开一条 per-task 事件 + inherit，
-- 才能覆盖多线程（common_pid 是 tid 不是 tgid）和之后 fork 出来的线程。
local MAX_TIDS = 256

local function task_tids(pid)
  local l = {}
  local f = io.popen("ls -1 /proc/"..pid.."/task 2>/dev/null")
  if not f then return l end
  for line in f:lines() do local x = tonumber(line) if x then l[#l+1] = x end end
  f:close()
  table.sort(l)
  return l
end

local function targets(pid, want_inherit, wakeup)
  local l = {}
  if pid then
    local tids = task_tids(pid)
    if #tids == 0 then tids = { pid } end
    if #tids > MAX_TIDS then
      io.stderr:write(("[trace_engine] 警告：pid %d 有 %d 个线程，超过上限 %d，只跟主线程\n")
        :format(pid, #tids, MAX_TIDS))
      tids = { pid }
    end
    for _, t in ipairs(tids) do
      l[#l+1] = { pid = t, cpu = -1, inherit = want_inherit, wakeup = wakeup, tid = t }
    end
  else
    for _, cpu in ipairs(online_cpus()) do
      l[#l+1] = { pid = -1, cpu = cpu, inherit = false, wakeup = wakeup }
    end
  end
  return l
end

local ring_errs = {}
local function rerr(k) ring_errs[k] = (ring_errs[k] or 0) + 1 end
local function ring_err_note()
  local l = {}
  for k, v in pairs(ring_errs) do l[#l+1] = ("%s×%d"):format(k, v) end
  if #l == 0 then return "" end
  table.sort(l)
  return "（" .. table.concat(l, " ") .. "）"
end

local function open_ring(spec, t, sample_type, cc, period)
  local fd, err = perf_open(spec, t.pid, t.cpu, sample_type, period or 1, t)
  if not fd then rerr("open errno=" .. tostring(err)) return nil, err end
  local mmap_len = PAGE * (1 + RING_PAGES)
  local bp = ffi.cast("uint8_t*", ffi.C.mmap(nil, mmap_len, 3, 1, fd, 0))
  if ffi.cast("intptr_t", bp) == -1 then
    rerr("mmap errno=" .. tostring(ffi.errno()))
    ffi.C.close(fd)
    return nil, "mmap 失败"
  end
  -- data_offset/data_size 一律按 perf_event_mmap_page ABI 读（1040/1048），不再假设 = PAGE
  local doff = tonumber(ffi.cast("uint64_t*", bp+1040)[0])
  local dsz  = tonumber(ffi.cast("uint64_t*", bp+1048)[0])
  if doff == 0 or doff >= mmap_len then doff = PAGE end
  if dsz == 0 or doff + dsz > mmap_len then dsz = mmap_len - doff end
  local r = { fd = fd, bp = bp, d = bp + doff, dsz = dsz, mmap_len = mmap_len,
              off = doff, size = dsz, tail = 0, cpu = t.cpu, tid = t.tid, cc = cc,
              scpu = bit.band(sample_type, SAMPLE_CPU) ~= 0,
              sraw = bit.band(sample_type, SAMPLE_RAW) ~= 0 }
  all_rings[#all_rings+1] = r
  return r
end
local function ring_on(r)  ffi.C.ioctl(r.fd, 0x2400, ffi.cast("long", 1)) end
local function ring_off(r) ffi.C.ioctl(r.fd, 0x2401, ffi.cast("long", 0)) end

local function ring_close(r)
  if r.closed then return end
  r.closed = true                 -- cleanup 见到这个标记就不重复 close（fd 可能已被复用）
  ring_off(r)
  pcall(function() ffi.C.munmap(r.bp, r.mmap_len) end)
  pcall(function() ffi.C.close(r.fd) end)
end

------------------------------------------------------------------------
-- ring 池
------------------------------------------------------------------------
-- 内核拒绝 mmap「带 inherit 的 per-task 事件」（mmap 返回 EINVAL），
-- 所以 ring 模式跟进程时不开 inherit，而是定期重扫 /proc/PID/task 给新线程补 ring。
-- srcs 省略时用 probes；每项只需 { id=<perf spec>, key=名字, period=采样频率 }
local function ring_pool(st, cc, pid, srcs)
  local P = { rings = {}, seen = {}, pfd = ffi.new("struct pollfd[?]", 0), npfd = 0 }

  local function rebuild()
    P.npfd = #P.rings
    P.pfd = ffi.new("struct pollfd[?]", P.npfd)
    for i = 1, P.npfd do P.pfd[i-1].fd = P.rings[i].fd P.pfd[i-1].events = 1 end
  end

  -- 给还没 ring 的目标补坑，返回新增数量
  function P.sync()
    local added = 0
    for _, p in ipairs(srcs or probes) do
      for _, t in ipairs(targets(pid, false, WAKEUP_BATCH)) do
        local k = (p.key or tostring(p.id)) .. ":" .. t.pid .. ":" .. (t.cpu or -1)   -- 全机模式 pid 恒为 -1，必须用 cpu 区分
        if not P.seen[k] then
          local r = open_ring(p.id, t, st, cc, p.period)
          if r then
            P.seen[k] = true
            ring_on(r)
            P.rings[#P.rings+1] = r
            added = added + 1
          else
            P.seen[k] = "fail"        -- 记下失败，别每轮对同一目标反复试
          end
        end
      end
    end
    if added > 0 then rebuild() end
    return added
  end

  -- 线程退出后 ring 上会挂 POLLHUP：残留数据已 drain，收掉 fd 免得 poll 空转
  function P.reap()
    local dead = 0
    for i = P.npfd, 1, -1 do
      if bit.band(P.pfd[i-1].revents, 0x18) ~= 0 then     -- POLLERR|POLLHUP
        ring_close(P.rings[i])
        table.remove(P.rings, i)
        dead = dead + 1
      end
    end
    if dead > 0 then rebuild() end
    return dead
  end

  function P.close_all()
    for _, r in ipairs(P.rings) do ring_close(r) end
    P.rings = {}
    rebuild()
  end

  return P
end

-- 等 ring 有数据：忙等会吃满一个核，还会把被测系统的调度搅乱，这里用 poll 睡在 fd 上
local function wait_ready(pfd, npfd, deadline)
  while _stop[0] == 0 do
    local rem = deadline - now_s()
    if rem <= 0 then return false end
    local ms = math.floor(rem * 1000)
    if ms > 100 then ms = 100 end
    if ms < 1 then ms = 1 end
    local rc = tonumber(ffi.C.poll(pfd, ffi.cast("unsigned long", npfd), ms))   -- npfd=0 时纯 sleep
    -- 超时（rc==0）也要交回上层：只有回到主循环才会 P.sync()/P.reap()，
    -- 否则一次 poll 一路阻塞到 deadline，期间新起的线程永远挂不上 ring（曾导致 events=0）。
    if rc < 0 and ffi.errno() == 4 then
      -- 被信号打断，原地重试
    else
      return true
    end
  end
  return false
end

------------------------------------------------------------------------
-- 跨进程读串
------------------------------------------------------------------------
local iov_t = ffi.typeof("struct { void *base; size_t len; }[1]")
local CBUF = 4096
local sbuf = ffi.new("char[?]", CBUF)
local function read_cstr(pid, addr)
  if addr == 0 then return nil end
  local li, ri = iov_t(), iov_t()
  li[0].base, li[0].len = sbuf, CBUF
  ri[0].base, ri[0].len = ffi.cast("void*", addr), CBUF
  local n = tonumber(ffi.C.syscall(ffi.cast("long", SYS_process_vm_readv), ffi.cast("int", pid),
      li, ffi.cast("unsigned long", 1), ri, ffi.cast("unsigned long", 1), ffi.cast("unsigned long", 0)))
  if n <= 0 then return nil end
  return (ffi.string(sbuf, n):gsub("%z.*$", ""))
end

------------------------------------------------------------------------
-- 解码（format 驱动）
------------------------------------------------------------------------
-- tracepoint 自带的 common_* 是引擎元数据（common_type 就是事件 id），不是负载
local NOISE = { common_type = true, common_flags = true,
                common_preempt_count = true, common_pid = true }
local function decode(p, raw, pid, strfield)
  local out = {}
  for _, f in ipairs(p.fields) do
    local v
    if f.dyn then
      local dv = ffi.cast("uint32_t*", raw+f.off)[0]
      local o, l = bit.band(dv, 0xffff), bit.rshift(dv, 16)
      v = (l > 0) and ffi.string(raw+o, l):gsub("%z.*$", "") or ""
    elseif f.arr then
      v = ffi.string(raw+f.off)
    elseif f.size == 8 then v = tonumber(ffi.cast("uint64_t*", raw+f.off)[0])
    elseif f.size == 4 then v = ffi.cast("uint32_t*", raw+f.off)[0]
    elseif f.size == 2 then v = ffi.cast("uint16_t*", raw+f.off)[0]
    else v = raw[f.off] end
    if strfield and f.name == strfield and type(v) == "number" then
      v = read_cstr(pid, v) or ("<0x%x>"):format(v)
    end
    if not NOISE[f.name] then out[f.name] = v end
  end
  return out
end

-- 遍历 ring：cb(probe, pid, tid, time_ns, raw, rawlen, ccptr, nips)
-- 顺带统计 PERF_RECORD_LOST(2) / THROTTLE(5)：这两类记录以前被静默跳过，
-- 于是 events= 会变成一个看起来精确、实际偏小的数字。
local stats = { lost = 0, throttled = 0 }
local function walk(r, by_id, cb)
  local h = tonumber(ffi.cast("uint64_t*", r.bp+1024)[0])
  local d0, dsz = r.d, r.dsz
  local scratch = nil
  -- data_head / data_tail 都是「绝对累加值」，不是环内偏移。
  -- 之前把 tail 取模写回，内核看到用户进度回退 → 认为 ring 满 → 大量丢样本并自己推进 tail，
  -- 我们再从旧位置读到填充区（size=0）就永久 break（folded 全机 events=0 的真因）。
  local kt = tonumber(ffi.cast("uint64_t*", r.bp+1032)[0])
  if kt and kt ~= r.tail and kt - r.tail < 0x7fffffffffffffff then
    r.tail = kt                    -- 内核已丢弃 [旧 tail, kt)，跟着跳
  end
  while r.tail < h do
    local d, off = d0, r.tail % dsz
    local ty = ffi.cast("uint32_t*", d+off)[0]
    local sz = ffi.cast("uint16_t*", d+off+6)[0]
    if sz == 0 then break end                    -- 填充区，没有后续记录
    if sz < 8 or sz > dsz then break end         -- 头不可信：宁可停，不越界乱读
    if off + sz > dsz then
      -- perf 记录会绕过 ring 末尾连续写入，线性读会读到别的内存（曾把时间戳当成丢失计数）
      if not scratch then scratch = ffi.new("uint8_t[?]", dsz) end
      for i = 0, sz-1 do scratch[i] = (d0 + ((off+i) % dsz))[0] end
      d, off = scratch, 0
    end
    if ty == 9 then
      local p = off + 8
      local pid = ffi.cast("uint32_t*", d+p)[0]
      local tid = ffi.cast("uint32_t*", d+p+4)[0]
      local tm  = tonumber(ffi.cast("uint64_t*", d+p+8)[0])
      -- 内核 perf_output_sample 的落盘顺序是固定的：
      --   TID → TIME → CPU{u32 cpu; u32 reserved} → CALLCHAIN{u64 nr; nr*8} → RAW{u32 len; bytes}
      -- 之前把 CPU 读在 callchain 之后，只要 cc 与 scpu 同时开（folded 模式）整个偏移就错位，
      -- raw 里的 common_type 读成 0 → 一条样本都认不出来。
      local q = p + 16
      local cpu = nil
      if r.scpu then
        cpu = tonumber(ffi.cast("uint32_t*", d+q)[0])
        q = q + 8
      end
      local nr, ccp = 0, nil
      if r.cc then
        if q + 8 > off + sz then break end      -- callchain 头都放不下
        nr = tonumber(ffi.cast("uint64_t*", d+q)[0])
        if nr < 0 or q + 8 + nr*8 > off + sz then break end   -- 垃圾 nr：别按它越界读
        ccp = d + q + 8
        q = q + 8 + nr*8
      end
      if not r.sraw then                    -- on-CPU：sample_type 里没有 RAW，callchain 就是记录尾
        cb(nil, pid, tid, tm, nil, 0, ccp, nr, cpu)
      else
        if q + 4 > off + sz then break end  -- 头里写的 nr 大得离谱：停在这条，别越界读
        local rl = ffi.cast("uint32_t*", d+q)[0]
        local raw = d + q + 4
        local pr = by_id[tonumber(ffi.cast("uint16_t*", raw)[0])]   -- common_type 是 u16，别读成 u32
        if pr then cb(pr, pid, tid, tm, raw, rl, ccp, nr, cpu) end
      end
    elseif ty == 2 then                               -- LOST: hdr(8)+id(8)+lost(8)
      stats.lost = stats.lost + tonumber(ffi.cast("uint64_t*", d+off+16)[0])
    elseif ty == 5 then                               -- THROTTLE：内核限流，同样丢数据
      stats.throttled = stats.throttled + 1
    end
    r.tail = r.tail + sz
  end
  ffi.cast("uint64_t*", r.bp+1032)[0] = r.tail   -- 绝对偏移，绝不取模
end

------------------------------------------------------------------------
-- 参数
------------------------------------------------------------------------
local opt = { mode = "count", duration = 2, keys = "comm", limit = 8 }
local probe_specs, entry_spec, exit_spec, args = {}, nil, nil, {}
do
  local i = 1
  local function val() i = i + 1 return arg[i] end
  while arg and arg[i] do
    local a = arg[i]
    if     a == "--mode"     then opt.mode = val()
    elseif a == "--probe"    then probe_specs[#probe_specs+1] = val()
    elseif a == "--entry"    then entry_spec = val()
    elseif a == "--exit"     then exit_spec = val()
    elseif a == "--arg"      then args[#args+1] = val()
    elseif a == "--duration" then opt.duration = tonumber(val())
    elseif a == "--key"      then opt.keys = val()
    elseif a == "--str"      then opt.strfield = val()
    elseif a == "--pid"      then opt.pid = tonumber(val())
    elseif a == "--limit"    then opt.limit = tonumber(val())
    elseif a == "--freq"     then opt.freq = tonumber(val())
    elseif a == "--event"    then opt.event = val()
    elseif a == "--ring-size" then RING_PAGES = math.max(1, math.min(1024, tonumber(val()) or 8))
    elseif a == "--flame"    then opt.flame = val()
    elseif a == "--heat"     then opt.heat = val()
    elseif a == "--heat-top" then opt.heat_top = tonumber(val())
    elseif a == "--rank"     then opt.rank = val()
    elseif a == "--rank-top" then opt.rank_top = tonumber(val())
    elseif a == "--rank-by"  then opt.rank_by = tostring(val())
    elseif a == "--sym"      then opt.sym = true
    elseif a == "--json"     then opt.json = true
    else io.stderr:write("未知参数: "..tostring(a).."\n") os.exit(2) end
    i = i + 1
  end
end

local function fail(msg)
  io.stderr:write("[trace_engine] "..tostring(msg).."\n")
  cleanup()
  os.exit(3)
end

local argstr = (#args > 0) and table.concat(args, " ") or nil
cleanup()   -- 启动自愈：清掉上次异常退出遗留的 lite_* 探针

if opt.mode == "oncpu" then                       -- 纯 perf 事件采样，一个探针都不需要
  -- 什么都不注册
elseif opt.mode == "offcpu" then
  if #probe_specs == 0 then probe_specs = { "tracepoint:sched:sched_switch" } end
  for _, s in ipairs(probe_specs) do
    local p, err = add_probe(s, argstr)
    if not p then fail(err) end
  end
elseif opt.mode == "latency" then
  local pe, e1 = add_probe(entry_spec, argstr)
  if not pe then fail(e1) end
  local px, e2 = add_probe(exit_spec)
  if not px then fail(e2) end
  opt.entry_probe, opt.exit_probe = pe, px
else
  for _, s in ipairs(probe_specs) do
    local p, err = add_probe(s, argstr)
    if not p then fail(err) end
  end
end
if #probes == 0 and opt.mode ~= "oncpu" then fail("没有探针") end
local by_id = {}
for _, p in ipairs(probes) do by_id[p.id] = p end

------------------------------------------------------------------------
-- comm 缓存
------------------------------------------------------------------------
local comm_cache, comm_n = {}, 0
local COMM_MAX = 4096            -- 长跑 / 大量 pid 时不再无限增长
local function comm_of(pid)
  local c = comm_cache[pid]
  if c then return c end
  local s = rf("/proc/"..pid.."/comm")
  c = s and s:gsub("%s+$", "") or ("pid"..pid)
  if comm_n < COMM_MAX then comm_cache[pid] = c comm_n = comm_n + 1 end
  return c
end

------------------------------------------------------------------------
-- 直方图（us，log2 桶）
------------------------------------------------------------------------
local function new_hist() return { n = 0, sum = 0, max = 0, b = {} } end
local function hist_add(h, ns)
  h.n = h.n + 1
  h.sum = h.sum + ns
  if ns > h.max then h.max = ns end
  local us = ns / 1000
  local k = 0
  while us >= 2^(k+1) and k < 40 do k = k + 1 end
  h.b[k] = (h.b[k] or 0) + 1
end
local function hist_json(h)
  local out, acc, p50, p99 = {}, 0, nil, nil
  local ks = {}
  for k in pairs(h.b) do ks[#ks+1] = k end
  table.sort(ks)
  local t50, t99 = math.floor(h.n*0.5+0.5), math.floor(h.n*0.99+0.5)
  for _, k in ipairs(ks) do
    acc = acc + h.b[k]
    if not p50 and acc >= t50 then p50 = 2^k end
    if not p99 and acc >= t99 then p99 = 2^k end
    out[#out+1] = { us = 2^k, count = h.b[k] }
  end
  return { count = h.n, avg_us = h.n > 0 and (h.sum/h.n/1000) or 0,
           max_us = h.max/1000, p50_us = p50 or 0, p99_us = p99 or 0, hist = out }
end

------------------------------------------------------------------------
-- 模式
------------------------------------------------------------------------
local result = { mode = opt.mode, duration = opt.duration,
                 probes = {}, events = 0 }

local function run_count()
  local res, total = {}, 0
  local fds = {}
  -- count 用 period=0（只计数不采样）：--pid 时按 tid 展开 + inherit，否则每 CPU 一条
  for _, t in ipairs(targets(opt.pid, true, 1)) do
    local fd = perf_open(probes[1].id, t.pid, t.cpu, 0, 0, t)
    if fd then
      ffi.C.ioctl(fd, 0x2400, ffi.cast("long", 1))
      fds[#fds+1] = { fd = fd, cpu = t.cpu, tid = t.tid }
    end
  end
  if #fds == 0 then fail("perf_event_open 全部失败（需 root + perf_event_paranoid<=0）") end
  sleep_seconds(opt.duration)
  for _, f in ipairs(fds) do
    ffi.C.ioctl(f.fd, 0x2401, ffi.cast("long", 0))
    local b = ffi.new("uint64_t[1]")
    ffi.C.read(f.fd, b, ffi.cast("unsigned long", 8))
    local c = tonumber(b[0])
    total = total + c
    if c > 0 then res[#res+1] = { cpu = f.cpu, tid = f.tid, count = c } end
    ffi.C.close(f.fd)
  end
  table.sort(res, function(a, b) return a.count > b.count end)
  result.per_cpu, result.count = res, total
  result.rate = total / opt.duration
end

local function run_samples()
  local st = bit.bor(SAMPLE_TID, SAMPLE_TIME, SAMPLE_CPU, SAMPLE_RAW)
  -- 每个探针 × 每个目标一份 ring：多 --probe 不再被静默丢掉
  local P = ring_pool(st, false, opt.pid)
  P.sync()
  if #P.rings == 0 then fail("ring 建立失败" .. ring_err_note()) end
  local out, total = {}, 0
  local deadline = now_s() + opt.duration
  local function drain()
    for _, r in ipairs(P.rings) do
      walk(r, by_id, function(pr, pid, tid, tm, raw, rl, ccp, nr, cpu)
        total = total + 1
        if #out < opt.limit then
          local ev = decode(pr, raw, pid, opt.strfield)
          ev.pid, ev.tid, ev.time_ns = pid, tid, tm
          ev.cpu = cpu or r.cpu
          ev.probe, ev.comm = pr.name, comm_of(pid)
          out[#out+1] = ev
        end
      end)
    end
  end
  while wait_ready(P.pfd, P.npfd, deadline) do
    drain() P.reap() P.sync()               -- 先取数，再收死 ring，再给新线程补 ring
  end
  drain()                                  -- 收尾：已到 ring 里但没唤醒 poll 的尾巴
  P.close_all()
  result.samples, result.events = out, total
end

------------------------------------------------------------------------
-- latency：entry/exit 按 tid 配对
------------------------------------------------------------------------
local function key_of(ev)
  local k = opt.keys
  if k == "comm" then return comm_of(ev.pid) end
  if k == "pid" then return "pid:"..ev.pid end
  if k == "tid" then return "tid:"..ev.tid end
  if ev[k] ~= nil then return tostring(ev[k]) end
  return tostring(ev.filename or ev.file or ev.name or ev.__probe_ip or "?")
end

local function run_latency()
  local st = bit.bor(SAMPLE_TID, SAMPLE_TIME, SAMPLE_CPU, SAMPLE_RAW)
  -- entry / exit 各一份 ring，挂到所有目标
  local P = ring_pool(st, false, opt.pid)
  P.sync()
  if #P.rings == 0 then fail("ring 建立失败" .. ring_err_note()) end

  local pend, hists = {}, {}
  local paired, unpaired, total = 0, 0, 0
  local eid, xid = opt.entry_probe.id, opt.exit_probe.id
  local deadline = now_s() + opt.duration
  local function drain()
    for _, r in ipairs(P.rings) do
      walk(r, by_id, function(pr, pid, tid, tm, raw, rl, ccp, nr, c) 
        total = total + 1
        if pr.id == eid then
          local ev = decode(pr, raw, pid, opt.strfield)
          ev.pid, ev.tid, ev.cpu = pid, tid, c or r.cpu
          -- 同一 tid 可能有多条 entry 没等到 exit：排队，别用后一条覆盖前一条
          local q = pend[tid]
          if not q then q = {} pend[tid] = q end
          q[#q+1] = { tm = tm, pid = pid, key = key_of(ev) }
          if #q > 64 then table.remove(q, 1) unpaired = unpaired + 1 end   -- 异常堆积时丢最老的
        else
          -- 只认最早一条 tm <= 本次 exit 的 entry，否则宁可不配对，也不记账负延迟
          local q, si = pend[tid], nil
          if q then
            for i = 1, #q do if q[i].tm <= tm then si = i break end end
          end
          if si then
            local s = table.remove(q, si)
            if #q == 0 then pend[tid] = nil end
            paired = paired + 1
            local k = s.key
            local h = hists[k]
            if not h then h = new_hist() hists[k] = h end
            hist_add(h, tm - s.tm)
          else
            unpaired = unpaired + 1
          end
        end
      end)
    end
  end
  while wait_ready(P.pfd, P.npfd, deadline) do
    drain() P.reap() P.sync()
  end
  drain()
  P.close_all()
  -- 只有 entry 没等到 exit 的也记成未配对，别让它悄悄消失
  for _, q in pairs(pend) do unpaired = unpaired + #q end   -- 队列里每条没配上的 entry 都算未配对
  pend = {}

  local keys = {}
  for k in pairs(hists) do keys[#keys+1] = k end
  table.sort(keys, function(a, b) return hists[a].n > hists[b].n end)
  local top, all = {}, new_hist()
  for i, k in ipairs(keys) do
    if i <= opt.limit then
      local j = hist_json(hists[k])
      j.key = k
      top[#top+1] = j
    end
    local h = hists[k]
    all.n, all.sum = all.n + h.n, all.sum + h.sum
    if h.max > all.max then all.max = h.max end
    for b, c in pairs(h.b) do all.b[b] = (all.b[b] or 0) + c end
  end
  result.events = total
  result.paired, result.unpaired = paired, unpaired
  result.top = top
  result.overall = hist_json(all)
end

------------------------------------------------------------------------
-- folded：内核栈符号化
------------------------------------------------------------------------
local ksym_addr = nil            -- nil = 未加载（不能初始化成 {}，否则缓存哨兵失效）
-- 内核地址超出 double 精度(2^53)：全程 16 位小写 hex 字符串比较（等长 hex 字典序 == 数值序）
local function hxstr(a)
  a = tostring(a):lower():gsub("0x", "")
  if #a < 16 then a = string.rep("0", 16 - #a) .. a end
  return a:sub(-16)
end

local function load_kallsyms()
  if ksym_addr then return end
  local txt = rf("/proc/kallsyms") or ""
  local lines = {}
  for addr, ty, nm in txt:gmatch("(%x+)%s+(%a)%s+([%w_%.]+)") do
    lines[#lines+1] = { hxstr(addr), nm }      -- 直接存原串，不经过 tonumber
  end
  table.sort(lines, function(a, b) return a[1] < b[1] end)
  ksym_addr = lines
end

-- key: 16 位 hex 串（调用方从 uint32 高低位拼，绝不 tonumber 64 位）
local function sym(key)
  load_kallsyms()
  local lo, hi, best = 1, #ksym_addr, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if ksym_addr[mid][1] <= key then best = ksym_addr[mid] lo = mid + 1 else hi = mid - 1 end
  end
  if not best then return nil end
  -- 偏移按 32 位切片算，稳定不丢精度
  local bh, bl = tonumber(best[1]:sub(1,8),16), tonumber(best[1]:sub(9,16),16)
  local ah, al = tonumber(key:sub(1,8),16),   tonumber(key:sub(9,16),16)
  local off = (ah - bh) * 4294967296 + (al - bl)
  if off < 0 or off >= 0x20000 then return nil end
  return off == 0 and best[2] or ("%s+0x%x"):format(best[2], off)
end

------------------------------------------------------------------------
-- util：一帧地址 → 名字
------------------------------------------------------------------------
-- 内核帧走 kallsyms；用户帧走 /proc/pid/maps（给 模块+文件偏移，
-- 能直接喂 addr2line -e libfoo.so <偏移>），否则一屏 0x55b3... 什么都看不出来。
local maps_cache, maps_n = {}, 0
local MAPS_MAX = 256                       -- 长跑 / 大量进程时不再无限缓存
local function load_maps(pid)
  local m = maps_cache[pid]
  if m then return m end
  m = {}
  local f = io.open("/proc/"..pid.."/maps")
  if f then
    for line in f:lines() do
      local a, b, off = line:match("^(%x+)%-(%x+)%s+%S+%s+(%x+)")
      if a then
        local path = line:match("%s(/[^%s]*)$")
        if path then path = path:gsub(" %(deleted%)$", "") end   -- 已删模块打不开，只留名字兜底
        m[#m+1] = { s = tonumber(a,16), e = tonumber(b,16), off = tonumber(off,16),
                    p = path, n = path and path:match("([^/]+)$") or nil }
      end
    end
    f:close()
  end
  table.sort(m, function(x, y) return x.s < y.s end)
  if maps_n < MAPS_MAX then maps_cache[pid] = m maps_n = maps_n + 1 end
  return m
end
-- ---------------------------------------------------------------------
-- --sym：把「模块+文件偏移」变成函数名。两路来源：
--   ① /tmp/perf-<pid>.map —— JIT（LuaJIT/Node/JVM）的运行时地址表，绝对地址
--   ② 模块自己的 ELF —— maps 给的是文件偏移，先按 PT_LOAD 折回 vaddr，
--      再在 .symtab（被 strip 的库只有 .dynsym）里二分最近的 STT_FUNC
-- 找不到符号就退回原来的「模块+偏移」，不加 --sym 时这段完全不参与。
-- ---------------------------------------------------------------------
local elf_cache, elf_n = {}, 0
local ELF_MAX = 32                     -- 别把几百个 .so 的符号表一直留着
local pmap_cache = {}
local sym_hit = 0                      -- 命中计数，只在报告里露一面

local function read_build_id(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a") f:close()
  if #data < 64 or data:sub(1, 4) ~= "\127ELF" then return nil end
  local buf = ffi.cast("const uint8_t*", data)
  local function u16(o) return ffi.cast("const uint16_t*", buf+o)[0] end
  local function u32(o) return ffi.cast("const uint32_t*", buf+o)[0] end
  local function u64(o) return tonumber(ffi.cast("const uint64_t*", buf+o)[0]) end
  local shoff, shentsize, shnum = u64(40), u16(58), u16(60)
  for i = 0, shnum - 1 do
    local o = shoff + i * shentsize
    if u32(o+4) == 7 then                                 -- SHT_NOTE
      local noff, nsz = u64(o+24), u64(o+32)
      local q = noff
      while q + 12 <= noff + nsz do
        local nsz2, descsz, ty = u32(q), u32(q+4), u32(q+8)
        local name_end = q + 12
        while buf[name_end] ~= 0 do name_end = name_end + 1 end
        if ty == 3 and ffi.string(buf+q+12, name_end-q-12) == "GNU" then
          local d = q + 12 + nsz2
          local t = {}
          for b = 0, math.min(descsz, 20) - 1 do t[#t+1] = ("%02x"):format(buf[d+b]) end
          return table.concat(t)
        end
        q = q + 12 + math.floor((nsz2 + 3) / 4) * 4 + math.floor((descsz + 3) / 4) * 4
      end
    end
  end
  return nil
end

local function elf_syms(path)
  local c = elf_cache[path]
  if c ~= nil then return c or nil end
  local f = io.open(path, "rb")
  if not f then elf_cache[path] = false return nil end
  local data = f:read("*a") f:close()
  if #data < 64 or data:sub(1, 4) ~= "\127ELF" then elf_cache[path] = false return nil end
  local buf = ffi.cast("const uint8_t*", data)      -- data 活着，指针有效
  local function u8(o) return buf[o] end
  local function u16(o) return ffi.cast("const uint16_t*", buf+o)[0] end
  local function u32(o) return ffi.cast("const uint32_t*", buf+o)[0] end
  local function u64(o) return tonumber(ffi.cast("const uint64_t*", buf+o)[0]) end
  local shoff, shentsize, shnum = u64(40), u16(58), u16(60)
  local phoff, phnum, phentsize = u64(32), u16(56), u16(54)
  local pl = {}
  for i = 0, phnum - 1 do
    local o = phoff + i * phentsize
    if u32(o) == 1 then pl[#pl+1] = { o = u64(o+8), v = u64(o+16), f = u64(o+32) } end
  end
  local pick
  for i = 0, shnum - 1 do
    local o = shoff + i * shentsize
    if u32(o+4) == 2 then pick = o break end          -- .symtab 优先
  end
  if not pick then
    for i = 0, shnum - 1 do
      local o = shoff + i * shentsize
      if u32(o+4) == 11 then pick = o break end       -- strip 过的只剩 .dynsym
    end
  end
  local syms = {}
  if pick then
    local link, off, size, ent = u32(pick+40), u64(pick+24), u64(pick+32), u64(pick+56)
    if ent > 0 then
      local stroff = u64(shoff + link * shentsize + 24)
      for j = 0, math.floor(size / ent) - 1 do
        local so = off + j * ent
        local nm, info, va, sz = u32(so), u8(so+4), u64(so+8), u64(so+16)
        local ty = info % 16
        if nm ~= 0 and va ~= 0 and (ty == 2 or ty == 10) then   -- FUNC / GNU_IFUNC
          local e = stroff + nm
          local q = e
          while buf[q] ~= 0 do q = q + 1 end
          syms[#syms+1] = { v = va, sz = sz, n = ffi.string(buf+e, q-e) }
        end
      end
    end
  end
  table.sort(syms, function(a, b) return a.v < b.v end)
  for i = 1, #syms - 1 do           -- 汇编标签常没 st_size，用下一个符号当上界
    if syms[i].sz == 0 then syms[i].sz = syms[i+1].v - syms[i].v end
  end
  local r = { pl = pl, syms = syms }
  if elf_n < ELF_MAX then elf_cache[path] = r elf_n = elf_n + 1 end
  return r
end

-- 发行版把符号表单独放进 debuginfo 包：模块里没有 FUNC 时，
-- 按 .note.gnu.build-id 找 /usr/lib/debug/.build-id/xx/rest.debug，
-- 那个文件段布局与自身一致，pl/syms 可以直接顶替。
local function elf_debug_syms(path)
  local id = read_build_id(path)
  if not id then return nil end
  local dbg = ("/usr/lib/debug/.build-id/%s/%s.debug"):format(id:sub(1, 2), id:sub(3))
  if not io.open(dbg) then return nil end
  return elf_syms(dbg)
end

local function elf_lookup(path, fileoff)
  local e = elf_syms(path)
  if e and #e.syms == 0 then e = elf_debug_syms(path) end
  if not e or #e.syms == 0 then return nil end
  local va
  for _, s in ipairs(e.pl) do
    if fileoff >= s.o and fileoff < s.o + s.f then va = s.v + (fileoff - s.o) break end
  end
  if not va then return nil end
  local syms = e.syms
  local lo, hi, best = 1, #syms, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if syms[mid].v <= va then best = syms[mid] lo = mid + 1 else hi = mid - 1 end
  end
  if not best then return nil end
  local d = va - best.v
  if d >= best.sz then return nil end       -- 落在函数尾巴外的空洞，别硬塞个名字
  return best.n, d
end

local function perf_map(pid)
  local c = pmap_cache[pid]
  if c ~= nil then return c or nil end
  local hs = {}
  for line in (rf("/tmp/perf-"..pid..".map") or ""):gmatch("[^\n]+") do
    local a, sz, nm = line:match("^(%x+)%s+(%x+)%s+(.+)$")
    if a then
      local st = tonumber(a, 16)
      hs[#hs+1] = { s = st, e = st + tonumber(sz, 16), n = nm }
    end
  end
  table.sort(hs, function(x, y) return x.s < y.s end)
  pmap_cache[pid] = (#hs > 0) and hs or false
  return pmap_cache[pid] or nil
end

local function sym_lookup(pid, a, best, fileoff)
  local pm = perf_map(pid)
  if pm then                                    -- JIT 代码：maps 里是 anon，只有 perf map 认识
    local lo, hi, hit = 1, #pm, nil
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      if pm[mid].s <= a then hit = pm[mid] lo = mid + 1 else hi = mid - 1 end
    end
    if hit and a < hit.e then sym_hit = sym_hit + 1 return hit.n end
  end
  if best and best.p then
    local nm, off = elf_lookup(best.p, fileoff)
    if nm then
      sym_hit = sym_hit + 1
      return off == 0 and nm or ("%s+0x%x"):format(nm, off)
    end
  end
  return nil
end

local ucache, ucache_n = {}, 0
local USCACHE_MAX = 65536

local function usym(pid, a)
  local c = ucache[pid]
  local v = c and c[a]
  if v then return v end
  local m = load_maps(pid)
  local lo, hi, best = 1, #m, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if m[mid].s <= a then best = m[mid] lo = mid + 1 else hi = mid - 1 end
  end
  local name
  if not best or a >= best.e then
    name = (opt.sym and sym_lookup(pid, a, nil, 0)) or ("[anon+0x%x]"):format(a)
  else
    -- 用户态地址 < 2^47，double 精确，可以直接算文件偏移
    local fileoff = a - best.s + best.off
    name = (opt.sym and sym_lookup(pid, a, best, fileoff))
        or ("%s+0x%x"):format(best.n or "[anon]", fileoff)
  end
  if ucache_n < USCACHE_MAX then             -- 同一叶子地址会反复出现，缓存省掉二分
    if not c then c = {} ucache[pid] = c end
    c[a] = name
    ucache_n = ucache_n + 1
  end
  return name
end

-- 一帧：内核地址走 sym()，用户地址走 usym()；
-- PERF_CONTEXT_* 是标记不是地址（值域 -4096..-1，即 lo32 >= 0xfffff000），跳过
local function frame_name(pid, hi32, lo32)
  if hi32 == 0xffffffff and lo32 >= 0xfffff000 then return nil end
  if hi32 >= 0xffff8000 then                        -- 内核空间：高位全 1
    local key = ("%08x%08x"):format(hi32, lo32)
    return sym(key) or ("0x" .. key)
  end
  return usym(pid, hi32 * 4294967296 + lo32)
end
-- callchain → 名字数组（内核给的就是 innermost-first）
local function stack_frames(pid, ccp, nr)
  local frames = {}
  for i = 0, nr-1 do
    local w = ffi.cast("uint32_t*", ccp + i*8)
    local n = frame_name(pid, w[1], w[0])           -- little-endian: [0]=低 [1]=高
    if n then frames[#frames+1] = n end
  end
  return frames
end
-- 反向拼成 root;...;leaf：leaf 才是「此刻忙/阻塞在这个函数」
local function stack_str(frames, rev)
  local t = {}
  if rev then for i = #frames, 1, -1 do t[#t+1] = frames[i] end
  else          for i = 1, #frames do t[#t+1] = frames[i] end end
  return table.concat(t, ";")
end

local SCHED_DROP = { ["__schedule"] = true, ["schedule"] = true,
                     ["schedule_idle"] = true, ["__schedule_loop"] = true,
                     ["finish_task_switch"] = true, ["finish_task_switch.isra.0"] = true,
                     ["__perf_event_task_sched_out"] = true, ["__perf_event_task_sched_in"] = true }
local function trim_sched(frames)
  local i = 1
  while i <= #frames and SCHED_DROP[(frames[i]:gsub("%+0x%x+$", ""))] do i = i + 1 end
  local o = {}
  for j = i, #frames do o[#o+1] = frames[j] end
  return o
end
-- 单调 ns（与 sched_switch 的 ftrace 时间戳同一时钟）。double 在 1.7e18 上
-- 只剩 ~400ns 分辨率，对 ms 级阻塞足够；换成两个 u64 桥接得不偿失。
local function now_ns()
  local ts = TS()
  ffi.C.clock_gettime(1, ts)
  return tonumber(ts.tv_sec) * 1e9 + tonumber(ts.tv_nsec)
end

-- /proc/<tid>/stat 的第 3 字段：R/S/D/t/Z。comm 可能带空格，得先吃掉括号。
local function proc_state(tid)
  local s = rf("/proc/"..tid.."/stat")
  if not s then return nil end
  return s:match("^%d+ %b() (%a)")
end

-- 已阻塞任务的真实内核栈（root 可读）。方向与 perf callchain 一致：内层在头。
local function proc_kstack(tid)
  local s = rf("/proc/"..tid.."/stack")
  if not s then return nil end
  local fr = {}
  for line in s:gmatch("[^\n]+") do
    local sym = line:match("^%s*%[<%d+>%]%s*(%S+)")
    if sym and sym ~= "0xffffffffffffffff" then
      fr[#fr+1] = (sym:gsub("%+0x%x+", ""):gsub("/0x%x+$", ""))
    end
  end
  if #fr == 0 then return nil end
  return stack_str(trim_sched(fr), true)
end

------------------------------------------------------------------------
-- oncpu：perf 软件时钟采样，看 CPU 时间烧在哪段代码
------------------------------------------------------------------------
-- sample_type 里绝不能带 RAW —— 这不是 tracepoint，没有 payload。
-- walk() 按「TID→TIME→CPU→CALLCHAIN」解，sraw=false 时直接把 callchain 交上来。
local function run_oncpu()
  local freq = opt.freq or 99
  if freq < 1 then freq = 1 end
  if freq > 100000 then freq = 100000 end
  local st = bit.bor(SAMPLE_TID, SAMPLE_TIME, SAMPLE_CPU, SAMPLE_CALLCHAIN)
  local src = { id = { type = PERF_TYPE_SOFTWARE, config = PERF_COUNT_SW_CPU_CLOCK,
                       freq = true, exclude_idle = true },
                key = "oncpu", period = freq }
  local P = ring_pool(st, true, opt.pid, { src })
  P.sync()
  if #P.rings == 0 then fail("ring 建立失败" .. ring_err_note()) end

  local acc, comms, total = {}, {}, 0
  local deadline = now_s() + opt.duration
  local function drain()
    for _, r in ipairs(P.rings) do
      walk(r, by_id, function(_, pid, _tid, _tm, _raw, _rl, ccp, nr)
        total = total + 1
        local line = stack_str(stack_frames(pid, ccp, nr), true)
        if line == "" then line = "[unknown]" end
        acc[line] = (acc[line] or 0) + 1
        local c = comm_of(pid)
        comms[c] = (comms[c] or 0) + 1
      end)
    end
  end
  while wait_ready(P.pfd, P.npfd, deadline) do
    drain() P.reap() P.sync()
  end
  drain()
  P.close_all()

  local arr = {}
  for k, v in pairs(acc) do arr[#arr+1] = { stack = k, count = v } end
  table.sort(arr, function(a, b) return a.count > b.count end)
  local top = {}
  for i = 1, math.min(#arr, opt.limit) do top[#top+1] = arr[i] end
  local cl = {}
  for k, v in pairs(comms) do cl[#cl+1] = { comm = k, count = v } end
  table.sort(cl, function(a, b) return a.count > b.count end)
  local ctop = {}
  for i = 1, math.min(#cl, opt.limit) do ctop[#ctop+1] = cl[i] end
  result.freq, result.events, result.stacks = freq, total, #arr
  result.top, result.comms = top, ctop
  result.frame_dir = "root-first"    -- stack_str(_, true) 已反成 root;...;leaf，叶子在末尾
end

------------------------------------------------------------------------
-- offcpu：sched_switch 配对 —— 切出到下次切入的间隔 = 阻塞/等锁/等 IO
------------------------------------------------------------------------
-- 切出那一刻的 callchain 就是「阻塞点」，所以栈必须和 prev 一起存下来。
-- 内核给的这个栈天然从 __schedule 开始，头几帧没有信息量，剥掉。

local function run_offcpu()
  local st = bit.bor(SAMPLE_TID, SAMPLE_TIME, SAMPLE_CPU, SAMPLE_RAW, SAMPLE_CALLCHAIN)
  -- 一律 per-CPU ring：sched_switch 的 prev/next 得同时看到，
  -- 按任务挂事件只会拿到自己那侧（切出），配对永远配不上。
  local P = ring_pool(st, true, nil)
  P.sync()
  if #P.rings == 0 then fail("ring 建立失败" .. ring_err_note()) end

  local want
  if opt.pid then
    want = { [opt.pid] = true }
    for _, t in ipairs(task_tids(opt.pid)) do want[t] = true end
  end

  local pend, np = {}, 0            -- pend[tid] = {tm, stack, state}
  local hists = {}
  local total, matched, blocked, preempted, unmatched = 0, 0, 0, 0, 0
  local MAX_PEND = 65536
  local migrated = 0                  -- 跨 CPU 迁回的任务数（仅诊断，区间本身是真的）            -- 全机模式下别让 pend 无限涨
  local deadline = now_s() + opt.duration
  local t0 = now_ns()
  local function hit(tid) return (not want) or want[tid] end

  -- 起始就已睡下的任务永远不会产生「切出」事件，直接配对会漏掉整段阻塞
  -- （拿 lite 自身测就是这样：全程卡在 wait4，配对=0）。用 /proc 状态+内核栈
  -- 把它假装成在 t0 切出，后面真切回时自然闭合。
  local seeded = 0
  if want then
    for tid in pairs(want) do
      local stt = proc_state(tid)
      if stt and stt ~= "R" and stt ~= "Z" and np < MAX_PEND then
        pend[tid] = { tm = t0, stack = proc_kstack(tid) or ("[起始已阻塞 "..stt.."]"), state = 1 }
        np = np + 1
        seeded = seeded + 1
      end
    end
  end

  local function close_at(ntid, tm, cpu)
    local p = pend[ntid]
    if not p then return end
    pend[ntid] = nil np = np - 1
    local dur = tm - p.tm
    if dur < 0 then return end
    if cpu and p.cpu and cpu ~= p.cpu then migrated = migrated + 1 end
    local h = hists[p.stack]
    if not h then h = new_hist() hists[p.stack] = h end
    hist_add(h, dur)
    matched = matched + 1
    if p.state == 0 then preempted = preempted + 1 else blocked = blocked + 1 end
  end

  -- 跨 CPU 合并重排。
  -- per-CPU ring 各自独立，drain 的顺序不代表事件发生的顺序：ring A 的「切出」
  -- 可能比 ring B 的「切回」更晚被读到。直接顺序配对会配不上（区间丢失），
  -- 或者把几段相邻的阻塞粘成一段超长区间（实测全机 100ms 睡眠报出 801ms，
  -- 绑单核就正常 —— 这就是病因）。像 perf 的 ordered_events 一样按时间戳
  -- 排序，并压住 HOLD_NS 不结算，等落后的 ring 追上来。
  local HOLD_NS = 200e6
  local mbuf, mlen = {}, 0

  local function apply(e)
    if e.ntid then close_at(e.ntid, e.tm, e.cpu) end
    local ptid = e.ptid
    -- 压缓冲期间 pend 状态会变，开区间前必须重新判空；line 也可能算不出
    if e.line and ptid and ptid ~= 0 and hit(ptid) and not pend[ptid] and np < MAX_PEND then
      pend[ptid] = { tm = e.tm, stack = e.line, state = e.st, cpu = e.cpu }
      np = np + 1
    end
  end

  local function flush(upto)
    if mlen == 0 then return end
    -- 待处理项必须连续存放：中途置 nil 会在数组里留洞，table.sort 依赖 # 求边界，
    -- 边界一错就会拿 nil 去比较。所以整表排序，再重建残留列表。
    local arr = mbuf
    table.sort(arr, function(a, b) return a.tm < b.tm end)
    local keep, kn = {}, 0
    for k = 1, mlen do
      local e = arr[k]
      if e.tm <= upto then apply(e)
      else kn = kn + 1 keep[kn] = e end
    end
    mbuf, mlen = keep, kn
  end

  local function drain()
    local newest = 0
    for _, r in ipairs(P.rings) do
      walk(r, by_id, function(pr, pid, _tid, tm, raw, _rl, ccp, nr, cpu)
        total = total + 1
        if tm > newest then newest = tm end
        local ev = decode(pr, raw, pid)
        local ntid, ptid = tonumber(ev.next_pid), tonumber(ev.prev_pid)
        local line
        if ptid and ptid ~= 0 and hit(ptid) then
          line = stack_str(trim_sched(stack_frames(ptid, ccp, nr)), true)
          if line == "" then line = "[unknown]" end
        end
        mlen = mlen + 1
        mbuf[mlen] = { tm = tm, ntid = ntid, ptid = ptid, line = line,
                       st = tonumber(ev.prev_state) or 0, cpu = cpu }
      end)
    end
    if mlen > 200000 then flush(math.huge)      -- 兜底，别让缓冲撑爆
    else flush(newest - HOLD_NS) end
  end

  while wait_ready(P.pfd, P.npfd, deadline) do
    drain() P.reap() P.sync()
  end
  drain()
  flush(math.huge)                              -- 收尾：把压住的窗口全部结算
  P.close_all()
  -- 结束时仍睡着的区间：截到 deadline 结算并标为截断，而不是扔掉。
  -- 否则「采样窗口内一直阻塞」这种最该被抓到的样本反而消失。
  local t_end = now_ns()
  local trunc = 0
  for tid, p in pairs(pend) do
    local dur = t_end - p.tm
    if dur > 0 then
      local h = hists[p.stack]
      if not h then h = new_hist() hists[p.stack] = h end
      hist_add(h, dur)
      matched = matched + 1
      blocked = blocked + 1
      trunc = trunc + 1
    end
  end
  unmatched = trunc                    -- 未回切（区间被截断）
  pend, np = {}, 0

  local arr, allh = {}, new_hist()
  for k, h in pairs(hists) do
    local j = hist_json(h)
    j.stack = k
    j.total_ms = h.sum / 1e6
    arr[#arr+1] = j
    allh.n, allh.sum = allh.n + h.n, allh.sum + h.sum
    if h.max > allh.max then allh.max = h.max end
    for b, c in pairs(h.b) do allh.b[b] = (allh.b[b] or 0) + c end
  end
  table.sort(arr, function(a, b) return a.total_ms > b.total_ms end)
  local top = {}
  for i = 1, math.min(#arr, opt.limit) do top[#top+1] = arr[i] end
  result.events, result.matched = total, matched
  result.blocked, result.preempted, result.unmatched = blocked, preempted, unmatched
  result.seeded = seeded
  result.migrated = migrated
  result.top, result.overall = top, hist_json(allh)
  result.frame_dir = "root-first"    -- stack_str(_, true) 反成 root;...;leaf，阻塞点(leaf)在末尾
  result.unit = "ms"                 -- 权重是阻塞时长，不是样本数
end

local function run_folded()
  local st = bit.bor(SAMPLE_TID, SAMPLE_TIME, SAMPLE_CPU, SAMPLE_RAW, SAMPLE_CALLCHAIN)
  local P = ring_pool(st, true, opt.pid)
  P.sync()
  if #P.rings == 0 then fail("ring 建立失败" .. ring_err_note()) end
  local acc, total = {}, 0
  local np = #probes
  local function short(p) return p:match("([^:]+)$") or p end
  local deadline = now_s() + opt.duration
  local function drain()
    for _, r in ipairs(P.rings) do
      walk(r, by_id, function(pr, pid, tid, tm, raw, rl, ccp, nr)
        total = total + 1
        local frames = {}
        for i = 0, nr-1 do
          local w = ffi.cast("uint32_t*", ccp + i*8)
          local lo32, hi32 = w[0], w[1]              -- little-endian: [0]=低 [1]=高
          if not (hi32 == 0xffffffff and lo32 >= 0xffff0000) then   -- 跳过 context marker
            local key = ("%08x%08x"):format(hi32, lo32)
            frames[#frames+1] = sym(key) or ("0x" .. key)
          end
        end
        if #frames > 0 then
          local line = table.concat(frames, ";")
          if np > 1 then line = short(pr.name) .. ";" .. line end   -- 多探针不混栈
          acc[line] = (acc[line] or 0) + 1
        end
      end)
    end
  end
  while wait_ready(P.pfd, P.npfd, deadline) do
    drain() P.reap() P.sync()
  end
  drain()
  P.close_all()
  local arr = {}
  for k, v in pairs(acc) do arr[#arr+1] = { stack = k, count = v } end
  table.sort(arr, function(a, b) return a.count > b.count end)
  local top = {}
  for i = 1, math.min(#arr, opt.limit) do top[#top+1] = arr[i] end
  result.events, result.folded = total, top
  result.stacks = #arr
  result.frame_dir = "leaf-first"
end

------------------------------------------------------------------------
-- 执行 + 输出
------------------------------------------------------------------------
if opt.mode == "count" then run_count()
elseif opt.mode == "samples" then run_samples()
elseif opt.mode == "latency" then run_latency()
elseif opt.mode == "folded" then run_folded()
elseif opt.mode == "oncpu" then run_oncpu()
elseif opt.mode == "offcpu" then run_offcpu()
else fail("未知 mode: "..opt.mode) end

for _, p in ipairs(probes) do result.probes[#result.probes+1] = p.name end
cleanup()
result.lost, result.throttled = stats.lost, stats.throttled
if opt.sym then result.sym, result.sym_hits = true, sym_hit end
if stats.lost > 0 or stats.throttled > 0 then
  io.stderr:write(("[trace_engine] 警告：ring 溢出，丢事件 %d 个 / throttle %d 次，" ..
                   "统计偏小；用 --ring-size 调大或收窄探针范围重跑\n"):format(stats.lost, stats.throttled))
end

-- --flame / --heat / --rank：采完直接出图，全程进程内（tools/render.lua + cairo/librsvg），零 Python
local RENDER = {
  flame = { what = "火焰图",   modes = { oncpu = 1, offcpu = 1, folded = 1 } },
  heat  = { what = "热力图",   modes = { oncpu = 1, offcpu = 1, folded = 1 } },
  rank  = { what = "卡点排行", modes = { oncpu = 1, offcpu = 1, folded = 1 } },
}
-- render.lua / svgpng.lua 里都有 ffi.cdef，dofile 两次会 "attempt to redefine"；缓存住只加载一次
local MODCACHE = {}
local function load_lua(path)
  local m = MODCACHE[path]
  if not m then m = dofile(path) MODCACHE[path] = m end
  return m
end
local function render(kind, out)
  local cfg = RENDER[kind]
  if not cfg.modes[opt.mode] then
    io.stderr:write(("[trace_engine] --%s 只支持 oncpu/offcpu/folded，当前 %s 跳过\n"):format(kind, tostring(opt.mode)))
    return
  end
  local self = arg[0] or "engine.lua"
  local dir = self:match("^(.*)/[^/]*$") or "."
  -- 渲染脚本跟引擎同目录（lite 仓库 = lua/trace/render.lua）；后面两条是迁移前
  -- 老仓（src/engine.lua + tools/render.lua）的候选，本机老仓还在就别删。
  local fp
  for _, c in ipairs({ dir.."/render.lua", dir.."/tools/render.lua",
                       dir.."/../tools/render.lua", "tools/render.lua" }) do
    if io.open(c) then fp = c break end
  end
  if not fp then fail("找不到 render.lua（应与 engine.lua 同目录）") end
  -- svgpng.lua 跟渲染脚本同目录：不能拿 arg[0] 的 dir 拼（src/engine.lua 的 dir 是 src）
  local pnglua = fp:gsub("[^/]*$", "") .. "svgpng.lua"
  local label = ({ oncpu = "on-CPU", offcpu = "off-CPU 阻塞时长", folded = "折叠栈" })[opt.mode] or opt.mode
  local rate = result.freq and ("@"..result.freq.."Hz") or (result.unit == "ms" and "@阻塞时长" or "")
  local t = ("%s · %s · %ds %s%s"):format(label,
    os.date("%m-%d %H:%M"), opt.duration, rate,
    opt.pid and (" · pid "..opt.pid) or "")
  -- 渲染脚本只出 SVG；要 PNG 就在进程内用 cairo+librsvg 转（2 倍图，汇报材料直接可用）
  local want_png = out:lower():match("%.png$") ~= nil
  local tmp = want_png and os.tmpname() or nil
  local svgout = want_png and (tmp .. ".svg") or out
  local opts = { heat_top = opt.heat_top, rank_top = opt.rank_top, rank_by = opt.rank_by }
  local rend = load_lua(fp)
  local ok, err = rend.render(kind, result, svgout, t, opts)
  if not ok then
    io.stderr:write(("[trace_engine] %s 渲染失败：%s\n"):format(cfg.what, tostring(err)))
    return
  end
  local note, kindtxt = "", want_png and "PNG" or "SVG(可交互)"
  if want_png then
    local pok, perr = pcall(function()
      local svg = io.open(svgout, "rb")
      if not svg then error("读不到临时 SVG: " .. svgout, 0) end
      local body = svg:read("*a") svg:close()
      local png = load_lua(pnglua)
      local done, why = png.render(body, out, 2)
      if not done then error(why, 0) end
    end)
    if not pok then note = "(PNG 转换失败：" .. tostring(perr) .. "，SVG 留在 " .. svgout .. ")" end
    if pok then os.remove(svgout) end        -- 只删中间产物；直接要 .svg 时不能删用户给的路径
  end
  io.stderr:write(("[trace_engine] %s %s -> %s %s\n"):format(cfg.what, kindtxt, out, note))
end

if opt.flame then render("flame", opt.flame) end
if opt.heat  then render("heat",  opt.heat)  end
if opt.rank  then render("rank",  opt.rank)  end

if opt.json then
  print(require("cjson").encode(result))
else
  local function lostnote()
    if (result.lost or 0) > 0 or (result.throttled or 0) > 0 then
      return ("（丢失 %d / 限流 %d，实际更大）"):format(result.lost or 0, result.throttled or 0)
    end
    return ""
  end
  local pname = table.concat(result.probes, ",")
  local function human(n) if n > 1e6 then return ("%.1fM"):format(n/1e6) elseif n > 1e3 then return ("%.1fk"):format(n/1e3) end return tostring(n) end
  if opt.mode == "count" then
    print(("%s  %s 次 / %gs  (%.0f/s)"):format(result.probes[1], human(result.count), opt.duration, result.rate))
    for _, r in ipairs(result.per_cpu) do
      local lab = r.tid and ("tid "..r.tid) or ("cpu"..r.cpu)
      print(("  %-8s %s"):format(lab, human(r.count)))
    end
  elseif opt.mode == "latency" then
    print(("%s → %s  events=%d paired=%d unpaired=%d%s"):format(result.probes[1], result.probes[2],
      result.events, result.paired, result.unpaired, lostnote()))
    local o = result.overall
    print(("  overall n=%d avg=%.1fus p50=%dus p99=%dus max=%.1fus"):format(o.count, o.avg_us, o.p50_us, o.p99_us, o.max_us))
    for _, t in ipairs(result.top) do
      print(("  %-24s n=%-7d avg=%7.1fus p99=%-6dus max=%.1fus"):format(t.key, t.count, t.avg_us, t.p99_us, t.max_us))
    end
  elseif opt.mode == "folded" then
    print(("%s  events=%d stacks=%d%s"):format(pname, result.events, result.stacks, lostnote()))
    for _, f in ipairs(result.folded) do print(("  %6d  %s"):format(f.count, f.stack)) end
  elseif opt.mode == "oncpu" then
    print(("oncpu  %dHz  样本=%d 栈种类=%d%s"):format(result.freq, result.events, result.stacks, lostnote()))
    for _, f in ipairs(result.top) do
      local pct = result.events > 0 and (f.count * 100 / result.events) or 0
      print(("  %5.1f%% %6d  %s"):format(pct, f.count, f.stack))
    end
    if #result.comms > 0 then
      local cs = {}
      for _, c in ipairs(result.comms) do cs[#cs+1] = ("%s=%d"):format(c.comm, c.count) end
      print("  comm: " .. table.concat(cs, " "))
    end
  elseif opt.mode == "offcpu" then
    print(("offcpu  events=%d 配对=%d 阻塞=%d 被抢占=%d 未回切=%d 补种=%d 迁移=%d%s"):format(
      result.events, result.matched, result.blocked, result.preempted, result.unmatched,
      result.seeded or 0, result.migrated or 0, lostnote()))
    local o = result.overall
    print(("  overall n=%d avg=%.1fus p50=%dus p99=%dus max=%.1fus"):format(
      o.count, o.avg_us, o.p50_us, o.p99_us, o.max_us))
    for _, t in ipairs(result.top) do
      print(("  total=%8.2fms n=%-6d avg=%7.1fus p99=%-6dus max=%8.2fms  %s"):format(
        t.total_ms, t.count, t.avg_us, t.p99_us, t.max_us/1000, t.stack))
    end
  else
    local np = #result.probes
    local function short(p) return p:match("([^:]+)$") or p end
    print(("%s  events=%d%s"):format(pname, result.events, lostnote()))
    for _, e in ipairs(result.samples) do
      local kv = {}
      for k, v in pairs(e) do
        if k ~= "probe" and k ~= "comm" then
          if type(v) == "number" and v >= 2^31 and v % 1 == 0 then v = ("%.0f"):format(v) end  -- 指针/u64 别打成浮点
          kv[#kv+1] = k.."="..tostring(v)
        end
      end
      table.sort(kv)
      local tag = np > 1 and (short(e.probe) .. " ") or ""
      print(("  [%s] %s%s/%d %s"):format(e.comm, tag, e.pid, e.tid, table.concat(kv, " ")))
    end
  end
end
