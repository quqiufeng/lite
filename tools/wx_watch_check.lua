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

-- 触发前缀默认 "#lite"：# 是标记的一部分，不能被抹平（用 norm 而非 key 比对）。
eq(W.PREFIX, "#lite", "default trigger is #lite")
check(W.has_trigger("#lite 列一下 /tmp", "#lite"), "trigger with space")
check(W.has_trigger("#lite：列一下", "#lite"), "trigger with fullwidth colon")
check(W.has_trigger("#lite测试", "#lite"), "trigger glued by OCR")
check(W.has_trigger("＃lite 全角井号", "#lite"), "fullwidth # accepted")
check(W.has_trigger("# lite 井号后空格", "#lite"), "space after # tolerated")
-- OCR 实测会把 "#lite 列一下" 认成 "lite"（井号被吞），此时必须仍然命中，
-- 否则真实指令会被静默丢掉；形态用 trigger_form 区分，daemon 日志里标 loose。
check(W.has_trigger("lite 列一下 /tmp", "#lite"), "OCR dropped the # but still triggers")
eq(W.trigger_form("lite 列一下 /tmp", "#lite"), "loose", "loose form reported")
eq(W.trigger_form("#lite 列一下 /tmp", "#lite"), "hash", "hash form reported")
eq(W.trigger_form("今天的笔记", "#lite"), nil, "no trigger has no form")
check(W.has_trigger("#llte 列一下", "#lite"), "OCR i->l confusion tolerated")
check(W.has_trigger("1ite 列一下", "#lite"), "OCR i->1 confusion tolerated")
check(not W.has_trigger("#litex 蹭前缀", "#lite"), "prefix needs a boundary")
check(not W.has_trigger("今天的笔记", "#lite"), "no trigger rejected")
check(W.has_trigger("随便什么", ""), "empty trigger accepts all")

eq(W.strip_trigger("#lite 列一下 /tmp", "#lite"), "列一下 /tmp", "strip trigger keeps body")
eq(W.strip_trigger("#lite: 报一下时间", "#lite"), "报一下时间", "strip trigger eats colon")
eq(W.strip_trigger("#lite，帮我看看", "#lite"), "帮我看看", "strip trigger eats comma")
eq(W.strip_trigger("＃lite 全角井号", "#lite"), "全角井号", "strip fullwidth #")
eq(W.strip_trigger("#Lite 大写保留正文", "#lite"), "大写保留正文", "strip keeps body case")
-- 回执标记 "lite:" 不带 #，与触发前缀 "#lite" 不同形；井号丢失的宽容匹配会命中它，
-- 但 daemon 先跑 is_own（is_reply）再判 trigger，回执在更早一步就被拦掉了。
check(W.is_reply("lite: 结论如下", "lite:"), "reply caught by is_reply before trigger check")
check(W.has_trigger("lite: 结论如下", "#lite"), "loose trigger would match a reply (why is_own runs first)")

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

-- 微信模式的 TUI 开关（lua/tui/wxmode.lua）：命令识别 + 插件调用的成败判定。
-- 钉住：只认整行命令（别把「#微信模式总结一下」当开关）、off 的四套写法、
-- 插件报错时 on 必须保持 false（否则状态栏亮着 WX 而守护进程根本没起来）。
-- 共用关闭动词（lua/tui/modecmd.lua）：三个模式同一套词，裸 #退出 交给 loop 一把全关。
do
    local MC = require("tui.modecmd")
    eq(table.concat(MC.OFF, ","), "退出,终止,关闭", "modecmd: 共用动词表")
    for _, w in ipairs(MC.OFF) do
        eq(MC.is("#" .. w .. "微信模式", { "微信" }), true, "modecmd is: " .. w .. "微信模式")
        eq(MC.is("#" .. w .. "微信", { "微信" }), true, "modecmd is: " .. w .. "微信")
        eq(MC.bare("#" .. w), true, "modecmd bare: #" .. w)
        eq(MC.is("#" .. w .. "语音模式", { "微信" }), nil, "modecmd is: 不串模式(" .. w .. ")")
    end
    eq(MC.is("#退出", { "微信" }), nil, "modecmd is: 裸退出不是某模式")
    eq(MC.bare("#退出微信模式"), nil, "modecmd bare: 带模式名不算裸")
    eq(MC.bare("#退出  "), true, "modecmd bare: 尾部空白")
    eq(MC.bare("#退出 微信模式 谢谢"), nil, "modecmd: 带尾巴不是命令")
    eq(MC.bare("退出"), nil, "modecmd: 缺 # 不算")
    eq(MC.bare(nil), nil and true or nil, "modecmd: nil 安全")
