# LuaJIT 加热指南（lite 版）

> 目标：让热路径真的被 JIT 编译，并且**只在有收益的地方**改代码。
> 本文件倍率都是本机实测，跑法见 §6，可原样复现。标 `[static]` 的是抄来的结论，没在本地验。
> **版本**：主体数据在 `LuaJIT 2.1.1780076327`（上游）上测得；lite 自 2026-11-14 起改用
> `openresty/luajit2` 的 `v2.1-agentzh`（`2.1.1793955606`），差异与复测见 §4.1。

---

## 1 什么算「加热」

LuaJIT 有两种执行模式，同一份字节码两条路：

| 模式 | 谁在跑 | 何时 |
|---|---|---|
| 解释器 | 手写汇编 VM | 一开始，所有代码 |
| JIT | 录 trace → IR → 机器码 | 热函数入口 / 热循环回边超过阈值 |

* 默认阈值 `hotloop=56`（回边 56 次）、`hotexit=10`、`hotcall`。可用
  `jit.opt.start("hotloop=10")` 或命令行 `-Ohotloop=10` 调整——调低方便调试，别带上线。
* **trace 是「一条走过的路径」**，不是「一个函数」。所以：

  > 同一条 `if`，数据只走同一支时才录得顺；数据一抖，`exit` 回解释器，
  > 抖得凶就 `trace abort`，甚至一条 trace 都建不起来。

* **stitch**：逻辑跨进 C 函数边界但没被内联，录到 `stitch string.gsub` 这种。
  stitch 意味着「循环骨架被编译了，C 里的活还是 C 在干」——**有 trace ≠ 有收益**（见 §3.2）。

### 三种常见状态

| 状态 | 表现 | 含义 |
|---|---|---|
| record | `[TRACE 1 loop]` | 真编译了 |
| stitch | `[TRACE 1 stitch string.gsub]` | 边界缝合，C 内部没编译 |
| abort | `[TRACE --- f.lua:455 -- NYI: ...]` | 编译到一半放弃，整条 trace 作废 |
| blacklist | 不再尝试 | 同一处连续 abort，被拉黑 200 次窗口 |

---

## 2 看出来加没加热

lite 自带 LuaJIT 在 `~/.local/share/lite/third_party/luajit/src/luajit`，
统一走包装器 `./tools/lite-lua`：

```bash
./tools/lite-lua -jv    app.lua > /dev/null 2> /tmp/jit.log   # 流水（推荐）
./tools/lite-lua -jdump app.lua > /dev/null 2> /tmp/jit.log   # 字节码/IR/机器码
./tools/lite-lua -jv -Ohotloop=10 app.lua                     # 早点录，便于观察
./tools/lite-lua -e 'print(jit.version, jit.version_num)'     # 先确认版本！
```

`-jv` 输出逐行读法：

```
[TRACE   1 cases.lua:6 loop]                                  → 成功，从 6 行热循环起
[TRACE   2 (1/4) cases.lua:6 -> 1]                            → 成功，且和第 1 条连起来
[TRACE   3 (2/0) cases.lua:7 stitch string.gmatch]            → 缝到 C 边界
[TRACE --- waf-core.lua:455 -- NYI: FastFunc pairs at :458]   → abort，原因 + 位置
[TRACE --- exit.lua:27 -- NYI: bytecode FNEW at :439]         → abort，FNEW 建闭包
```

进程内自取（脚本里做断言用）：

```lua
local v = require("jit.v")
v.on("/tmp/jit.log")     -- 采样窗口开
-- ... 跑热循环 ...
v.off()                  -- 关掉再读文件，否则读到半截
local log = io.open("/tmp/jit.log"):read("*a")
print(log:match("NYI: ([^%]]*)"))   -- 有 abort 就能拿到原因
```

⚠️ **abort 只报第一次**。日志里没有 `---` 不代表后面没 abort，也可能只是采样窗口没盖住。

---

## 3 本机实测：哪些能加热

判据：`JIT关 / JIT开` 的耗时比（>1 = 有收益），结果必须被消费（§6 的 sink 陷阱）。
**`trace×N` 只说明建了 trace，不代表这行快了**——看倍率列。

