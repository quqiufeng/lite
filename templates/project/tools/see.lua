#!/usr/bin/env luajit
-- see.lua — 定位窗口 → 截图 → 打印路径。闭环第 1~3 步（第 4 步是 read/ocr）。
--
--   ./tools/see.lua --list
--   ./tools/see.lua --class myapp --width 1280
--   ./tools/see.lua --pid 12345
--   ./tools/see.lua --full              # 只有确实需要全屏时才用
--
-- 为什么先定位：桌面同时跑几十个进程时，全屏截图会截到遮挡窗口，验收等于看别人的界面。
-- 依赖：lua/ffi/x11.lua + lua/ffi/xdo.lua（自包含对）+ 系统 libX11/libxdo。
-- 缩放可选：找得到 liblite_image.so 就缩（省 token），找不到原图 + 提示。

local ROOT = (arg and arg[0] or ""):match("^(.*)/tools/[^/]+$") or "."
package.path = ROOT .. "/lua/?.lua;" .. ROOT .. "/lua/?/init.lua;" .. package.path

local ok, x11 = pcall(require, "ffi.x11")
if not ok then
    io.stderr:write("找不到 lua/ffi/x11.lua（自包含对，可整对拷进来）\n")
    os.exit(2)
end

local opt = { width = 1280 }
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--list" then opt.list = true
    elseif a == "--full" then opt.full = true
    elseif a == "--active" then opt.active = true
    elseif a == "--viewable" then opt.viewable = arg[i + 1]; i = i + 1
    elseif a == "--class" then opt.class = arg[i + 1]; i = i + 1
    elseif a == "--name" then opt.name = arg[i + 1]; i = i + 1
    elseif a == "--id" then opt.id = arg[i + 1]; i = i + 1
    elseif a == "--pid" then opt.pid = tonumber(arg[i + 1]); i = i + 1
    elseif a == "--width" then opt.width = tonumber(arg[i + 1]); i = i + 1
    elseif a == "-h" or a == "--help" then
        io.stderr:write("用法: see.lua --list | --class X | --name X | --pid N | --active | --full [--width 1280]\n")
        os.exit(0)
    else io.stderr:write("未知参数: " .. a .. "\n"); os.exit(2) end
    i = i + 1
end

local function shot_dir()
    local d = os.getenv("SHOT_DIR") or ((os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/shot")
    os.execute("mkdir -p '" .. d:gsub("'", "'\\''") .. "' 2>/dev/null")
    return d
end

if opt.list then
    local act = x11.display():active()
    print(string.format("%-11s %-28s %-16s %-7s %-5s %s", "id", "name", "class", "pid", "view", "z"))
    for _, w in ipairs(x11.windows()) do
        print(string.format("%-11s %-28s %-16s %-7s %-5s %d%s",
            (tostring(w.id):gsub("ULL", "")), (w.name or "?"):sub(1, 28),
            tostring(w.class), tostring(w.pid), tostring(w.viewable), w.z,
            (w.id == act) and "  <-ACTIVE" or ""))
    end
    os.exit(0)
end

local shot
if opt.full then
    local okc, path = x11.capture_screen()
    if not okc then io.stderr:write("capture failed: " .. tostring(path) .. "\n"); os.exit(1) end
    shot = path
else
    local query = {
        class = opt.class, name = opt.name, id = opt.id, pid = opt.pid,
        active = opt.active or nil, viewable = (opt.viewable ~= "0") or nil,
    }
    local empty = true
    for _, v in pairs(query) do if v ~= nil then empty = false end end
    if empty then
        io.stderr:write("需要 --class / --name / --pid / --id / --active / --full 之一\n")
        io.stderr:write("先跑 --list 看看有哪些窗口\n")
        os.exit(2)
    end
    local w, cand = x11.resolve(query)
    if not w then
        io.stderr:write(string.format("定位失败：%d 个候选\n", #(cand or {})))
        for _, c in ipairs(cand or {}) do
            io.stderr:write(string.format("  %-11s %-28s class=%s pid=%s\n",
                (tostring(c.id):gsub("ULL", "")), (c.name or "?"):sub(1, 28),
                tostring(c.class), tostring(c.pid)))
        end
        os.exit(1)
    end
    io.stderr:write(string.format("locate: %s %s class=%s pid=%s geom=%d,%d %dx%d\n",
        (tostring(w.id):gsub("ULL", "")), (w.name or ""):sub(1, 40),
        tostring(w.class), tostring(w.pid), w.x, w.y, w.w, w.h))
    local okc, path = w:capture()
    if not okc then io.stderr:write("capture failed: " .. tostring(path) .. "\n"); os.exit(1) end
    shot = path
end

-- 缩放（可选）：2560 宽原图纯烧 token。只缩不放——小窗口放大既糊又费 token。
local out = shot
local function png_width(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local hdr = f:read(24)
    f:close()
    if not hdr or #hdr < 24 or hdr:sub(2, 4) ~= "PNG" then return nil end
    local b1, b2, b3, b4 = hdr:byte(17, 20)
    return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
end
local orig_w = png_width(shot)
if (opt.width or 0) > 0 and orig_w and orig_w <= opt.width then
    io.stderr:write(string.format("resize skipped: 原图 %dpx <= %dpx，不放大\n", orig_w, opt.width))
    opt.width = 0
end
if (opt.width or 0) > 0 then
    local function first_existing(list)
        for _, p in ipairs(list) do
            if p then
                local f = io.open(p, "rb")
                if f then f:close(); return p end
            end
        end
    end
    -- 候选顺序同 libfind：本项目的 build → $LITE_ROOT/build → 裸名
    local lib = os.getenv("SHOT_IMAGE_LIB") or first_existing({
        ROOT:gsub("/+$", "") .. "/build/liblite_image.so",
        (os.getenv("LITE_ROOT") or ".") .. "/build/liblite_image.so",
        "liblite_image.so",
    })
    if lib then
        local ffi = require("ffi")
        pcall(ffi.cdef, [[
int lite_image_resize(const char *src, const char *dst, int width, int height, int force);
const char *lite_image_error(void);
]])
        local ok2, il = pcall(ffi.load, lib)
        if ok2 then
            local dst = shot_dir() .. "/" .. (shot:match("([^/]+)%.png$") or "shot") .. "-" .. opt.width .. ".png"
            if il.lite_image_resize(shot, dst, opt.width, 0, 0) == 0 then out = dst
            else io.stderr:write("resize skipped: " .. tostring(ffi.string(il.lite_image_error())) .. "\n") end
        end
    else
        io.stderr:write("提示：没找到 liblite_image.so，输出原图（token 更贵）\n")
    end
end

print(out)
