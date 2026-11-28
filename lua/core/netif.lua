-- 本机网卡地址（纯 LuaJIT FFI 调 libc 的 getifaddrs，不 shell 出去问 `ip`/`hostname -I`）。
--
-- 为什么需要它：初始化页/二维码要告诉人「拿手机连 http://<哪台机器>:8080」。
-- 绑的地址是 0.0.0.0（通配），照抄进 URL 是打不开的，必须换成真实网卡地址。
-- 盒子是 DHCP，写死 IP 换个网就废，所以每次用时现取。
--
--   local netif = require("core.netif")
--   netif.lan_ip()        -- "192.168.1.121" / nil
--   netif.url(8080)       -- "http://192.168.1.121:8080"（取不到退回 127.0.0.1）
--
-- 选哪一个：跳过回环、跳过没 up 的；私网段（10/172.16-31/192.168）优先，
-- 多条私网时按「最长前缀掩码」挑（/24 比 /16 更像那根真实网线），仍并列就按
-- 名字字典序——同一台机器多次调用必须给同一个答案，否则 URL 会来回跳。
--
-- 只 cdef 一个 struct ifaddrs（指针字段一律 void *，布局不变），地址一律按字节偏移
-- 读：core/net 已经 cdef 过 sockaddr/sockaddr_in，这里再申一次就是 hard error，
-- 而拿 pcall 吞掉又会让字段半残（踩过：报 implicit tag / no member named 'sa_family'）。

local ffi = require("ffi")
local bit = require("bit")

pcall(ffi.cdef, [[
struct ifaddrs {
	struct ifaddrs *ifa_next;
	char *ifa_name;
	unsigned int ifa_flags;
	void *ifa_addr;
	void *ifa_netmask;
	void *ifa_dstaddr;
	void *ifa_data;
};
int getifaddrs(struct ifaddrs **ifap);
void freeifaddrs(struct ifaddrs *ifa);
]])

local AF_INET = 2
local IFF_UP, IFF_LOOPBACK = 1, 8
-- struct sockaddr: [0..1] sa_family, struct sockaddr_in 里 sin_addr 在 [4..7]。
local OFF_FAMILY, OFF_ADDR = 0, 4

local M = {}

local function rd16(p)
	return ffi.cast("unsigned short *", p)[0]
end

local function rd32(p)
	return ffi.cast("unsigned int *", p)[0]
end

-- 指针按字节偏移取址：cdef 里指针字段是 void *（避免和 core/net 的 sockaddr 打架），
-- void* 不能直接做算术，先 cast 成 uint8_t*。
local function at(p, off)
	return ffi.cast("uint8_t *", p) + off
end

local function mask_bits(netmask)
	-- 网络字节序按字节数 1，不必关心大小端。
	local n = 0
	for i = 0, 3 do
		local v = bit.band(bit.rshift(netmask, i * 8), 255)
		for k = 7, 0, -1 do
			if bit.band(v, bit.lshift(1, k)) ~= 0 then n = n + 1 end
		end
	end
	return n
end

local function is_private(a)
	local o1 = bit.band(a, 255)
	local o2 = bit.band(bit.rshift(a, 8), 255)
	if o1 == 10 then return true end
	if o1 == 192 and o2 == 168 then return true end
	if o1 == 172 and o2 >= 16 and o2 <= 31 then return true end
	return false
end

local function ip4(a)
	return ("%d.%d.%d.%d"):format(bit.band(a, 255), bit.band(bit.rshift(a, 8), 255),
		bit.band(bit.rshift(a, 16), 255), bit.rshift(a, 24))
end

-- 所有网卡的 IPv4（含回环），按「最能代表本机」排序。
function M.ipv4_list()
	local head = ffi.new("struct ifaddrs *[1]")
	if ffi.C.getifaddrs(head) ~= 0 then return {} end
	local rows = {}
	local p = head[0]
	while p ~= nil do
		local up = bit.band(p.ifa_flags, IFF_UP) ~= 0
		local lo = bit.band(p.ifa_flags, IFF_LOOPBACK) ~= 0
		local addr = p.ifa_addr
		if addr ~= nil and rd16(at(addr, OFF_FAMILY)) == AF_INET then
			local a = rd32(at(addr, OFF_ADDR))
			if a ~= 0 then
				local bits = 0
				local nm = p.ifa_netmask
				if nm ~= nil and rd16(at(nm, OFF_FAMILY)) == AF_INET then
					bits = mask_bits(rd32(at(nm, OFF_ADDR)))
				end
				rows[#rows + 1] = {
					ip = ip4(a),
					name = ffi.string(p.ifa_name or "?"),
					up = up,
					loop = lo,
					private = is_private(a),
					bits = bits,
				}
			end
		end
		p = p.ifa_next
	end
	ffi.C.freeifaddrs(head[0])
	-- 排序：up 且非回环 > 私网 > 掩码长 > 名字/IP 稳定（同样输入必须同样输出）。
	table.sort(rows, function(x, y)
		local kx = (x.up and not x.loop) and 1 or 0
		local ky = (y.up and not y.loop) and 1 or 0
		if kx ~= ky then return kx > ky end
		if x.private ~= y.private then return x.private end
		if x.bits ~= y.bits then return x.bits > y.bits end
		if x.name ~= y.name then return x.name < y.name end
		return x.ip < y.ip
	end)
	return rows
end

-- 最能代表「这台机器」的地址：非回环、已 up；取不到给 nil。
function M.lan_ip()
	for _, r in ipairs(M.ipv4_list()) do
		if r.up and not r.loop then return r.ip end
	end
	return nil
end

function M.loopback_ip()
	return "127.0.0.1"
end

-- 给页面/终端用的「去哪打开」。绑在具体地址上就直接用它；绑 0.0.0.0/::（通配）
-- 时现取本机 IP——把 0.0.0.0 印给人是打不开的，写死 IP 又会被 DHCP 换掉。
function M.url(port, bind_host)
	local h = bind_host
	if h == "" or h == "0.0.0.0" or h == "::" or h == "*" then h = nil end
	if h == nil then h = M.lan_ip() or M.loopback_ip() end
	local n = tonumber(port)
	if n == nil or n == 0 then return ("http://%s"):format(h) end
	return ("http://%s:%d"):format(h, n)
end

return M
