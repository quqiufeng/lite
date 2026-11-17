# pdf.md —— `demo.txt` 怎么变成 `assets/lite-proposal-v8.pdf`

一句话：**`demo.txt` 是内容（提纲），lite 把它编译成 14 页 16:9 幻灯片 PDF；中间不碰 Chrome、不碰 PowerPoint，也装任何第三方包。**

目录现状：

| 路径 | 是什么 |
|---|---|
| `demo.txt` | 提纲源文（2.3 KB，四章十三条，`test.txt` 改名而来） |
| `assets/deck-v8.lua` | v8 的生成脚本（唯一的「怎么排版」真相） |
| `assets/lite-proposal-v8.pdf` | 成品：14 页 / 960×540 pt / 1.1 MB（1144 KB）/ 矢量文字可选中 |
| `assets/lite-proposal-v8-01…14.png` | 逐页预览 @2x，验收和截图 diff 用 |
| `assets/lite-proposal-v8-chart-05.png`、`-06.png` | 第 5、6 页的图表原图（charts 引擎产出） |
| `pdf.md` | 本文（仓库根目录） |

---

## 1. 用 lite 使用 `demo.txt`（最短路径）

`demo.txt` 是给人看的分点提纲，不是排版格式。lite 的做法是：**读它 → 决定每页讲什么 → 写一份 spec → 出图**。

三条命令，按需选一条：

```bash
# ① 单轮交给 agent：它自己读提纲、写 spec、出 PDF、逐页看图修
./tools/run.sh --once "读 demo.txt，用 bizdeck 模板做 16:9 幻灯片 PDF：assets/demo.pdf，moon 主题，
每页给我一句话要点；出完读一遍 -01.png…-NN.png，有溢出或排版问题自己改到干净"

# ② 直接用现成脚本重出 v8（改文案/改配色就改这个文件）
./tools/lite-lua assets/deck-v8.lua

# ③ TUI 里迭代（推荐，改一句看一次）
./tools/run.sh --tui          # 然后说「把第 9 页插件表换成两张对比表」
```

产物固定三种，同目录落盘：`xxx.pdf` + `xxx-01.png…`（逐页预览）+ `xxx-chart-NN.png`（图表原图）。

要点：**不给数据它会拒绝出图**（`bizdeck` 对 `chart.spec.rows` 是硬报错，不让卡片 demo 数据漏进正文），
所以 `demo.txt` 里的数字要么自己写、要么先去 `./tools/run.sh --once` 让它查证再写。

---

## 2. 管线：五层，零浏览器

```
demo.txt（提纲）
   │  人／模型把提纲拆成"每页一个 kind"        ← assets/deck-v8.lua 的 spec
   ▼
spec（Lua 表：brand/date/slides[]）
   │  helper/bizdeck.lua: build()  每页 kind → 一段 HTML
   ▼
HTML + 内联 CSS（litehtml 子集：table 布局、绝对定位、var() 令牌）
   │  ① chart 页先出图：lua/charts → SVG → cairo+librsvg → PNG → <img> 嵌回页面
   │  ② helper/md2png.lua: theme_css() 展开 :root 令牌
   ▼
ffi 调 build/liblite_html.so（litehtml + cairo）
   ├─ cairo_pdf_surface_create → 矢量 PDF（文字可选中/可搜索，每页 save/restore 独立缩放）
   └─ cairo image surface      → 逐页 PNG @2x（验收用）
   ▼
assets/lite-proposal-v8.pdf + 14 张预览 PNG
```

| 层 | 实现 | 职责 |
|---|---|---|
| 内容 | `assets/deck-v8.lua` | 14 个 slide 表，字段名以 `helper/bizdeck.lua` 的 `slides.<kind>()` 为准 |
| 模板 | `helper/bizdeck.lua` | 11 种页型 + CSS + 字号等比缩放 + 溢出探针 + 报告 |
| 图表 | `lua/charts/`（`init.lua` 注册表、`pen.lua` 画、`types/*` 卡） | `C.render(id, spec, png)`：SVG → cairo+librsvg → PNG |
| 渲染 | `helper/md2png.lua` → `build/liblite_html.so`（`src/html/render.cpp`） | HTML/CSS → cairo PDF / PNG |
| 主题 | `lua/gui/theme.lua` | 只换 `:root` 令牌，版式不动（moon/light/bamboo/china/indigo/cinnabar/dark） |

**为什么不用浏览器**：litehtml 是自带解析器 + cairo 绘制，`.so` 几十 KB 级、启动毫秒级；
拉 Chrome/CEF 只为出一张图，是把「一分钟的任务」变成「一个进程池的任务」。代价是 CSS 子集受限
（见 §6），换来的是 `bash` 里一行命令就能出稿。