### 3.1 真加速（值得写进热路径）

| 调用 | 倍率 | 调用 | 倍率 |
|---|---:|---|---:|
| `ffi` 数组读写 | **103×** | `string.lower` | 101× |
| `string.reverse` | 77× | `find(plain=true)` | **62×** |
| `string.rep` | 53× | `string.sub` | 50× |
| `string.char` | 48× | `rawget/rawset` | 46× |
| `pcall(f, x)` | **43×** | `string.byte` | 42× |
| `__index` 元表取值 | 33× | `tonumber` | 31× |
| `type` | 21× | `select('#', ...)` | 21× |
| `bit.band` / `bit.lshift` | 20× / 19× | `math.floor` | 19× |
| `math.max/min` | 18× | `varargs ...` | 18× |
| `assert` | 16× | 普通局部函数调用 | 15× |
| `ipairs` | 11× | `string.len` | 11× |
| `table.insert`(push) | 10× | `math.random` | 7.5× |
| `math.sqrt` | 6.4× | `next` | 5.0× |
| `table.concat` | 4.8× | `table.remove`(pop) | 2.8× |

### 3.2 录了但**没收益**（别为 JIT 改这些）

| 调用 | 倍率 | 说明 |
|---|---:|---|
| `pairs` | 1.97× | trace 建得起来，逐元素仍比 `ipairs` 慢约 4×（0.35µs vs 0.09µs / 100 元素） |
| `unpack` | **1.00×**（fork）/ 0.09×（旧上游） | 旧上游上 `f(unpack(t))` 慢 **27.5×**（1.27s vs 0.046s / 3e7 次）；`openresty/luajit2` 已修好，现与显式展开等价（§4.1） |
| `table.sort` | 1.03× | 排序在 C 里，JIT 只优化外壳 |
| `math.fmod` | 1.04× | 同上；需要取模用 `%` 或 `bit.band`（2 的幂） |
| `os.clock` | 0.99× | 纯 C 调用 |
| `coroutine.yield` | 1.00× | 协程切换不吃 JIT |
| `string.gsub` | 1.01× | stitch，C 内循环没编 |
| `gmatch` | 1.00× | stitch |
| `find(模式)` | 1.11× | 见 §5.3，真正的账不是这个 |
| `string.match` | 1.03× | stitch |
| `string.format` | 1.52× | 只有 1.5×，别指望 |
| `setmetatable` | 1.17× | 建表本身是 C |
| `tostring(数字)` | 1.39× | 数字转字符串仍是 C |

### 3.3 撞 abort（连尝试都失败）

| 写法 | abort 原因 | 改法 |
|---|---|---|
| `pcall(function() ... end)` | `NYI: bytecode FNEW` | `pcall(f, args)` → **43×** |
| `xpcall(f, function(e) ... end, x)` | `FNEW` | handler 提到循环外 |
| 循环体里 `local f = function() ... end` | `FNEW` | 提到循环外；0.98×（等于没加热） |
| `("a"):gsub("a", function() ... end)` | `FNEW` | 用字符串替换或事先建好函数 |
| `table.foreach` / `table.foreachi` | `FNEW`（库内部建闭包） | 改 `for i=1,#t` 或 `ipairs` |
| `coroutine.wrap(function() ... end)` | `FNEW` | 循环外只 `wrap` 一次 |
| 任何基于 `lua_CFunction` 的 C 模块 | 永不编译 | **用 FFI 重写**（`ffi` 数组 103×） |

`FNEW` 是唯一的高频元凶：**它在录到「创建闭包」这个动作时无法继续**。
`GLOBAL`/`UPVAL`/`UCLO`（含 `goto` 跨 `local` 作用域）也会 abort，位置次之。

---

## 4 版本差异：别照抄 2015 年的文章

流传最广的中文资料（OpenResty 1.5.8.1 时代，`2.1.0-alpha`）断言
`pairs` / `string.gmatch` / `string.gsub` / `string.match` / `table.sort` / `unpack` 是 NYI。
**在本机 `2.1.1780076327`（上游）与 `2.1.1793955606`（openresty fork）上均已能缝合或录制**，实测：

