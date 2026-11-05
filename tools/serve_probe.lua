-- serve 协议探针：connect → hello/replay/state → ping → diff。
local net = require("core.net")
local cjson = require("cjson")

local host = arg[1] or "127.0.0.1"
local port = tonumber(arg[2])
assert(port, "usage: serve_probe.lua <host> <port>")

local fd, err = net.connect(host, port)
assert(fd, err)

local buf = ""

local function read_obj(timeout)
    local deadline = os.time() + timeout
    while true do
        local line, rest = buf:match("^([^\n]*)\n(.*)$")
        if line then
            buf = rest
            if line ~= "" then
                local ok, obj = pcall(cjson.decode, line)
                if ok and type(obj) == "table" then return obj end
            end
        else
            if os.time() > deadline then return nil, "timeout" end
            local _, revs = net.poll({ fd }, 100)
            if revs[1] and revs[1] ~= 0 then
                local data, rerr = net.recv(fd)
                if data then buf = buf .. data else return nil, rerr end
            end
        end
    end
end

local seen_state = false
while true do
    local obj, rerr = read_obj(5)
    assert(obj, rerr)
    if obj.type == "state" then
        seen_state = true
        break
    end
    assert(obj.type ~= "error", obj.error)
end
assert(seen_state, "no state")

assert(net.send(fd, cjson.encode({ type = "ping" }) .. "\n"))
local pong = assert(read_obj(5), "no pong")
assert(pong.type == "pong", "expected pong")

assert(net.send(fd, cjson.encode({ type = "diff" }) .. "\n"))
local diff = assert(read_obj(5), "no diff")
assert(diff.type == "diff", "expected diff")

net.close(fd)
print("OK serve.probe")
