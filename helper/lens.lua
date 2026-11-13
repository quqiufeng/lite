-- lens（旧名 codesearch）：代码索引 / 符号 / 调用图 / 数据流 / 语义搜索。
-- 工具名 = 文件名（lens），实现模块仍是 src/codesearch + lua/ffi/codesearch.lua。
-- 数据默认落在 $LITE_CS_HOME（缺省 ~/.local/share/lite/codesearch），
-- 每个项目一个 analysis 目录，KV 落在其 kv/ 子目录，避免和 lite 自己的
-- mem.bin 写实例抢锁。实现是 liblite_codesearch.so（从 /opt/my_db 全量迁移），
-- 语义向量需要 /opt/models 下的 Jina 模型与 ONNX Runtime。
--
-- ═══════════════ 最佳实践：按使用顺序排的行为边界 ═══════════════════════════════
-- 下面每条都是「工具的真实行为边界」，不是理想设计；括号里是当初踩出来的证据，
-- 别当成可以随手改掉的注释。改行为前先重跑一次证据里的命令（入口都在
-- helper/lens.lua:run_inner / do_locate / do_peek / do_grep）。
-- 证据分两轮，语气不同别混：
--   2026-11-13 内核（/opt/code_caches/linux_7212_cache，C/大规模/重名）→ [8]-[20]
--   2026-11-14 三个 agent 仓库（/opt/pi-mono、/opt/reasonix、/opt/opencode，
--     TS/Go/多包）→ [1][2][21]-[24]。同一条 query 在三者上的命中质量差 3 倍以上，
--     所以「选哪个动词」比「怎么读输出」更早决定成败。
--
-- [0] 先判该不该用 lens。它只索引 cwd 之外的项目（AGENTS.md §7）：改 lite 自己用
--     read/cgrep/edit，别为 lite 建索引。索引是一次性成本、查询才是毫秒级；只查一次
--     的小问题直接 action=grep 更省，别为它跑几十分钟 build。
--
-- [1] 【起手式】先判仓库形状，再按问题类型选动词 —— 默认用 locate 是错的。
--     形状决定 locate 可不可信（2026-11-14 三个 agent 仓库实测，15 条 locate）：
--       · 单包、名字唯一（reasonix：一个 internal/ 树）：每条都到点，闭眼用。
--       · 多包 + 同名目录 + 服务化碎片（opencode：35 个 packages、12 个名字带 plugin
--         的目录(含 test/stories 噪声)、5702 个 ts 里 920 个含 Effect.gen）→ 3/3 全错：「plugin 钩子」全落 GUI
--         桥接（createPluginBridge / pluginEnabled），「compaction」全落配置校验
--         （normalizeCompaction）。语义被词表重叠压平，不是排序 bug。
--     判形状只花一次 bash，别拿 locate 试错：
--       ls packages; find . -name '*.ts' -not -path '*/node_modules/*' | wc -l
--     多包仓：locate 必须带 path_prefix（[5]），否则直接跳到下面的 peek / grep。
--     动词表（按「读完能不能直接下结论」排，别跳级）：
--       peek  ← 「架构长什么样 / 状态在哪维护」。实测 peek llm.ts:85 lines=60 一发
--               拿下整个 advanceToStep 的收件箱分派（inbox type 分流的返回路径）——
--               全程唯一「读完即结论」的动作；locate 只给候选，还得再 read 一遍。
--       symbol← 「符号定义在哪」，不加载 ONNX 模型，最省（[3]）。
--       grep  ← 「这个词在哪出现过 / 复核猜疑」，配 path= 是 3ms 零噪声（[7]）。
--       context / dataflow ← 「谁调我」，结构化那半，见 [8]-[13]。
--       locate← 只留给「知道概念、不知道名字」，且把 [1] 判断的形状一起喂给它。
--     推断捷径仍在（语法糖，不是选路依据）：query→locate、pattern→grep、
--     path=file[:line]→peek、都不给→status；显式 action= 覆盖推断。
--     连续 locate 三次没中 = 该换 grep，别再换 query 重投。
--
-- [2] locate 的输出怎么读（默认 max_results=3、lines=40、before=2、max_chars=8000）：
--       · 表头 `search "x" -> N result(s), M with source [static]` 里的 M 是**真读到盘**
--         的条数，不是 N（预算砍掉、文件不在 repo 都不算），别拿 N 当证据量。
--       · score 只说「排第几」，confidence 才说「该不该信」（语义+词面+调用图三样实证）。
--         top score < 0.35 或 confidence=low 会直接给 note —— 那意思是别当成找到了，
--         换 action=symbol（定义直查）或 action=grep（词面兜底）。
--       · 同名精确命中会置顶（与 top 分差 ≤0.25 才提），note 写 `hoisted exact name match`：
--         语义排序会把真定义压到 [3] 之后（locate "do_peek" 时 [1] 是别的 do_* 函数），
--         只读前两条就判「没找到」正是这条要防的。
--       · 窗口**读盘优先**：盘上首行与索引 chunk 首行不一致时标 stale。索引是建索引
--         那一刻的快照，文件改过后行号会错开，看着正常但引用出去就是错的，以盘上为准。
--       · `no hit` 会打印 grep / symbol / build 三条下一步，照抄一条改 action 即可。
--       · confidence 是「该不该信」的过滤器，不是判决书 —— 每条仍要 peek 复核。
--         实测常年落在 low/mid（15 条 0.37-0.63，一次 high 都没出过）。自然语言 query
--         的「词元命中比」现在只数实词（the/how/does 不算 term），lex 会比旧版高，
--         但高出来的只是词面巧合那段，语义分（0.6 权重）没动 —— 该 peek 还是 peek。
--         别因为 note 写着 low 就重投 query，那时该做的是换 action（[1]）。
--       · 每个命中带的 `why` 行（`vector: cosine-sim 0.663 | keyword: 1/5 terms`）
--         约占总输出三成，对「读什么」零帮助：真要分数/证据用 json=true，别在
--         默认输出上纠结；字符预算紧张时靠它省下来给源码窗口。
--
-- [3] locate 的 type 与自动退回：默认 type=search（语义）。一条真命中都没有（或缺向量）
--     时它**自动**退回 symbol，note 写 `retried as symbol`；显式给了 type= 就不退
--     （那时你要的就是那一种）。查定义更省的路：action=symbol 或 type=symbol，
--     不加载 ONNX 模型（tools:run_inner 只对 search 传 analysis_dir）。
--
-- [4] 语义检索只吃英文标识符/短语。中文 query 基本 0 命中（无向量时纯词面）。
--     实测：「NAPI 轮询收包」→ 0 命中；换 "napi poll receive packets" → napi_poll 0.921。
--     仓库里 ship 的名字本来就是英文，query 直接用符号名或英文短语，别翻译。
--
-- [5] 降噪只有两个旋钮，别处调不动：path_prefix（子树）+ lang（语言）。
--     path_prefix=net/core 就只翻该子树的 75 个文件、21ms 出结果；不给就是全仓噪声。
--     lang=c/cpp/lua/... 同时收窄 symbol 的 definitions/callers/callees，被过滤掉的条数
--     写进输出的 filtered_by_lang（不静默丢；数字对不上就看这个字段）。
--
-- [6] peek 吃 `file:line` 原文（grep/locate/编译器报错都是这个形状），也吃 query=<符号>
--     自己去找定义行（内部一次 symbol 查询）。相对 path 按 cwd 解析；打不开报
--     `cannot open <path>` —— 先确认 repo 传的是不是你要的那棵树。
--
-- [7] grep 是 cgrep 的作用域版，不是整仓版（护栏都在 helper/lens.lua:do_grep）：
--       · 超过 LITE_CS_GREP_MAX_FILES（默认 3000 文件）直接拒，并给「先 locate 收窄」
--         的 fix。这是护栏不是 bug；单文件/小目录不受限。
--       · 走 POSIX ERE，不是 Lua pattern：`%.`/`%d` 在这=字面 `%`，0 命中时会提示；
--         要字面串用 fixed=true（查 `[`、`*`、`.` 这类必须）。
--       · 输出先给热点（哪个文件最热、散在几处）再给正文；正文按 file:line 去重，
--         per_file 默认 10、max_hits 默认 120，不够就显式调大。
--
-- [8] 【最重要】call_graph 的边是「函数体文本扫到的标识符」，不是语法解析；
--     注释/字符串里的提及曾经也算边。**2026-11-13 起 callgraph 扫之前先把注释和
--     字符串字面量抹成空格**（src/codesearch/callgraph.c:strip_comments），
--     所以 < 2026-11-13 的旧索引里那些「注释伪边」才是假的，重建后应当消失：
--       旧证据 A：enqueue_task_fair 报 callers=remove_entity_load_avg / clear_delayed /
--         tg_unthrottle_up，前两条来自 fair.c:5917 / 6439 的 `* enqueue_task_fair()…`
--         注释。重建后只剩 tg_unthrottle_up（fair.c:7004 真调用）。
--       旧证据 B：tcp_v4_rcv 报 callers=rds_cong_queue_updates / inet_child_forget，
--         分别只来自 net/rds/cong.c:235 与 inet_connection_sock.c:1384 的注释
--         「held by tcp_v4_rcv()」。
--     仍然要 grep 兜底的场合（这次没治的）：
--       · 裸名撞名（[9]）—— 同名函数被当成同一个；
--       · 预处理宏展开体（#define foo(x) bar(x) 里的 bar() 仍算 foo 的边 ——
--         行首 # 整行被抹掉，但续行 `\` 后的宏体不是行首，会留下）；
--       · 函数指针注册（[10]）—— 压根不在文本里出现调用形式。
--     复核手法：被报成 caller 却看不出调用关系时，去对方函数体里 grep 这个名字，
--     命中落在 /* */ 或 // 行内 → 旧索引的伪边，重建后才可信。
--
-- [9] call_graph.json 顶层 key 是裸函数名（无文件前缀），同名函数直接串边。
--     内核里 init / read / xmit 之类满地重名，这类边一律不可信。
--     物证：arguments 字段里的 `ntttt` 是 ctags 输出 \n\t 的转义残留 ——
--     这就是「按行抓文本」而非解析 AST 的铁证。
--
-- [10] 函数指针注册出来的入口，调用图完全看不见，必须手工 grep 赋值点：
--       .handler      = tcp_v4_rcv        → net/ipv4/af_inet.c:1937（inet_protos[]）
--       .enqueue_task = enqueue_task_fair → kernel/sched/fair.c:15671（sched_class ops）
--     同类断点：f_op->read_iter、ndo_start_xmit、irq handler 表、notifier/rcu 回调链、
--     SYSCALL_DEFINE3(read,...)（生成 sys_read，但索引里搜不到 sys_read 的定义）。
--     ⇒「这个函数谁调我」的两个真源只有：grep 调用点 + grep 表项赋值。
--
-- [11] 间接边带 [via xxx] 标注（obj->fn() / obj.fn() / M.fn()），语义是
--     「这条边可能混了同名直接调用」，不是精确虚调用解析；边仍按裸名解析（无类型信息）。
--     看到 [via] 当「可能」，不要当「就是」。
--
-- [12] context 的 depth 上限 5，但内核规模两层就够看清形状；再深一路穿到
--     printk / kmalloc 这类公共出口，全是噪声。
--
-- [13] dataflow 走 KV 键 funcs/<函数> 与 vars/<变量> 直取，不要去解析 dataflow.json。
--     查变量时还带跨过程 hop（变量作为第 pos 个实参传给 callee 的哪个形参，最多显示
--     8 条 + `... and N more`），这是 dataflow.json 里没有的落盘信息。
--     注意旧 KV 可能根本没有这两类键（实测 /opt/code_caches/linux_7212_cache 下
--     连 dataflow/ 目录都没有，只有 58M 的 call_graph.json），要 only_dataflow=true
--     重跑一次 import 才查得到。
--
-- [14] 内核建索引的参数（一次成功，别重来）：excludes 掉
--      Documentation,tools,samples,scripts（除非专门要查），
--      skip_kinds=header,file,enumerator,macro（头文件声明和宏会淹没符号表），
--      先 index 看切块量再 import。产物按 G 算（该 cache 8.0G），磁盘先腾。
--
-- [15] 复用已有索引靠 analysis_dir / kv_dir / project 三个覆盖参数，别在
--      /opt/linux 下重跑 build（几十分钟换不到新信息）。status 先看产物；
--      报「找不到索引」时会列出磁盘上真实存在的那几个，按它给路径重试。
--      lite 仓库自身不建索引（改自己用 read/cgrep/edit）。
--
-- [16] 读代码前先确认版本：cat Makefile | head -6 拿 VERSION/PATCHLEVEL/SUBLEVEL，
--      不要用记忆里的版本套结论。7.2.12 上已变、与 6.x 记忆冲突的例子：
--        __schedule(int sched_mode)，preempt = sched_mode > SM_NONE
--          （SM_NONE 定义在 core.c:6732；PREEMPT_RT 合并后把抢占来源压成一个参数）
--        proxy execution 已进树（core.c:6917 find_proxy_task）
--        sched_ext 已是目录 kernel/sched/ext/{ext,arena,cid,idle}.c
--        pick_next_task 换成 pick_task(rq, rf)（sched.h:2637），pick_task_fair 对外导出
--        netif_receive_skb_core 是导出的非双下划线包装（dev.c:6289）
--      结论标 [verified]（读到了具体源码行）/ [static]（仅从索引推断）。
--
-- [17] 【静默坑】ns（KV 键前缀）错一个斜杠 = 读到旧数据却报 count=0。
--     键就是 `<ns>/...` 原文，`code/x` 与 `/code/x` 是两套互不可见的前缀：import 用
--     ns="code/linux" 写进 code/linux/*，查询默认拼 /code/linux/* → 一条不中，
--     而 read 侧还可能命中上一次构建残留的旧 key（不报错，只给你旧答案）。
--     三道防线（改行为时别拆）：
--       a. norm_ns() 统一补前导 '/'（两种写法都落 /code/x），非法字符直接报错带协议；
--       b. import 成功就把 ns 钉进 `<analysis>/namespace.txt`，paths() 优先读它
--          → import / query 不可能各写一套前缀；索引目录名与 repo 名不一致时
--          （/opt/code_caches/linux_7212_cache）靠目录名反推本来就会推错；
--       c. 已有 namespace.txt 且与本次 ns 不同 → 只 WARN 不覆盖（可能是有意的另一套）。
--     自查：build 输出里的 ns 与 `cat <analysis>/namespace.txt` 不一致 = 踩了这条。
--
-- [18] 没有向量时 search 不会退化，它直接「没用」：do_search 在 g_ve 为空时只返回
--     一条 {"_note":"Vector engine not initialized..."} 的假结果（query.c:934 的
--     !g_ve 分支）；关键词 boost 只是在向量命中上重排，不是关键词兜底。所以：
--       · build 阶段缺模型/ORT 会跳过 vectorize（输出 "vectorize skipped
--         (model/onnxruntime missing)"），status 的 vectors 字段随之变成 none；
--       · 缺向量时查符号要走 symbol/exact/context，别用 search，也别信它的空结果。
--       · locate 侧已按这条兜底：先剥掉 _note 占位（它不算命中，也不该顶掉
--         「退回 symbol」的重试），再判定有没有真结果；一条都没有就打印
--         `no hit` + grep/symbol/build 三条下一步，而不是渲染 "[1] ? nil:1" 的空壳。
--
-- [19] analysis_dir 与 kv_dir 是两样东西，别混：analysis 放 chunks/call_graph/
--     dataflow.json 与向量，kv 才是查询真正读的键值库（默认 <analysis>/kv）。
--     只拿到旧 cache 的 analysis 却没重跑 import → status 看得见几十 M 的
--     call_graph.json，查询却全空（旧 KV 里连 /code 前缀的键都没有）；
--     只拷 kv 没有 analysis → 符号/调用边能查，但 status 全是 missing、没有向量
--     （search 只有 _note）、locate 的窗口还得靠 repo 文件本身在。两者要同源同版本。
--
-- [20] 输出预算与截断：单行 200 字符（SNIP_LINE_MAX），一次调用总预算 max_chars
--      （默认 8000）。凡是有内容没显示都会明说：`… (function spans 100-220, shown
--      100-139; next: peek ...)` / `budget reached: lower max_results/lines or raise
--      max_chars`。别把窗口末尾当函数末尾，也别把「截断」当「没找到」；
--      要看得全就一次调大 max_chars / lines，而不是原样重试同一调用。
--
-- ═══════════ 2026-11-14 增补：多包 / TS / 文档密集仓库的额外边界 ═══════════════
--
-- [21] 【文档会给出不存在的符号】比排错序更坑，因为它看着像答案。
--     物证：opencode 的 `packages/core/src/tool/AGENTS.md:8` 是 grep
--     "registry|Tool\.define" 的头号命中，里面写的 `ToolEditor.add` 在
--     packages/core/src 下 `grep -rn ToolEditor --include=*.ts` **零命中** [verified]。
--     成因：22 个 README*.md（th/ko/bn/zht/da… 同一段话翻了十几遍）+ 18 个 AGENTS.md，
--     让 tool/plugin/session/permission 这些词的词频彻底失真，规范文字混进代码语料。
--     纪律：**从 .md 读到的符号，先 grep 一次代码确认真身再用**；反过来，
--     grep 命中落在 .md 里就不算代码证据，别拿它支撑结论。
--
-- [22] 同名不同层是常态，不是异常。opencode：`loop.ts` 两份（packages/ui/src/motion/
--     loop.ts 是动画循环，packages/ai/src/loop.ts 是 provider 流循环），真正的 agent
--     循环却叫 session/runner/llm.ts（advanceToStep）；compaction 三份
--     （config/normalize.ts 校验 / session/compaction.ts 实现 / session/transfer.ts 脱敏）。
--     locate 会把它们一起端上来 —— 看到同名命中，先看路径前缀属于哪个 package 再读内容。
--     「这个仓没有唯一符号」本身就是仓库结构的证据，别为了消歧反复换 query。
--
-- [23] 非内核仓的 excludes 配方（省掉的全是噪声源）：
--       node_modules,dist,build,coverage,.next,out,specs,stories,docs,__fixtures__
--       以及 tests/testdata 这类只有数据的目录。
--     path_prefix 与 lang 仍是仅有的两个降噪旋钮（[5]）；多包仓优先 path_prefix
--     （opencode 上 path_prefix=packages/core/src/session/runner 立刻把三份同名收成一份）。
--
-- [24] 【lens 答不了「这个仓为什么难查」】包清单、目录深度、同名目录聚集、文档/代码比
--     —— 全是一次 bash 的事（ls packages、find|wc、grep -c 比较），lens 没有
--     map/overview 档，也别用 locate 硬凑，凑出来的是「检索质量问题」这种错答案。
--     这个误判会污染后面所有结论，所以 [1] 把「判形状」提到了起手式的位置。
-- ═══════════════════════════════════════════════════════════════════════════════

local CS = require("ffi.codesearch")
local cjson = require("cjson")

local function env(name)
    local v = os.getenv(name)
    if v and v ~= "" then return v end
end

local function cpu_count()
    local n = 0
    local f = io.open("/proc/cpuinfo")
    if f then
        for line in f:lines() do
            if line:match("^processor%s*:") then n = n + 1 end
        end
        f:close()
    end
    return n > 0 and n or 1
end

local function worker_count(args)
    if args.workers then return args.workers end
    local n = env("LITE_CS_WORKERS")
    n = n and tonumber(n)
    if n and n > 0 then return n end
    return args.fork and cpu_count() or 1
end

local function home()
    local h = env("LITE_CS_HOME")
    if h then return (h:gsub("/+$", "")) end
    local x = env("XDG_DATA_HOME")
    if x then return (x:gsub("/+$", "")) .. "/lite/codesearch" end
    local hh = env("HOME") or "/tmp"
    return hh .. "/.local/share/lite/codesearch"
end

local function abs_path(p, cwd)
    if not p or p == "" then p = "." end
    if p:sub(1, 1) == "/" then return (p:gsub("(.)/+$", "%1")) end
    local base = cwd or env("PWD") or "."
    if p == "." then return (base:gsub("(.)/+$", "%1")) end
    return (base .. "/" .. p)
end

local function basename(p)
    local b = p:gsub("/+$", ""):match("([^/]+)$") or "workspace"
    return b
end

local function safe_name(s)
    return (s:gsub("[^%w%._%-]", "_"))
end

-- namespace 只由索引目录决定，不能拿 repo 目录名推：/opt/code_caches/linux_7212_cache
-- 这种命名的项目，用 repo 名会拼出 /code/linux_7212_cache，跟 import 写的 /code/linux_7212
-- 对不上 → 所有查询稳定返回 0 条且不报错（看起来像「没索引」）。优先读 build 时写的
-- <analysis>/namespace.txt，没有就按目录名去掉 _cache 后缀推。
local function marker_ns(dir)
    if not dir or dir == "" then return nil end
    local f = io.open(dir .. "/namespace.txt", "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    s = s and s:gsub("%s+$", "")
    if not s or s == "" then return nil end
    -- 文件里的值可能是手写的 `code/x`（少前导斜杠）：KV 前缀是 ns 原文，
    -- 原样用会落到另一套键空间，所有查询稳定 0 命中且不报错 —— 这里就地归一化。
    s = (s:gsub("%s+", "")):gsub("^/+", "")
    if s == "" or not s:match("^[%w%._%-/:]+$") then return nil end
    return "/" .. s
end

local function ns_from_dir(dir)
    if not dir or dir == "" then return nil end
    local base = dir:gsub("/+$", ""):match("([^/]+)$")
    if not base then return nil end
    return "/code/" .. safe_name((base:gsub("_cache$", "")))
end

-- 老索引（早于 namespace.txt 这个约定）只能靠目录名反推 ns。反推对了就顺手钉下来：
-- 下次不用再猜，也挡住 `_cache` 后缀/改名差一格就静默 0 命中。只在查询**命中后**调用——
-- 0 命中时写进去等于把错的 ns 固化。已有 marker 就不碰（可能是别人有意写的另一套）。
local function pin_ns(analysis, ns)
    if not analysis or analysis == "" or not ns or ns == "" then return false end
    if marker_ns(analysis) then return false end
    local f = io.open(analysis .. "/namespace.txt", "w")
    if not f then return false end
    f:write(ns, "\n")
    f:close()
    return true
end

-- 手工传 ns 时统一补前导 '/'。KV 键前缀就是 ns 原文，`code/x` 与 `/code/x` 是两套
-- 互不可见的键空间：import 写错一个斜杠，查询侧仍是 /code/x → 读到的是上一次构建留下的
-- 旧 key，表现为「重建了但 dataflow 还是垃圾」，且不报错。归一化让两种写法都落到 /code/x；
-- 非法字符则直接报错（带原参数 + 期望格式），别让它静默写进一套查不到的前缀。
local function norm_ns(ns)
    if not ns or ns == "" then return nil end
    local raw = tostring(ns)
    ns = (raw:gsub("%s+", "")):gsub("^/+", "")
    if not ns:match("^[%w%._%-/]+$") then
        -- 报错回报**原始入参**，别报归一化后的串：否则 `code/x y!` 被剥成 `code/xy!`，
        -- 用户对着报错找不回自己写的那个值（这里要的是可自修，不是整洁）。
        error(string.format(
            "codesearch: bad ns %q (required: ns like \"/code/<repo>\" / [A-Za-z0-9._-/:])",
            raw), 0)
    end
    return "/" .. ns
end

local has_index, index_candidates   -- 定义在下方，paths() 里先用

local function paths(args, ctx)
    local repo = abs_path(args.path, ctx and ctx.cwd)
    local project = safe_name(args.project or basename(repo))
    local analysis = args.analysis_dir or os.getenv("LITE_CS_ANALYSIS")
        or (home() .. "/" .. project)
    analysis = (analysis:gsub("/+$", ""))
    -- 默认目录没有索引时，按项目名去已知位置找一份（项目名可能带 _cache 后缀，
    -- 也可能落在 /opt/code_caches/<project>_cache），找到就直接用，省掉手写长路径。
    if not args.analysis_dir and has_index and not has_index(analysis) then
        local hit
        for _, dir in ipairs(index_candidates and index_candidates() or {}) do
            local base = dir:match("([^/]+)$") or ""
            if base == project or base == project .. "_cache"
                or base:gsub("_cache$", "") == project then hit = dir break end
        end
        if hit then analysis = hit end
    end
    local kv = args.kv_dir or (analysis .. "/kv")
    -- ns 跟着「实际用的索引目录」走，否则 fallback/analysis_dir 换目录时 ns 还留在 repo 名上，
    -- 查询会一条不中却报 count=0（错误不可自修）。build 侧同样走 paths()，两边一致。
    local ns = norm_ns(args.ns) or marker_ns(analysis) or ns_from_dir(analysis)
        or ("/code/" .. project)
    return repo, project, analysis, kv, ns
end

local function one_line(s, n)
    if not s or s == "" then return "" end
    s = tostring(s):gsub("%s+", " ")
    if #s > n then s = s:sub(1, n) .. "..." end
    return s
end

-- 单行硬上限（read_window / fmt_content_window 共用）。
local SNIP_LINE_MAX = 200

-- fmt_content_window 要「窗口读盘优先」，但 read_window/abs_file 写在下面几百行：
-- 这里前置声明，下面定义处必须写成 `function x(...)`（再写 `local function` 会新起一个
-- 同名 local，遮蔽掉这个引用 → 运行期拿到 nil 报 "attempt to call a nil value"）。
local read_window, abs_file

-- 索引里的 chunk 是建索引那一刻的源码快照，文件改过之后它「看着像、行号错开」。
-- 判定办法：chunk 首行 vs 盘上 line_start 那一行，都去空白后比较。
local function norm_ws(s)
    return (tostring(s or ""):gsub("%s+", ""))
end

-- content 里的换行是 JSON 层的字面 `\n`（两字符）。不还原的话整块挤成一行，
-- 编号就只剩第一个行号，窗口看着像「这函数只有一行」。
local function unescape_content(s)
    s = tostring(s or "")
    if not s:find("\n", 1, true) and s:find("\\n", 1, true) then
        s = s:gsub('\\"', '"'):gsub("\\r", ""):gsub("\\n", "\n"):gsub("\\t", "\t")
    end
    return s
end

-- 没有盘上内容时的退路：按 chunk 起行编号（与 locate/peek 的 `  123| code` 同格式）。
local function window_from_text(text, first, cap, indent)
    indent = indent or "      "
    local out, n = {}, 0
    for ln in (text .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        ln = ln:gsub("\r$", "")
        if #ln > SNIP_LINE_MAX then ln = ln:sub(1, SNIP_LINE_MAX) .. " …" end
        out[#out + 1] = string.format("%s%5d| %s", indent, first + n - 1, ln)
        if n >= (cap or 12) then out[#out + 1] = indent .. "     …"; break end
    end
    return table.concat(out, "\n")
end

-- search/symbol 的 r.content 是一整块源码（chunk）。压成一行只剩开头几百字，
-- 调用方拿不到行号还得自己数 → 没法直接引用 file:line。这里按 chunk 起行右对齐编号，
-- 与 locate/peek 的窗口格式一致（`  123| code`）。
--
-- 窗口**读盘优先**：索引里的是建索引那一刻的快照，文件改过之后 chunk 会给出
-- 「旧代码 + 对得上的行号」，看着完全正常，引用出去就是错的。所以能用 r.file
-- 读到盘就显示盘上内容；盘上首行和 chunk 首行对不上时明说 stale（而不是静默）。
-- 读不到盘（文件删了/不在 repo）才退回 chunk，并标 `(index copy)`。
local function fmt_content_window(r, cap, indent, cwd)
    indent = indent or "      "
    cap = cap or 12
    local text = unescape_content(r and r.content)
    local first = tonumber(r.line_start or r.line) or 1
    local path = r and r.file and abs_file(r.file, cwd)
    local live = path and read_window(path, first, first + cap - 1)
    if live then
        local stale = ""
        if text ~= "" then
            local idx_first = norm_ws((text:match("^([^\n]*)") or ""))
            local disk_first = norm_ws((live:match("^%s*%d+%|([^\n]*)") or ""))
            if idx_first ~= "" and disk_first ~= "" and idx_first ~= disk_first then
                stale = string.format("\n%s  [stale: index copy ≠ disk @%d — 显示的是盘上内容; "
                    .. "要新索引跑 action=index]", indent, first)
            end
        end
        return live .. stale
    end
    if text == "" then return nil end
    return window_from_text(text, first, cap, indent)
        .. string.format("\n%s  (index copy; %s)", indent, tostring(r.file or "no file"))
end

-- 置信度标签：score 只说明「排第几」，confidence 说明「该不该信」。
-- 缺字段（旧的 .so / non-vector 结果）就退回 score，不硬造数字。
local function conf_tag(r)
    local c = tonumber(r and r.confidence)
    if not c then
        return (r and r.score) and string.format("  conf=%.2f", r.score) or ""
    end
    return string.format("  conf=%.2f(%s)", c, tostring(r.confidence_label or "?"))
end

-- 证据来源一行：只挑最关键的两条（vector/keyword/graph/penalty），
-- metadata 那条是每条都有的出处，进正文反而占地方；全量看 json=true。
local function fmt_evidence(r, max_items)
    local ev = r and r.evidence
    if type(ev) ~= "table" or #ev == 0 then return nil end
    local parts = {}
    for _, e in ipairs(ev) do
        if type(e) == "table" and e.source and e.source ~= "metadata" then
            parts[#parts + 1] = e.source .. ": " .. tostring(e.detail)
        end
        if #parts >= (max_items or 2) then break end
    end
    if #parts == 0 then return nil end
    return "    why: " .. table.concat(parts, " | ")
end

local function fmt_status(d)
    local out = { string.format("analysis: %s", d.analysis_dir) }
    local f = d.files or {}
    for _, name in ipairs({ "chunks_meta.jsonl", "chunks_text.txt", "word_freq.json",
                            "call_graph.json", "dataflow.json" }) do
        local x = f[name] or {}
        local info = x.exists and (tostring(x.bytes) .. "B") or "missing"
        local lines = x.lines
        if lines and lines >= 0 then info = info .. "  " .. lines .. " lines"
        elseif x.exists then info = info .. "  large" end
        out[#out + 1] = string.format("  %-20s %s", name, info)
    end
    local vs = d.vectors or {}
    if #vs == 0 then
        out[#out + 1] = "  vectors             none"
    else
        for _, v in ipairs(vs) do
            out[#out + 1] = string.format("  %-20s %dB", v.name, v.bytes or 0)
        end
    end
    local m = d.models or {}
    out[#out + 1] = string.format("  models              jina=%s ort=%s (%s)",
        tostring(m.jina_onnx), tostring(m.onnxruntime), tostring(m.model_dir))
    if not (((d.files or {})["chunks_meta.jsonl"] or {}).exists) and index_candidates then
        local c = index_candidates()
        if #c > 0 then
            local want = d.analysis_dir:match("([^/]+)$")
            local pick
            for _, dir in ipairs(c) do
                if want and dir:find(want, 1, true) then pick = dir break end
            end
            if pick then
                out[#out + 1] = "  hint                no index here; pass analysis_dir=" .. pick
            else
                -- 没有同名索引：别瞎指一个别的项目，只列出现有的
                local names = {}
                for _, dir in ipairs(c) do
                    names[#names + 1] = (dir:match("([^/]+)$") or dir):gsub("_cache$", "")
                end
                out[#out + 1] = "  hint                no index for this project; built: "
                    .. table.concat(names, ", ")
            end
        end
    end
    return table.concat(out, "\n")
end

-- exact 能直取任意键，值形状五花八门：{entries=[路径]}、{callers=[边]}、{callees=[边]}、
-- {occurrences=[…]}，还有单个 chunk。以前只认 entries 和 chunk 两种形状，其余渲染成
-- `[1] ? ?:? kind=` —— 键明明取到了却显示成空的，比报错更坑（会误判「这个键没数据」）。
-- 这里按 键 → 数组 → 一行一条 兜底；主数组（最长那个）排前面。
local function fmt_payload(r, cap)
    local keys = {}
    for k, v in pairs(r) do
        if type(k) == "string" and k:sub(1, 1) ~= "_" and type(v) == "table" then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, function(a, b)
        local la, lb = #(r[a] or {}), #(r[b] or {})
        if la ~= lb then return la > lb end
        return a < b
    end)
    local lines = {}
    for _, k in ipairs(keys) do
        local arr = r[k]
        if #arr == 0 and next(arr) ~= nil then
            -- 不是数组而是 map（path → meta 之类的键值对）：一条一行
            lines[#lines + 1] = "  " .. k
            local n = 0
            for kk, vv in pairs(arr) do
                n = n + 1
                if n > cap then
                    lines[#lines + 1] = "    ... +more (json=true)"
                    break
                end
                local vs = type(vv) == "table" and one_line(cjson.encode(vv), 200) or tostring(vv)
                lines[#lines + 1] = "    " .. tostring(kk) .. ": " .. vs
            end
        else
            lines[#lines + 1] = string.format("  %s (%d)", k, #arr)
            local shown = 0
            for _, item in ipairs(arr) do
                if shown >= cap then
                    lines[#lines + 1] = string.format("    ... +%d more (raise cap: json=true)", #arr - shown)
                    break
                end
                shown = shown + 1
                if type(item) ~= "table" then
                    lines[#lines + 1] = "    " .. tostring(item)
                elseif item.file then
                    local s = string.format("%s:%s", tostring(item.file),
                        tostring(item.line or item.line_start or "?"))
                    if item.name then s = s .. "  " .. tostring(item.name) end
                    if item.args and item.args ~= "" then s = s .. "(" .. tostring(item.args) .. ")" end
                    if item.scope then s = s .. "  scope=" .. tostring(item.scope) end
                    if item.type then s = s .. "  " .. tostring(item.type) end
                    lines[#lines + 1] = "    " .. s
                else
                    lines[#lines + 1] = "    " .. one_line(cjson.encode(item), 240)
                end
            end
        end
    end
    if #keys == 0 then lines[#lines + 1] = "  " .. one_line(cjson.encode(r), 400) end
    return lines
end

local function fmt_results(d, max_chars, ns, cwd)
    local rs = d.results or {}
    local out = { string.format('%s "%s" -> %d result(s), %d ms',
        d.type or "?", d.query or "", #rs, d.timing_ms or 0) }
    if #rs == 0 and (d.type or "") == "exact" then
        -- 0 命中绝大多数不是「键不存在」，而是查询走的前缀和 import 写的不是一套
        -- （namespace.txt 缺失时只能靠目录名反推）。把实际用的 ns 报出来才可自修。
        out[#out + 1] = "hint: exact 试过 <key> 直取 → <key>/... 子键 → /symbols/<name> → 文件路径，" ..
            "都没有；用 symbol/locate/grep 再收窄"
        if ns then
            out[#out + 1] = string.format(
                "      查询前缀 ns=%s（KV 键就是它拼出来的；索引前缀不同时稳定 0 命中且不报错）"
                .. " → 确认前缀用 action=status，或显式 ns=/code/<repo>", tostring(ns))
        end
    end
    local total = 0
    for i, r in ipairs(rs) do
        local line
        if r.entries then
            line = string.format("[%d] %s (exact)", i, r._key or "?")
            out[#out + 1] = line
            if type(r.entries[1]) == "string" then
                -- 纯路径清单：一行一条（原来整坨 JSON 挤一行，还被 800 字静默砍掉）
                for j, p in ipairs(r.entries) do
                    if j > 40 then
                        out[#out + 1] = string.format("    ... +%d more (json=true)", #r.entries - 40)
                        break
                    end
                    out[#out + 1] = "    " .. tostring(p)
                    total = total + #tostring(p)
                end
            else
                for _, l in ipairs(fmt_payload(r, 20)) do
                    out[#out + 1] = l
                    total = total + #l
                end
            end
        elseif type(r[1]) == "table" then
            -- 值是 chunk 数组（如直取 /symbols/<name>）：以前落到标量兜底，整坨 JSON 挤一行。
            -- 按普通结果逐条打，带源码窗口。
            line = string.format("[%d] %s (exact)", i, r._key or "?")
            out[#out + 1] = line
            for j, it in ipairs(r) do
                local s = string.format("  [%d] %s  %s:%s  kind=%s", j, it.name or "?",
                    it.file or "?", tostring(it.line or it.line_start or "?"), it.kind or "")
                out[#out + 1] = s
                total = total + #s
                local win = fmt_content_window(it, 12, nil, cwd)
                if win then
                    out[#out + 1] = win
                    total = total + #win
                end
            end
        elseif not r.name and not r.file and not r.content then
            -- 不是 chunk、不是文件清单 = exact 直取的任意结构化键（callers/callees/…）
            line = string.format("[%d] %s (exact)", i, r._key or "?")
            out[#out + 1] = line
            for _, l in ipairs(fmt_payload(r, 20)) do
                out[#out + 1] = l
                total = total + #l
            end
        else
            line = string.format("[%d] %s  %s:%s  kind=%s", i,
                r.name or "?", r.file or "?", tostring(r.line_start or "?"), r.kind or "")
            if r.score then line = line .. string.format("  score=%.3f", r.score) end
            line = line .. conf_tag(r)
            out[#out + 1] = line
            if r.signature and r.signature ~= "" then
                out[#out + 1] = "    sig: " .. one_line(r.signature, 200)
            end
            local win = fmt_content_window(r, 12, nil, cwd)
            if win then out[#out + 1] = win end
        end
        total = total + #line
        if total > (max_chars or 8000) then
            out[#out + 1] = "... (capped, raise max_results or use json=true)"
            break
        end
    end
    return table.concat(out, "\n")
end

local function fmt_context(d, max_chars)
    local ctx = d.context or {}
    local sym = ctx.symbol or (d.results or {})[1] or {}
    local out = { string.format("%s  %s:%s  kind=%s", sym.name or "?",
        sym.file or "?", tostring(sym.line or sym.line_start or "?"), sym.kind or "") }
    local function names(label, arr, cap)
        if not arr or #arr == 0 then return end
        -- 一条边 = 一个调用点，不是一条「关系」：内核函数动辄 90+ callee 而其中
        -- 三十个是同一个名字的多次调用（tcp_ack 里 tcp_sacktag_write_queue×3），
        -- 不去重时长函数光重复就吃满 cap，真正独有的被挤掉。按名字合并成 name×N，
        -- 顺序保留首次出现；cap 数的是「唯一名字」，表头仍报原始边数。
        local order, cnt = {}, {}
        for _, v in ipairs(arr) do
            local s
            if type(v) == "table" then
                -- 间接调用：obj->fn()/obj.fn() 只能按裸名挂边，标出来让调用方打折
                s = v.name or "?"
                if v.indirect then s = s .. "[via " .. (v.via or "?") .. "]" end
                -- 同名多份实现混在这条边上：不是精确边，用 def= 收窄
                if v.scope == "ambiguous" then s = s .. "[?def " .. tostring(v.defs or 2) .. "]" end
            else
                s = tostring(v)
            end
            if not cnt[s] then order[#order + 1] = s; cnt[s] = 0 end
            cnt[s] = cnt[s] + 1
        end
        local t = {}
        for i, s in ipairs(order) do
            if i > (cap or 30) then t[#t + 1] = "...(+" .. (#order - i + 1) .. " more)"; break end
            t[#t + 1] = cnt[s] > 1 and (s .. "×" .. cnt[s]) or s
        end
        out[#out + 1] = string.format("%s(%d, %d unique): %s", label, #arr, #order,
            table.concat(t, ", "))
    end
    names("callers", ctx.callers)
    names("callees", ctx.callees)
    local paths = ctx.call_paths or {}
    if #paths > 0 then
        local t = {}
        for i, p in ipairs(paths) do
            if i > 10 then t[#t + 1] = "..."; break end
            t[#t + 1] = table.concat(p, " -> ")
        end
        out[#out + 1] = "paths: " .. table.concat(t, " | ")
    end
    local df = ctx.dataflow or {}
    local vars = {}
    local function add_var(name, data)
        local occ = data.occurrences or {}
        local lines = {}
        for i, o in ipairs(occ) do
            if i > 6 then lines[#lines + 1] = "..."; break end
            lines[#lines + 1] = string.format("%s:%s %s",
                o.file or "?", tostring(o.line or "?"), o.type or "")
        end
        vars[#vars + 1] = string.format("%s(%d) %s", name or "?", #occ,
            table.concat(lines, "; "))
    end
    for _, entry in ipairs(df) do
        local data = entry.data
        if type(data) == "table" then
            if data.occurrences then
                add_var(data.name, data)
            else
                local keys = {}
                for k in pairs(data) do keys[#keys + 1] = k end
                table.sort(keys)
                for i, k in ipairs(keys) do
                    if i > 20 then vars[#vars + 1] = "..."; break end
                    add_var(k, data[k])
                end
            end
        end
    end
    if #vars > 0 then
        out[#out + 1] = "dataflow: " .. table.concat(vars, "\n          ")
    end
    -- path_prefix 过滤过就报一声：否则「callers 变少」看起来像索引没建全
    local fo = (d.stats or {}).filtered_out
    if fo then
        out[#out + 1] = string.format("filtered by path_prefix=%s: -%d callers, -%d callees",
            fo.path_prefix or "?", tonumber(fo.callers) or 0, tonumber(fo.callees) or 0)
    end
    -- 同名多定义：把几份实现与解析分档摊开。ambiguous>0 说明这些边混了同名实现，
    -- 不是精确事实 —— 先用 def= 收窄再下「谁调用谁」的结论。
    local defs = ctx.definitions or {}
    if #defs > 1 then
        local t = {}
        for i, dv in ipairs(defs) do
            if i > 8 then t[#t + 1] = "..."; break end
            t[#t + 1] = string.format("%s:%s", dv.file or "?", tostring(dv.line or "?"))
        end
        out[#out + 1] = string.format("definitions(%d): %s", #defs, table.concat(t, ", "))
    end
    local rs = (d.stats or {}).resolution
    if rs then
        out[#out + 1] = string.format(
            "resolution: local=%d global=%d ambiguous=%d external=%d",
            tonumber(rs["local"]) or 0, tonumber(rs.global) or 0,
            tonumber(rs.ambiguous) or 0, tonumber(rs.external) or 0)
    end
    local fd = (d.stats or {}).filtered_by_def
    if fd then
        out[#out + 1] = string.format("filtered by def=%s: -%d callers, -%d callees",
            fd.def or "?", tonumber(fd.callers) or 0, tonumber(fd.callees) or 0)
    end
    local s = table.concat(out, "\n")
    if #s > (max_chars or 8000) then s = s:sub(1, max_chars or 8000) .. "\n... (capped)" end
    return s
end

local function fmt_dataflow(d)
    local rs = d.results or {}
    if #rs == 0 then
        return string.format('dataflow "%s" not found (run action=import to rebuild ' ..
            'dataflow funcs index, or check the spelling)', d.query or "")
    end
    local out = {}
    for _, entry in ipairs(rs) do
        if entry.kind == "function" then
            out[#out + 1] = string.format("func %s — %d var(s)", entry.func or "?",
                tonumber(entry.var_count) or 0)
            for _, v in ipairs(entry.vars or {}) do
                local occ = v.occurrences or {}
                -- import 侧存的 occurrences 是遍历顺序、不是行号顺序（delta 会排成
                -- 6551,6565,6568,…,6524,6538,…），不排就看着像乱跳；v.line 也只是
                -- 「第一条命中行」，不是定义行 —— 所以标签写 first_occ，别让人当声明看。
                -- 只列 6 条还不标总数，会被读成「这变量就这么多用法」。
                local sorted = {}
                for i, o in ipairs(occ) do sorted[i] = o end
                table.sort(sorted, function(a, b) return (a.line or 0) < (b.line or 0) end)
                local lines = {}
                for i, o in ipairs(sorted) do
                    if i > 6 then
                        lines[#lines + 1] = string.format("…+%d more", #sorted - 6)
                        break
                    end
                    lines[#lines + 1] = string.format("%s:%s %s", o.file or "?",
                        tostring(o.line or "?"), o.type or "")
                end
                -- v.line 是 import 时第一条命中（遍历序），跟行号最小值没关系；
                -- 既然已经排过序，就报真正最小的那行，标签 first_occ 才不撒谎。
                -- v.decl 存在时那是 analyzer 挑出的真·定义行，写 decl= 才叫声明。
                local first = (sorted[1] and sorted[1].line) or v.line
                local where = string.format("first_occ=%s", tostring(first or "?"))
                if type(v.decl) == "table" and v.decl.line then
                    where = string.format("decl=%s:%s", v.decl.file or "?", tostring(v.decl.line))
                    -- decl_scope=module = 本函数里没找到声明，这个 decl 是全库同名的
                    -- 另一处局部（内核里 last/in/reason 这种名字有成百上千个），
                    -- 不标出来就会把别人的声明当本函数的。
                    if v.decl_scope == "module" then where = where .. " [module-scope]" end
                end
                -- occurrences 被 MAX_OCCURS 截过时把总数说出来（「这么多用法」是假结论）。
                local occ_note = string.format("occ_in_func=%s",
                    tostring(v.occurrences_in_func or #occ))
                if v.occurrences_truncated then
                    occ_note = occ_note .. string.format(" (capped %s of %s total)",
                        tostring(v.occurrences_limit or "?"),
                        tostring(v.occurrences_total or "?"))
                end
                out[#out + 1] = string.format("  %s %s  %s  %s",
                    v.var or "?", where, occ_note, table.concat(lines, "; "))
            end
        elseif entry.kind == "variable" then
            local head = string.format("var %s — %s occurrence(s) across %d func(s)",
                entry.var or "?", tostring(entry.occurrence_count or 0), #(entry.funcs or {}))
            -- 真·声明行 + 截断说明（occurrence_count 只是落盘条数，有上限）。
            if type(entry.decl) == "table" and entry.decl.line then
                head = head .. string.format("  decl=%s:%s",
                    entry.decl.file or "?", tostring(entry.decl.line))
                -- 变量视角永远是 module-scope（同一个名字在内核里有几十上百处声明）
                if entry.decl_scope == "module" then
                    head = head .. " [module-scope]"
                end
            end
            if entry.occurrences_truncated then
                head = head .. string.format("  (capped %s of %s total)",
                    tostring(entry.occurrences_limit or "?"),
                    tostring(entry.occurrence_total or "?"))
            end
            out[#out + 1] = head
            -- 跨过程跳：变量在 caller 里作为第 pos 个实参传给 callee 的哪个形参。
            -- 以前这条边只在查询侧用 strstr(args, var) 猜，既不落盘也不给形参名。
            local hops = entry.hops or {}
            if #hops > 0 then
                local show = math.min(#hops, 8)
                for i = 1, show do
                    local h = hops[i]
                    out[#out + 1] = string.format(
                        "  → %s:%s %s() calls %s(%s) [arg %s, %s]",
                        h.file or "?", tostring(h.line or "?"), h.caller or "?",
                        h.callee or "?",
                        (h.param and h.param ~= "") and h.param
                            or ("arg" .. tostring(h.pos or "?")),
                        tostring(h.pos or "?"), h.scope or "external")
                end
                local more = tonumber(entry.hop_count or #hops) - show
                if more > 0 then
                    out[#out + 1] = string.format("  ... and %d more cross-proc hop(s)", more)
                end
            end
            -- 一行一个函数：`name ×count @file:行列表`。原来 `name (12) lines 1,2,3`
            -- 每行多 8 字节前缀（"lines "），一对齐就看不清哪个函数命中最多；
            -- file 只有字段聚合那一路会带，没有就只给行号（别硬造 "@?"）。
            for _, f in ipairs(entry.funcs or {}) do
                local lines = {}
                for i, l in ipairs(f.lines or {}) do
                    if i > 8 then lines[#lines + 1] = "…"; break end
                    lines[#lines + 1] = tostring(l)
                end
                out[#out + 1] = string.format("  %s ×%s  %s%s", f.func or "?",
                    tostring(f.count or 0),
                    f.file and (tostring(f.file) .. ":") or "line ",
                    table.concat(lines, ","))
            end
        elseif entry.kind == "candidates" then
            out[#out + 1] = string.format('"%s" not found; similar functions: %s',
                entry.query or "?", table.concat(entry.functions or {}, ", "))
        elseif entry.kind == "note" then
            -- dataflow 只做 C 族词法：空结果时把覆盖范围讲清楚（而不是让人去猜拼写）
            local n = entry.note or {}
            local langs = {}
            for k, v in pairs(n.langs or {}) do
                langs[#langs + 1] = string.format("%s=%s", k, tostring(v))
            end
            table.sort(langs)
            out[#out + 1] = string.format(
                'no dataflow hit for "%s" — analyzer covered %s function(s) ' ..
                '(c-family %s, other %s; %s); langs: %s',
                entry.query or "?", tostring(n.functions or "?"),
                tostring(n.c_family_functions or 0), tostring(n.other_language_functions or 0),
                tostring(n.lexer or "?"), table.concat(langs, ", "))
            if n.note then out[#out + 1] = "  note: " .. tostring(n.note) end
        end
    end
    local s = table.concat(out, "\n")
    if #s > 8000 then s = s:sub(1, 8000) .. "\n... (capped)" end
    return s
end

local function fmt_symbols(d, cwd)
    local rs = d.results or {}
    if #rs == 0 then return string.format('symbol "%s" not found', d.query or "") end
    local out, seen, shown = {}, {}, 0
    for _, r in ipairs(rs) do
        -- 同名符号在别的文件里也有一份（内核里同名 static 满地是）：按 file:line 去重，
        -- 否则 max_results 全被同一个定义的多个 chunk 吃掉。
        local key = tostring(r.file or "?") .. ":" .. tostring(r.line or r.line_start or "?")
        if not seen[key] then
            seen[key] = true
            shown = shown + 1
            out[#out + 1] = string.format("[%d] %s  %s:%s  kind=%s", shown, r.name or "?",
                r.file or "?", tostring(r.line or r.line_start or "?"), r.kind or "")
            local win = fmt_content_window(r, 8, nil, cwd)
            if win then out[#out + 1] = win end
        end
    end
    if shown < #rs then
        out[#out + 1] = string.format("(%d 条同名/同位置重复已折叠)", #rs - shown)
    end
    return table.concat(out, "\n")
end

-- 失败必须能定位：报错带上日志路径，进度/真实 stderr 都在那里面。
local function check_stage(name, r, logpath)
    if not r then
        error("codesearch: " .. name .. " failed: " ..
              tostring(CS.lib and "no result" or "library missing") ..
              (logpath and ("\n日志: " .. logpath) or ""), 0)
    end
    if r.ok == false or (r.exit and r.exit ~= 0) then
        error(string.format("codesearch: %s failed (exit %s): %s%s", name,
            tostring(r.exit), tostring(r.error or ""),
            logpath and ("\n日志: " .. logpath) or ""), 0)
    end
    return r
end

has_index = function(dir)
    local f = io.open(dir .. "/chunks_meta.jsonl", "rb")
    if f then f:close() return true end
    return false
end

-- 索引不在默认路径时报错要可自修（AGENTS.md §5）：把磁盘上真实存在的索引列出来，
-- 免得调用方看着「run action=build first」去重跑几小时的建索引。
index_candidates = function()
    local out, seen = {}, {}
    local function scan(glob)
        local p = io.popen("ls -d " .. glob .. " 2>/dev/null")
        if not p then return end
        for line in p:lines() do
            line = line:gsub("/+$", "")
            if line ~= "" and not seen[line] and has_index(line) then
                seen[line] = true
                out[#out + 1] = line
            end
        end
        p:close()
    end
    scan("/opt/code_caches/*_cache")
    scan("/opt/code_caches/*")
    scan(home() .. "/*")
    return out
end

local function need_built(d, what)
    local meta = ((d.files or {})["chunks_meta.jsonl"] or {})
    if not meta.exists then
        local cands = index_candidates()
        local hint = ""
        if #cands > 0 then
            -- 项目名相关的排前面，最多列 8 个，别把 20 多份索引全糊到报错里
            local want = tostring(d.analysis_dir):match("([^/]+)$") or ""
            local head, tail = {}, {}
            for _, dir in ipairs(cands) do
                if want ~= "" and dir:find(want, 1, true) and #head < 3 then head[#head + 1] = dir
                else tail[#tail + 1] = dir end
            end
            local list = {}
            for _, dir in ipairs(head) do list[#list + 1] = dir end
            for _, dir in ipairs(tail) do
                if #list >= 8 then break end
                list[#list + 1] = dir
            end
            hint = "\navailable indexes: " .. table.concat(list, ", ")
                .. (#cands > #list and string.format(" (+%d more)", #cands - #list) or "")
                .. "\n  -> pass analysis_dir=<dir> (add project=<name> when the KV namespace differs)"
        end
        error(string.format("codesearch: no index at %s\n"
            .. "fix: analysis_dir=<dir> overrides it (default ~/.local/share/lite/codesearch/<project>, "
            .. "LITE_CS_ANALYSIS changes the default), or action=build creates one%s",
            tostring(d.analysis_dir), hint), 0)
    end
    if what == "kv" then
        local kvf = d.analysis_dir .. "/kv/mem.bin"
        local f = io.open(kvf, "rb")
        if not f then
            error(string.format("codesearch: KV import missing at %s\n"
                .. "fix: action=import (or action=build) with the same analysis_dir/kv_dir", kvf), 0)
        end
        f:close()
    end
end

local function do_build(args, repo, project, analysis, kv, ns)
    local stages = {}
    local logpath = (args.log and args.log ~= "") and args.log or CS.log_path(analysis)
    -- 每个阶段都在 <analysis>/build.log 上留起止+退出码，失败原因不再只活在 stdout
    local function stage(name, fn)
        local r, e = CS.logged(name, logpath, fn)
        check_stage(name, r or nil, logpath)
        stages[#stages + 1] = name .. " ok"
        return r
    end

    stage("index", function()
        return CS.index({ repo = repo, analysis_dir = analysis,
                          workers = worker_count(args),
                          fork = args.fork, skip_kinds = args.skip_kinds,
                          include_dirs = args.include_dirs,
                          excludes = args.excludes, plugins = args.plugins })
    end)
    stage("word_freq", function() return CS.word_freq(analysis) end)
    stage("callgraph", function() return CS.callgraph(analysis) end)
    stage("dataflow", function() return CS.dataflow(analysis) end)
    stage("import", function() return CS.import(analysis, ns, kv, args.only_dataflow) end)
    -- 落一份 namespace 标记：查询侧 paths() 优先读它。索引目录名和 repo 名不一致时
    -- （/opt/code_caches/linux_7212_cache），靠目录名反推会得到错的 ns → 稳定 0 命中。
    do
        local f = io.open(analysis .. "/namespace.txt", "w")
        if f then f:write(ns, "\n"); f:close() end
    end

    local caps = CS.check(analysis) or {}
    local models = caps.models or {}
    local want_vec = args.vector ~= false and not env("LITE_CS_DISABLE_VECTOR")
    if want_vec and models.jina_onnx and models.onnxruntime then
        stage("vectorize", function()
            return CS.vectorize(analysis, args.model or "jina", project,
                                { batch = args.batch, fp16 = args.fp16 })
        end)
    elseif want_vec then
        stages[#stages + 1] = "vectorize skipped (model/onnxruntime missing)"
    else
        stages[#stages + 1] = "vectorize skipped (disabled)"
    end

    local st = CS.check(analysis)
    return "build: " .. project .. "\n  " .. table.concat(stages, "\n  ") ..
        "\n" .. fmt_status(st) .. "\n日志: " .. logpath
end

-- ── 组合动作：locate（搜+读）/ grep（作用域搜）/ peek（定点读）──────────────
-- 这三条来自 src/codesearch/code_search_best_practices.md 里最高频的组合拳：
--   search → 人工拼 read（两次往返，且常读错行）⇒ locate 直接内联源码窗口
--   整仓 grep（慢 + 噪声命中）                  ⇒ grep 先按目录/文件收窄 + 护栏
--   read 文件再数行号                            ⇒ peek 给 file:line 直接读窗口
-- 读源码的硬上限：单行 200 字符（SNIP_LINE_MAX，见 one_line 上方）、总输出 8000 字符，
-- 超了明确说怎么调。
-- 3000 是照内核「子树一次也别全树」的直觉拍的，在多包 JS/TS 仓直接变成「全树不能用」：
-- opencode prune 掉 node_modules 后仍有 11233 个真源文件，locate 恰在这里最不可信，
-- 两个动词一起失效。实测 cgrep 扫 11233 个文件 914 ms（含正则），并没有慢到要拦；
-- 「噪音」靠 max_hits + 表头热力图控，不靠拒绝。所以上限按「实测还能等」定，内核树
-- （~80k）仍会被拦下并提示先 locate 收窄。
local GREP_MAX_FILES_DEFAULT = 20000

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function abs_file(p, base)
    if not p or p == "" then return nil end
    if p:sub(1, 1) == "/" then return p end
    return ((base or env("PWD") or "."):gsub("/+$", "")) .. "/" .. p
end

-- 读 [first, last]；行号右对齐，输出可以直接当 file:line 引用回填。
-- 末尾额外报「文件共几行」，好让调用方判断窗口之外还剩多少（read_window 只读数到 last）。
function read_window(path, first, last)
    if not path then return nil, "no path" end
    local f = io.open(path, "rb")
    if not f then return nil, "cannot open " .. path end
    first = math.max(1, tonumber(first) or 1)
    last = math.max(first, tonumber(last) or first)
    local out, n, cut = {}, 0, false
    for line in f:lines() do
        n = n + 1
        if n >= first and n <= last then
            line = line:gsub("\r$", "")
            if #line > SNIP_LINE_MAX then
                line = line:sub(1, SNIP_LINE_MAX) .. " …"
                cut = true
            end
            out[#out + 1] = string.format("%5d| %s", n, line)
        end
        if n > last then break end
    end
    f:close()
    if #out == 0 then
        return nil, string.format("line %d beyond EOF (%d lines)", first, n)
    end
    return table.concat(out, "\n") .. (cut and "\n      (long lines cut at 200 chars)" or "")
end

-- 护栏用：一次问完「是不是目录 + 里面有多少文件」。
-- 原来 is_dir 和 scan_file_count 各起一个 sh（各带一个 find），热路径上多花一次
-- fork/exec + 一次 find 遍历；合成一条 shell：非目录就回 -1，是目录最多数到 cap+1
-- 个文件就停（find | head 靠 SIGPIPE 提前退出）。
local function probe_dir(dir, cap)
    -- 必须和 cgrep.c 的 SKIP 名单对齐：护栏数的是「cgrep 会不会扫」的文件，不是
    -- 「磁盘上有多少」。opencode 全树 11264 个文件里 node_modules/dist/build 占大头，
    -- 不 prune 就直接 >3000 被拒——而 locate 恰恰在 JS/TS 多包仓最不可信，两个动词
    -- 同时不可用只剩 peek 硬啃。prune 后同一棵树落到千级，escape hatch 才真的开着。
    local cmd = string.format(
        "test -d %s || { echo -1; exit 0; }; find %s \\( -name .git -o -name node_modules "
        .. "-o -name build -o -name dist -o -name .cache -o -name __pycache__ -o -name .venv "
        .. "-o -name target -o -name .idea -o -name .vscode \\) -prune -o -type f -print "
        .. "2>/dev/null | head -n %d | wc -l",
        shell_quote(dir), shell_quote(dir), cap + 1)
    local f = io.popen(cmd)
    if not f then return -1 end
    local s = f:read("*l") or "-1"
    f:close()
    return tonumber(s:match("^%s*(%-?%d+)")) or -1
end

-- 单次查询：type 决定走向量（search）还是 KV（symbol/context/exact）。
local function cs_query(args, kv, ns, analysis, t, maxr)
    return CS.query({
        query = args.query, repo = ns, type = t,
        kv_dir = kv,
        -- 只有语义搜索需要 vector engine，其余传空目录避免每次加载 ONNX
        analysis_dir = (t == "search") and analysis or "",
        model = args.model or "jina",
        max_results = maxr or args.max_results or 10, depth = args.depth or 0,
        no_boost = args.no_boost, kind = args.kind, lang = args.lang, file = args.file,
        path_prefix = args.path_prefix, def = args.def,
    })
end

local function do_locate(args, ctx, analysis, kv, ns, repo)
    if not args.query or args.query == "" then
        error("codesearch: query required for locate (symbol name or natural language)\n"
            .. "required: query (string); optional: max_results (default 3), lines (default 40), "
            .. "before (default 2), kind/lang/file/path_prefix, type", 0)
    end
    local maxr = math.min(tonumber(args.max_results) or 3, 10)
    local budget = tonumber(args.max_chars) or 8000
    local before = tonumber(args.before) or 2
    local want = math.max(1, tonumber(args.lines) or 40)

    local t = args.type
    if t == "auto" then t = nil end
    t = t or "search"

    -- 索引/KV 不存在时先给可自修的报错，别让 C 层的 "query failed" 冒到调用方面前
    local pre = CS.check(analysis)
    if pre then need_built(pre, "kv") end

    local notes = {}
    -- 去重：search 的 _note 会在「首查」和「退回 symbol」两次都回来，原样拼两遍
    -- 会把同一条「引擎没开」刷成两条，看着像两个独立故障。
    local function add_note(s)
        s = tostring(s)
        for _, e in ipairs(notes) do if e == s then return end end
        notes[#notes + 1] = s
    end
    local d, err = cs_query(args, kv, ns, analysis, t, maxr)

    -- [14] search 在没有向量时不退化，只回一条 {"_note":"Vector engine not
    -- initialized..."} 占位（query.c 的 !g_ve 分支）。它是「引擎没开」不是命中：
    -- 混进 rs 会渲染成 "[1] ?  nil:1  kind=" + "(no path)" 的假结果，还会让
    -- 「结果非空就重试」的判断失效（#rs==1）。先剥成「真命中 / 说明」两堆。
    local function split_results(dd)
        local ok, junk = {}, {}
        for _, r in ipairs((dd or {}).results or {}) do
            if type(r) == "table" and r._note then
                junk[#junk + 1] = one_line(r._note, 300)
            elseif type(r) == "table" and (r.file or r.entries) then
                ok[#ok + 1] = r        -- 没 file 又没 entries 的条目渲染不出窗口
            end
        end
        return ok, junk
    end

    local rs, junk = split_results(d)
    local first_note = junk[1]
    if first_note then add_note(first_note) end
    if #rs == 0 and not args.type then
        -- 没向量 / 没命中就退回 KV 符号查找，别让调用方自己猜该用哪个 action
        add_note(string.format('%s: %s -> retried as symbol',
            t, tostring(err or first_note or "no hit")))
        d, err = cs_query(args, kv, ns, analysis, "symbol", maxr)
        t = "symbol"
        rs, junk = split_results(d)
        if junk[1] then add_note(junk[1]) end
    end
    if not d then error("codesearch: locate failed: " .. tostring(err), 0) end

    -- 真的一条都没有：不输出空壳表头（"1 result(s)" + "[1] ? nil:1"），给可执行的下一步
    if #rs == 0 then
        local out = { string.format('locate "%s" — no hit (type=%s)',
            tostring(args.query), t) }
        if #notes > 0 then out[#out + 1] = "note: " .. table.concat(notes, "; ") end
        out[#out + 1] = "next:"
        out[#out + 1] = string.format(
            "  action=grep pattern=%s path=%s   # 词面兜底，不需要向量",
            tostring(args.query), tostring(repo or args.path or (ctx and ctx.cwd) or "."))
        out[#out + 1] = string.format(
            "  action=symbol query=%s          # 结构化符号，走 KV 直查",
            tostring(args.query))
        out[#out + 1] = "  action=build vector=true        # 要语义 search 必须先建向量索引"
        return table.concat(out, "\n")
    end

    -- 命中说明 ns 是对的：顺手给没有 namespace.txt 的老索引钉一份，后续查询不再猜。
    if pin_ns(analysis, ns) then
        add_note("ns pinned -> " .. analysis .. "/namespace.txt = " .. ns)
    end

    -- best practices §10 的不变量：语义 top1 score 应 > 0.3；低分说明索引或措辞有问题，
    -- 别让噪声命中被当成「找到了」。
    if rs[1] and rs[1].score and rs[1].score < 0.35 then
        notes[#notes + 1] = string.format("top score %.3f < 0.35 — weak match, "
            .. "换个符号名/关键词或 action=grep pattern=...", rs[1].score)
    end
    -- confidence 比 score 更严：它只认语义+词面共现+调用图三样实证，
    -- 所以 low 意味着「排第一也只是排第一」，别直接信。
    if rs[1] and rs[1].confidence_label == "low" then
        notes[#notes + 1] = string.format("top confidence %.2f (low) — 证据不足, "
            .. "先看 why 行确认命中理由; 需要确定答案用 action=symbol/grep",
            tonumber(rs[1].confidence) or 0)
    end
    -- 同名精确命中置顶：语义 search 的排序会把真正要找的那个定义压到 [3] 之后
    -- （例如 locate "do_peek" 时 [1] 是别的 do_* 函数），调用方只读前两条就判断「没找到」。
    -- 只在 score 相差不大时才提：宁可少提，不要把语义排序整体打乱。
    do
        local q = tostring(args.query)
        local bare = q:match("([%w_~]+)$") or q
        local function hit(r)
            local n = tostring(r.name or "")
            return n == q or n == bare or (n:match("([%w_~]+)$") or "") == bare
        end
        if #rs > 1 and not hit(rs[1]) then
            local top, moved, at = rs[1], nil, nil
            for i = 2, #rs do
                if hit(rs[i]) then moved, at = table.remove(rs, i), i; break end
            end
            if moved and (not moved.score or not top.score or moved.score >= top.score - 0.25) then
                table.insert(rs, 1, moved)
                add_note(string.format("hoisted exact name match %s from #%d",
                    tostring(moved.name), at))
            end
        end
    end

    -- 表头晚一步拼：`with source` 要数「真读到窗口的条数」，不能拿 #rs 冒充
    -- （否则命中文件不在 repo 里、或预算截断时也报成满额）。
    local out = {}
    local used = 0
    local nxt = {}
    local withsrc = 0
    for i = 1, math.min(#rs, maxr) do
        local r = rs[i]
        local line = tonumber(r.line_start or r.line) or 1
        local head = string.format("[%d] %s  %s:%d  kind=%s%s", i, r.name or "?",
            tostring(r.file), line, r.kind or "",
            r.score and string.format("  score=%.3f", r.score) or "")
        head = head .. conf_tag(r)
        out[#out + 1] = head
        used = used + #head + 1
        local why = fmt_evidence(r, 2)
        if why then
            out[#out + 1] = why
            used = used + #why + 1
        end
        local last = line + want - 1
        if tonumber(r.line_end) and tonumber(r.line_end) < last then
            last = tonumber(r.line_end)          -- chunk 边界更准：函数没被腰斩
        end
        local snip, serr = read_window(abs_file(r.file, ctx and ctx.cwd),
            math.max(1, line - before), last)
        snip = snip or ("      (" .. tostring(serr) .. ")")
        if used + #snip > budget then
            out[#out + 1] = "      ... (budget reached: lower max_results/lines or raise max_chars)"
            break            -- 被预算砍掉的不算 with source：它没出现在输出里
        end
        if not serr then withsrc = withsrc + 1 end
        out[#out + 1] = snip
        used = used + #snip + 1
        -- 截断必须明说：函数 120 行只给 40 行时，调用方会把「窗口末尾」当成
        -- 「函数末尾」——和 `read` 的 `…` 语义对齐，凡是有内容没显示就标出来。
        local tail
        local endline = tonumber(r.line_end)
        local first_shown = math.max(1, line - before)
        if endline and endline > last then
            tail = string.format("      … (function spans %d-%d, shown %d-%d; next: peek path=%s line=%d)",
                line, endline, first_shown, last, tostring(r.file), last + 1)
        elseif not endline and last == line + want - 1 then
            tail = string.format("      … (window capped at %d lines; next: peek path=%s line=%d lines=%d)",
                want, tostring(r.file), last + 1, want)
        end
        if tail then
            if used + #tail <= budget then
                out[#out + 1] = tail
                used = used + #tail + 1
            else
                out[#out + 1] = "      … (more lines; budget reached)"
                break
            end
        end
        if r.name then
            nxt[#nxt + 1] = string.format("action=context query=%s depth=2   # %s",
                r.name, tostring(r.file))
        end
    end
    -- withsrc 只数到「预算内真读到」的条数，表头这才成立
    table.insert(out, 1, string.format('%s "%s" -> %d result(s), %d with source [static]',
        d.type or t, tostring(args.query), #rs, withsrc))
    if #notes > 0 then
        out[#out + 1] = "note: " .. table.concat(notes, "; ")
    end
    out[#out + 1] = "-- next --"
    for i = 1, math.min(#nxt, 4) do out[#out + 1] = "  " .. nxt[i] end
    if rs[1] and rs[1].file then
        out[#out + 1] = string.format("  action=grep path=%s pattern=<re>", tostring(rs[1].file))
    end
    out[#out + 1] = "  [static] 证据要跑起来才算 [verified]（best practices §3）"
    return table.concat(out, "\n")
end

local function do_grep(args, ctx)
    local pattern = args.pattern or (args.fixed and args.query) or args.query
    if not pattern or pattern == "" then
        error("codesearch: pattern required for grep (POSIX regex; fixed=true 时按字面串)\n"
            .. "required: pattern (string); optional: path (目录或文件, default cwd), "
            .. "ext, fixed, ignore_case, max_hits, per_file", 0)
    end
    local path = abs_file(args.path or args.file or ".", ctx and ctx.cwd)
    -- 注意：上面的 env() 未命中时返回「零个值」，直接 tonumber(env(...)) 会变成零参数
    -- 调用而炸 "value expected"，所以先 or "" 兜一个实参。
    local cap = tonumber(env("LITE_CS_GREP_MAX_FILES") or "") or GREP_MAX_FILES_DEFAULT
    local nfiles = probe_dir(path, cap)          -- -1 = 单文件，不做规模护栏
    if nfiles > cap then
        error(string.format("codesearch: refusing whole-tree grep under %s (>%d files, "
            .. "noise + slow).\nfix: narrow first — action=locate query=\"...\" then "
            .. "grep path=<file> or path=<subdir>; LITE_CS_GREP_MAX_FILES raises the cap",
            path, cap), 0)
    end
    if not ctx or not ctx.call then
        error("codesearch: grep needs the cgrep native helper (env.call); "
            .. "call it through lite instead of loadfile()", 0)
    end
    local res = ctx.call("cgrep", cjson.encode({
        pattern = pattern, path = path, ext = args.ext,
        ignore_case = (args.ignore_case ~= false), fixed = (args.fixed == true),
        max_hits = tonumber(args.max_hits) or 120, per_file = tonumber(args.per_file) or 10,
        threads = tonumber(args.threads) or 4,
    }))
    local ok, d = pcall(cjson.decode, tostring(res))
    if not ok or type(d) ~= "table" or not d.ok then
        error("codesearch: grep failed: " .. tostring(ok and d and d.error or res):sub(1, 300), 0)
    end
    local hits = type(d.hits) == "table" and d.hits or {}
    -- 表头先给「面」再给「点」：内核里一句 tcp_ack\( 能扫出几百条，调用方要的是
    -- 「哪几个文件最热、一共散在几处」，逐条读原文是第二步。per-file 计数用去重后
    -- 的 file:line（C 端一行多命中会重复），与下面正文口径一致。
    local per, order, seen0 = {}, {}, {}
    for _, h in ipairs(hits) do
        local key = tostring(h.file) .. ":" .. tostring(h.line)
        if not seen0[key] then
            seen0[key] = true
            if not per[h.file] then per[h.file] = 0; order[#order + 1] = h.file end
            per[h.file] = per[h.file] + 1
        end
    end
    table.sort(order, function(a, b)
        if per[a] ~= per[b] then return per[a] > per[b] end
        return a < b
    end)
    local nhits = d.count or #hits
    local out = { string.format('grep /%s/ in %s -> %d hit(s) in %d file(s), scanned %d, %d ms%s',
        pattern, path, nhits, d.files or #order, d.scanned or 0, d.ms or 0,
        d.truncated and " (truncated, raise max_hits)" or "") }
    if #order > 1 then
        local top = {}
        for i = 1, math.min(#order, 5) do
            top[#top + 1] = string.format("%s×%d", order[i], per[order[i]])
        end
        out[#out + 1] = string.format("  hot: %s%s", table.concat(top, "  "),
            #order > 5 and string.format("  … (%d more)", #order - 5) or "")
    end
    local seen, shown, used, files = {}, 0, 0, {}
    for _, h in ipairs(hits) do
        local key = h.file .. ":" .. h.line
        if not seen[key] then                   -- C 端一行多命中会重复，按 file:line 去重
            seen[key] = true
            local line = string.format("%s:%d: %s", h.file, h.line, (h.text or ""):gsub("^%s+", ""))
            used = used + #line + 1
            if used > (tonumber(args.max_chars) or 8000) then
                out[#out + 1] = "... (output capped, raise max_chars or lower per_file/max_hits)"; break
            end
            out[#out + 1] = line
            shown = shown + 1
            if #files < 3 and not files[h.file] then files[#files + 1] = h.file; files[h.file] = true end
        end
    end
    if shown == 0 then
        out[#out + 1] = "(no match)"
        -- cgrep 走 POSIX ERE，不是 Lua pattern：`%.`/`%d` 这类转义在 ERE 里是字面 `%`，
        -- 照搬 Lua 写法会静默 0 命中，所以给一条原地改法。
        if (not args.fixed) and pattern:find("%", 1, true) then
            out[#out + 1] = "hint: POSIX ERE, not Lua patterns — use \\. for a literal dot "
                .. "(or fixed=true for a literal string); %d/%s/%w do not exist here"
        end
    end
    for i = 1, #files do
        out[#out + 1] = string.format("-- next --\n  action=peek path=%s line=<n> lines=40", files[i])
        break
    end
    return table.concat(out, "\n")
end

local function do_peek(args, ctx, kv, ns)
    local path = args.path or args.file
    local line = tonumber(args.line)
    -- peek 的 path 经常是直接抄过来的 `file:line`（grep/locate/编译器报错都是这个形状）。
    -- 原样当路径 open 必然 ENOENT，还报成「peek failed: cannot open ...」，看着像文件不在。
    if path and path ~= "" and not line then
        local p, l = tostring(path):match("^(.-):(%d+)$")
        if p and p ~= "" then path, line = p, tonumber(l) end
    end
    local out = {}
    if (not path or path == "") and args.query and args.query ~= "" then
        local d, err = CS.query({ query = args.query, repo = ns, type = "symbol",
            kv_dir = kv, analysis_dir = "", max_results = 1 })
        local r = d and (d.results or {})[1]
        if not r then
            error(string.format("codesearch: peek needs path=<file:line> (symbol %q not found: %s)",
                tostring(args.query), tostring(err)), 0)
        end
        path, line = r.file, r.line_start or r.line
        out[#out + 1] = string.format("%s  %s:%s  kind=%s", r.name or "?", tostring(path),
            tostring(line), r.kind or "")
    end
    if not path or path == "" then
        error("codesearch: peek needs path=<file> [line=N] or query=<symbol>\n"
            .. "required: path (string); optional: line, lines (default 40), before (default 5)", 0)
    end
    path = abs_file(path, ctx and ctx.cwd)
    local lines = math.max(1, tonumber(args.lines) or 40)
    local before = tonumber(args.before) or 5
    local first = math.max(1, (line or 1) - before)
    local snip, serr = read_window(path, first, first + lines - 1)
    if not snip then error("codesearch: peek failed: " .. tostring(serr), 0) end
    out[#out + 1] = string.format("-- %s:%d-%d", path, first, first + lines - 1)
    out[#out + 1] = snip
    out[#out + 1] = string.format("-- next --\n  action=grep path=%s pattern=<re>", path)
    return table.concat(out, "\n")
end

local schema = {
        name = "lens",
        description = "代码库索引与检索：建索引/调用图/数据流，按符号、上下文、语义查询。"
            .. "locate=搜+内联源码窗口（recommended 起点），peek=file:line 读窗口，"
            .. "grep=作用域 cgrep（拒整仓扫描）。数据在 ~/.local/share/lite/codesearch/<project>，与 lite 记忆隔离。",
        parameters = {
            type = "object",
            properties = {
                action = { type = "string", enum = { "build", "index", "import", "search", "symbol", "context", "exact", "file", "dataflow", "status", "locate", "peek", "grep" },
                           description = "省略时按参数推断：pattern→grep，query→locate，path→peek，都没有→status。locate=搜+内联源码（默认起手式）；peek=file:line 读窗口；grep=作用域 cgrep；build=全流程；index=只切块（不刷新 KV，要 import 才可查）；import=analysis 导入 KV；search=语义+关键词；symbol/context/exact=结构化查询；file=按文件列 chunk；dataflow=函数读写了哪些变量 / 变量流过哪些函数；status=看产物" },
                query = { type = "string", description = "符号名（可省略表前缀，M.foo 查 foo 也行）、自然语言查询、文件路径，或 exact 的完整 KV key；peek 时=符号名（免给 path）" },
                pattern = { type = "string", description = "grep 的正则（fixed=true 时按字面串）" },
                line = { type = "integer", description = "peek 的行号（默认 1，给了 before/lines 就围绕它读）" },
                lines = { type = "integer", description = "locate/peek 读取行数（locate 默认 40，peek 默认 40）" },
                before = { type = "integer", description = "locate/peek 命中行前保留的上下文行（默认 2/5）" },
                path = { type = "string", description = "仓库路径（index/build，默认 cwd）；grep/peek 时=要扫的目录或文件路径" },
                project = { type = "string", description = "项目名（默认取仓库目录名），决定 analysis/KV 目录与 namespace" },
                type = { type = "string", description = "query 类型：auto/exact/symbol/context/search，默认 auto" },
                max_results = { type = "integer", description = "返回条数，默认 10，上限 100" },
                max_chars = { type = "integer", description = "输出字符预算，默认 8000（locate/grep/symbol/exact 都认；调大才看得全）" },
                depth = { type = "integer", description = "context 调用链向上展开深度，默认 0，上限 5" },
                kind = { type = "string", description = "按符号 kind 过滤：function/struct/macro/..." },
                lang = { type = "string", description = "按语言过滤：c/cpp/python/lua/javascript/typescript/go/rust/java/kotlin/ruby/php/objc/csharp" },
                file = { type = "string", description = "按文件名子串过滤（语义搜索）" },
                path_prefix = { type = "string", description = "按目录子树过滤（search/context/symbol），如 arch/x86、net/、drivers/gpu/" },
                def = { type = "string", description = "context：按解析到的定义文件收窄（同名多定义时用），如 fs/ext4、arch/x86" },
                model = { type = "string", description = "向量模型 jina（默认）或 mpnet" },
                no_boost = { type = "boolean", description = "关闭 TF-IDF/调用者 boost" },
                vector = { type = "boolean", description = "build 时是否做语义向量化（默认 true，缺模型自动跳过）" },
                workers = { type = "integer", description = "index 进程数；默认 1，fork=true 时默认 CPU 核数" },
                fork = { type = "boolean", description = "index 用 fork 多进程并行（fresh 进程更快；已加载 ORT 的会话慎用）" },
                batch = { type = "integer", description = "向量化 batch，默认 128；长 chunk 多时降到 64" },
                fp16 = { type = "boolean", description = "用 model_fp16.onnx 推理（默认开；GPU 约快 1.5-2x）" },
                excludes = { type = "string", description = "index 跳过目录，逗号分隔" },
                skip_kinds = { type = "string", description = "按 ctags kind 过滤，逗号分隔，如 header,file,enumerator,macro（内核推荐）" },
                include_dirs = { type = "string", description = "把默认 noise 目录重新纳入，如 tools,utils" },
                plugins = { type = "string", description = "index 插件 registry JSON 路径" },
                only_dataflow = { type = "boolean", description = "import 只导入 dataflow（增量更新时用）" },
                log = { type = "string", description = "构建日志路径，默认 <analysis_dir>/build.log（每阶段起止/退出码/progress/stderr 都写这里）" },
                analysis_dir = { type = "string", description = "覆盖 analysis 目录（高级）" },
                kv_dir = { type = "string", description = "覆盖 KV 目录（高级）" },
                json = { type = "boolean", description = "返回原始 JSON 而不是摘要文本" },
            },
        },
}

-- 内部文案沿用模块名 codesearch，暴露前统一换成工具名 lens。
local function run_inner(args, ctx)
        if not CS.available then
            error("codesearch: liblite_codesearch.so not built (see build/liblite_codesearch.so)", 0)
        end
        local repo, project, analysis, kv, ns = paths(args, ctx)
        local action = args.action
        if action == nil or action == "" then
            -- 省掉 action 时按给了什么参数推断，别让「只想搜一下」白跑成 status。
            if args.pattern and args.pattern ~= "" then action = "grep"
            elseif args.query and args.query ~= "" then action = "locate"
            elseif args.path and args.path ~= "" then action = "peek"
            else action = "status" end
        end

        if action == "build" then
            return do_build(args, repo, project, analysis, kv, ns)
        elseif action == "index" then
            local logpath = (args.log and args.log ~= "") and args.log or CS.log_path(analysis)
            local r = CS.logged("index", logpath, function()
                return CS.index({ repo = repo, analysis_dir = analysis,
                    workers = worker_count(args),
                    fork = args.fork, skip_kinds = args.skip_kinds,
                    include_dirs = args.include_dirs,
                    excludes = args.excludes, plugins = args.plugins })
            end)
            check_stage("index", r, logpath)
            if args.json then return cjson.encode(r) end
            return "index 只切块，KV 未刷新（symbol/search/exact 查不到新代码）。" ..
                "要可查再跑 action=import（或 action=build 全流程）。\n" ..
                fmt_status(CS.check(analysis))
        elseif action == "import" then
            local logpath = (args.log and args.log ~= "") and args.log or CS.log_path(analysis)
            check_stage("import", CS.logged("import", logpath, function()
                return CS.import(analysis, ns, kv, false)
            end), logpath)
            -- 把 ns 钉进 <analysis>/namespace.txt：查询侧优先读它，import 与 query 从此
            -- 不可能各写一套前缀。已有且不一致时只提示不覆盖（可能是别人有意的另一套）。
            local note, marker = "", marker_ns(analysis)
            if marker and marker ~= ns then
                note = string.format(
                    "\nWARN: %s/namespace.txt says %s, imported as %s"
                    .. "\n      queries will still read %s (pass ns= explicitly or fix that file)",
                    analysis, marker, ns, marker)
            elseif not marker then
                local f = io.open(analysis .. "/namespace.txt", "w")
                if f then f:write(ns, "\n"); f:close(); note = "\nns pinned: " .. analysis .. "/namespace.txt" end
            end
            return "import ok: " .. ns .. " -> " .. kv .. note .. "\n日志: " .. logpath
        elseif action == "status" then
            local d = CS.check(analysis)
            if not d then error("codesearch: status failed", 0) end
            if args.json then return cjson.encode(d) end
            return fmt_status(d)
        elseif action == "dataflow" then
            if not args.query or args.query == "" then
                error("codesearch: query required for dataflow (function or variable name)", 0)
            end
            local d0 = CS.check(analysis)
            if not d0 then error("codesearch: cannot read analysis dir " .. analysis, 0) end
            need_built(d0, "kv")
            local d, err = CS.dataflow_query(args.query, kv, ns, args.max_results or 10)
            if not d then error("codesearch: dataflow query failed: " .. tostring(err), 0) end
            if args.json then return cjson.encode(d) end
            return fmt_dataflow(d)
        elseif action == "locate" then
            -- repo 往下传：locate 的「没命中」提示里要给出 grep 的 path，
            -- 拿 ctx.cwd（lite 自己的仓库）当 path 会把调用方带到错的树里。
            return do_locate(args, ctx, analysis, kv, ns, repo)
        elseif action == "peek" then
            return do_peek(args, ctx, kv, ns)
        elseif action == "grep" then
            return do_grep(args, ctx)
        elseif action == "search" or action == "symbol" or action == "context"
            or action == "exact" or action == "file" then
            if not args.query or args.query == "" then
                error("codesearch: query required for " .. action, 0)
            end
            -- symbol/context/file/exact 查的是 KV 里的符号表；语义 search 只要
            -- vectors/ + chunks_meta（KV 只用来 boost），所以别对 search 强求 kv。
            if action ~= "exact" and action ~= "search" then
                local d0 = CS.check(analysis)
                if not d0 then error("codesearch: cannot read analysis dir " .. analysis, 0) end
                need_built(d0, "kv")
            end

            local t = action
            -- 只有语义搜索才需要 vector engine；其余传空目录，
            -- 避免每次查询都白加载 ONNX 模型（~1s + 数百 MB）。
            local analysis_arg = (t == "search") and analysis or ""
            local d, err = CS.query({
                query = args.query, repo = ns, type = args.type and args.type ~= "auto" and args.type or t,
                kv_dir = kv, analysis_dir = analysis_arg, model = args.model or "jina",
                max_results = args.max_results or 10, depth = args.depth or 0,
                no_boost = args.no_boost, kind = args.kind, lang = args.lang, file = args.file,
                path_prefix = args.path_prefix, def = args.def,
            })
            if not d then error("codesearch: query failed: " .. tostring(err), 0) end
            -- C 侧对 context 查不到符号时会带 error（不再吐空壳），这里直接抛给调用方
            if d.error then error("lens: " .. tostring(d.error), 0) end
            if args.json then return cjson.encode(d) end
            if action == "context" then return fmt_context(d, tonumber(args.max_chars)) end
            -- 命中就说明 ns 对：老索引顺手钉一份 namespace.txt，别再靠目录名反推。
            if #(d.results or {}) > 0 then pin_ns(analysis, ns) end
            if action == "symbol" then return fmt_symbols(d, ctx and ctx.cwd) end
            return fmt_results(d, tonumber(args.max_chars), ns, ctx and ctx.cwd)
        end

        error("codesearch: unknown action " .. tostring(action), 0)
end

return {
    schema = schema,
    run = function(args, ctx)
        local ok, res = pcall(run_inner, args, ctx)
        if ok then return res end
        error((tostring(res):gsub("^codesearch: ", "lens: ", 1)), 0)
    end,
}