---

## 3. v8 的 14 页结构

| 页 | kind | 内容 | 配图 |
|---|---|---|---|
| 1 | `cover` | 标题「原生 AI Agent：完全不一样的思路」+ 副标题 + 项目组 | — |
| 2 | `agenda` | 四个判断，一条主线 | — |
| 3 | `bullets` | 01 能力上限：规则只划安全边界 | — |
| 4 | `compare` | 左「平台式 Agent」↔ 右「原生 Agent（lite）」 | — |
| 5 | `chart` | 前缀缓存： waffle 94 / 6，图右文左 | `chart-05.png` |
| 6 | `chart` | 体量：6 段横向柱（C 20570 → gui 969） | `chart-06.png` |
| 7 | `bullets` | 机制一：把自己当成可随时改的程序 | — |
| 8 | `bullets` | 机制二：它看得见自己，所以学得会别的软件 | — |
| 9 | `table` | 19 个插件，覆盖「真有人要干」的活 | — |
| 10 | `bullets` | 03 生态与治理的新变化 | — |
| 11 | `timeline` | 落地：先集成 → 再交互 → 最后沉淀 | — |
| 12 | `bullets` | 04 Agent 对模型：手、眼睛、训练场 | — |
| 13 | `quote` | 「缺能力先造，别降级。」 | — |
| 14 | `end` | 「规则应当是护栏，不是天花板」 | — |

节奏是有意的：`封面 → 目录 → 论点 → 对照 → 两个数字 → 机制 → 清单 → 外部趋势 → 路径 → 意义 → 金句 → 收尾`，
**每三页必有一页非纯文字**（对比 / 图 / 表 / 时间轴），投影时不至于连着念稿。

---

## 4. 关键机制

### 4.1 定高页 + 溢出探针（最容易踩）
每页 `.slide` 写死 `height:720px`（16:9），内容超了**会被静默裁掉**，肉眼在缩略图上看不出来。
所以 `bizdeck` 每页多渲一张**探针图**：同一份 body，换成 `height:auto` 的 CSS，宽不变、scale=1，
量出来的高度才是真实内容高；`>720` 就报

```
⚠ 溢出被裁（缩字数 / 拆页）: 第 5 页超出 118px（内容 838 / 页高 720）
```

注意探针必须是 `height:auto` 那份——固定高页的探针量到的恒等于页高，等于没测（`helper/pdf.lua` 坑 1）。

### 4.2 没有 flex/grid，多栏一律 `<table>`
litehtml 不支持 flex/grid。KPI 卡、左右对比、时间轴、页脚左右对齐，全是 `<table>` + `table-layout:fixed` +
`<colgroup>` 给像素宽。表格数值列用 `td.n` 统一右对齐，否则「20570」和「969」会参差。

### 4.3 字号随页宽等比缩放
CSS 里的 `@N` 表示「1280 宽下的 N px」，出页时乘 `k = w/1280`。这样 `16:9 / 4:3 / a4 / a4l` 四个尺寸
用同一套样式，不会 4:3 挤成一团。正文 19px（会议室距离），比 trending 长图的 16px 大一档。

### 4.4 图表页：先出 PNG，再当 `<img>` 嵌进页
`chart` 页的图不是 litehtml 画的，是 `charts` 引擎先出 PNG（`<stem>-chart-NN.png`），
再由 `md2png.set_base_dir(dir)` 按 PDF 所在目录解析 `<img src>` 贴进页面，按页高缩放到 `height`。
三个**静默错**的防线写在 `helper/bizdeck.lua` 里：

1. 卡片自带的 `title/note/unit/spanLabel` 会继承进正文（比如「雨水桶，一个星期」），没给就清空；
2. 不给 `rows/values/flows/…` 会**静默用卡片 demo 的示例数据** → 图对不上正文，所以缺数据直接报错；
3. 演示单位会硬套（「68 h」）→ `parts.lua:piv` 改成 `spec.unit` 可传 `''` 只打占比。

还有一个**不报错的坑**：`<img src>` 只能写文件名。litehtml 把相对 src 拼在 `base_dir` 之后
（`src/html/imgcache.cpp:resolve`），而 `M.run` 已经 `set_base_dir(PDF 目录)`；写成 `assets/x-chart-05.png`
会被拼成 `assets/assets/…`，找不到图就画成**虚线占位框**——页面上看着像「图还没画」，其实是路径错。
`bizdeck.img_tag()` 现在只取 `path:match("([^/]+)$")`（见 §9 第 8 条）。

