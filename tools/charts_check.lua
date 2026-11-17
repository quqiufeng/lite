-- tools/charts_check.lua —— 图表卡边界回归：54 卡 × 7 组坏数据
--
-- 为什么单独一个进程：坏数据以前会把 pen.resample/spline 的循环次数放大到
-- 十亿级（坐标爆炸），进程直接挂住；跑在自动单测里会把整个 `tools/test.sh` 拖死。
-- 所以由 test.sh 用 `timeout` 包起来跑：挂住 = 失败，但不是把 CI 一起带走。
--
-- 每条用例的判据只有三条，都是「用户能看见」的：
--   1. 不出错（pcall 通过）        2. SVG 里不出现 nan/inf   3. 单张耗时有上限
-- 这样它不锁死具体画法（卡片还能改），只锁「不许崩/不许出坏图」。
local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local C = require("charts")

-- 坏数据矩阵。rows 驱动的卡全吃这些；非 rows 驱动的卡（sankey/er/org/mind…）
-- 会忽略 rows 用自己 demo 的字段，等于顺带验「多余字段不炸」。
local CASES = {
  { "empty", { rows = {} } },
  { "zero", { rows = { { label = "a", value = 0 }, { label = "b", value = 0 } } } },
  { "single", { rows = { { label = "a", value = 7 } } } },
  { "neg", { rows = { { label = "a", value = -5 }, { label = "b", value = 3 } } } },
  { "huge", { rows = { { label = "a", value = 1e12 }, { label = "b", value = 1 } } } },
  { "garbage", { rows = { { label = "a", value = "oops" }, { label = "b" }, {}, 7 } } },
  { "nan", { rows = { { label = "a", value = 0 / 0 }, { label = "b", value = math.huge },
                      { label = "c", value = -math.huge } } } },
}

local MAX_SEC = 3.0      -- 单张上限：正常 0.00x 秒，挂住就是十亿级循环
local MAX_BYTES = 4 << 20 -- 点数爆炸的另一个症状：SVG 吹到几十兆

-- 只看数值属性里的 nan/inf：卡片正文（标签）里出现 "nan" 字样不算坏图
local function has_bad_num(svg)
  for val in svg:gmatch('d="([^"]*)"') do
    if val:find("nan", 1, true) or val:find("inf", 1, true) then return "path d", val:sub(1, 80) end
  end
  for attr in svg:gmatch('%s(cx|cy|x|y|r|width|height)="([^"]*)"') do
    if attr:find("nan", 1, true) or attr:find("inf", 1, true) then return "attr", attr end
  end
  return nil
end

local cards = C.list()
local ok, bad = 0, {}
local slowest, slowest_what = 0, ""

for _, c in ipairs(cards) do
  for _, case in ipairs(CASES) do
    local what = c.id .. "/" .. case[1]
    if os.getenv("CHARTS_CHECK_TRACE") then
      io.stderr:write(what .. "\n"); io.stderr:flush()
    end
    local t0 = os.clock()
    local good, svg = pcall(C.svg, c.id, case[2])
    local dt = os.clock() - t0
    if dt > slowest then slowest, slowest_what = dt, what end
    if not good then
      bad[#bad + 1] = string.format("%s: error %s", what, tostring(svg):gsub("^.*:%d+: ", ""))
    elseif type(svg) ~= "string" then
      bad[#bad + 1] = what .. ": 没返回字符串"
    elseif #svg > MAX_BYTES then
      bad[#bad + 1] = string.format("%s: SVG %d 字节（>%d），点数爆炸", what, #svg, MAX_BYTES)
    else
      local kind, frag = has_bad_num(svg)
      if kind then
        bad[#bad + 1] = string.format("%s: %s 里有 nan/inf: %s", what, kind, frag)
      elseif dt > MAX_SEC then
        bad[#bad + 1] = string.format("%s: %.1fs（>%.1fs）", what, dt, MAX_SEC)
      else
        ok = ok + 1
      end
    end
  end
end

-- 一张正常卡必须仍然正常：边界全过但正常图坏了，说明守卫下手太重
do
  local svg = C.svg("pie", {})
  if #svg < 2000 or svg:find("nan", 1, true) then
    bad[#bad + 1] = "sanity: pie 的 demo 出图异常（长度/内容）"
  else
    ok = ok + 1
  end
end

print(string.format("[charts] %d 卡 × %d 组 = %d 项，ok %d，fail %d（最慢 %s %.2fs）",
  #cards, #CASES, #cards * #CASES, ok, #bad, slowest_what, slowest))
for _, b in ipairs(bad) do print("FAIL " .. b) end
os.exit(#bad == 0 and 0 or 1)
