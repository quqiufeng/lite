-- 配置：环境变量 > ~/.config/lite/config.lua > 默认值。
local M = {}

local function load_file(path)
    local f = loadfile(path)
    if not f then return {} end
    if setfenv then setfenv(f, {}) end
    local ok, t = pcall(f)
    if ok and type(t) == "table" then return t end
    return {}
end

-- env 可注入（测试用）；默认读 os.getenv。
function M.load(env)
    local function get(k)
        if env and env[k] ~= nil then return env[k] end
        return os.getenv(k)
    end

    local home = get("HOME") or "."
    local file = load_file(home .. "/.config/lite/config.lua")

    return {
        api_key = get("DEEPSEEK_API_KEY") or file.api_key,
        base_url = get("DEEPSEEK_BASE_URL") or file.base_url or "https://api.deepseek.com",
        model = get("DEEPSEEK_MODEL") or file.model or "deepseek-chat",
        cwd = get("LITE_CWD") or file.cwd or get("PWD") or ".",
        max_turns = tonumber(get("LITE_MAX_TURNS") or file.max_turns) or 16,
        temperature = tonumber(get("LITE_TEMPERATURE") or file.temperature) or 0,
        memory_dir = get("LITE_MEMORY_DIR") or file.memory_dir,
        memory_mb = tonumber(get("LITE_MEMORY_MB") or file.memory_mb) or 100,
        memory_flush = tonumber(get("LITE_MEMORY_FLUSH") or file.memory_flush) or 30,
        context_chars = tonumber(get("LITE_CONTEXT_CHARS") or file.context_chars) or 8000,
        context_turns = tonumber(get("LITE_CONTEXT_TURNS") or file.context_turns) or 16,
    }
end

return M
