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

function M.is_reply(text, tag)
    local n, kt = slim(text or ""):lower(), slim(tag or ""):lower()
    if kt == "" or n == "" then return false end
    return n:sub(1, #kt) == kt
end

-- 触发前缀：不设就全收（危险，文件传输助手本来就是发笔记/文件的地方），
-- 设了就只认 "lite xxx" / "lite：xxx"。
function M.has_trigger(text, prefix)
    if not prefix or prefix == "" then return true end
    local n = M.key(text or "")
    return n ~= "" and n:sub(1, #M.key(prefix)) == M.key(prefix)
end

-- 去掉触发前缀，交给 agent 的正文更干净
function M.strip_trigger(text, prefix)
    if not prefix or prefix == "" then return M.norm(text) end
    local t = M.norm(text)
    local p = M.norm(prefix)
    local head = t:sub(1, #p)
    if head:lower() == p:lower() then t = t:sub(#p + 1) end
    return (M.norm(t:gsub("^[:：,，.。%s]+", "")))
end

return M
