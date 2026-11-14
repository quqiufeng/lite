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

**2026-11-14 全表复测**（§6 的跑法 + 一条新规矩：**参数必须随迭代变化**，否则被 LICM 抬出循环，
见 §6.1）。旧版这张表有 50–100× 的行，复测发现多数是「调用被搬到循环外」的假象，已按下表修正。

**决定倍率的不是「是不是 C 函数」，而是「C 里干多少活」**——JIT 只省 Lua 侧派发和装箱，
省不掉 C 内部的分配与拷贝，所以两类要分开看：

**A. 不分配的调用**（JIT 省下的派发占大头，倍率高）：

| 调用 | 倍率 | 备注 |
|---|---:|---|
| `ffi` 数组读写 | **178×** | IR 直接出机器码访存；这就是天花板 |
| `string.sub` | 32× | ⚠ 只消费 `#s` 会被**常量折叠**成常数（定长），基准里要 `string.byte(r,1)` 消费 |
| `__index` 元表取值 | 31× | |
| `tonumber` | 28× | |
| `type` | 25× | 参数类型单一时更稳（§5.6） |
| `string.len` | 22× | |
| `string.byte` | 20× | |
| `select('#', ...)` | 20× | |
| `rawget/rawset` | 45× | |
| `bit.band` / `bit.lshift` | 18× | IR 原生位运算 |
| `math.floor` | 17× | |
| `math.max/min` | 16× | |
| `pcall(f, x)` | 16× | 传函数不传闭包（§5.2）；旧表 43× 已修正 |
| `普通局部函数调用` | 14× | |
| `assert` | 11× | |
| `ipairs` | 11× | |
| `table.insert`(push) | 8× | |
| `math.random` | 7× | |
| `find(plain=true)` | **5.8×** | 只对 `plain` 有收益；带模式 1.04×（§3.2）。旧表 62× 是 LICM 假象 |
| `math.sqrt` | 5.2× | |
| `next` | 4.2× | |
| `unpack` | **40×** | 4 元素：0.8 ns vs 33 ns；与显式展开等价（同为 0.8 ns/call）[verified] |

**B. 分配型调用**（每次迭代新建字符串/表，C 侧的拷贝和 GC 占满，JIT 只剩一点派发可省）：

| 调用 | 倍率 | 备注 |
|---|---:|---|
| `string.lower` / `string.reverse` / `string.rep` | **2.2× / 2.4× / 1.8×** | 旧表写 101/77/53×，是把参数当循环不变量测出来的 |
| `table.concat` | 1.5× | 11 段字符串；旧表 4.8× 复现不出（空表形状也只有 1.8×） |
| `table.remove`(pop) | 1.5× | 旧表 2.8× 的形状里混了 insert |

**结论**：想靠 JIT 拿 10× 以上，得让热循环里**不分配**——不是把 `string.lower` 挪进热循环就变快，
是尽量别在热循环里产生字符串。分配型的活只能换算法（§5.3）。

### 3.2 录了但**没收益**（别为 JIT 改这些）

这一组 2026-11-14 复测**全部落在 0.94–1.54×**，是本文最可靠的部分：改它们纯属浪费时间。
（`setmetatable` 1.17× 与 `unpack` 1.00× 已挪走：前者只测到「建表」的 C 成本，
只把 `setmetatable` 本身放进循环是 51×；后者是跨实现对比被误放进本表，真 JIT 收益 40×，见 §3.1。）

| 调用 | 倍率 | 说明 |
|---|---:|---|
| `pairs` | 1.34× | trace 建得起来，逐元素仍比 `ipairs` 慢约 4×（0.35µs vs 0.09µs / 100 元素） |
| `table.sort` | 1.02× | 排序在 C 里，JIT 只优化外壳 |
| `math.fmod` | 1.02× | 同上；需要取模用 `%` 或 `bit.band`（2 的幂） |
| `os.clock` | 1.02× | 纯 C 调用 |
| `coroutine.yield` | 1.00× | 协程切换不吃 JIT `[static]` |
| `string.gsub` | 1.00× | stitch，C 内循环没编 |
| `gmatch` | 0.94× | stitch |
| `find(模式)` | 1.04× | 见 §5.3，真正的账不是这个（且**比 plain 慢 4×**） |
| `string.match` | 1.04× | stitch |
| `string.format` | 1.54× | 只有 1.5×，别指望 |
| `tostring(数字)` | 1.38× | 数字转字符串仍是 C |

### 3.3 撞 abort（连尝试都失败）

