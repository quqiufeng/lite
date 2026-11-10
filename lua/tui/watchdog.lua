-- 监工模式：模型有时跑完一小步就收手，把光标交回输入框等人敲「继续」。
-- 开监工后每 watchdog.sec 秒替你在输入框发一句「继续」并回车。
--
-- 纪律（不干扰正常开发）：
--   1. 只在「空闲 + 队列空 + 输入框空」时发，绝不抢用户正在打的字；
--   2. agent 忙的时候不断把 deadline 往后推，任务跑完还要等满一个周期才催；
--   3. 纯逻辑、不碰 io/终端，能在 tools/auto_unit.lua 里直接单测。
local M = {}

M.SEC = tonumber(os.getenv("LITE_WATCHDOG_SEC") or "") or 180
M.TEXT = os.getenv("LITE_WATCHDOG_TEXT") or "继续"

-- 命令识别：整行就是 #监工模式 / #终止监工（前后允许空白）。
-- 返回 "on" / "off" / nil。
function M.command(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "#监工模式" or s == "#watchdog" then return "on" end
    if s == "#终止监工" or s == "#关闭监工" or s == "#watchdog off" then return "off" end
    return nil
end

-- 定时器实例。tick(now, idle) 返回 true = 这一拍该发「继续」。
function M.new(sec)
    local self = { sec = sec or M.SEC, on = false, next_at = nil, fired = 0 }
    if self.sec < 5 then self.sec = 5 end

    function self:start(now)
        self.on = true
        self.fired = 0
        self.next_at = (now or os.time()) + self.sec
        return self
    end

    function self:stop()
        self.on = false
        self.next_at = nil
        return self
    end

    -- 剩余秒数（状态栏显示用）；未开启返回 nil。
    function self:left(now)
        if not self.on or not self.next_at then return nil end
        local d = self.next_at - (now or os.time())
        if d < 0 then d = 0 end
        return d
    end

    -- 落盘快照：只有「开/关 + 周期 + 时间戳」三个标量，恢复时不依赖任何进程态。
    -- 调用方负责存进 mem（见 lua/tui/loop.lua 的 watchdog_save）。
    function self:state(now)
        return { on = self.on == true, sec = self.sec, ts = now or os.time() }
    end

    -- 从快照恢复：开着的就重新起一个完整周期（不追讨关机期间欠下的那几次催）。
    -- 快照缺失 / 已关闭 / 坏数据一律落到关闭态，绝不让脏状态自己把「继续」发起来。
    function self:restore(st, now)
        if type(st) ~= "table" or st.on ~= true then return self:stop() end
        if type(st.sec) == "number" and st.sec >= 5 then self.sec = st.sec end
        return self:start(now)
    end

    function self:tick(now, idle)
        if not self.on then return false end
        now = now or os.time()
        if not idle then
            -- 忙 / 有人在打字：滑窗后推，不打断。
            self.next_at = now + self.sec
            return false
        end
        if now < self.next_at then return false end
        self.next_at = now + self.sec
        self.fired = self.fired + 1
        return true
    end

    return self
end

return M
