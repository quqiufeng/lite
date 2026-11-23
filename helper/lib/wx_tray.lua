-- wx_tray.lua — 「微信托盘图标在闪吗」= 有没有新消息。
--
-- 为什么要有这个模块：微信 Linux 版（Qt/SNI）收到新消息时，托盘图标会在两组画面之间
-- 来回闪（实测周期约 0.9s）；没有新消息时图标静止。所以判「要不要去点开微信读消息」
-- 只需要**盯住托盘那一小块像素**，不用抢焦点、不用截全屏、不用 OCR。
--
-- **不认红点、认「出现过几种画面」**：用 helper/lib/wx_sni.lua 直读 StatusNotifier 的
-- IconPixmap 验过——未读时换的是 {64x64,22x22} 与 {16x16,16x16} 两组帧，64x64 那张
-- 本身**不带红点**。按红点判会全漏。多采样看「出现过几种画面」才稳。
--
-- 代价对比：一次小区域 XGetImage 是几 KB 的服务器端拷贝（亚毫秒），而之前每轮都要
-- activate 微信 + 截整屏 PNG + OCR，那是秒级，而且会把你正在打的字/正在看的窗口抢走。
--
-- 关键取舍：
--   * **不认「红点」认「变化」**：闪动时红点是半周期出现，单帧快照有一半概率读到「没红点」，
--     会漏消息。采样多次看「出现过几种画面」才稳。
--   * **图标位置不写死**：屏幕/面板尺寸、托盘顺序都会变。先按面板窗口几何取一条横带，
--     扫「微信绿」找包围盒；只在缓存的矩形里绿像素没了才重新定位。
--   * 采样是**提前退出**的：一旦见到第二种画面就返回（有消息时快，没消息时等满窗口）。
--
-- 用法（进程外自检，不需要跑守护进程）：
--   ./tools/lite-lua helper/lib/wx_tray.lua            # 出 rect / states / 判定
--   ./tools/lite-lua helper/lib/wx_tray.lua --quiet    # 只出 "blink" 或 "idle"
local ffi = require("ffi")
-- 先加载 ffi.xdo：它 cdef 了 Display/Window 等基础 typedef。少了它，下面这段 cdef 会因为
-- 未知类型整体失败，而 pcall 又把错误吞掉，症状是调用时才炸「missing declaration」。
require("ffi.xdo")

pcall(ffi.cdef, [[
/* XImage 的字段布局在 libX11 里是 ABI 稳定的（X.h），按 64 位对齐写。
   只用 width/height/data/bytes_per_line 四个字段，其余读都不用读。 */
typedef struct {
    int width, height;
    int xoffset;
    int format;
    char *data;
    int byte_order;
    int bitmap_unit;
    int bitmap_bit_order;
    int bitmap_pad;
    int depth;
    int bytes_per_line;
    int bits_per_pixel;
    unsigned long red_mask, green_mask, blue_mask;
    void *obdata;
    struct { void *create_image; void *destroy_image; void *get_pixel; void *put_pixel;
             void *sub_image; void *add_pixel; } f;
} WxImage;
WxImage *XGetImage(Display *display, Window d, int x, int y,
    unsigned int width, unsigned int height, unsigned long plane_mask, int format);
int XDestroyImage(WxImage *img);
]])

local M = {}

local ALL_PLANES = ffi.cast("unsigned long", -1)
local ZPIXMAP = 2

-- 微信绿的判据：主色附近 #07C160。判「绿得明显」而不是精确等于某个 RGB，
-- 免得换主题/透明度/缩放后一点都对不上就整轮瞎。
local function is_wx_green(r, g, b)
    return g > 140 and (g - r) > 50 and (g - b) > 40
end

local function grab(X11, dpy, drawable, x, y, w, h)
    if w <= 0 or h <= 0 then return nil end
    local img = X11.XGetImage(dpy, drawable, x, y, w, h,
        ffi.cast("unsigned long", -1), ZPIXMAP)
    if img == nil then return nil end
    return img
end

