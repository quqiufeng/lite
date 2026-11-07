-- 鼠标选区：按下开始、拖拽扩展、松手复制到剪贴板。
-- 只处理正文区域（bounds 由调用方给），不改 transcript/scroller，纯屏幕层高亮。
local clipboard = require("tui.clipboard")
local utf8 = require("tui.utf8")

local M = {}
M.__index = M

function M.new(screen)
    return setmetatable({ screen = screen, dragging = false, moved = false, message = nil }, M)
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- bounds = { top = 1, bottom = transcript_h }
-- 返回 "begin" / "update" / "copy" / nil，由调用方决定是否重绘。
function M:handle(ev, bounds)
    if not ev or ev.key ~= "mouse" then return nil end
    local screen = self.screen
    local top = (bounds and bounds.top) or 1
    local bottom = (bounds and bounds.bottom) or screen.h
    local raw_y = ev.y or 1
    -- 正文区外（composer/status）不开始选择；拖拽/松手仍夹到正文边界。
    if ev.action == "press" and (raw_y < top or raw_y > bottom) then return nil end
    local y = clamp(raw_y, top, bottom)
    local x = clamp(ev.x or 1, 1, screen.w)

    if ev.action == "press" then
        if ev.button ~= 0 then return nil end -- 只认左键，右键/中键留给终端
        self.dragging = true
        self.moved = false
        self.message = nil
        screen:set_selection(y, x, y, x)
        return "begin"
    elseif ev.action == "drag" then
        if not self.dragging then return nil end
        local sel = screen.sel
        if not sel then return nil end
        if sel.y0 == y and sel.x0 == x then return nil end
        if sel.y1 == y and sel.x1 == x then return nil end
        self.moved = true
        screen:set_selection(sel.y0, sel.x0, y, x)
        return "update"
    elseif ev.action == "release" then
        if not self.dragging then return nil end
        self.dragging = false
        local sel = screen.sel
        if not sel or not self.moved then
            screen:clear_selection()
            return nil
        end
        local text = screen:selection_text()
        screen:clear_selection()
        if not text or text == "" then return nil end
        local ok, how = clipboard.copy(text)
        if ok then
            self.message = string.format("已复制 %d 字符 · %s", utf8.len(text), how)
        else
            self.message = "复制失败：" .. tostring(how)
        end
        return "copy"
    end
    return nil
end

function M:cancel()
    local was = self.dragging or (self.screen.sel ~= nil)
    self.dragging = false
    self.moved = false
    self.screen:clear_selection()
    return was
end

return M