```
pairs     trace×2  1.97×      （旧文：no）
gmatch    trace×5  1.00×      stitch string.gmatch_aux
gsub      trace×2  1.01×      stitch string.gsub
match     trace×2  1.03×
sort      trace×2  1.03×
unpack    trace×2  0.93×      （能录，但更慢）
setfenv   trace×2  —          （旧文：no）
tostring(表) trace×2  —       （旧文：partial）
```

结论不变但理由变了：**「能录」不等于「有用」**，旧文那张表把两者混在一起。
旧表可以当「哪些曾是 NYI」的考古，别当现状；现状以 `-jv` 现跑为准，官方清单：
<http://wiki.luajit.org/NYI>。

---

## 4.1 openresty/luajit2 的差异（lite 自带的就是它）

`v2.1-agentzh` = 上游 `v2.1` + OpenResty 维护补丁 + 3.0 语法回移。换过来之后有 4 处要点：

**1）`table.new/clear/clone/isarray/nkeys/isempty` 走 `require`，不是全局字段** `[verified]`

```lua
print(table.new)                      -- nil（别写成 table.new(3,0)）
local new = require("table.new")       -- 注册在 _PRELOAD 里
local t = new(3, 0); t[1]=1; print(#t) -- 1
```

**2）`unpack` 修好了**：`f(unpack(t))` 在上游是 27.5× 慢，fork 上 1.00×（同机 3e7 次复测）。

**3）LuaJIT 3.0 语法全部回移** `[verified]`：`& | ~ << >> ~>>`、`! && || !=`、`?:`、`?.`、`??`、
`+= -= *= /= %= &= |= <<= >>= ~>>= ..=`、`continue`、`const`、`|a| -> expr` 短函数、数字字面量 `1_000_000`。
**坑：`~=` 一身两职** —— 表达式位置是「不等于」（`if a ~= b then`），**语句位置是异或赋值**：

```lua
local a = 5
if a ~= 3 then print("ok") end   -- 表达式：没变
a ~= 3                           -- 语句：a = a ~ 3 → 6，静默改值！
```

**lite 自己的代码不要用这些语法**：一旦退回上游/换发行版 LuaJIT 就是语法错误，
而 `tools/test.sh` 只跑 bundled 解释器、发现不了。`helper/` 里的一次性脚本可以用。

**4）`jit.*` 的 Lua 侧模块必须用 bundled 的那份**：`-jv`/`-jdump`/`require("jit.v")` 会去
`package.path` 找 `jit/vmdef.lua`，`;;` 展开到系统 `/usr/local/share/luajit-2.1` 时就报
`LuaJIT core/library version mismatch`（core 是随包新二进制，Lua 侧是系统旧 share）。
`tools/lite-lua` 与 `tools/lua.sh` 已把 `$ROOT/third_party/luajit/src/?.lua` 排在最前解决；
自己拼 `LUA_PATH` 时要带上它。

---

## 5 最佳代码规范

### 5.1 热循环里不建闭包（FNEW）

```lua
-- 反例：每次迭代 FNEW → abort，1.00×（等于纯解释）
for i = 1, n do
  local ok, r = pcall(function() return work(i) end)
end

-- 正例：一次都不建，43×
local function call_work(i) return work(i) end
for i = 1, n do
  local ok, r = pcall(call_work, i)
end
```

`gsub` 的回调、`table.foreach`、`coroutine.wrap` 同理——建函数这一步必须在循环外。

### 5.2 `pcall` 传函数，不传匿名闭包

`pcall` 本身可编译（`pcall(f,x)` 实测 43×），abort 的是你塞进去的 `FNEW`。
`pcall(f, x1, x2)` —— 零闭包、零 abort、43×。

### 5.3 能用 plain 就不用模式

```lua
s:find("ll", 1, true)   -- 303 ns，JIT 1.14×
s:find("l+l")           -- 5603 ns，JIT 1.00×   ← 贵 18×，且 JIT 帮不上
```

