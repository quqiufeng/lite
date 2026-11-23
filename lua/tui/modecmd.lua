-- 模式开关命令的**共用**解析：语音 / 监工 / 微信三个模式共用一套关闭动词，
-- 写法统一成「#退出微信模式」「#退出监工模式」，裸「#退出」= 把开着的都关掉。
--
-- 为什么独立成模块：三份 command() 各写一套 OFF 词，用户就得为每个模式记一个词
-- （#终止监工 / #退出微信 / #关闭语音…），而且改一处漏两处。动词只此一份。
--
-- 纯逻辑、不碰 io/终端：能在 tools/wx_watch_check.lua / tools/auto_unit.lua 里直接单测。
local M = {}

-- 关闭动词：全部模式共用，谁也别自己造。
M.OFF = { "退出", "终止", "关闭" }

local function trim(s)
    if type(s) ~= "string" then return nil end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- "#退出微信模式" / "#退出 微信模式" → "退出", "微信模式"
-- 不是关闭命令返回 nil；是但没带模式名，target 为空串。
function M.off(s)
    s = trim(s)
    if not s or s:sub(1, 1) ~= "#" then return nil end
    for _, v in ipairs(M.OFF) do
        local head = "#" .. v
        if s:sub(1, #head) == head then
            return v, (s:sub(#head + 1):gsub("^%s+", ""))
        end
    end
    return nil
end

-- 这行是不是「关掉某个模式」且目标就是 name（"微信" 与 "微信模式" 等价）。
-- names 给短名就行：M.is(s, {"微信"}) 认 #退出微信 / #退出微信模式。
function M.is(s, names)
    local _, target = M.off(s)
    if not target or target == "" then return nil end
    for _, n in ipairs(names or {}) do
        if target == n or target == n .. "模式" then return true end
    end
    return nil
end

-- 裸「#退出」/「#终止」/「#关闭」：不分模式，把开着的全关掉。
function M.bare(s)
    local _, target = M.off(s)
    return target == "" or nil
end

-- 「#退出 微信模式 谢谢」这类带尾巴的不算命令：整行必须是纯命令。
function M.command(s)
    return M.off(s) ~= nil
end

return M
