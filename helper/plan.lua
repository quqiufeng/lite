-- helper/plan.lua —— plan(只读) / 执行 两态切换，开关 = cwd 下有没有 `.plan` 文件。
--
--   touch .plan   → 进 plan：只读工具放行，其余工具调用被 before_tool 拦下
--   rm .plan      → 回执行模式
--
-- 只提供 hooks，不提供 run/schema，所以不进工具列表（见 lua/core/tools.lua:1305）。
-- 改这个文件要 /reboot 才生效：hook 列表和 schema 一样是会话快照。
--
-- 定位：**软约束**，拦的是「工具调用」，不是内核。适合「我想先把方案想清楚再动手」，
-- 不适合「防住不听话的模型」—— 真硬保证请开 --sandbox（bwrap 只读根，见
-- lua/core/sandbox.lua）。判断只认命令串首词，绕法很多，别当安全边界用。

local ALLOW_TOOL = {
    read = true, recall = true, todo = true, lens = true, cgrep = true,
    pdftext = true, search = true, fetch = true, web = true, ocr = true,
}

-- bash 只读首词白名单：少而稳，宁可错杀（拦了就说"rm .plan 再执行"）。
local ALLOW_CMD = {
    ls = true, cat = true, head = true, tail = true, wc = true, tree = true,
    grep = true, rg = true, find = true, file = true, stat = true, pwd = true,
    diff = true, cut = true, sort = true, uniq = true, tr = true, jq = true,
    du = true, df = true, nm = true, ldd = true, echo = true, date = true,
    which = true, lsmod = true, sha256sum = true, md5sum = true,
    git = true, sed = true, awk = true,
}

-- git 只读子命令（其余的 add/commit/push/checkout/clean 都算写）
local GIT_READ = {
    log = true, diff = true, show = true, status = true, blame = true,
    branch = true, ["rev-parse"] = true, ["ls-files"] = true, grep = true,
    remote = true, config = true, describe = true, ["shortlog"] = true,
}

-- 命令串里出现这些就算写，不管首词是什么
local WRITE_HINT = {
    "rm ", "mv ", "cp ", "tee ", "chmod", "chown", "mkdir", "touch ", "ln ",
    "truncate", "dd ", "-delete", "patch ", "install ", "shred", "sudo ",
}

local function has_redirect(s)
    -- 允许 `2>&1` 和 `> /dev/null`（只读命令常带），其他重定向一律当写。
    local t = s:gsub("%d*>&%d+", ""):gsub("%d?%s*>%s*/dev/null", "")
    return t:find(">", 1, true) ~= nil
end

-- 拆 `a && b | c; d`，每段首词都得在只读白名单里
local function cmds_ok(s)
    if has_redirect(s) then return false, "重定向 >" end
    local low = s:lower()
    for _, w in ipairs(WRITE_HINT) do
        if low:find(w, 1, true) then return false, w:gsub("%s+$", "") end
    end
    -- 先把 `2>&1` 这类 fd 复制抹掉，否则下面的 `&` 拆分会把 "1" 当成命令首词。
    for seg in (s:gsub("%d*>&%d+", "")):gmatch("[^;&|\n]+") do
        local first = seg:match("^%s*(%S+)")
        if first then
            first = first:gsub("^%S*/", "")   -- /bin/ls → ls
            if not ALLOW_CMD[first] then return false, first end
            if first == "git" then
                local sub = seg:match("^%s*%S+%s+([%w%-]+)")
                if not (sub and GIT_READ[sub]) then
                    return false, "git " .. tostring(sub)
                end
            elseif first == "sed" and seg:find("-i", 1, true) then
                return false, "sed -i"
            elseif first == "find" and seg:find("-exec", 1, true) then
                return false, "find -exec"
            end
        end
    end
    return true
end

local function plan_on(env)
    local dir = tostring((env and env.cwd) or ".")
    local f = io.open(dir .. "/.plan", "r")
    if f then f:close() return true end
    return false
end

local HINT = "。方案想清楚就 `rm .plan` 再执行；现在先把要改什么写成方案。"

return {
    hooks = {
        before_tool = function(name, args, env)
            if not plan_on(env) then return nil end
            if ALLOW_TOOL[name] then return nil end
            if name == "bash" then
                local c = tostring((args and args.command) or "")
                local ok, bad = cmds_ok(c)
                if ok then return nil end
                return "plan 模式只读，`" .. tostring(bad) .. "` 会写东西" .. HINT
            end
            return "plan 模式只读，`" .. name .. "` 会改东西" .. HINT
        end,
    },
}