| 写法 | abort 原因 | 改法 |
|---|---|---|
| `pcall(function() ... end)` | `NYI: bytecode FNEW` | `pcall(f, args)` → **16×** |
| `xpcall(f, function(e) ... end, x)` | `FNEW` | handler 提到循环外 |
| 循环体里 `local f = function() ... end` | `FNEW` | 提到循环外；0.98×（等于没加热） |
| `("a"):gsub("a", function() ... end)` | `FNEW` | 用字符串替换或事先建好函数 |
| `table.foreach` / `table.foreachi` | `FNEW`（库内部建闭包） | 改 `for i=1,#t` 或 `ipairs` |
| `coroutine.wrap(function() ... end)` | `FNEW` | 循环外只 `wrap` 一次 |
| 任何基于 `lua_CFunction` 的 C 模块 | 永不编译 | **用 FFI 重写**（`ffi` 数组 178×） |

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
unpack    trace×2  40×       （fork 已修，§3.1）
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

**2）`unpack` 修好了**：`f(unpack(t))` 在旧上游上比 fork 慢 27.5×（那是**跨实现对比**，不是 JIT 开关）；
fork 上与显式展开等价（0.8 ns/call，同机复测）`[verified]`。**JIT 开/关**的收益是 40×（§3.1）。

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

-- 正例：一次都不建，16×
local function call_work(i) return work(i) end
for i = 1, n do
  local ok, r = pcall(call_work, i)
end
```

`gsub` 的回调、`table.foreach`、`coroutine.wrap` 同理——建函数这一步必须在循环外。

### 5.2 `pcall` 传函数，不传匿名闭包

`pcall` 本身可编译（`pcall(f,x)` 实测 **16×**），abort 的是你塞进去的 `FNEW`。
`pcall(f, x1, x2)` —— 零闭包、零 abort、16×。

### 5.3 能用 plain 就不用模式

```lua
s:find("ll", 1, true)   -- 8.6 ns，JIT 6.0×
s:find("l+l")           -- 66.7 ns，JIT 1.22×   ← 贵 7.8×，且 JIT 帮不上
```

（2026-11-14 复测，参数随迭代变化。旧文写 303 ns / 5603 ns / 18×，量级方向一致但绝对值偏大。）

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

-- 正例：一次分配，#out 只在最后算（JIT 收益仅 1.5×，真正省的是 n 次拷贝）
local buf = {} for i = 1, n do buf[i] = parts[i] end
local out = table.concat(buf)
```

### 5.8 热路径里不 `loadstring` / `dofile`

实测「循环里 `loadstring` + 调」：**不 abort，但产生 26 条 trace**。
每次编译新函数都会打断 trace 链、污染 trace 缓存和前缀缓存——比 abort 更隐蔽。
要动态代码就**一次性编译**，把函数存起来复用。

### 5.9 优先 FFI，不写 `lua_CFunction` 模块

* `ffi` 数组/结构体访问：**178×**（本机最高）
* 经典 `lua_CFunction` 模块：**永远不会被编译**，只能 stitch。

lite 的取向已经如此（`helper/lib/*` 全走 FFI）。新写 C 扩展时，
`native build` 出 `.so` + `ffi.load`，不要 `luaopen_*` 注册表。

### 5.10 该用元表就用

`__index` 取值 **31×**——元表方法调用本身不是问题。
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

### 5.15 全仓过一遍的结论（2026-11-14，253 个 .lua）

方法三件套：`./tools/lite-lua -jv lua/main.lua --tui --snapshot`（看 abort）、`-jp`（看时间去哪）、
静态扫描（只报**循环体内**的 FNEW/CONCAT/pattern/PATH/建表）。结论：**热路径基本已经合规**，
`-jv` 跑真实 TUI 渲染**零 NYI abort**；剩下能改的都是「一次性动作」，按 §5.11/§5.14 不改。

