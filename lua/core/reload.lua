-- Lua 层热重载：重载 tools / prompt / FFI 封装，保留 C .so 已加载的句柄。
local M = {}

local MODULES = {
    "core.tools",
    "core.prompt",
    "ffi.image",
    "ffi.magick",
}

function M.lua(agent, ctx)
    local ok, err = pcall(function()
        for _, name in ipairs(MODULES) do
            package.loaded[name] = nil
        end

        local NewTools = require("core.tools")
        if agent.tools then
            local mt = getmetatable(agent.tools)
            if mt then
                for k, v in pairs(NewTools) do mt[k] = v end
            end
            agent.tools.image_native = nil
            agent.tools.image_backend = nil
        end
        -- 工具清单和 schema 字符数是 memo 的：不在这里作废，热重载完预算仍按旧名单算，
        -- 且 helper 增删也看不出条数变化（agent.lua:reset_tool_memo）。
        if agent.reset_tool_memo then agent:reset_tool_memo() end

        local NewPrompt = require("core.prompt")
        if agent.prompt ~= nil then
            agent.prompt = NewPrompt
        end

        if agent.system_prompt and ctx and ctx.session and ctx.session.messages then
            local msgs = ctx.session.messages
            if msgs[1] and msgs[1].role == "system" then
                msgs[1].content = agent:system_prompt()
            end
        end
    end)
    return ok, err
end

return M