### 4.5 矢量 PDF 怎么来的
C 侧用 `cairo_pdf_surface_create` 逐页 `save / restore / show_page`，px→pt 系数 0.75
（1280×720 px → 960×540 pt）。每页必须 `cairo_save/restore` 包住 `cairo_scale`，否则缩放会跨页累乘。
好处：文字可选中、可搜索、1.1 MB 装 14 页；位图 PDF 要 10 倍体积且搜不到字。

### 4.6 颜色只有一个来源
CSS 里不写任何 hex，只写 `var(--ink)` / `var(--accent)`，由 `lua/gui/theme.lua:M.css` 展开。
换 `theme` 就是换 `:root`，版式一行不动 —— 和 trending 图卡是同一套主题引擎。

---

## 5. 从提纲到 v8 的过程

1. **先证道路**：`pdf({path="deck.md", mode="html", size="16:9"})` —— Markdown + `---` 分页，矢量但版式弱
   （标题/表格/引用能看，不能做封面、双栏、大数字）。
2. **探 litehtml 边界**：写探针页验证「table 能不能当栅格」「绝对定位能不能贴页脚」「var() 能不能展开」
   「中文字体装没装」。结论决定模板只能用表格布版。
3. **搭模板**：`helper/bizdeck.lua` 出 11 种页型（cover/section/agenda/kpi/bullets/compare/timeline/table/chart/quote/end），
   先跑自带 demo 的 9 页，确认字号、留白、页脚。
4. **进真内容**：把 `demo.txt` 的四章拆成 14 页节奏，写 `assets/deck-v8.lua`；每轮改完重出，
   **逐页 `read` 预览 PNG**，专看三件事：溢出、页脚被压、中文行头标点。
5. **图表页接引擎**：第 5 页要「94% 命中」，从饼图换到 `waffle`（100 格里 94 格），第 6 页用 `bar`。
   为此改了 `lua/charts/types/parts.lua`（`spec.unit` 可关单位）和 `bars.lua`（空标签不画、瀑布图
   `startLabel/endLabel/spanLabel` 可覆盖），否则演示口径漏进正文。
6. **收口**：溢出探针清零 → `pdfinfo` 确认 14 页 / 960×540 pt → 逐页图过一遍 → 交付。

v8 是这条环滚到「探针无告警 + 每页都看一眼」的版本，不是一次成稿。

---

## 6. 验收（改完怎么签收）

```bash
./tools/lite-lua assets/deck-v8.lua      # 出 PDF + 预览 + 溢出报告
pdfinfo assets/lite-proposal-v8.pdf | head   # Pages: 14 / Page size: 960 x 540 pts
pdftotext -f 1 -l 1 assets/lite-proposal-v8.pdf - | head   # 能抽出文字 = 矢量，不是截图拼的
```

输出最后一行是 `⚠ 溢出被裁 …` 列表：**空才算过**。然后 `read assets/lite-proposal-v8-05.png`
这类逐页看图——探针只能量高度，量不出「两个元素压在一起」。

## 7. 改版入口

| 想改什么 | 改哪里 |
|---|---|
| 文案 / 页序 / 加一页 | `assets/deck-v8.lua` 的 `spec.slides`（字段见 `helper/bizdeck.lua` 头注释） |
| 配色 | `theme = "moon|light|bamboo|china|indigo|cinnabar|dark"` |
| 尺寸 | `size = "16:9|4:3|a4|a4l"` |
| 图表类型 / 数据 | `chart = { id = "…", spec = { rows = {…} } }`，id 见 `charts({action="list"})` |
| 新页型 | `helper/bizdeck.lua` 加 `slides.<kind>()` + CSS，再在 `M.build` 登记 |

## 8. 坑（改之前先读，都踩过）

1. litehtml 无 flex/grid → 多栏用 `<table>`；数值列 `td.n` 右对齐。
2. 溢出探针要 `height:auto` 那份，固定高的量不出真实内容高。
3. 中文没有 kinsoku：行头可能出现「，」。长句自己拆成 `t=` 标题 + `d=` 说明。
4. 字号/间距必须乘 `k = w/1280`，否则 4:3 和 A4 挤成一团。
5. 页脚用 `position:absolute` 贴底（`.slide` 是 `position:relative`）；放流里会随内容长短跳动。
6. `body` 默认 margin 8px 必须清零，否则整页留白全错。
7. 色值只写 `var(--token)`，加色去 `lua/gui/theme.lua:M.css` 加令牌，别在本文件写 hex。
8. `<img src>` 只写文件名（`bizdeck.img_tag` 已取 basename）：相对路径会拼在 `base_dir` 之后再
   被拼一次，图变虚线占位框且**不报错**。
