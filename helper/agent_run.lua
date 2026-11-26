-- helper/agent_run.lua — lite 侧调外部插件仓（默认 my-agent）的通用面：结构化 args → 字符串
-- 实现在 helper/lib/agent_bridge.lua（子目录不参与工具发现）
local function load_lib(name, env)
    local dirs = { (env and env.helper_dir) or "helper", "helper",
                   ((env and env.cwd) or ".") .. "/helper" }
    local fallback = (os.getenv("LITE_ROOT") or (os.getenv("HOME") .. "/.local/share/lite")) .. "/helper"
    dirs[#dirs + 1] = fallback
    for _, d in ipairs(dirs) do
        local p = d .. "/lib/" .. name .. ".lua"
        local f = io.open(p, "rb")
        if f then
            f:close()
            local chunk, err = loadfile(p)
            if not chunk then error("加载 " .. p .. " 失败: " .. tostring(err)) end
            return chunk()
        end
    end
    error("找不到 helper/lib/" .. name .. ".lua")
end

return {
    description = "调用外部插件仓（默认 /opt/my-agent，$AGENT_ROOT 可改）里 plugins/<g>/<n> 的入口。"
        .. "plugin 必填；argv 为参数数组；mode=exec(默认,子进程隔离)/inline(同进程,最快但模块不能 os.exit)；"
        .. "action 省略=执行，list=列出可用插件，help=单个插件的 manifest。",
    parameters = {
        type = "object",
        properties = {
            plugin = { type = "string", description = "插件名，如 chrome / camera_grid / find_file" },
            argv = { type = "array", items = { type = "string" }, description = "透传给插件的参数数组" },
            mode = { type = "string", description = "exec(默认) 或 inline" },
            timeout = { type = "integer", description = "exec 模式超时毫秒" },
            action = { type = "string", description = "run(默认)/list/help" },
        },
        required = { "action" },
    },
    run = function(args, env)
        local b = load_lib("agent_bridge", env)
        local action = args.action or "run"
        if action == "list" then
            local names, rows = {}, {}
            for name, e in pairs(b.index()) do
                names[#names + 1] = name
                rows[name] = e
            end
            table.sort(names)
            local out = { ("%d plugins under %s"):format(#names, b.root()) }
            for _, n in ipairs(names) do
                out[#out + 1] = ("  %-22s %-10s %s"):format(n, rows[n].group or "-", rows[n].module or "(no module)")
            end
            return table.concat(out, "\n")
        end
        if action == "help" then
            local e, err = b.resolve(args.plugin or "")
            if not e then return "error: " .. tostring(err) end
            local f = io.open(e.dir .. "/manifest.json")
            local body = f and f:read("*a") or "(no manifest.json)"
            if f then f:close() end
            return body
        end
        local out, err = b.call(args.plugin, args, { mode = args.mode, timeout = args.timeout,
                                                     helper_dir = env and env.helper_dir })
        if not out then return "error: " .. tostring(err) end
        return out
    end,
}
