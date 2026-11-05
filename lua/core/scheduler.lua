-- 定时唤醒：headless serve 空闲时按间隔提交任务。
local M = {}
M.__index = M

function M.new(opts)
    opts = opts or {}
    local now = tonumber(opts.start_at) or os.time()
    return setmetatable({
        every = tonumber(opts.every) or 0,
        task = opts.task or "",
        max_runs = tonumber(opts.max_runs) or 0,
        memory = opts.memory,
        can = opts.can or function() return true end,
        submit = opts.submit or function() end,
        runs = 0,
        last_run = now,
        last_answer = "",
        started_at = now,
    }, M)
end

function M:load()
    if not self.memory then return end
    local saved = self.memory:get("/agent/working", "wake")
    if type(saved) == "table" then
        self.runs = tonumber(saved.runs) or self.runs
        self.last_run = tonumber(saved.last_run) or self.last_run
        self.last_answer = tostring(saved.last_answer or "")
    end
end

function M:save()
    if not self.memory then return end
    local ttl = self.memory.TTL and self.memory.TTL.long or 0
    self.memory:put("/agent/working", "wake", {
        runs = self.runs,
        last_run = self.last_run,
        last_answer = self.last_answer,
        ts = os.time(),
    }, ttl)
end

function M:due(now)
    now = now or os.time()
    if self.every <= 0 or self.task == "" then return false end
    if self.max_runs > 0 and self.runs >= self.max_runs then return false end
    return now >= self.last_run + self.every
end

function M:next_run()
    return self.last_run + self.every
end

function M:build_prompt(run)
    local prev = tostring(self.last_answer or ""):gsub("%s+", " ")
    if #prev > 800 then prev = prev:sub(1, 800) .. "..." end
    return table.concat({
        string.format("[Scheduled wake #%d]", run or (self.runs + 1)),
        "Task: " .. self.task,
        "Previous result: " .. (prev ~= "" and prev or "(none)"),
        "This is an unattended scheduled wake. Do the task now. " ..
            "If there is nothing to do, reply \"idle\" briefly. " ..
            "Update the todo list if the task has multiple steps, then report briefly.",
    }, "\n")
end

function M:tick(now)
    now = now or os.time()
    if not self:due(now) then return false end
    if not self.can() then return false end
    self.runs = self.runs + 1
    self.last_run = now
    self:save()
    self.submit(self:build_prompt(self.runs), self.runs)
    return true
end

function M:set_answer(answer)
    self.last_answer = tostring(answer or "")
    self:save()
end

return M
