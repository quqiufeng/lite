-- wx_watch_check.lua — helper/lib/wx_watch.lua 的纯逻辑回归（无 FFI、无微信、全离线）。
--
-- 钉住三件踩过的事：
--  ① 回执标记（tag="lite:"）判定：key() 会吃掉 ":"，用原文长度去截 key 后的串会多啃一个字
--     （"lite现在是…"），回执认不出来 → 自己的回复被当新指令，无限自激（真发生过）。
--  ② diff() 只认尾部公共后缀：聊天区只显示最后一屏，整屏都变（换会话）时绝不整屏重放。
--  ③ blocks() 多行消息必须合成一块：拆成多条会把一条指令切碎成好几个半句去执行。
local ROOT = (os.getenv("LITE_ROOT") or ".")
package.path = ROOT .. "/lua/?.lua;" .. ROOT .. "/?.lua;" .. package.path

local SELF = arg and arg[0] or ""
local LIB = (SELF:match("^(.*)/[^/]+$") or ".") .. "/../helper/lib/wx_watch.lua"
local W = assert(loadfile(LIB))()

local total, fails = 0, 0
local function check(ok, what)
    total = total + 1
    if not ok then
        fails = fails + 1
        io.stderr:write("  FAIL " .. what .. "\n")
    end
end
local function eq(a, b, what)
    check(a == b, ("%s: got %s want %s"):format(what, tostring(a), tostring(b)))
end

-- ① 回执 / 触发前缀
eq(W.key("lite: 现在是 9 点"), "lite现在是9点", "key strips punctuation")
check(W.is_reply("lite: 现在是 9 点 33 分（2026-11-23 周一）。", "lite:"), "reply tag recognised")
check(W.is_reply("lite：全角冒号也认", "lite:"), "fullwidth colon reply recognised")
check(not W.is_reply("lite现在几点", "lite:"), "colon-less text is NOT a reply (it is an instruction)")
check(W.is_reply("LITE: 大写的也要认", "lite:"), "reply tag case-insensitive")
check(not W.is_reply("lite 测试四：只回一句话", "lite:"), "instruction is not a reply")
check(not W.is_reply("帮我看下 /tmp", "lite:"), "unprefixed text is not a reply")
check(not W.is_reply("", "lite:"), "empty is not a reply")
check(not W.is_reply("说", ""), "empty tag never matches")

check(W.has_trigger("lite 列一下 /tmp", "lite"), "trigger with space")
check(W.has_trigger("lite：列一下", "lite"), "trigger with fullwidth colon")
check(W.has_trigger("lite测试", "lite"), "trigger glued by OCR")
check(not W.has_trigger("今天的笔记", "lite"), "no trigger rejected")
check(W.has_trigger("随便什么", ""), "empty trigger accepts all")

eq(W.strip_trigger("lite 列一下 /tmp", "lite"), "列一下 /tmp", "strip trigger keeps body")
eq(W.strip_trigger("lite: 报一下时间", "lite"), "报一下时间", "strip trigger eats colon")
eq(W.strip_trigger("lite，帮我看看", "lite"), "帮我看看", "strip trigger eats comma")

-- ② diff：尾部后缀
eq(W.diff({}, { "a" }), 2, "no baseline never replays history")
eq(W.diff({ "a", "b" }, { "a", "b" }), 3, "identical frame has nothing new")
eq(W.diff({ "a", "b" }, { "a", "b", "c" }), 3, "append detected at tail")
eq(W.diff({ "a", "b" }, { "b", "c" }), 2, "scroll: new tail only")
eq(W.diff({ "a", "b", "c" }, { "x", "y" }), 2, "whole screen changed: last one only")
eq(W.diff({ "a" }, {}), 1, "empty frame")

-- ③ blocks：多行一条消息 / 时间行与噪声被丢掉
local boxes = {
    { x = 100, y = 100, w = 200, h = 20, text = "lite 帮我" },
    { x = 100, y = 132, w = 300, h = 20, text = "列一下 /tmp" },
    { x = 100, y = 164, w = 180, h = 20, text = "前五个文件" },
    { x = 900, y = 320, w = 60,  h = 20, text = "09:33" },
    { x = 100, y = 400, w = 80,  h = 20, text = "翻译" },
    { x = 100, y = 500, w = 200, h = 20, text = "lite 第二条" },
}
local bl = W.blocks(boxes)
eq(#bl, 2, "two messages from six boxes")
check(bl[1] and bl[1].text:find("前五个文件", 1, true) ~= nil, "multiline merged into one block")
check(bl[2] and bl[2].text == "lite 第二条", "second block intact")
check(bl[1] and bl[1].cx and bl[1].cy, "block carries click point")
-- maxy：输入框工具条被切掉
local cut = W.blocks(boxes, { maxy = 450 })
eq(#cut, 1, "maxy drops whole blocks below the cut")
local half = W.blocks(boxes, { maxy = 170 })
check(half[1] and half[1].text:find("列一下 /tmp", 1, true) and not half[1].text:find("前五个文件", 1, true),
    "maxy cuts inside a block (toolbar strip)")
eq(#W.blocks(boxes, { maxy = 60 }), 0, "maxy above everything yields no block")

if fails > 0 then
    io.stderr:write(("FAIL wx_watch (%d/%d)\n"):format(fails, total))
    os.exit(1)
end
print("OK wx_watch (" .. total .. " checks)")