| 区域 | 频率 | 判定 | 处置 |
|---|---|---|---|
| `core/provider.lua:feed` | 每 SSE chunk | 纯 `find`/下标、无 pattern | 工具参数分片累积原本 `..` 是 O(n²) → 改 `_abuf` 表 + `finish` 一次拼：合成 40KB/200 片 **2.08×**，产出逐字节一致；缺 delta 的 chunk 共用 `EMPTY` 空表 |
| `core/text.lua:sanitize` | 每请求全量历史 | 零分配 `utf8_ok` 快速路径 | 不动 |
| `core/memory.lua` 打分 | 每轮 | `hbits/tbits` 位掩码、`totw` 已提到循环外 | 不动 |
| `tui/screen.lua:put` | 逐格逐帧 | `utf8.decode` 一次 + 无 FNEW | 不动 |
| `tui/diff_layout.lua` | 每 diff 行 | `prefix`/`side` 每行 FNEW；`wrap_segments_lua` 的 `newline` 闭包 | 都提到模块层/内联：大 diff **1.01×**（耗时在 C 的 `count_lines`），真收益在 abort——`-jv` 跑单测 `diff_layout.lua:49 UCLO×32 + :29 FNEW×25` → **0** |
| `core/memory.lua:recall` | 每轮、每条候选 | `allowed(key)` 闭包建在扫描循环外但每次 recall 一次（§5.1） | 提成模块层 `allowed_kind(key, allow_transcript)`；`-jv` 的 `memory.lua:1089 FNEW×5` → **0** |
| `core/agent.lua:schema_chars` | 每次 rebuild 一次 | `pcall(function() return tools:schemas() end)`（§5.2） | `pcall(tools.schemas, tools)`：零闭包 |
| `tui/transcript.lua:build_lines` | 每帧缓存未命中 | 键 `w.."\|"..text` 每次重建拷整段 | 直接比字符串（内部化 = O(1)）；帧内命中原缓存，**不改倍率** |
| `core/tools.lua`、`compact.lua`、`session.lua`、`agent.lua` | 每轮/每工具一次 | 有 `..`/`format`/`pairs`，但都 ≤32KB 单次 | 不动（§5.14） |
| `helper/*.lua`、`lua/charts/*`、`lua/trace/*` | 一次性动作/生成 | `pcall(function…)` 在 3 次重试里、路径拼接 | 不动 |

**教训**：先在**真实工作负载**上取 `-jv`/`-jp`，别对静态命中列表动手——静态扫描 4454 行命中里，
真热且真违规的只有 provider 的工具参数累积一处；纯 Lua 侧改 FNEW 的倍率通常 <1.1×，
大头在 C（字符计数、wrap、cjson）。`helper/` 的 `pcall(function…)` 看着像 §5.2 反例，
但它在 3 次重试循环里、每次动作只跑一次，改它只有折旧风险。

---

## 6 测量规范（血泪四条）

1. **结果必须被消费**（挡死代码消除，§6.1）
2. **参数必须随迭代变化**（挡 LICM 把调用搬出循环，§6.1）—— 2026-11-14 全表复测证明它比第 1 条更要命
3. **别拿 `#` 消费**（挡常量折叠，§6.1.1）
4. **基线用 `jit.off()`；三次取中位、窗口 ≥3 ms**（§6.2、§6.3）

### 6.1 sink 陷阱（最容易骗自己的坑）

```lua
-- 错：返回值没人用 → JIT 把整个调用消除，测出 3ns（假 17×）
for i = 1, n do string.find(s, "ll", 1, true) end

-- 对：结果必须被消费
local sink = 0
for i = 1, n do sink = sink + (string.find(s, "ll", 1, true) or 0) end
```

**但只做到这一步还不够**（2026-11-14 复测踩到）：`s` 和 `"ll"` 都是**循环不变量**，
JIT 会把整个调用**提到循环外**（LICM），加不加 sink 都一样测出近 0：

| 写法 | jit 开 | 倍率 |
|---|---:|---:|
| 不消费返回值 | 1.8 ns/次 | 循环被消除，全假 |
| 消费返回值，**但参数是循环不变量** | 0.76 ns/次 | **51×（LICM 假象）** |
| 消费返回值，**参数随迭代变化** | 8.7 ns/次 | **5.8×（真值）** |

同一条 `find`，三种写法差 9 倍。**所以基准里参数必须随迭代变化**：用一张打乱的下标表驱动
（`local k = perm[(i%64)+1]`，表内容编译期不可知，既挡 LICM 又挡常量折叠）。加 `sink` 只挡死代码消除，
挡不住提升。

### 6.1.1 常量折叠：别拿 `#` 消费

`#string.sub(s, 2, 12)` 这种消费方式会被折成常数 11（定长子串长度编译期已知），
测出来 0.78 ns/次 —— 那不是在测 `sub`，是在测一个常数。**要么 `string.byte(r, 1)` 消费真实内容，
要么把结果存进变量后参与后续计算**。

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
* ~~`unpack` 0.93×（负收益）~~ **已在 `openresty/luajit2` 上消失**：旧上游 27.5× 慢（跨实现对比），
  fork 上与显式展开等价（0.8 ns/call）。**JIT 开关本身的收益是 40×**（§3.1），旧文的 1.00× 是把
  跨实现比值误当成了本表口径。
