-- 测试辅助：写入一个种子会话 + 该 session 的 todo。
local dir = arg[1]
assert(dir, "usage: seed_todos.lua <dir>")

local Memory = require("core.memory")
local mem = assert(Memory.new({ dir = dir, max_mb = 16 }))
local cwd = os.getenv("LITE_CWD") or dir
local id = "seed"

mem:ensure_session(id, cwd, "deepseek-flash")
mem:remember_turn(id, 1, "seed session", "seeded")
mem:put("/agent/session", id .. "/todos", {
    items = {
        { content = "write code", status = "completed" },
        { content = "run tests", status = "pending" },
    },
    ts = os.time(),
}, mem.TTL.long)
mem:close()
print("seeded session " .. id)
