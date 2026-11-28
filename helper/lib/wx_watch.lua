-- wx_watch.lua — 微信「文件传输助手」轮询的**纯逻辑**（无 FFI、无 IO、无子进程）。
-- 上游 wx_watch_daemon.lua 负责截图/OCR/右键复制/派发，这里只做三件能单测的事：
--   blocks() 把 OCR 的 box 行合并回「一条消息 = 一块」（多行消息不能拆成多条指令）
--   diff()   和上一帧比，取尾部新增的消息（聊天区会滚动，所以只认公共后缀之后那段）
--   is_reply()/filter()  认出「自己回执」，否则自己的回复会被当成新指令无限自激
local M = {}

-- 行间距实测（2560x1408 最大化，PP-OCRv4）：同一消息内相邻行 cy 差 ~32，
-- 两条消息之间 ~75。取 46 当中线，两头都留 14px 余量。
M.BLOCK_GAP = 46
M.ROW_GAP = 10          -- 同一视觉行：左右两列 box 的 cy 差在此之内算一行

-- 噪声：微信在气泡上悬停会浮出「翻译」小浮标；聊天区顶部/中部还有居中的时间行。
-- 鼠标挪开时浮标不会出现，但手指/合成事件偶尔会带出来，认文字直接丢。
local NOISE = { ["翻译"] = true, ["复制"] = true, ["转发"] = true }