**跑在 C 里的开销，比 JIT 开关大一个数量级。** 模式匹配改 plain / 手写字符扫描
的收益远大于任何 JIT 调优。这条和 `perf(provider): SSE feed 热路径去掉 gsub/pattern`
是同一条经验。

### 5.4 数组遍历用 `ipairs` 或数字 for，别用 `pairs`

| 写法 | 每元素 |
|---|---|
| `for i=1,#t` | 最快（回边直接编） |
| `ipairs(t)` | ≈ 0.88 ns（11× ） |
| `pairs(t)` | ≈ 3.5 ns（1.97×） |

`pairs` 走 `next` + hash 遍历，`trace` 再努力也补不回来。

### 5.5 局部化全局

```lua
local floor, sqrt = math.floor, math.sqrt   -- 循环外
for i = 1, n do acc = acc + floor(sqrt(i)) end
```

`M.field` 每次是两次表访问 + 一次 `GLOBAL`；局部化后是 `UPVAL`→`SLOT`，
顺带避免 `GLOBAL` 相关的 abort。**同类项在循环外取一次**。

### 5.6 类型别抖

LuaJIT 按**观测到的类型**特化 trace：整数混浮点、中途出现 `nil`、同一变量一会儿
string 一会儿 table，都会 `exit` 回解释器再录。要抖就**在循环外归一**：

```lua
acc = acc + 0                  -- 明确浮点
local x = tonumber(v) or 0     -- 循环前把 nil 抹平
```

### 5.7 字符串拼接走 `table.concat`

```lua
-- 反例：每轮新建字符串，GC 压力 + 不回边
for i = 1, n do out = out .. parts[i] end

-- 正例：4.8×，且 #out 只在最后算
local buf = {} for i = 1, n do buf[i] = parts[i] end
local out = table.concat(buf)
```

### 5.8 热路径里不 `loadstring` / `dofile`

实测「循环里 `loadstring` + 调」：**不 abort，但产生 26 条 trace**。
每次编译新函数都会打断 trace 链、污染 trace 缓存和前缀缓存——比 abort 更隐蔽。
要动态代码就**一次性编译**，把函数存起来复用。

### 5.9 优先 FFI，不写 `lua_CFunction` 模块

* `ffi` 数组/结构体访问：**103×**（本机最高）
* 经典 `lua_CFunction` 模块：**永远不会被编译**，只能 stitch。

lite 的取向已经如此（`helper/lib/*` 全走 FFI）。新写 C 扩展时，
`native build` 出 `.so` + `ffi.load`，不要 `luaopen_*` 注册表。

### 5.10 该用元表就用

`__index` 取值 **33×**——元表方法调用本身不是问题。
约束在**metamethod 函数体**：里面不能有 `FNEW`，否则整个调用链 abort。

### 5.11 别为 JIT 改这些

`table.sort`、`math.fmod`、`os.clock`、`coroutine.yield`、`string.gsub`、
`gmatch` 的倍率都在 1.0 附近。它们的成本在 C 里，改写 Lua 层无收益——
要快只能换算法（排序改桶、`%` 改 `bit.band`）。

### 5.12 别在运行时反复开关 JIT

`jit.off()` / `jit.flush()` 在热路径里 = 把已编译的东西全扔掉重录。
只用于测量和调试，不要留在生产代码。

### 5.13 保持热循环「一条路」

```lua
-- 反例：数据一半命中一半不命中 → 反复 exit/重录
for i = 1, n do if t[i] then a = a + t[i] else b = b + 1 end end

-- 正例：先分流，两个循环各自路径单一
for i = 1, n do if t[i] then a = a + t[i] end end
for i = 1, n do if not t[i] then b = b + 1 end end
```

分支预测友好 + trace 单路径，两边都赚。

### 5.14 只在测量时相信「次数」

`hotloop` 默认 56，短循环（`n < 56`）根本录不到。**优化前后都要保证 n 足够大**，
否则测到的是「没热」，不是「没收益」。

---

## 6 测量规范（血泪三条）

### 6.1 sink 陷阱（最容易骗自己的坑）

