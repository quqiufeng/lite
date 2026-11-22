-- tools/perfprobe_check.lua —— perfprobe 离线回归（符号归因 + 错误分支）
--
-- 为什么要有这条：helper/perfprobe.c 里两个 bug 都是「看起来成功了其实全错」，
-- 不跑真进程根本看不出来：
--   1) elf_sym 拿文件偏移（ip - map.start + map.off）去比 st_value（vaddr）。
--      只有 PIE/so 能满足 p_vaddr == p_offset，ET_EXEC（-no-pie）差一个加载基址，
--      二分查找直接返回 NULL —— 表现是整张表全 [nosym]，而 samples 正常、exit 0。
--   2) perfprobe.lua 写 `if not d.ok`：cjson 把 0 解成 Lua 的 0（真值），
--      于是 exec 失败 / perf_event_open EACCES / 目标太短 四种错误全渲染成成功。
--
-- 断言挑用户能看见的东西：热函数名字、错误文本里有没有 stage 标签。
-- 全离线：现场 cc 编两个 fixture（PIE 与 -no-pie 各一个），不依赖预编译产物。
-- paranoid > 2 时普通用户采不到别人的 CPU，这里 fork 的是自己的子进程所以 =2 就够；
-- 真的被挡住（paranoid 3/4）就 SKIP 而不是 FAIL —— 那是环境问题不是回归。
local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
local cjson = require("cjson")
local ffi = require("ffi")

local function sh(cmd)                        -- 返回 输出, 退出码
    local p = io.popen(cmd .. " 2>&1")
    local s = p:read("*a")
    local ok = p:close()
    return s, ok and 0 or 1
end

local dir = os.tmpname()
os.remove(dir)
sh("mkdir -p " .. dir .. "/b")
local D = dir

-- 两个 fixture：同一份源码，一份 PIE 一份 ET_EXEC（这是 bug1 的分水岭）
local SPIN = [[
volatile long sink;
__attribute__((noinline)) void hot_alpha(void){ for(long i=0;i<80000000L;i++) sink+=i; }
__attribute__((noinline)) void hot_beta(void){  for(long i=0;i<80000000L;i++) sink-=i; }
int main(void){ long e=0; for(int k=0;k<1000;k++){ hot_alpha(); hot_beta(); } return (int)(e+sink&1); }
]]
local BRIEF = [[
#include <time.h>
volatile unsigned long acc;
static void busy(void){ for(int i=0;i<50000;i++) acc+=i; }
int main(void){
  struct timespec a,b; clock_gettime(CLOCK_MONOTONIC,&a);
  for(;;){ busy(); clock_gettime(CLOCK_MONOTONIC,&b);
    double d=(b.tv_sec-a.tv_sec)+(b.tv_nsec-a.tv_nsec)/1e9; if(d>0.055) break; }
  return 0; }
]]

local function put(path, body)
    local f = assert(io.open(path, "w")); f:write(body); f:close()
end
put(D .. "/spin.c", SPIN)
put(D .. "/brief.c", BRIEF)

local _, rc1 = sh(("cc -O1 -o %s/b/spin_pie %s/spin.c"):format(D, D))
local _, rc2 = sh(("cc -O1 -no-pie -o %s/b/spin_exec %s/spin.c"):format(D, D))
local _, rc3 = sh(("cc -O1 -o %s/b/brief %s/brief.c"):format(D, D))
if rc1 + rc2 + rc3 ~= 0 then
    io.stderr:write("SKIP perfprobe (cc 不可用或 -no-pie 不支持)\n")
    os.exit(0)
end

-- 按 helper/perfprobe.json 的 so 字段加载，和 tools.lua 用同一份真相
local function so_path()
    local f = io.open(root .. "/helper/perfprobe.json")
    if not f then return nil end
    local cfg = cjson.decode(f:read("*a")); f:close()
    if not cfg.so then return nil end
    return root .. "/helper/" .. (cfg.so:gsub("^helper/", ""))
end
local SO = so_path()
if not SO then
    io.stderr:write("FAIL perfprobe (helper/perfprobe.json 缺 so 字段)\n"); os.exit(1)
end

ffi.cdef[[
char *lite_helper(const char *input);
void  lite_helper_free(char *out);
]]
local lib = ffi.load(SO)

local function probe(argv, secs)
    local req = cjson.encode({ argv = argv, freq = 99, seconds = secs or 10, top = 8 })
    local out = lib.lite_helper(req)
    local s = ffi.string(out)
    lib.lite_helper_free(out)
    local ok, d = pcall(cjson.decode, s)
    return (ok and type(d) == "table") and d or nil, s