-- 一段区域的内容指纹。用逐像素加权和而不是 CRC：够区分「两张不同的图标」，
-- 又不需要额外库；32 位溢出交给 LuaJIT 的 double 取模处理。
function M.region_hash(X11, dpy, drawable, x, y, w, h)
    local img = grab(X11, dpy, drawable, x, y, w, h)
    if img == nil then return nil end
    local d = ffi.cast("const uint8_t *", img.data)
    local bpl = img.bytes_per_line
    local acc = 5381.0
    for yy = 0, h - 1 do
        local row = d + yy * bpl
        for xx = 0, w - 1 do
            local p = row + xx * 4
            -- 蓝色通道权重最低（面板底色偏蓝，别让背景主导指纹）
            acc = (acc * 33 + p[0] + p[1] * 3 + p[2] * 7) % 4294967296
        end
    end
    X11.XDestroyImage(img)
    return acc
end

-- 面板窗口：优先找类名像 panel/dock/bar 的可见窗口（几何才准）；
-- 找不到就退回屏幕底部 48px 一条（大多数桌面面板在底下）。
local function panel_rect(X11, dpy, root, sw, sh)
    local ok, x11 = pcall(require, "ffi.x11")
    if ok then
        local ok2, list = pcall(x11.windows)
        if ok2 and type(list) == "table" then
            for _, w in ipairs(list) do
                local cls = (w.class or ""):lower()
                local g = w.geometry
                if g and g.w and g.w > 0 and (cls:find("panel") or cls:find("dock")
                    or cls:find("polybar") or cls:find("waybar")) then
                    return { x = g.x, y = g.y, w = g.w, h = g.h, window = w.id }
                end
            end
        end
    end
    return { x = 0, y = sh - 48, w = sw, h = 48, window = root }
end

-- 在面板横带里扫微信绿，返回图标包围盒（屏幕坐标）。找不到返回 nil, 原因。
--
-- 不能简单取「所有绿像素的包围盒」：面板上别处散落几十个偏绿的抗锯齿像素，会把包围盒
-- 撑到整个屏宽（实测 2386px）。所以先做**列直方图**，取「绿像素最集中的一段连续列」
-- （允许 <=4 列的空隙，图标内部气泡之间本来就有缝），再在段内求 bbox。
local MAX_GAP = 4        -- 一个图标内部的合法空隙
local MIN_COL_PX = 2     -- 单列至少几个绿像素才算图标的一部分