```lua
-- 错：返回值没人用 → JIT 把整个调用消除，测出 3ns（假 17×）
for i = 1, n do string.find(s, "ll", 1, true) end

-- 对：结果必须被消费
local sink = 0
for i = 1, n do sink = sink + (string.find(s, "ll", 1, true) or 0) end
```

同一条 `find`：不 sink → **3 ns**；加 sink → **303 ns**。差 100 倍，全是假的。

### 6.2 基线用 `jit.off()`，不是「标准 Lua」

* 本机**没有**标准 `lua` 5.1，只有 bundled LuaJIT。
* 老文章的 4× / 40× 是 **LuaJIT 整体 vs Lua 5.1**；「JIT 贡献」要做
  **`jit.off()` vs `jit.on()`**。两者可相乘：`4× ≈ 1.04× × 3.8`，
  意思是 LuaJIT 的**解释器**本身已快约 3.8×，JIT 只是再加一点。

```lua
jit.on();  jit.flush(); for i=1,50 do warm() end; local a = bench()   -- 开
jit.off(); jit.flush(); for i=1,10 do warm() end; local b = bench()   -- 关
jit.on();  jit.flush()
print(b / a)   -- 这才是「加热收益」
```

### 6.3 一次不算数

* 预热 ≥ 50 次（过 `hotloop`）；测量窗口 ≥ 3 ms（`os.clock` 分辨率）。
* 比较循环形状要一致：`pairs` 我这次测出 1.97×，上一轮另个形状是 1.04×——
  **同函数不同形状可以差一倍**，报数必须带形状和数据量。
* 跑三次取中位，变异 > 20% 就别下结论。

---

## 7 在 lite 里怎么落

| 场景 | 动作 |
|---|---|
| 怀疑某段慢 | `./tools/lite-lua -jv file.lua`，看 `---` abort 和 trace 条数 |
| 要火焰图/热点排行 | `trace` 插件（`lua/trace/`，`perf_event_open` + JIT perfmap），比 `-jv` 更宏观 |
| 看到 `NYI: bytecode FNEW` | 按 §5.1 / §5.2 把闭包提到循环外 |
| 看到 `stitch string.gsub` + 倍率 ≈ 1 | 别改 Lua，换算法（§5.3） |
| 新写 C 能力 | FFI（`native build` + `ffi.load`），不要 `lua_CFunction` 注册表 |
| 改完要验证 | `./tools/test.sh`（契约）+ 真实数据跑一次 `-jv` |

**`helper/lib/*.lua` 里的热循环优先过一遍 §5.1**（`pcall(function…)`、`gsub` 回调、
循环内闭包）。这些是 lite 自己进程内的热点，改法零风险、倍率最高。

---

## 8 参数速查

| 项 | 值 |
|---|---|
| LuaJIT 版本 | `2.1.1793955606`（openresty/luajit2 `v2.1-agentzh`，tag `v2.1-20261107`，`version_num=20199`） |
| bundled 路径 | `~/.local/share/lite/third_party/luajit/src/` |
| 包装器 | `./tools/lite-lua` |
| 默认阈值 | `hotloop=56` `hotexit=10` `hotcall` |
| 常用开关 | `-jv` `-jdump` `-Ohotloop=N` `-O3` |
| 拉黑窗口 | 同一处连续 abort 后拉黑（200 次尝试窗口） |
| 官方 NYI 清单 | <http://wiki.luajit.org/NYI> |
| 字节码文档 | <http://wiki.luajit.org/Bytecode-2.0> |

---

## 9 已知未解

* `coroutine.resume/yield` 在 JIT 开时**比全关慢约 28%**（39.1µs vs 28.5µs），三轮稳定复现。
  已排除 GC（停 GC 数字不变）和录制尝试（`hotloop=1000000` 完全不录也一样慢）。
  归因未定，热路径避开协程切换。
* ~~`unpack` 0.93×（负收益）~~ **已在 `openresty/luajit2` 上消失**：旧上游 27.5× 慢，fork 1.00×。
  结论翻转为「可用」，但显式多返回依然比它更省 trace 记录成本。
