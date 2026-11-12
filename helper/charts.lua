-- helper/charts.lua —— 手绘风图表卡（54 种，纯 Lua 出 SVG，cairo+librsvg 出 PNG）
--
-- 定位：引擎在 lua/charts/（pen=笔触/配色/纸纹，types/*=六族卡面，init=注册表），
--       本文件只做编排，和 lens 之于 src/codesearch 的关系一样。
--
-- 用法：
--   charts({action="list"})                          六族 54 张卡（含中文标签）
--   charts({action="spec", id="pie"})                这张卡的 demo spec（JSON）
--   charts({action="svg",  id="pie"})                出 demo 的 SVG 字符串（默认带动效）
--   charts({action="render", id="pie"})              出 PNG + 同名 SVG → /tmp/chart-pie.{png,svg}
--   charts({action="render", id="bar", out="/tmp/a.png", spec={rows={...}, title="..."}})
--   charts({action="gallery", out="/tmp/charts"})    全部 54 张各出 PNG + 可动 SVG（验收用）
--
-- 动效（墨线描出/色块淡入/纸纹，纯 CSS 零 JS）默认开着；要纯静态就 anim=false。
--
-- spec = 卡自己的 demo 覆盖层（只写你要改的键，其余取 demo）：
--   通用   title / note / scale
--   parts  rows = {{label=, value=}}                         pie/rose/pyramid/nested/doughnut/stacked/waffle/sunburst
--   bars   rows = {{label=, value=}} / radar 用 {label, values, col} + axes,max
--   lines  rows / gantt 用 {label, from, to} + span,finish
--   dist   rows = {{label=, values={数}}}
--   flow   sinks/flows / er 用 {entities, links} / org 用 {tree, posts}
--   hier   tree/kids（各卡字段不同，先 action=spec 看 demo）
--
-- 依赖：cairo + librsvg（lua/trace/svgpng.lua，与 trace render 同一后端）。
--       只出 SVG 不需要任何 .so —— 走 action=svg 时纯 Lua。

local C = require("charts")

local schema = {
    name = "charts",
    description = "手绘/纸感风格图表卡：六族 54 种（饼、树图、瀑布、甘特、桑基、词云…），"
        .. "纯 Lua 生成 SVG，cairo+librsvg 出 PNG。不给 spec 就用卡自带 demo；"
        .. "先 action=list 看有哪些卡，action=spec 看该卡需要的字段。",
    parameters = {
        type = "object",
        properties = {
            action = { type = "string", enum = { "list", "spec", "svg", "render", "gallery" },
                description = "list=族与卡清单（默认）；spec=该卡的 demo spec；svg=输出 SVG 文本；"
                    .. "render=出 PNG（默认 /tmp/chart-<id>.png）+ 同名 SVG；gallery=全部卡各出 PNG + SVG" },
            id = { type = "string", description = "卡 id，如 pie / treemap / waterfall / gantt / sankey / wordcloud" },
            family = { type = "string", enum = { "parts", "bars", "lines", "dist", "flow", "hier" },
                description = "list 时按族过滤" },
            spec = { type = "object", description = "覆盖卡 demo 的字段（title/note/rows/…），见 action=spec" },
            out = { type = "string", description = "render/gallery 输出路径；gallery 给目录，默认 /tmp/charts" },
            scale = { type = "number", description = "render 的 device scale，默认 2" },
            anim = { type = "boolean", description = "动效层开关，默认 true（墨线描出/色块淡入/纸纹，纯 CSS 零 JS）；"
                .. "anim=false 出纯静态，PNG 渲染时自动降级" },
            svg = { type = "boolean", description = "默认 true：render 落同名 .svg、gallery 落 <family>-<id>.svg；"
                .. "svg=false 只要 PNG/单文件" },
        },
    },
}

local function q(s) return "'" .. tostring(s) .. "'" end

local function list_txt(fam)
    -- 族顺序按 C.families 表意走；族内按 id 排序（模块里是 pairs 加载，顺序不稳定）
    local cards, byfam = C.list(fam), {}
    for _, c in ipairs(cards) do
        byfam[c.family] = byfam[c.family] or {}
        table.insert(byfam[c.family], c)
    end
    local out = {}
    for _, f in ipairs({ "parts", "bars", "lines", "dist", "flow", "hier" }) do
        local list = byfam[f]
        if list then
            table.sort(list, function(a, b) return a.id < b.id end)
            out[#out + 1] = string.format("%s —— %s", f, C.families[f] or "")
            for _, c in ipairs(list) do
                out[#out + 1] = string.format("  %-10s %s", c.id, c.label)
            end
        end
    end
    out[#out + 1] = string.format("共 %d 张。下一步：action=spec id=<卡> 看字段，action=render 出图。",
        #cards)
    return table.concat(out, "\n")
end

local function spec_txt(id)
    local d = C.get(id)
    if not d then error("charts: 没有这张卡 " .. tostring(id), 0) end
    local cjson = require("cjson")
    local s = { title = d.demo and d.demo.title, demo = d.demo }
    return string.format("id=%s family=%s label=%s\n%s", id, d.family, d.label,
        cjson.encode(d.demo or {}))
end

local function copy(t)
    local s = {}
    if type(t) == "table" then for k, v in pairs(t) do s[k] = v end end
    return s
end

-- 动效默认开：只有显式 anim=false 才退成纯静态
local function anim_on(v) return v ~= false end

-- 拷贝一份 spec 再补 scale，别改调用方传进来的表（重复调用会累积）
local function render_one(id, spec, out, scale)
    local s
    if spec then
        s = {}
        for k, v in pairs(spec) do s[k] = v end
    end
    if scale then s = s or {}; s.scale = scale end
    return C.render(id, s, out or ("/tmp/chart-" .. id .. ".png"))
end

return {
    schema = schema,
    run = function(args)
        local action = args.action or (args.id and "render") or "list"
        if action == "list" then
            if args.json then
                local cjson = require("cjson")
                return cjson.encode(C.list(args.family))
            end
            return list_txt(args.family)
        elseif action == "spec" then
            if not args.id then error("charts: spec 需要 id", 0) end
            return spec_txt(args.id)
        elseif action == "svg" then
            if not args.id then error("charts: svg 需要 id", 0) end
            local spec = copy(args.spec)
            spec.anim = anim_on(args.anim)
            local s = C.svg(args.id, spec)
            if args.out then
                local f = assert(io.open(args.out, "wb")); f:write(s); f:close()
                return args.out
            end
            return s
        elseif action == "render" then
            if not args.id then error("charts: render 需要 id", 0) end
            local spec = copy(args.spec)
            if args.scale then spec.scale = args.scale end
            spec.anim = anim_on(args.anim)
            local p = render_one(args.id, spec, args.out, nil)
            local out = { p }
            -- 默认再落一份同名 SVG：PDF 式图文双份，浏览器打开就能看描线动效
            if args.svg ~= false then
                local svgp = p:gsub("%.[Pp][Nn][Gg]$", "") .. ".svg"
                local f = io.open(svgp, "wb")
                if f then f:write(C.svg(args.id, spec)); f:close(); out[#out + 1] = svgp end
            end
            out[#out + 1] = "（用 read 看图；改数据就带 spec={...}，字段见 action=spec）"
            return table.concat(out, "\n")
        elseif action == "gallery" then
            local dir = args.out or "/tmp/charts"
            os.execute("mkdir -p " .. q(dir))
            local ok, bad = 0, {}
            for _, c in ipairs(C.list()) do
                local path = dir .. "/" .. c.id .. ".png"
                local good, err = pcall(render_one, c.id, nil, path, args.scale)
                if good then ok = ok + 1 else bad[#bad + 1] = c.id .. ": " .. tostring(err) end
                if args.svg ~= false then -- 默认也落一份可动 SVG（浏览器里描线/淡入）
                    local f = io.open(dir .. "/" .. c.family .. "-" .. c.id .. ".svg", "wb")
                    if f then f:write(C.svg(c.id, { anim = anim_on(args.anim) })); f:close() end
                end
            end
            local msg = string.format("%s：成功 %d 张", dir, ok)
            if args.svg ~= false then msg = msg .. string.format("（+ %d 个 anim SVG）", ok) end
            if #bad > 0 then msg = msg .. "，失败 " .. #bad .. " 张：\n" .. table.concat(bad, "\n") end
            return msg
        end
        error("charts: 未知 action " .. tostring(action), 0)
    end,
}