function M.candidates(X11, dpy, root, sw, sh)
    local p = panel_rect(X11, dpy, root, sw, sh)
    local band_x = math.max(0, p.x)
    local band_y = math.max(0, math.min(p.y, sh - 1))
    local band_w = math.min(p.w, sw - band_x)
    local band_h = math.min(p.h, sh - band_y)
    local img = grab(X11, dpy, root, band_x, band_y, band_w, band_h)
    if img == nil then return nil, "取不到面板像素" end
    local d = ffi.cast("const uint8_t *", img.data)
    local bpl = img.bytes_per_line
    local hist = {}
    local total = 0
    for xx = 0, img.width - 1 do hist[xx] = 0 end
    for yy = 0, img.height - 1 do
        local row = d + yy * bpl
        for xx = 0, img.width - 1 do
            local px = row + xx * 4
            if is_wx_green(px[2], px[1], px[0]) then
                hist[xx] = hist[xx] + 1
                total = total + 1
            end
        end
    end
    if total < 30 then
        X11.XDestroyImage(img)
        return nil, "面板里没找到微信绿（图标被藏了？）"
    end
    -- 切连续列段，**全部留下**：面板上不止微信一个是绿的。只取「绿量最大的那段」会锁到
    -- 错的那个（实测面板左边还有个 12x14 的绿块，比真托盘图标先被扫到），而 cache.rect
    -- 一旦指向它，rect_alive 就恒真 —— 盯着一块永远静止的绿，永远判「没新消息」。
    -- 症状正是「手机上发了消息，daemon 一直没反应」，日志还骗人说图标没闪。
    local segs, cur, cur_n, gap = {}, nil, 0, 0
    for xx = 0, img.width - 1 do
        if hist[xx] >= MIN_COL_PX then
            cur = cur or xx
            cur_n = cur_n + hist[xx]
            gap = 0
        elseif cur then
            gap = gap + 1
            if gap > MAX_GAP then
                segs[#segs + 1] = { x0 = cur, x1 = xx - gap, n = cur_n }
                cur, cur_n, gap = nil, 0, 0
            end
        end
    end
    if cur then
        segs[#segs + 1] = { x0 = cur, x1 = img.width - 1 - gap, n = cur_n }
    end
    if #segs == 0 then
        X11.XDestroyImage(img)
        return nil, "绿像素没连成图标形状"
    end
    local out, why = {}, {}
    for _, seg in ipairs(segs) do
        local minx, maxx, miny, maxy, cnt = 1e9, -1, 1e9, -1, 0
        for yy = 0, img.height - 1 do
            local row = d + yy * bpl
            for xx = seg.x0, math.min(seg.x1, img.width - 1) do
                local px = row + xx * 4
                if is_wx_green(px[2], px[1], px[0]) then
                    cnt = cnt + 1
                    if xx < minx then minx = xx end
                    if xx > maxx then maxx = xx end
                    if yy < miny then miny = yy end
                    if yy > maxy then maxy = yy end
                end
            end
        end
        local bw, bh = maxx - minx + 1, maxy - miny + 1
        if cnt >= 30 and bw >= 8 and bh >= 8 and bw <= 64 and bh <= 64 then
            out[#out + 1] = { x = band_x + minx, y = band_y + miny, w = bw, h = bh, px = cnt }
        else
            why[#why + 1] = string.format("%dx%d/%dpx", bw, bh, cnt)
        end
    end
    X11.XDestroyImage(img)
    if #out == 0 then
        return nil, "没有尺寸像托盘图标的绿块（" .. table.concat(why, " ") .. "）"
    end
    -- 实心的赢：真图标是一块实心绿，零散抗锯齿点像素少，按 px 降序就是「最像图标」在前。
    table.sort(out, function(a, b) return a.px > b.px end)
    return out
end

-- 只要一个（CLI 自检与旧调用方用）：取最像的那个。
function M.locate(X11, dpy, root, sw, sh)
    local list, err = M.candidates(X11, dpy, root, sw, sh)
    if not list then return nil, err end
    return list[1]
end

-- 在 rect 里还有没有微信绿：用来判「缓存的矩形是不是过期了」。
function M.rect_alive(X11, dpy, root, rect)
    local img = grab(X11, dpy, root, rect.x, rect.y, rect.w, rect.h)
    if img == nil then return false end
    local d = ffi.cast("const uint8_t *", img.data)
    local bpl, cnt = img.bytes_per_line, 0
    for yy = 0, img.height - 1 do
        local row = d + yy * bpl
        for xx = 0, img.width - 1 do
            local p = row + xx * 4
            if is_wx_green(p[2], p[1], p[0]) then
                cnt = cnt + 1
                if cnt >= 20 then X11.XDestroyImage(img); return true end
            end
        end
    end
    X11.XDestroyImage(img)
    return false
end

-- 采样判闪动。外扩 4px 是为了把「图标本体没变、旁边多出红点/高亮环」也算进指纹里。
-- gap_ms 默认 160：比常见的 500ms 半周期小得多，2.4s 窗口能覆盖一到两个完整周期。
-- 一旦发现两种画面就立刻返回 —— 有消息的路径不该等满窗口。
function M.blinking(X11, dpy, root, rect, opts)
    opts = opts or {}
    local pad = opts.pad or 4
    local tries = opts.tries or 15
    local gap_ms = opts.gap_ms or 160
    local x = math.max(0, rect.x - pad)
    local y = math.max(0, rect.y - pad)
    local w, h = rect.w + pad * 2, rect.h + pad * 2
    local seen, order = {}, {}
    for i = 1, tries do
        local hh = M.region_hash(X11, dpy, root, x, y, w, h)
        if hh == nil then return nil, "取不到图标像素" end
        if not seen[hh] then
            seen[hh] = i
            order[#order + 1] = hh
            if #order >= 2 then
                return true, string.format("图标在变（%d 帧内出现 %d 种画面）", i, #order), order
            end
        end
        if i < tries then
            ffi.C.usleep(gap_ms * 1000)
        end
    end
    return false, string.format("%d 帧画面完全一致（图标静止）", tries), order
end

-- 一站式：面板定标 → 判闪。cache 是 {rect=..., miss=n} 的可变表，跨轮复用省掉整条横带的扫描。
-- 返回 blink(boolean), why(string), rect。
--
-- **必须自愈**：cache.rect 只能在「还绿着」时复用，但绿着不等于「还是微信图标」——面板上
-- 可能并排着别的绿块，一旦锁错就永远静止、永远 idle（用户看到的就是「微信模式没响应」）。
-- 所以连续 miss 轮静止就丢掉缓存重扫，并对**每个**候选做短采样：会变的那个才是真图标。
-- 这个自愈不能省成「反正重启就好」：daemon 是常驻的，没人会去盯它的日志。
local MISS_RELOCATE = 2

function M.check(X11, dpy, root, sw, sh, cache, opts)
    cache = cache or {}
    local rect = cache.rect
    if rect and not M.rect_alive(X11, dpy, root, rect) then
        rect, cache.rect, cache.miss = nil, nil, 0
    end
    if rect then
        local blink, why = M.blinking(X11, dpy, root, rect, opts)
        if blink or blink == nil then
            cache.miss = 0
            return blink, why, rect
        end
        cache.miss = (cache.miss or 0) + 1
        if cache.miss < MISS_RELOCATE then
            return blink, why, rect
        end
        rect, cache.rect, cache.miss = nil, nil, 0   -- 连轮静止：这块绿大概不是托盘图标
    end
    local list, err = M.candidates(X11, dpy, root, sw, sh)
    if not list then return false, err, nil end
    -- 多候选：3 帧快筛（480ms/个）。有消息时第一个会闪的立刻返回，不必等满 15 帧。
    local best, bestwhy = nil, nil
    for _, c in ipairs(list) do
        local b, w = M.blinking(X11, dpy, root, c, { pad = 4, tries = 3, gap_ms = 160 })
        if b then
            cache.rect = c
            return true, w, c
        end
        if not best then best, bestwhy = c, w end
    end
    -- 都不闪：取最像图标的一个缓存下来，并给一次完整的 15 帧采样（防快筛窗口太短漏判）。
    cache.rect = best
    local blink, why = M.blinking(X11, dpy, root, best, opts)
    return blink, why or bestwhy, best
end

function M.open()
    local ok, X11 = pcall(ffi.load, "X11")
    if not ok then return nil, "load libX11 failed" end
    local xdo, err = require("ffi.xdo").new()
    if not xdo then return nil, err end
    local sw, sh = xdo:display_size()
    local root = X11.XDefaultRootWindow(xdo.dpy)
    return { X11 = X11, dpy = xdo.dpy, root = root, sw = sw, sh = sh, xdo = xdo }
end

-- 命令行自检：直接跑本文件。
-- 只有「自己就是主脚本」才进 CLI（被 require 时 arg[0] 是调用方的路径，不会匹配）。
if arg and arg[0] and arg[0]:find("wx_tray%.lua$") then
    local ctx, err = M.open()
    if not ctx then io.stderr:write("error: " .. tostring(err) .. "\n"); os.exit(1) end
    local cache = {}
    local blink, why, rect = M.check(ctx.X11, ctx.dpy, ctx.root, ctx.sw, ctx.sh, cache)
    if arg[1] == "--quiet" then
        print(blink and "blink" or "idle"); os.exit(0)
    end
    print(string.format("screen %dx%d", ctx.sw, ctx.sh))
    if rect then
        print(string.format("rect   %dx%d+%d+%d (green %d px)", rect.w, rect.h, rect.x, rect.y, rect.px))
    end
    print(string.format("verdict %s — %s", blink and "blink(有新消息)" or "idle(无新消息)", tostring(why)))
    os.exit(0)
end

return M
