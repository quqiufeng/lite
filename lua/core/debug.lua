-- 可选 JSONL 调试日志：provider / agent / serve 事件。
--
-- 落盘策略（防止 --debug 长会话把 $TMPDIR 写爆）：
--   1) 文件名插 pid：多实例不再抢写同一文件，行也不会交错；
--      `LITE_DEBUG_NO_PID=1` 可关掉（要固定路径的脚本用）。
--   2) 单文件将超 `LITE_DEBUG_MAX_MB`（默认 128）时轮转到 `<path>.1`，只留一份旧文件，
--      磁盘上限 ≈ 2×阈值；轮转本身写一条 `debug_rotated` 留痕。
--   3) 单条字符串字段超过 `LITE_DEBUG_FIELD_CHARS`（默认 4096）截断，并补
--      `<field>_bytes` / `<field>_truncated`：任何调用点（例如整段 SSE 响应体）
--      都撑不爆文件，且看日志就知道被截过。
-- 体积大又每轮重复的内容（system prompt）别整段存，用 `M.hash` 存指纹。
local cjson = require("cjson")

local M = {}
M.__index = M

local MAX_FIELD = tonumber(os.getenv("LITE_DEBUG_FIELD_CHARS") or "") or 4096
local MAX_BYTES = (tonumber(os.getenv("LITE_DEBUG_MAX_MB") or "") or 128) * 1024 * 1024

local function pid()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return 0 end
    pcall(ffi.cdef, "int getpid(void);")
    local ok2, p = pcall(function() return ffi.C.getpid() end)
    if ok2 and p then return tonumber(p) end
    return 0
end

-- lite-debug.jsonl → lite-debug-12345.jsonl（扩展名保留，按 *.jsonl 扫的脚本照样认）
local function with_pid(path)
    if os.getenv("LITE_DEBUG_NO_PID") == "1" then return path end
    local dir, base = path:match("^(.*)/([^/]+)$")
    if not base then dir, base = "", path end
    local stem, ext = base:match("^(.+)(%.[^.]+)$")
    if not stem then stem, ext = base, "" end
    local name = stem .. "-" .. pid() .. ext
    if dir ~= "" then return dir .. "/" .. name end
    return name
end

-- FNV-1a 32bit：给"大且重复"的字段留指纹，比对两次请求是否同一份内容足够用。
function M.hash(s)
    s = tostring(s or "")
    local bit = require("bit")
    local h = 2166136261
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i))
        h = bit.tobit(h * 16777619)
    end
    if h < 0 then h = h + 4294967296 end
    return string.format("%08x", h)
end

local function put(rec, k, v)
    if type(v) == "string" and #v > MAX_FIELD then
        rec[k] = v:sub(1, MAX_FIELD)
        rec[k .. "_bytes"] = #v
        rec[k .. "_truncated"] = true
    else
        rec[k] = v
    end
end

function M.new(path)
    if not path or path == "" then return nil end
    local p = with_pid(path)
    local f, err = io.open(p, "a")
    if not f then return nil, err end
    local self = setmetatable({ f = f, path = p }, M)
    local ok, sz = pcall(function() return f:seek("end") end)
    self.bytes = (ok and tonumber(sz)) or 0
    return self
end

function M:rotate()
    if not self.f then return end
    self.f:close()
    self.f = nil
    os.rename(self.path, self.path .. ".1")
    local f = io.open(self.path, "a")
    self.f = f
    self.bytes = 0
end

function M:log(event, data)
    if not self.f then return end
    local rec = { ts = os.time(), event = event }
    if type(data) == "table" then
        for k, v in pairs(data) do put(rec, k, v) end
    elseif data ~= nil then
        put(rec, "data", tostring(data))
    end
    local ok, s = pcall(cjson.encode, rec)
    if not ok then return end

    if self.bytes + #s + 1 > MAX_BYTES then
        self:rotate()
        if not self.f then return end
        -- 轮转要留痕：下次看日志得知道这一段去哪了
        local note = cjson.encode({
            ts = os.time(), event = "debug_rotated",
            from = self.path, to = self.path .. ".1",
            max_mb = MAX_BYTES / 1048576,
        })
        self.f:write(note, "\n")
        self.bytes = self.bytes + #note + 1
    end
    self.f:write(s, "\n")
    self.f:flush()
    self.bytes = self.bytes + #s + 1
end

function M:close()
    if self.f then
        self.f:close()
        self.f = nil
    end
end

return M