end

do
    local Wx = require("tui.wxmode")
    eq(Wx.command("#微信模式"), "on", "wx cmd #微信模式")
    eq(Wx.command("  #wx \n"), "on", "wx cmd #wx with padding")
    eq(Wx.command("#微信"), "on", "wx cmd #微信")
    eq(Wx.command("#终止微信模式"), "off", "wx cmd 终止")
    eq(Wx.command("#关闭微信模式"), "off", "wx cmd 关闭")
    eq(Wx.command("#退出微信"), "off", "wx cmd 退出(短写)")
    eq(Wx.command("#退出微信模式"), "off", "wx cmd 退出+模式")
    eq(Wx.command("  #退出 微信模式 "), "off", "wx cmd 退出+空格+模式")
    eq(Wx.command("#退出语音模式"), nil, "wx cmd: 别的模式不归这里")
    eq(Wx.command("#退出"), nil, "wx cmd: 裸 #退出 归 loop 统一处理")
    eq(Wx.command("#微信模式总结一下"), nil, "wx cmd: 带尾巴不是开关")
    eq(Wx.command("#监工模式"), nil, "wx cmd: 监工模式不归这里")
    eq(Wx.command(""), nil, "wx cmd: 空串")

    eq(Wx.head("已启动：pid 42\n间隔 10s"), "已启动：pid 42", "wx head: 多行只取首行")
    eq(Wx.head("error: 找不到 daemon\n日志…"), "error: 找不到 daemon\n日志…", "wx head: 报错全透出")
    eq(Wx.head(nil), "", "wx head: nil 安全")

    local seen, mode = {}, nil
    local m = Wx.new(function(name, args)
        seen[#seen + 1] = name
        mode = args.action
        if args.action == "start" then return "已启动：pid 7" end
        if args.action == "stop" then return "已停止" end
        return "状态：运行中（pid 7）"
    end)
    local ok, msg = m:start({ interval = 15 })
    check(ok and m.on and seen[1] == "wechat_watch" and mode == "start", "wx start: 走插件名 start")
    check(msg == "已启动：pid 7" and m.interval == 15, "wx start: 摘要 + 间隔记下")
    m:stop()
    check(not m.on and mode == "stop", "wx stop: 关掉开关")
    check(m:status():find("运行中", 1, true) ~= nil, "wx status: 原样透出")

    -- 插件报错 / 执行入口缺失：都必须 ok=false + on=false，别亮着假 WX。
    local bad = Wx.new(function() return "error: 找不到 helper/lib/wx_watch_daemon.lua" end)
    local bok, bmsg = bad:start()
    check(not bok and not bad.on and bmsg:find("找不到", 1, true) ~= nil, "wx start: 报错不算开启")
    local boom = Wx.new(function() error("kaboom") end)
    local eok, emsg = boom:start()
    check(not eok and not boom.on and emsg:find("kaboom", 1, true) ~= nil, "wx start: 抛异常也不炸 TUI")
    local none = Wx.new(nil)
    local nok = none:start()
    check(not nok and not none.on, "wx start: 没有工具入口时降级")
end

if fails > 0 then
    io.stderr:write(("FAIL wx_watch (%d/%d)\n"):format(fails, total))
    os.exit(1)
end
print("OK wx_watch (" .. total .. " checks)")
