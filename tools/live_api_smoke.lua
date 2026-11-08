-- 最小真实 API 连通性测试：独立构造 system + user，只发一次请求。
local config = require("core.config").load()
if not config.api_key or config.api_key == "" then
    print("SKIP live.api (no DEEPSEEK_API_KEY)")
    os.exit(0)
end

local Context = require("context")
local Provider = require("core.provider")

local ctx = Context.new({
    cwd = os.getenv("PWD") or ".",
    model = config.model,
    api_key = config.api_key,
    base_url = config.base_url,
    max_retries = 0,
})

local messages = {
    { role = "system", content = "You are a concise assistant." },
    { role = "user", content = "回复ok即可" },
}

local assistant, err = Provider.stream(messages, {}, ctx.settings)
if not assistant then
    io.stderr:write("FAIL live.api: " .. tostring(err) .. "\n")
    os.exit(1)
end

print("OK live.api")
