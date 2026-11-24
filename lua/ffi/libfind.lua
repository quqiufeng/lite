-- 统一的 liblite_*.so 解析（cache/codesearch/image 共用，别各自维护候选表）。
--
-- 顺序（先命中先用）：
--   $LITE_ROOT/build/ → $LITE_ROOT/lib/ → <lua 所在树>/build|lib → ./build|lib → 裸名
--
-- 为什么 build/ 在 lib/ 前、安装目录在源码树前：跑安装版时 $LITE_ROOT 就是唯一
-- 权威副本（release.sh 一次把 build/ 和 lib/ 都刷新），源码树只兜底。反过来会踩：
-- lua/ 软链到源码时模块路径解析出的是安装目录，老库永远先命中（旧顺序踩过这个坑，
-- symbol 查询返回空、实际跑的是几天前的 .so）。
--
-- 但顺序统一也有代价：只跑 ./tools/build.sh 没跑 release.sh 时，源码树的
-- build/ 会被安装目录的旧副本遮蔽。所以命中后比一下所有候选的大小，不一致就
-- 往 stderr 打一行警告（每次进程每个库只打一次），别让新旧混编静默发生。
--
-- 架构对账（见 arch_ok）：跨平台迁移后 build/ 里可能还躺着上一个架构的 .so，
-- 「文件存在」不等于「能 dlopen」。
--
-- 自包含约束：x11.lua 需要能整对拷给别的项目，不走这里，它自己内联候选表。

local ffi = require("ffi")

local M = {}

local function norm(p)
    if type(p) ~= "string" then return "" end
    p = p:gsub("/+$", "")
    if p == "." then return "." end
    return p
end

local function exists(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

local function size(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:seek("end")
    f:close()
    return s
end

-- ELF e_machine（文件偏移 18，2 字节）与 LuaJIT ffi.arch 的对应。
-- 只列我们真会跑的架构；表里没有的一律放行，别用「判不出来」去拦本来能用的库。
local ARCH_MACHINE = {
    x64 = 62,    -- EM_X86_64
    x86 = 3,     -- EM_386
    arm64 = 183, -- EM_AARCH64
    arm = 40,    -- EM_ARM
}

local MACHINE_NAME = {
    [3] = "i386", [40] = "arm", [62] = "x86-64", [183] = "aarch64",
}

local function machine_name(m)
    if not m then return "非 ELF" end
    return MACHINE_NAME[m] or ("e_machine=" .. m)
end

-- 读不出来就返回 nil（非 ELF、空文件、被截断、没权限），由调用方决定怎么用。
local function elf_machine(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local head = f:read(20)
    f:close()
    if not head or #head < 20 then return nil end
    if head:sub(1, 4) ~= "\127ELF" then return nil end
    local lo, hi = head:byte(19), head:byte(20)
    if not lo or not hi then return nil end
    if head:byte(6) == 2 then return hi + lo * 256 end -- EI_DATA=2：大端
    return lo + hi * 256
end

-- 该 .so 是不是给本进程架构编的？
-- 三个「放行」都刻意 fail-open：宁可让 dlopen 报自己的错，也不要因为探测失败
-- 把合法库挡掉（测试里就有一个 4096 字节随机文件充当坏库，它不是 ELF）。
local function arch_ok(p)
    local want = ARCH_MACHINE[ffi.arch or (require("jit").arch)]
    if not want then return true end
    local got = elf_machine(p)
    if not got then return true end
    return got == want
end

-- 本文件所在的 lite 根（.../lua/ffi/libfind.lua → ...）
local function self_root()
    local src = (debug.getinfo(1, "S") or {}).source or ""
    local path = src:match("^@(.+)$")
    local dir = path and path:match("^(.*)/[^/]+$")
    local root = dir and dir:match("^(.*)/[^/]+/[^/]+$")
    if root and root ~= "" then return root end
    return nil
end
M.self_root = self_root

-- 候选路径（存在性无关，顺序即优先级）
function M.candidates(name, opts)
    opts = opts or {}
    local out, seen = {}, {}
    local function add(p)
        p = norm(p)
        if p == "" or seen[p] then return end
        seen[p] = true
        out[#out + 1] = p
    end
    if opts.explicit and opts.explicit ~= "" then add(opts.explicit) end
    -- 别写成 { a, self_root(), "." }：self_root() 可能返回 nil，中间位置的 nil 会把
    -- 表截断在它那里，"." 直接丢掉（源码树直接跑、没有 LITE_ROOT 时就没候选了）。
    local bases = {}
    local function base(b)
        b = norm(b)
        if b ~= "" and b ~= "/" then bases[#bases + 1] = b end
    end
    base(os.getenv("LITE_ROOT"))
    base(self_root())
    base(".")
    for _, b in ipairs(bases) do
        add(b .. "/build/" .. name)
        add(b .. "/lib/" .. name)
    end
    for _, p in ipairs(opts.extra or {}) do add(p) end
    add(name) -- 裸名：交给 dlopen 走系统路径 / LD_LIBRARY_PATH
    return out
end

local warned = {}

-- 选中的路径与其它存在的副本大小不同 → 只 warn 一次（新旧混编的典型症状）
local function warn_shadow(name, chosen, cands)
    if warned[name] then return end
    local cs = size(chosen)
    if not cs then return end
    for _, p in ipairs(cands) do
        -- 架构不同的副本不算「新旧混编」：那是另一个平台的产物，大小必然不同，
        -- 报「只 build 没 release」会把排查带偏。
        if p ~= chosen and arch_ok(p) then
            local s = size(p)
            if s and s ~= cs then
                warned[name] = true
                io.stderr:write(string.format(
                    "lite: %s 用到 %s（%d 字节），但 %s 是 %d 字节，内容不同；"
                        .. "只 build.sh 没 release.sh 时会出现这种新旧混编\n",
                    name, chosen, cs, p, s))
                return
            end
        end
    end
end

-- 返回 lib, path；失败返回 nil, nil, err（err 带上所有试过的路径）
function M.load(name, opts)
    local cands = M.candidates(name, opts)
    local tried, seen = {}, {}
    local function record(p)
        if not seen[p] then seen[p] = true; tried[#tried + 1] = p end
    end
    for _, p in ipairs(cands) do
        if p ~= name and exists(p) and not arch_ok(p) then
            -- 文件在但架构不对：绝不能交给 ffi.load。轻则 "wrong ELF class" 报错，
            -- 重则 dlopen 成功而符号布局不符、读结构体时炸在别处。跳过继续找，
            -- 并留下原因——否则用户只看到「加载不了」却不知道是拿错了架构的包。
            record(string.format("%s (架构 %s，本机 %s)",
                p, machine_name(elf_machine(p)), ffi.arch or "?"))
        elseif exists(p) or p == name then
            local ok, h = pcall(ffi.load, p)
            if ok then
                warn_shadow(name, p, cands)
                return h, p
            end
            record(p .. " (" .. tostring(h):gsub("^.*: ", "") .. ")")
        else
            record(p)
        end
    end
    return nil, nil, "cannot load " .. name .. "; tried: " .. table.concat(tried, ", ")
end

-- 只找路径不加载（自检/报错用）
function M.find(name, opts)
    for _, p in ipairs(M.candidates(name, opts)) do
        if p ~= name and exists(p) and arch_ok(p) then return p end
    end
end

return M
