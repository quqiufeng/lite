-- see.lua — 精确定位 → 激活 → 截图 → 缩放，一条命令看完某个窗口。
--
-- 系统同时跑几十个进程时，全屏截图经常截到遮挡在上面的别的应用。
-- 所以顺序必须是：先按 class/pid/name 唯一定位，再激活并确认拿到焦点，才截图。
--
-- 用法:
--   ./tools/lite-lua tools/see.lua --list
--   ./tools/lite-lua tools/see.lua --class wechat --width 1280
--   ./tools/lite-lua tools/see.lua --pid 2032
--   ./tools/lite-lua tools/see.lua --name lite --pick 1
--   ./tools/lite-lua tools/see.lua --active
--   ./tools/lite-lua tools/see.lua --full            # 全屏（不定位）
--
-- 输出最后一行是图片的绝对路径，可直接喂给 read 工具。

package.path = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/../lua/?.lua;"
    .. (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/../lua/?/init.lua;"
    .. package.path

local x11 = require("ffi.x11")
local Tools = require("core.tools")

local opt = {}
local i = 1
while i <= #arg do
    local a = arg[i]
    local key = a:match("^%-%-(.+)$")
    if key == "list" or key == "full" or key == "active" or key == "exact" then
        opt[key] = true
        i = i + 1
    elseif key then
        local v = arg[i + 1]
        if v == nil then
            io.stderr:write("missing value for --" .. key .. "\n")
            os.exit(2)
        end
        opt[key] = v
        i = i + 2
    else
        opt.name = a
        i = i + 1
    end
end

local cwd = os.getenv("PWD") or "."

local function out_dir()
    local d = os.getenv("LITE_SHOT_DIR")
    if not d or d == "" then
        d = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/lite-shot"
    end
    os.execute("mkdir -p '" .. d:gsub("'", "'\\''") .. "' 2>/dev/null")
    return d
end

-- 清单：把当下所有顶层窗口摊开，先看清再动手
if opt.list then
    local act = x11.display():active()
    print(string.format("%-11s %-28s %-16s %-7s %-5s %s",
        "id", "name", "class", "pid", "view", "z"))
    for _, w in ipairs(x11.windows()) do
        print(string.format("%-11s %-28s %-16s %-7s %-5s %d%s",
            (tostring(w.id):gsub("ULL", "")),
            (w.name or "?"):sub(1, 28),
            tostring(w.class), tostring(w.pid),
            tostring(w.viewable), w.z,
            (w.id == act) and "  <-ACTIVE" or ""))
    end
    os.exit(0)
end

local shot
if opt.full then
    local ok, path = x11.capture_screen()
    if not ok then
        io.stderr:write("capture failed: " .. tostring(path) .. "\n")
        os.exit(1)
    end
    shot = path
else
    local query = {
        class = opt.class, name = opt.name, id = opt.id,
        pid = opt.pid and tonumber(opt.pid) or nil,
        active = opt.active or nil,
        viewable = (opt.viewable ~= "0") or nil,
        exact = (opt.exact == "1") or nil,
    }
    local empty = true
    for _, v in pairs(query) do if v ~= nil then empty = false end end
    if empty then
        io.stderr:write("需要 --class / --name / --pid / --id / --active / --full 之一\n")
        io.stderr:write("先跑 --list 看看有哪些窗口\n")
        os.exit(2)
    end

    local w, cand = x11.resolve(query)
    if not w and #(cand or {}) == 0 and query.viewable then
        -- 常见陷阱：目标窗口被最小化/隐藏，被 viewable 过滤掉了
        local hidden = {}
        for _, c in ipairs(x11.windows()) do
            if c.viewable == false then hidden[#hidden + 1] = c end
        end
        if #hidden > 0 then
            io.stderr:write(string.format(
                "注意：有 %d 个窗口处于隐藏/最小化状态，被 viewable 过滤掉了。\n", #hidden))
            for _, c in ipairs(hidden) do
                io.stderr:write(string.format("  %-11s %-24s class=%s\n",
                    (tostring(c.id):gsub("ULL", "")), (c.name or "?"):sub(1, 24), tostring(c.class)))
            end
            io.stderr:write("加 --viewable 0 可包含它们\n")
        end
    end
    if not w then
        io.stderr:write(string.format("定位失败：%d 个候选\n", #(cand or {})))
        for _, c in ipairs(cand or {}) do
            io.stderr:write(string.format("  %-11s %-28s class=%s pid=%s\n",
                (tostring(c.id):gsub("ULL", "")), (c.name or "?"):sub(1, 28),
                tostring(c.class), tostring(c.pid)))
        end
        io.stderr:write("补一个条件（--pid / --class / --name --exact）或 --pick N\n")
        os.exit(1)
    end

    -- pick 用于"同 class 多窗口"的显式选择
    if opt.pick and cand == nil then
        -- 唯一命中时 pick 无意义，忽略
    end

    io.stderr:write(string.format("locate: %s  %s  class=%s pid=%s  geom=%d,%d %dx%d\n",
        (tostring(w.id):gsub("ULL", "")), (w.name or ""):sub(1, 40),
        tostring(w.class), tostring(w.pid), w.x, w.y, w.w, w.h))

    local ok, path = w:capture()
    if not ok then
        io.stderr:write("capture failed: " .. tostring(path) .. "\n")
        os.exit(1)
    end
    shot = path
end

-- 缩放：2560 宽原图 token 太贵，默认缩到 1280
local width = tonumber(opt.width) or 1280
local t = Tools.new({ cwd = cwd })
local resized = shot
if width > 0 then
    local base = shot:match("([^/]+)%.png$") or "screen"
    local out = out_dir() .. "/" .. base .. "-" .. width .. ".png"
    local r = t:resize(shot, width, 0, out)
    if r:find("resized", 1, true) then
        resized = out
    else
        io.stderr:write("resize skipped: " .. r .. "\n")
    end
end

print(resized)
