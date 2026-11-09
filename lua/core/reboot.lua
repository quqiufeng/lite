-- 自重启的「带话」通道：`/reboot <提示词>` 或 reboot 工具给 prompt 时，那句话要
-- 跨过进程边界，成为新进程里自动发出的第一句（优先于默认的「重启成功，继续工作。」）。
--
-- 为什么不用环境变量/argv：
--   - 子进程改不了父进程的环境；wrapper（tools/lite-lua）重启时继承的是**旧**环境，
--     所以 setenv 传不出去。
--   - argv 会把提示词暴露在 `ps` / shell 历史里，长文本与引号也不好处理。
-- 所以落一个一次性文件：写 = 退出码 75 之前（lua/main.lua 尾部），读 = 新进程带
-- `--reboot` 起来时 take()（读完即删，陈旧提示词不会污染下一次重启）。
local cjson = require("cjson")

local M = {}

M.DEFAULT_TEXT = "重启成功，继续工作。"

local function data_dir()
    local base = os.getenv("XDG_DATA_HOME")
    if not base or base == "" then base = (os.getenv("HOME") or ".") .. "/.local/share" end
    return base .. "/lite"
end

-- 每次调用现算：测试与不同 XDG_DATA_HOME 的实例互不干扰。
function M.path() return data_dir() .. "/reboot.prompt" end

local function clean(text)
    if type(text) ~= "string" then return nil end
    local s = text:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

function M.clear()
    local ok = os.remove(M.path())
    return ok and true or false
end

-- 空提示词 = 没说，直接清掉旧文件（避免上一轮的残留被下一次重启捡走）。
function M.save(text, cwd)
    local s = clean(text)
    if not s then M.clear(); return false end
    local dir = data_dir()
    os.execute(string.format("mkdir -p '%s'", dir:gsub("'", "'\\''")))
    local path = M.path()
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false, "cannot write " .. tmp end
    local rec = { cwd = cwd or os.getenv("PWD") or ".", text = s }
    local ok, body = pcall(cjson.encode, rec)
    f:write(ok and body or s)
    f:close()
    local rok, rerr = os.rename(tmp, path)
    if not rok then
        os.remove(tmp)
        return false, "cannot rename: " .. tostring(rerr)
    end
    return true
end

-- 一次性取走：读到就删，返回提示词（空/损坏都当没说）。
function M.take(cwd)
    local path = M.path()
    local f = io.open(path, "r")
    if not f then return nil end
    local body = f:read("*a") or ""
    f:close()
    os.remove(path)
    local ok, rec = pcall(cjson.decode, body)
    if not ok or type(rec) ~= "table" then return clean(body) end
    -- 同机多实例（不同 cwd）共用一个数据目录：cwd 对不上就不是给这次重启的。
    local want = cwd or os.getenv("PWD")
    if want and rec.cwd and rec.cwd ~= want then return nil end
    return clean(rec.text)
end

return M
