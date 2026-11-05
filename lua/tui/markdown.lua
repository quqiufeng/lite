-- 轻量 Markdown：标题/列表/引用/代码块/行内 code/bold/italic/link。
local utf8 = require("tui.utf8")

local M = {}

local function push(segs, text, style)
    if text == nil or text == "" then return end
    segs[#segs + 1] = { text = text, style = style }
end

local function inline(text, base)
    local segs = {}
    local i = 1
    while i <= #text do
        local bs, be, bstyle, btext, burl

        local function consider(s, e, style, txt, url)
            if s and (not bs or s < bs) then
                bs, be, bstyle, btext, burl = s, e, style, txt, url
            end
        end

        local s, e, v = text:find("`([^`]*)`", i)
        consider(s, e, "code", v)

        s, e, v = text:find("%*%*([^%*]+)%*%*", i)
        consider(s, e, "bold", v)

        s, e, v = text:find("%*([^%*]+)%*", i)
        consider(s, e, "italic", v)

        local ls, le, lt, lu = text:find("%[([^%]]+)%]%(([^%)]+)%)", i)
        consider(ls, le, "link", lt, lu)

        if not bs then
            push(segs, text:sub(i), base)
            break
        end

        push(segs, text:sub(i, bs - 1), base)
        if bstyle == "link" then
            push(segs, btext, "link")
            push(segs, " (" .. (burl or "") .. ")", "gray")
        else
            push(segs, btext, bstyle)
        end
        i = be + 1
    end
    return segs
end

function M.render(text)
    text = tostring(text or "")
    local out = {}
    local in_code = false

    for line in (text .. "\n"):gmatch("(.-)\n") do
        local fence = line:match("^%s*```(.*)$")
        if fence then
            in_code = not in_code
            if in_code and fence ~= "" then
                out[#out + 1] = { segs = { { text = "┌ " .. fence, style = "gray" } } }
            end
        elseif in_code then
            out[#out + 1] = { segs = { { text = line, style = "code_block" } } }
        else
            local h = line:match("^(#+)%s+(.*)$")
            local quote = line:match("^>%s?(.*)$")
            local bullet = line:match("^%s*[-*+]%s+(.*)$")
            local ordered, rest = line:match("^%s*(%d+)%.%s+(.*)$")
            local hr = line:match("^%s*%-%-%-+%s*$")

            if h then
                local level = #h
                local style = level <= 1 and "heading" or (level == 2 and "heading2" or "bold")
                out[#out + 1] = { segs = inline(h and line:sub(#h + 1):gsub("^%s+", ""), style) }
            elseif quote then
                local segs = { { text = "│ ", style = "quote" } }
                for _, s in ipairs(inline(quote, "quote")) do segs[#segs + 1] = s end
                out[#out + 1] = { segs = segs }
            elseif bullet then
                local segs = { { text = "• ", style = "default" } }
                for _, s in ipairs(inline(bullet, "default")) do segs[#segs + 1] = s end
                out[#out + 1] = { segs = segs }
            elseif ordered then
                local segs = { { text = ordered .. ". ", style = "default" } }
                for _, s in ipairs(inline(rest, "default")) do segs[#segs + 1] = s end
                out[#out + 1] = { segs = segs }
            elseif hr then
                out[#out + 1] = { segs = { { text = string.rep("─", 20), style = "gray" } } }
            else
                out[#out + 1] = { segs = inline(line, "default") }
            end
        end
    end
    return out
end

-- 把带样式的逻辑行按显示宽度换成 cells。
function M.wrap(line, width)
    width = math.max(1, width)
    local out = { {} }
    local cur, col = out[1], 0

    local function newline()
        out[#out + 1] = {}
        cur = out[#out]
        col = 0
    end

    for _, seg in ipairs(line.segs or {}) do
        local text = seg.text or ""
        local i = 1
        while i <= #text do
            local ch, ni, cp = utf8.decode(text, i)
            if not ch then ch, ni, cp = text:sub(i, i), i + 1, text:byte(i) end
            if ch == "\n" then
                newline()
            else
                local w = utf8.width(ch, cp)
                if col + w > width and col > 0 then newline() end
                cur[#cur + 1] = { text = ch, style = seg.style }
                col = col + w
            end
            i = ni
        end
    end
    return out
end

return M
