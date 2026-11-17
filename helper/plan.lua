-- helper/plan.lua —— plan(只读) / 执行 两态切换，开关 = cwd 下有没有 `.plan` 文件。
--
--   touch .plan   → 进 plan：只放行「看世界 + 记笔记」的工具，其余（含 bash 一切命令）全拦
--   rm .plan      → 回执行模式
--
-- 只提供 hooks，不提供 run/schema，所以不进工具列表（见 lua/core/tools.lua:1304）。
-- 改这个文件要 /reboot 才生效：hook 列表和 schema 一样是会话快照。
--
-- 放行判据只有一条：**这次调用不落盘、不改系统状态**。三层：
--   1. ALLOW_TOOL     纯读工具（读文件/读记忆/读网/读索引）整工具放行；
--   2. ALLOW_ACTION   一个插件里读和写混在一起的（lens build 写 GB 级索引、trace run 要 root
--                     采样），按 action 逐个放行，其余 action 拦；
--   3. 写自己人状态的（remember 写 mem.bin、todo 写 session），不碰仓库也不碰系统，放行——
--                     plan 阶段想到的约束正好该落盘，否则退出后靠上下文（会被 hard_window 丢）。
--
-- 有意不做的：不看 bash 命令串猜只读（`grep x | tee`、`git log --output=`、`find -exec` 绕法太多，
-- 猜错的代价是"以为拦住了"）；不做系统级隔离。真硬保证请开 --sandbox（bwrap 只读根）。
--
-- 拦下的工具如果确实只读，正确做法是给它加白名单（或按 action 加），不是放宽 bash。

local ALLOW_TOOL = {
    -- 内置：读文件 / 读记忆 / 记笔记 / 记账 / 读网
    read = true,        -- 读 workspace 文本、图片
    recall = true,      -- 读 mem.bin
    remember = true,    -- 只写 mem.bin（agent 自己的记忆）
    todo = true,        -- 只写 session 里的 todo
    ocr = true,         -- 读图，临时文件在 TMPDIR 且当场删
    web = true,         -- HTTP GET，只读远端
    -- 插件：只读
    fetch = true,       -- URL -> Markdown
    search = true,      -- 搜索 API
    cgrep = true,       -- 正则扫目录，只出 path:line
    pdftext = true,     -- 抽 PDF 文本
    tokens = true,      -- 读 /agent/usage 账本
}

-- 同一插件里读写混合的：只有这些 action 放行。
local ALLOW_ACTION = {
    -- lens：查询类只读；build/index/import 会写 GB 级索引 → 拦
    lens = {
        search = true, symbol = true, context = true, exact = true, file = true,
        dataflow = true, status = true, locate = true, peek = true, grep = true,
    },
    -- trace：status/prof 只读；run 要 root 采内核探针、render 落 svg/png、perfmap 写 /tmp → 拦
    trace = { status = true, prof = true },
}

local function plan_on(env)
    local dir = tostring((env and env.cwd) or ".")
    local f = io.open(dir .. "/.plan", "r")
    if f then f:close() return true end
    return false
end

-- 提示必须给出**出口**：plan 模式下模型唯一能做的是"把方案写出来"，
-- 所以告诉它剩什么可用、怎么退出，否则它会反复重试同一个被拦的调用。
local HINT = "。plan 模式下只放行只读工具（read/recall/remember/todo/ocr/web/fetch/search/"
    .. "cgrep/pdftext/tokens，以及 lens 的查询类 action）。要改什么先写成方案，"
    .. "需要执行时让用户 `rm .plan`（TUI 里连按 Tab）退出。"

return {
    hooks = {
        before_tool = function(name, args, env)
            if not plan_on(env) then return nil end
            if ALLOW_TOOL[name] then return nil end
            local acts = ALLOW_ACTION[name]
            if acts then
                local a = tostring((args and args.action) or "")
                if acts[a] then return nil end
                return "plan 模式只读，`" .. tostring(name) .. "` 的 action=" .. (a == "" and "(默认)" or a)
                    .. " 会落盘/改系统状态" .. HINT
            end
            if name == "bash" then
                local c = tostring((args and args.command) or "")
                c = c:gsub("%s+", " "):sub(1, 60)
                return "plan 模式只读，`" .. c .. "` 不许执行" .. HINT
            end
            return "plan 模式只读，`" .. tostring(name) .. "` 不许调用" .. HINT
        end,
    },
}
