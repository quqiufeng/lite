-- tools/trace_check.lua —— trace engine 两侧符号化的离线回归
--
-- 为什么要单独一条：engine.lua 的符号化有两条路，都出过「跑通了但名字全是兜底」的错：
--   ① 内核侧：kptr_restrict>0 时非 root 读 /proc/kallsyms 地址全是 0（名字在、地址被糊），
--      于是退到 /boot/System.map-<release>。这条**退化路**没法用真采样验 —— 内核帧采样要
--      root，而 root 下 /proc/kallsyms 又可读，退化分支永远不触发。所以 engine 加了
--      `--ksym` 自检开关，直接问它「符号从哪来、多少条」。
--   ② 用户态侧：`--sym` 读模块 ELF 的 .symtab；被 strip -s 的二进制没有符号表，只能靠
--      .eh_frame 的 FDE 边界出 sub_<入口>。曾经两遍 walk 的 CIE 指针错位、pcrel 判据写反，
--      结果是「0 条 FDE → 整屏 0x55b3…」而 samples 正常、exit 0。
--
-- 断言挑用户能看见的东西：engline 打印的源文件名/条数、栈里有没有 sub_%x / hot_alpha。
-- 用户态那侧要 perf_event_open（perf_event_paranoid=2 时 engine 不带 exclude_kernel，
-- 非 root 直接 EACCES），所以走 sudo -n；拿不到 root 就 SKIP 而不是 FAIL。
local ffi = require("ffi")
local cjson = require("cjson")

local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
local lua_bin = root .. "/tools/lite-lua"
local engine = root .. "/lua/trace/engine.lua"

local function sh(cmd)                        -- 返回 输出, 退出码
  local p = io.popen(cmd .. " 2>&1")
  local s = p:read("*a")
  local ok = p:close()
  return s, ok and 0 or 1
end

local fails, total = 0, 0
local function check(cond, name, detail)
  total = total + 1
  if not cond then
    fails = fails + 1
    io.stderr:write(("  FAIL %s (%s)\n"):format(name, tostring(detail)))
  end
end

-- ① 内核符号源：非 root 下必须能报出「多少条」并且非空 -------------------------
local out, rc = sh(("%s %s --ksym"):format(lua_bin, engine))
local n = tonumber(out:match("^(%d+) 条"))
local src = out:match("源=(%S+)") or ""
check(rc == 0, "ksym.rc", (out:gsub("\n.*", "")))
check(n and n > 10000, "ksym.count", out:gsub("\n.*", ""))
-- 非 root 且 kptr_restrict>0：必须退到 System.map；kptr_restrict=0 时读 /proc/kallsyms 也对
local rel = (io.open("/proc/sys/kernel/osrelease") or {}):read("*l") or ""
rel = rel:match("^%s*(.-)%s*$") or ""
check(src == "/proc/kallsyms" or src == "/boot/System.map-" .. rel or src == "/boot/System.map",
      "ksym.source", src)

-- ② 用户态符号化：有符号表 → 函数名；strip -s → sub_<入口>（.eh_frame FDE）---------
local D = (os.tmpname()):gsub("[^/]+$", "") .. "trace_check"
sh(("rm -rf %s && mkdir -p %s"):format(D, D))
local SPIN = [[
volatile long sink;
__attribute__((noinline)) void hot_alpha(void){ for(long i=0;i<400000000L;i++) sink+=i; }
__attribute__((noinline)) void hot_beta(void){  for(long i=0;i<400000000L;i++) sink-=i; }
int main(void){ for(;;){ hot_alpha(); hot_beta(); } return (int)(sink&1); }
]]
local f = assert(io.open(D .. "/spin.c", "w")); f:write(SPIN); f:close()
local _, cc = sh(("cc -O1 -o %s/spin %s/spin.c"):format(D, D))
if cc ~= 0 then
  io.stderr:write("SKIP trace (cc 不可用)\n")
  sh("rm -rf " .. D)
  print(("OK trace (%d checks)"):format(total))
  os.exit(fails > 0 and 1 or 0)
end
sh(("cp %s/spin %s/spin_strip && strip -s %s/spin_strip"):format(D, D, D))

-- 采样脚本：起目标 → 采 1s → 收工。engine 要 root（perf_event_paranoid=2 拒非 root），
-- 所以整段塞进一个 sudo 脚本里跑，目标进程与采样器同 uid 才看得见彼此。
local run = D .. "/run.sh"
f = assert(io.open(run, "w"))
f:write(([[
#!/bin/sh
# $1 = 目标二进制。engine 要 root，目标也以 root 起，同 uid 才采得到。
"$1" >/dev/null 2>&1 &
pid=$!
sleep 0.3
%s %s --mode oncpu --pid $pid --duration 1 --freq 99 --sym --json --limit 6 2>&1
rc=$?
kill $pid 2>/dev/null
exit $rc
]]):format(lua_bin, engine))
f:close()

local function sample(bin)
  return sh(("sudo -n sh %s %s"):format(run, bin))
end

local o1, r1 = sample(D .. "/spin")
if r1 ~= 0 and (o1:find("sudo") or o1:find("password") or o1:find("errno=13")) then
  io.stderr:write("  SKIP trace.sym* (无免密 sudo 或 perf 被挡)\n")
else
  local okj, j = pcall(cjson.decode, o1:match("(%b{})") or "")
  check(okj and type(j) == "table", "sym.json", o1:sub(1, 200))
  local function find_sub(d, pat)
    for _, t in ipairs((d and d.top) or {}) do
      if type(t.stack) == "string" and t.stack:find(pat) then return t.stack end
    end
  end
  check(find_sub(okj and j or nil, "hot_alpha") ~= nil, "sym.name",
        okj and ((j.top or {})[1] or {}).stack or "no hot_alpha")
  check(find_sub(okj and j or nil, "0x%x+;0x%x+$") == nil, "sym.no_hex_frames",
        okj and ((j.top or {})[1] or {}).stack or "")

  local o2 = sample(D .. "/spin_strip")
  local okj2, j2 = pcall(cjson.decode, o2:match("(%b{})") or "")
  check(okj2 and type(j2) == "table", "strip.json", o2:sub(1, 200))
  local sub = find_sub(okj2 and j2 or nil, "sub_%x")
  check(sub ~= nil, "strip.has_sub", (okj2 and ((j2.top or {})[1] or {}).stack or ""))

  -- 权限受限时 engine 会以 rc≠0 + errno 说明退出：这种环境问题不算回归
  if not okj and (o1 .. o2):find("errno=") then
    io.stderr:write("  SKIP trace.sym* (perf_event_open 被拒)\n")
    fails = math.max(0, fails - 4); total = math.max(0, total - 4)
  end
end

sh("rm -rf " .. D)
if fails > 0 then
  io.stderr:write(("FAIL trace (%d/%d 断言失败)\n"):format(fails, total))
  os.exit(1)
end
print(("OK trace (%d checks)"):format(total))
