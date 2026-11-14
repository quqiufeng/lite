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

local function current_dir(get)
    local p = get("PWD")
    if p and p ~= "" and p:sub(1, 1) == "/" then return p end
    local h = io.popen("pwd 2>/dev/null", "r")
    if h then
        local s = h:read("*l")
        h:close()
        if s and s ~= "" then return s end
    end
    return "."
end

local function candidate_dotenvs(get, cwd)
    local explicit = get("LITE_ENV_FILE")
    if explicit then
        if explicit == "" or explicit == "/dev/null" then return {} end
        if explicit:sub(1, 1) ~= "/" then explicit = cwd .. "/" .. explicit end
        return { explicit }
    end

    local out, seen = {}, {}
    local function add(path)
        if path and not seen[path] then
            seen[path] = true
            out[#out + 1] = path
        end
    end

    -- 近处优先：cwd → 父目录 → ~/.config/lite/.env → ~/.env → 安装目录。
    local dir = cwd
    for _ = 1, 10 do
        add(dir:gsub("/+$", "") .. "/.env")
        local parent = dir:match("^(.*)/[^/]+$")
        if not parent or parent == "" or parent == dir then break end
        dir = parent
    end
    local home = get("HOME")
    if home and home ~= "" then
        -- lite 专用在前，通用的 ~/.env 兜底（很多人只维护后者）。
        add(home .. "/.config/lite/.env")
        add(home .. "/.env")
    end
    -- `sudo lite` 会把 HOME 换成 /root 并按 env_reset 清掉进程环境里的 key，
    -- 但保留 SUDO_USER。此时补上调用者自己的两份 .env：凭据仍只活在原来那份
    -- 0600 文件里，既不进命令行参数（ps 可见），也不复制到 /root。
    local sudo_user = get("SUDO_USER")
    if sudo_user and sudo_user ~= "" and sudo_user ~= "root" then
        -- 家目录根可覆盖（/home2、macOS 的 /Users；测试也靠它造夹具）。
        local base = get("LITE_HOME_ROOT")
        if not base or base == "" then base = "/home" end
        local user_home = base:gsub("/+$", "") .. "/" .. sudo_user
        if user_home ~= home then
            add(user_home .. "/.config/lite/.env")
            add(user_home .. "/.env")
        end
    end
    local root = get("LITE_ROOT")
    if root and root ~= "" then add(root:gsub("/+$", "") .. "/.env") end
    return out
end

-- 合并多层 .env：近处键优先，缺失键由全局/安装目录补。
local function load_dotenv_merged(get, cwd)
    local merged = {}
    for _, path in ipairs(candidate_dotenvs(get, cwd)) do
        local d = load_dotenv(path)
        for k, v in pairs(d) do
            if merged[k] == nil then merged[k] = v end
        end
    end
    return merged
end

-- 优先级：注入 env / 进程环境 > .env > ~/.config/lite/config.lua > 默认值。
-- 传了 env 表 = 由它**完全接管**环境读取（不再回落到 os.getenv）：否则调用方
-- 无法表达「这个键就是没有」，宿主 shell 里的 DEEPSEEK_API_KEY 会把夹具里的
-- .env 值盖掉，测试永远拿不到自己写的那份。生产路径都是无参 load()。
function M.load(env)
    local function get(k)
        if env then return env[k] end
        return os.getenv(k)
    end

    local cwd = current_dir(get)
    local dotenv = load_dotenv_merged(get, cwd)

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
        cwd = getv("LITE_CWD") or file.cwd or cwd,
        max_turns = tonumber(getv("LITE_MAX_TURNS") or file.max_turns) or 256,
        temperature = tonumber(getv("LITE_TEMPERATURE") or file.temperature) or 0,
        memory_dir = getv("LITE_MEMORY_DIR") or file.memory_dir,
        memory_mb = tonumber(getv("LITE_MEMORY_MB") or file.memory_mb) or 100,
        memory_flush = tonumber(getv("LITE_MEMORY_FLUSH") or file.memory_flush) or 30,
        -- 单位是**整条请求的字符数**：system + digest + 尾巴 + 工具 schema 全算在内
        -- （schema 由 agent:schema_chars() 计入，见 design.md「预算的单位」）。
        -- 120000 字符 ≈ 38k tokens（实测 chars→tokens ≈ 0.46~0.5，见 tok_per_char），
        -- 留在 DeepSeek 128k 窗口内；旧默认 64000 只算消息不算 schema，实际请求
        -- 已经 ~80k 字符，改成显式总预算后总规模不变、留下来的尾巴更大。
        context_chars = tonumber(getv("LITE_CONTEXT_CHARS") or file.context_chars) or 120000,
        context_turns = tonumber(getv("LITE_CONTEXT_TURNS") or file.context_turns) or 16,
        context_window = tonumber(getv("LITE_CONTEXT_WINDOW") or file.context_window) or 64000,
        reserve_tokens = tonumber(getv("LITE_RESERVE_TOKENS") or file.reserve_tokens) or 8192,
        -- compact=true 恢复「先摘要」的老策略；默认 false = 丢弃优先（超线就从
        -- 最新往回装，更老的消息直接丢，需要时靠 recall）。
        compact = (function()
            local v = getv("LITE_COMPACT")
            if v == nil then v = file.compact end
            if v == nil then return false end
            if type(v) == "boolean" then return v end
            v = tostring(v):lower()
            return v == "1" or v == "true" or v == "on" or v == "yes"
        end)(),
        max_output_tokens = tonumber(getv("LITE_MAX_OUTPUT_TOKENS") or file.max_output_tokens) or 8192,
        token_budget = tonumber(getv("LITE_TOKEN_BUDGET") or file.token_budget) or 0,
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
        plugins = (function()
            local v = getv("LITE_PLUGINS")
            if v == nil then v = file.plugins end
            if v == nil then return true end
            if type(v) == "boolean" then return v end
            v = tostring(v):lower()
            return not (v == "0" or v == "false" or v == "off" or v == "no")
        end)(),
        debug_log = getv("LITE_DEBUG_LOG") or file.debug_log,
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