function M.norm(s)
    s = tostring(s or "")
    -- 注意：这里只能用整串替换，不能写成 [\194\160\227\128\128] 字符集——
    -- 字符集是「任一字节命中」，0x80 是 CJK 尾字节，会把每个汉字的第三字节啃掉。
    s = s:gsub("\194\160", " "):gsub("\227\128\128", " ")
    s = s:gsub("%s+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 比对用的键：连字符都抹平（OCR 会把 "lite 测试" 认成 "lite测试"，也不能因此漏判）
function M.key(s) return (M.norm(s):gsub("[%s%p]", "")) end

local function cy(b) return (b.y or 0) + (b.h or 0) / 2 end
local function cx(b) return (b.x or 0) + (b.w or 0) / 2 end

-- boxes（OCR 原始，坐标是裁剪图内坐标）→ rows（同视觉行合并）→ blocks（消息块）
-- opt.maxy：裁剪区底部留白（输入框工具条会被 OCR 认成乱七八糟的行，按 y 切掉）
function M.blocks(boxes, opt)
    opt = opt or {}
    local maxy = opt.maxy or math.huge
    local rows = {}
    for _, b in ipairs(boxes or {}) do
        local t = M.norm(b.text)
        if t ~= "" and cy(b) <= maxy and not NOISE[t]
            and not t:match("^%d%d?:%d%d$") and not t:match("^%d%d%d%d年") then
            rows[#rows + 1] = { text = t, x = b.x or 0, y = b.y or 0, w = b.w or 0,
                                h = b.h or 0, cy = cy(b), cx = cx(b) }
        end
    end
    table.sort(rows, function(a, b)
        if math.abs(a.cy - b.cy) > M.ROW_GAP then return a.cy < b.cy end
        return a.cx < b.cx
    end)
    -- 同视觉行 → 一行（多列拼起来，按 x 排序）
    local lines = {}
    for _, r in ipairs(rows) do
        local last = lines[#lines]
        if last and math.abs(r.cy - last.cy) <= M.ROW_GAP then
            last.parts[#last.parts + 1] = r
            last.cy = (last.cy * (#last.parts - 1) + r.cy) / #last.parts
        else
            lines[#lines + 1] = { cy = r.cy, parts = { r } }
        end
    end
    for _, l in ipairs(lines) do
        table.sort(l.parts, function(a, b) return a.x < b.x end)
        local t, x0, y0, x1, y1 = {}, nil, nil, nil, nil
        for _, p in ipairs(l.parts) do
            t[#t + 1] = p.text
            x0 = math.min(x0 or p.x, p.x); x1 = math.max(x1 or 0, p.x + p.w)
            y0 = math.min(y0 or p.y, p.y); y1 = math.max(y1 or 0, p.y + p.h)
        end
        l.text, l.x, l.y, l.w, l.h = table.concat(t, " "), x0, y0, x1 - x0, y1 - y0
    end
    -- 行 → 块：相邻行 cy 差 <= BLOCK_GAP 视为同一条消息
    local blocks = {}
    for _, l in ipairs(lines) do
        local last = blocks[#blocks]
        if last and (l.cy - last._cy) <= M.BLOCK_GAP then
            last.lines[#last.lines + 1] = l.text
            last.x = math.min(last.x, l.x); last.w = math.max(last.x + last.w, l.x + l.w) - last.x
            last.h = l.y + l.h - last.y
            last._cy = l.cy
        else
            blocks[#blocks + 1] = { lines = { l.text }, x = l.x, y = l.y, w = l.w, h = l.h, _cy = l.cy }
        end
    end
    local out = {}
    for _, b in ipairs(blocks) do
        b.text = table.concat(b.lines, "\n")
        b.key = M.key(b.text)
        b.cx = b.x + b.w / 2
        b.cy = b.y + b.h / 2
        b._cy = nil
        out[#out + 1] = b
    end
    return out
end

function M.keys(blocks)
    local out = {}
    for i, b in ipairs(blocks) do out[i] = b.key end
    return out
end

-- 返回「cur 里从第几条开始是新的」（1-based；返回 #cur+1 表示没有新的）。
-- 聊天区只显示最后一屏：新消息从底部追加，旧消息从顶部滚走，所以只有尾部公共后缀可信。
-- 尾部一条都对不上（换会话/首次/整屏都变了）时只认最后一条，绝不整屏重放。
function M.diff(prev, cur)
    local n, m = #(prev or {}), #(cur or {})
    if m == 0 then return m + 1 end
    if n == 0 then return m + 1 end     -- 没有基线：只建基线，不执行历史消息
    local k = 0
    while k < n and k < m and prev[n - k] == cur[m - k] do k = k + 1 end
    if k >= m then return m + 1 end
    if k == 0 then return m end
    return m - k + 1
end

-- 回执判定：daemon 让 agent 每条回复都以 `lite:` 开头（回环标记），
-- 另外 daemon 还拿 HTTP 响应的正文建一份前缀哈希表兜底（agent 忘了标记也不自激）。
-- 这里只能用 norm（保留标点）不能用 key：key 把 ":" 也抹掉后，回执标记 "lite:" 就跟
-- 触发前缀 "lite" 同形了，"lite 帮我列一下 /tmp" 这种**指令**会被误判成回执直接丢掉。
-- 冒号全角/半角都归一，因为 agent 偶尔写 "lite："。
local function slim(s)
    return (M.norm(s):gsub("：", ":"):gsub("，", ","):gsub("—", "-"))
end

-- OCR 常把回执标记的**第一个字符**啃成噪声（实测 09:26：`lite:` 认成 `\239\191\189lite:`，
-- 即 U+FFFD 替换符 + lite:）。此时复制菜单又刚好失败（复制失败→退回 OCR），前缀不比中，
-- 自己的回复就被当成新指令派回去 —— 自激环。所以剥掉**开头的噪声**再比：
--   * U+FFFD 替换符（OCR 认不出的字就出它）；
--   * 开头连续的 ASCII 标点/空白（`"lite:`、`- lite:` 这种被引起来的回执）。
-- 只剥前缀**之前**那几个字符，不碰正文；CJK 与字母一律不剥 —— 一旦允许剥字母，
-- `lite 帮我…`（没冒号的**指令**）就又跟回执同形了，那正是 slim 用 norm 不用 key 要防的。
local FFFD = "\239\191\189"
local function strip_noise(n)
    for _ = 1, 3 do
        if n:sub(1, 3) == FFFD then n = n:sub(4)
        else
            local c = n:sub(1, 1)
            local b = c:byte(1)
            if b and b < 128 and not c:match("[%w]") then n = n:sub(2) else break end
        end
    end
    return n
end

function M.is_reply(text, tag)
    local n, kt = slim(text or ""):lower(), slim(tag or ""):lower()
    if kt == "" or n == "" then return false end
    if n:sub(1, #kt) == kt then return true end
    return strip_noise(n):sub(1, #kt) == kt
end

-- 回执的**续块**：一条长回复被 OCR 切成两块时，第二块丢了 lite: 前缀就成了「新指令」回声
-- （实测：天气回复的「建议/数据源」那两行被派回去重跑了一遍）。判据只有几何三条，
-- 都对着「同一条气泡的下半截」：①上一块是回执；②紧贴在它下面（gap 内）；③水平范围大幅
-- 重叠（同宽度气泡）。缺 ③ 会把「用户在回执下面紧跟一句新指令」误吞——那是真指令，代价更大。
-- gap 默认 32：实测**同一气泡内的续行**间隙 ≤20（行高 21，续行紧贴），而**两个气泡之间**
-- 是 56~58。原来写 64 等于把「回执之后用户紧跟的下一句」也算续块——09:04 就这样吞掉了用户
-- 「把代码修改push到github」，只在 daemon 日志里留一行「忽略最新条」，用户看着像没回。
function M.is_reply_tail(prev, cur, opt)
    opt = opt or {}
    if not (prev and cur) then return false end
    if not M.is_reply(prev.text, opt.tag) then return false end
    local gap = opt.gap or 32
    if ((cur.y or 0) - ((prev.y or 0) + (prev.h or 0))) > gap then return false end
    local x0 = math.max(prev.x or 0, cur.x or 0)
    local x1 = math.min((prev.x or 0) + (prev.w or 0), (cur.x or 0) + (cur.w or 0))
    local narrow = math.min(prev.w or 0, cur.w or 0)
    return narrow > 0 and (x1 - x0) >= 0.6 * narrow
end

-- 同一条气泡是否**已经派过**。daemon 原来只按时间窗去重（same_after=60s），挡不住
-- 「老指令一直摊在聊天区最下面」：每过 60s 就被当成新消息再派一遍，副作用重复、还烧钱
-- （实测 09:49 起同一条部署指令被派了 30+ 次）。判据加一条几何指纹 fp（块数@纵坐标）：
--   * key 相同 + fp 相同 = 还是那块老气泡摊在原地 → 永久跳过（不必等时间窗过去）；
--   * key 相同 + fp 变了  = 用户真重发了一句一样的话（新气泡挤进来，块数/纵坐标必变）→ 照跑。
-- 两条都留：fp 缺省（没传）时退回纯时间窗，老调用点的行为不变。
function M.is_same_bubble(key, fp, last_key, last_fp, age, window)
    if not key or key == "" or key ~= last_key then return false end
    if fp and fp ~= "" and last_fp and last_fp ~= "" and fp == last_fp then return true end
    return (age or 0) < (window or 0)
end

-- 默认**全收**（prefix=""）：微信模式开着的时候，凡是新发到「文件传输助手」的消息都当指令
-- 跑（用户定的：每条都敲 #lite 太麻烦）。想要过滤就显式给 prefix="#lite"。
-- 代价明确：那一刻起，你自己随手发到箱子的笔记/链接也会被执行 —— 别开着模式发文件。
M.PREFIX = ""
-- 老的 "#lite" 写法仍然剥掉（见 strip_trigger），习惯难改，别把前缀当正文喂给模型。
M.LEGACY = "#lite"

-- 触发比对的归一：**必须用 norm 不能用 key** —— key 把标点一起抹掉，"#lite" 就退化成
-- 裸 "lite"，# 白加；而 is_reply 那边同理，两者一旦同形，"#lite 帮我…" 会被当回执丢掉。
-- OCR 常把 "#" 认成全角 "＃"、或在 "# lite" 中间塞空格，统一归一。
local function trig(s)
    return (M.norm(s):gsub("＃", "#"):gsub("#%s+", "#")):lower()
end

-- 骨架：除了 # 的形态，PP-OCRv4 还常把小写 i 认成 l/1/!（实测 "#lite 列一下" 出
-- "lite"、"#llte"、"1ite" 三种），所以比对时把这几兄弟归一成 i，两边同样处理。
local function skeleton(s)
    return (trig(s):gsub("[1!|]", "i"):gsub("l", "i"):gsub("^#", ""))
end

-- 不设就全收（危险）；设了就只认 "#lite xxx" / "#lite：xxx" / "＃lite xxx"。
-- 井号缺失也算命中：实测 OCR 会把 "#lite 列一下 /tmp" 认成 "lite"，严格只认 # 会漏指令
-- （宁可偶尔把以 lite 开头的笔记当指令，也不要静默丢指令——daemon 日志会把这种命中标出来）。
-- 边界：OCR 会吞空格，"#lite测试" 也必须算指令，所以只挡 ASCII 词字符，
-- "#litex" 这种蹭前缀的英文单词不认，中文直接跟上照收。
function M.has_trigger(text, prefix)
    if not prefix or prefix == "" then return true end
    local n, p = skeleton(text), skeleton(prefix)
    if p == "" or n:sub(1, #p) ~= p then return false end
    local rest = n:sub(#p + 1, #p + 1)
    return rest == "" or not rest:match("^[a-z0-9_]$")
end

-- 命中的形态："hash"（带井号）/"loose"（OCR 吞了 #）——daemon 用它区分日志级别。
function M.trigger_form(text, prefix)
    if not prefix or prefix == "" then return "any" end
    if not M.has_trigger(text, prefix) then return nil end
    return trig(text):sub(1, 1) == "#" and "hash" or "loose"
end

-- 去掉触发前缀，交给 agent 的正文更干净。井号在原文里可能被 OCR 吞掉，
-- 所以两种长度（带 # / 不带）都试，命中哪个切哪个。
-- 全收（prefix=""）时也剥老的 "#lite"：习惯难改，别把前缀当正文喂给模型。
-- 只剥带 # 的形态（OCR 吞 # 的 "lite 列一下" 在全收下照原样交给模型，它会自己看懂）。
local function strip_legacy(t)
    if t:sub(1, 1) ~= "#" then return nil end
    local p, cut = skeleton(M.LEGACY), #M.LEGACY
    if skeleton(t:sub(1, cut)) ~= p then return nil end
    local rest = t:sub(cut + 1, cut + 1)
    if rest ~= "" and rest:match("^[a-z0-9_]$") then return nil end   -- "#litex" 不是前缀
    return (M.norm(t:sub(cut + 1):gsub("^[:：,，.。%s]+", "")))
end

function M.strip_trigger(text, prefix)
    local t = (M.norm(text):gsub("＃", "#"):gsub("#%s+", "#"))
    if not prefix or prefix == "" then
        return strip_legacy(t) or (M.norm(t:gsub("^[:：,，.。%s]+", "")))
    end
    local p = skeleton(prefix)
    if p ~= "" then
        for _, cut in ipairs({ #prefix, #prefix - 1 }) do
            if cut > 0 and skeleton(t:sub(1, cut)) == p then
                return (M.norm(t:sub(cut + 1):gsub("^[:：,，.。%s]+", "")))
            end
        end
    end
    return (M.norm(t:gsub("^[:：,，.。%s]+", "")))
end

-- 「模式开关命令」：全收模式下 #退出/#退出微信模式 也会被当成新消息抄下来，但它们必须
-- **原样**贴给主进程（由 lua/tui/modecmd.lua 的 submit() 拦），不能包进「微信远程指令（…）」
-- 外壳 —— 主进程只认整行命令，包了壳就退化成让模型念一句"退出"，模式根本关不掉。
-- 动词表不在这里复制：modecmd 是唯一一份（AGENTS §5）。拿不到就说 false，退回旧行为。
-- 手机上敲 # 也是麻烦事（全收模式本来就是为了免前缀）：裸词也算，但**整行必须就是那个词**。
-- 返回该透传的规范写法（带 #），不是模式命令返回 nil。
-- 词表一律不复制：ON 取 tui.wxmode.ON_WORDS，OFF 取 tui.modecmd.OFF（AGENTS §5）。
-- 裸「退出」**刻意不认**（它更像一句正文，留给人让模型理解）；带模式名的裸「退出微信」认。
function M.mode_cmd_norm(text)
    local s = (M.norm(text or ""):gsub("＃", "#"))
    if s == "" then return nil end
    local MC = select(2, pcall(require, "tui.modecmd"))
    if s:sub(1, 1) == "#" then
        if type(MC) == "table" and MC.command(s) then return s end
        return nil
    end
    local WX = select(2, pcall(require, "tui.wxmode"))
    if type(WX) == "table" then
        for _, w in ipairs(WX.ON_WORDS or {}) do
            if (w:gsub("^#", "")) == s then return "#" .. s end
        end
    end
    if type(MC) == "table" then
        for _, v in ipairs(MC.OFF or {}) do
            if s == v .. "微信" or s == v .. "微信模式" then return "#" .. s end
        end
    end
    return nil
end

function M.is_mode_cmd(text) return M.mode_cmd_norm(text) ~= nil end

-- ── 媒体消息（图片/文件/视频）：不处理 ──────────────────────────────
-- 用户定的：微信模式收到的**图片和文件不处理**（截图里的字、文件名都不是指令）。
-- 这里只判「OCR 抄出来的这块文本本身长成什么样」，便宜、先跑；
-- 文本长得像正文的（截图里有字）由 daemon 的剪贴板信号兜住：图片右键「复制」进
-- 剪贴板的是 image/png，复制不出文本 —— 那才是权威判据（见 wx_watch_daemon.lua:copy_at）。

-- 微信自己写的占位符（手机端发来的、或某些渲染下会出现的裸词）
local MEDIA_WORDS = { "图片", "照片", "视频", "文件", "语音", "表情", "动画表情",
                      "聊天记录", "链接", "位置", "视频通话", "语音通话", "已取消" }

-- OCR 把占位符的括号认成全角是常态（"【文件】"），key() 只抹 ASCII 标点，所以再剥一层全角括号。
local function bare(s)
    return (M.key(s):gsub("[【】（）〔〕「」『』]", ""))
end
local function is_placeholder(t)
    local k = bare(t)
    if k == "" then return false end
    for _, w in ipairs(MEDIA_WORDS) do
        if k == bare(w) then return true end
    end
    return false
end

-- 文件气泡的大小行：「19.4M」「1.2K」「312B」「3.05GB」。
-- 纯整数 + 单字母（"5G"）不算：那太像正文（"清到 5G"），宁可漏判，后面还有剪贴板那层兜。
local function size_line(l)
    l = (l or ""):gsub("%s", "")
    if not l:match("^%d+%.?%d*[BKMG]B?$") then return false end
    return l:find(".", 1, true) ~= nil or l:sub(-1) == "B"
end

-- 文件名行：以扩展名收尾
local function name_line(l)
    return l:match("%.[%a%d][%a%d]+$") ~= nil
end

-- text 是 OCR 的块文本（行之间是 \n）。norm 会把换行压成空格，所以**先切行再归一**。
function M.is_media(text)
    local raw = tostring(text or "")
    if M.norm(raw) == "" then return true end      -- 纯图/表情：认不出字 = 没有指令
    local lines = {}
    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
        local t = M.norm(line)
        if t ~= "" then lines[#lines + 1] = t end
    end
    if #lines == 0 then return true end
    if #lines == 1 and is_placeholder(lines[1]) then return true end
    -- 整条就是一个裸文件名（"报告.pdf" / "lite-0.1.1.tar.gz"）：文件气泡只抄得出这个
    if #lines == 1 and not lines[1]:find("%s") and name_line(lines[1]) then return true end
    -- 整条就是一串大小（"312B" / "19.4M"）：没人会拿这个当指令
    if #lines == 1 and size_line(lines[1]) then return true end
    -- 文件气泡 = 文件名行 + 大小行，两样都在才认
    local has_name, has_size = false, false
    for _, l in ipairs(lines) do
        if size_line(l) then has_size = true end
        if name_line(l) or (l:find("%s") and l:match("%.[%a%d][%a%d]+%s")) then has_name = true end
    end
    return has_name and has_size
end

-- ── 闪烁门的采样参数（daemon 与回归共用一份，AGENTS §5：判据不复制）─────────
-- 「托盘图标在闪」是唯一免费的新消息信号（不抢焦点、不截图、不 OCR），但它**只亮一两秒**。
-- 早先 10s 一轮 × 2.4s 采样窗 = 时间轴覆盖 ~24%，剩下的全靠 force_every 定期 raise 微信
-- 强检进去（那正是用户抱怨的打扰）。改成**短窗 + 快轮询**后覆盖 ~73%，强检退成纯安全网。
--
-- 窗长是硬约束不是口味：图标在两组画面之间换，实测周期 ~0.9s（半周期 450ms）。采样窗
-- **必须长于半周期**才保证「不管相位必然见到两种画面」；短于它就有一半概率同相采到两张
-- 一样的图判成 idle —— 那种漏是静默的，日志还会骗人说「图标没闪」。
M.BLINK_HALF_MS = 450
M.GATE = {
    tries = 5,        -- 5 帧 × 200ms = 800ms 采样窗（> 450ms 半周期）
    gap_ms = 200,
    poll_ms = 300,    -- 空闲轮睡 300ms → 覆盖 800/1100 ≈ 73%（一轮才几 KB 像素拷贝）
}
-- 兜底强检（秒）：门仍有 ~27% 死区，偶尔漏一次靠它补。它不打扰用户的前提是
-- surface() 判「窗口本来就被盖住才 raise」，所以这个数只是安全网，不是主要通路。
M.FORCE_EVERY = 120

-- 采样窗长（ms）= 帧间隔 × (帧数-1)。回归钉住它 > BLINK_HALF_MS。
function M.gate_window_ms(g)
    g = g or M.GATE
    return (g.tries - 1) * g.gap_ms
end

return M
