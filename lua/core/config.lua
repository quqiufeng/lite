-- 配置：环境变量 > .env > ~/.config/lite/config.lua > 默认值。
local M = {}

local function load_file(path)
    local f = loadfile(path)
    if not f then return {} end
    if setfenv then setfenv(f, {}) end
    local ok, t = pcall(f)
    if ok and type(t) == "table" then return t end
    return {}
end

-- 解析简单 .env：KEY=VALUE，忽略注释/空行，去掉成对引号。
local function load_dotenv(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local out = {}
    for line in f:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local k, v = line:match("^([%w_]+)%s*=%s*(.*)$")
            if k then
                v = v:gsub("^(['\"])(.-)%1$", "%2")
                out[k] = v
            end
        end
    end
    f:close()
    return out
end

local function find_dotenv(get)
    local explicit = get("LITE_ENV_FILE")
    if explicit then
        if explicit == "" or explicit == "/dev/null" then return nil end
        return explicit
    end
    for _, dir in ipairs({ get("PWD") or ".", get("LITE_ROOT") }) do
        if dir then
            local path = dir:gsub("/+$", "") .. "/.env"
            local f = io.open(path, "r")
            if f then f:close(); return path end
        end
    end
    return nil
end

-- 优先级：注入 env / 进程环境 > .env > ~/.config/lite/config.lua > 默认值。
function M.load(env)
    local function get(k)
        if env and env[k] ~= nil then return env[k] end
        return os.getenv(k)
    end

    local dotenv = load_dotenv(find_dotenv(get) or "")

    local function getv(k)
        local v = get(k)
        if v ~= nil then return v end
        return dotenv[k]
    end

    local home = get("HOME") or "."
    local file = load_file(home .. "/.config/lite/config.lua")

    return {
        api_key = getv("DEEPSEEK_API_KEY") or file.api_key,
        base_url = getv("DEEPSEEK_BASE_URL") or file.base_url or "https://api.deepseek.com",
        model = getv("DEEPSEEK_MODEL") or file.model or "deepseek-flash",
        cwd = getv("LITE_CWD") or file.cwd or get("PWD") or ".",
        max_turns = tonumber(getv("LITE_MAX_TURNS") or file.max_turns) or 16,
        temperature = tonumber(getv("LITE_TEMPERATURE") or file.temperature) or 0,
        memory_dir = getv("LITE_MEMORY_DIR") or file.memory_dir,
        memory_mb = tonumber(getv("LITE_MEMORY_MB") or file.memory_mb) or 100,
        memory_flush = tonumber(getv("LITE_MEMORY_FLUSH") or file.memory_flush) or 30,
        context_chars = tonumber(getv("LITE_CONTEXT_CHARS") or file.context_chars) or 8000,
        context_turns = tonumber(getv("LITE_CONTEXT_TURNS") or file.context_turns) or 16,
        thinking = (function()
            local v = getv("LITE_THINKING") or getv("DEEPSEEK_THINKING") or file.thinking
            if v == nil then return false end
            if type(v) == "boolean" then return v end
            v = tostring(v):lower()
            return v == "1" or v == "true" or v == "on" or v == "yes"
        end)(),
        reasoning_effort = getv("LITE_REASONING_EFFORT") or getv("DEEPSEEK_REASONING_EFFORT")
            or file.reasoning_effort,
        max_retries = tonumber(getv("LITE_MAX_RETRIES") or file.max_retries) or 2,
        approval = getv("LITE_APPROVAL") or file.approval or "auto",
        sandbox = getv("LITE_SANDBOX") or file.sandbox,
        sandbox_net = (function()
            local v = getv("LITE_SANDBOX_NET")
            if v == nil then v = file.sandbox_net end
            if v == nil then return true end
            if type(v) == "boolean" then return v end
            v = tostring(v):lower()
            return not (v == "0" or v == "false" or v == "off" or v == "no")
        end)(),
    }
end

return M