end

local fails, total = 0, 0
local function check(cond, name, detail)
    total = total + 1
    if not cond then
        fails = fails + 1
        io.stderr:write(string.format("  FAIL %s (%s)\n", name, tostring(detail)))
    end
end

local function sym_pct(d, want)
    for _, s in ipairs((d and d.symbols) or {}) do
        if s.symbol == want then return s.pct or 0 end
    end
    return nil
end

-- bug1 的两面：PIE 能查到符号（一直是对的），ET_EXEC 也必须能（曾经全是 [nosym]）
local d1, raw1 = probe({ D .. "/b/spin_pie" })
check(d1 and d1.ok == 1, "spin_pie.ok", raw1:sub(1, 160))
check((d1 and d1.samples or 0) > 0, "spin_pie.samples", d1 and d1.samples)
check(sym_pct(d1, "hot_alpha") ~= nil, "spin_pie.sym_alpha", "no hot_alpha in table")
check(sym_pct(d1, "hot_beta") ~= nil, "spin_pie.sym_beta", "no hot_beta in table")
check(sym_pct(d1, "[nosym]") == nil, "spin_pie.no_nosym",
      string.format("nosym=%.1f%%", sym_pct(d1, "[nosym]") or 0))

local d2, raw2 = probe({ D .. "/b/spin_exec" })
check(d2 and d2.ok == 1, "spin_exec.ok", raw2:sub(1, 160))
check((d2 and d2.samples or 0) > 0, "spin_exec.samples", d2 and d2.samples)
check(sym_pct(d2, "hot_alpha") ~= nil, "spin_exec.sym_alpha", "ET_EXEC lost hot_alpha")
check(sym_pct(d2, "hot_beta") ~= nil, "spin_exec.sym_beta", "ET_EXEC lost hot_beta")
check(sym_pct(d2, "[nosym]") == nil, "spin_exec.no_nosym",
      string.format("nosym=%.1f%%", sym_pct(d2, "[nosym]") or 0))

-- 短命目标：样本很少但不能崩，main 至少要认出来
local d3, raw3 = probe({ D .. "/b/brief" }, 5)
check(d3 and d3.ok == 1, "brief.ok", raw3:sub(1, 160))
check(d3 and (d3.samples or 0) >= 1, "brief.samples", d3 and d3.samples)
check(sym_pct(d3, "main") ~= nil, "brief.sym_main", "no main in table")

-- bug2 的两面：ok=0 必须带 stage 标签，不能被渲染成「0 样本」的成功
local d4, raw4 = probe({ "/bin/true" }, 5)
if d4 and d4.ok == 1 then                    -- 正常：跑完了但没采到样本
    check((d4.samples or 0) == 0, "true.zero_samples", d4.samples)
    check(type(d4.hint) == "string", "true.hint", "0 样本却没给 hint")
else                                          -- paranoid 挡住：错误必须可见
    check(d4 and d4.ok == 0, "true.ok", raw4:sub(1, 160))
    check(d4 and type(d4.error) == "string" and #d4.error > 0, "true.error", raw4:sub(1, 160))
end

local d5, raw5 = probe({ "/nonexistent-perfprobe-xyz" }, 5)
check(d5 and d5.ok == 0, "missing.ok", raw5:sub(1, 160))
check(d5 and type(d5.error) == "string", "missing.error", raw5:sub(1, 160))
check(d5 and d5.stage == "exec", "missing.stage", d5 and tostring(d5.stage))

-- Lua 渲染层：ok=0 要落到 "perfprobe: [stage]" 而不是成功块
local tool = dofile(root .. "/helper/perfprobe.lua")
local txt = tool.run({ argv = { "/nonexistent-perfprobe-xyz" } },
                     { call = function(_, input) return ffi.string(lib.lite_helper(input)) end })
check(txt:find("^perfprobe: %[exec%]") ~= nil, "lua.error_render", (txt:gsub("\n.*", "")))
check(txt:find("samples") == nil, "lua.no_fake_success", (txt:gsub("\n.*", "")))

sh("rm -rf " .. D)

if fails > 0 then
    io.stderr:write(string.format("FAIL perfprobe (%d/%d 断言失败)\n", fails, total))
    os.exit(1)
end
print(string.format("OK perfprobe (%d checks)", total))
