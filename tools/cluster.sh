#!/usr/bin/env bash
# lite 集群派活：一份 TSV → 并行 ssh（或本机）→ 每任务一份 JSONL/rc/sec → 汇总表。
#
# 「槽」= 一台机器上的一个 work dir。同一个目录里的两个 lite 会抢 mem.lock
# （第二个以退出码 3 拒绝启动），所以并发度 = 机器数 × 每台目录数，不是进程数。
#
#   tools/cluster.sh tasks.tsv                       # 执行
#   tools/cluster.sh --dry-run tasks.tsv             # 只打命令，不动一行
#   tools/cluster.sh --jobs 4 --out out tasks.tsv
#
# TSV 每行三列（# 开头与空行跳过）：
#   <box>\t<dir>\t<prompt>[\t<task 名>]
# box：ssh 目标（host / user@host / ~/.ssh/config 里的别名）；
#      `local` 或 `-` 表示在 master 本机跑（不 ssh，用于本机多槽并行）。
# task：缺省按出现顺序 t1、t2…；决定 out/<task>.{jsonl,rc,sec} 文件名。
#
# 退出码：0 全部 ok；1 有任务失败（rc≠0 或 JSONL 里没有 done ok:true）；2 用法错误。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LITE="${LITE_CLUSTER_LITE:-lite}"     # 远端 PATH 上的 lite
SSH_OPTS="${LITE_CLUSTER_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30}"

OUT="cluster-out"
JOBS=0
TIMEOUT=1800
DRY=0
MKDIR=1
TSV=""

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --no-mkdir) MKDIR=0; shift ;;
        --jobs|-j) JOBS="${2:?--jobs needs N}"; shift 2 ;;
        --out|-o) OUT="${2:?--out needs DIR}"; shift 2 ;;
        --timeout) TIMEOUT="${2:?--timeout needs SEC}"; shift 2 ;;
        -h|--help) usage ;;
        -*) echo "cluster: unknown option $1" >&2; usage ;;
        *) TSV="$1"; shift ;;
    esac
done

[ -n "$TSV" ] || { echo "cluster: missing tasks.tsv" >&2; usage; }
[ -f "$TSV" ] || { echo "cluster: no such file: $TSV" >&2; exit 2; }

# 远端路径引用：`~/x` 必须留给远端 shell 展开（%q 会把 ~ 转义掉 → 目录不存在）。
qdir() {
    case "$1" in
        "~/"*) printf '"$HOME"/%q' "${1#\~/}" ;;
        "~")   printf '"$HOME"' ;;
        /*)    printf '%q' "$1" ;;
        *)     printf '"$HOME"/%q' "$1" ;;   # 相对路径视为远端 $HOME 下
    esac
}

# 百分号转义：任务名只留 [A-Za-z0-9._-]，其余变 _，避免拼出子目录。
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-60; }

mkdir -p "$OUT"
MANIFEST="$OUT/tasks.tsv"
: >"$MANIFEST"

n=0
while IFS=$'\t' read -r box dir prompt name; do
    case "$box" in ''|\#*) continue ;; esac
    [ -n "${dir:-}" ] || { echo "cluster: line $((n + 1)): missing dir" >&2; exit 2; }
    [ -n "${prompt:-}" ] || { echo "cluster: line $((n + 1)): missing prompt" >&2; exit 2; }
    n=$((n + 1))
    [ -n "${name:-}" ] || name="t$n"
    printf '%s\t%s\t%s\t%s\n' "$(slug "$name")" "$box" "$dir" "$prompt" >>"$MANIFEST"
done <"$TSV"

TOTAL="$(wc -l <"$MANIFEST" | tr -d ' ')"
[ "$TOTAL" -gt 0 ] || { echo "cluster: $TSV 里没有任务行" >&2; exit 2; }
[ "$JOBS" -gt 0 ] 2>/dev/null || JOBS="$TOTAL"

echo "cluster: $TOTAL task(s) | jobs=$JOBS | timeout=${TIMEOUT}s | out=$OUT"

# 一个任务 = 一条 ssh（或一条本地 bash）；prompt 用 base64 过 ssh，避开引号地狱。
run_task() {
    local task="$1" box="$2" dir="$3" prompt="$4"
    local jsonl="$OUT/$task.jsonl" err="$OUT/$task.err"
    local t0 t1 rc
    t0="$(date +%s.%N)"
    set +e
    if [ "$box" = "local" ] || [ "$box" = "-" ]; then
        ( [ "$MKDIR" = 1 ] && mkdir -p "$dir"
          cd "$dir" && timeout "$TIMEOUT" "$LITE" --once --json "$prompt" ) >"$jsonl" 2>"$err"
        rc=$?
    else
        local b64 qdir remote
        b64="$(printf '%s' "$prompt" | base64 -w0)"
        qd="$(qdir "$dir")"
        # shellcheck disable=SC2016  # 远端展开：$(...) 与 $b64 是有意留给远端 shell 的
        local pre=""
        [ "$MKDIR" = 1 ] && pre="mkdir -p $qd && "
        remote="${pre}cd $qd && timeout $TIMEOUT $LITE --once --json \"\$(printf %s $b64 | base64 -d)\""
        # shellcheck disable=SC2086  # SSH_OPTS 有意分词
        ssh $SSH_OPTS "$box" "$remote" >"$jsonl" 2>"$err"
        rc=$?
    fi
    set -e
    t1="$(date +%s.%N)"
    printf '%s\n' "$rc" >"$OUT/$task.rc"
    awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f\n", b-a}' >"$OUT/$task.sec"
    # 失败的一眼可见：rc 与 stderr 直接在终端留一行（进度感，不用等汇总表）。
    if [ "$rc" -ne 0 ]; then
        echo "  [$task] rc=$rc  $(head -c 160 "$err" 2>/dev/null | tr '\n' ' ')" >&2
    fi
}

if [ "$DRY" = 1 ]; then
    echo "--- dry-run: 下面是要执行的命令（不动磁盘、不发 ssh）"
    while IFS=$'\t' read -r task box dir prompt; do
        b64="$(printf '%s' "$prompt" | base64 -w0)"
        if [ "$box" = "local" ] || [ "$box" = "-" ]; then
            printf '[%s] local  cd %s && timeout %s %s --once --json <prompt %s chars>\n' \
                "$task" "$dir" "$TIMEOUT" "$LITE" "${#prompt}"
        else
            printf '[%s] %s  cd %s && timeout %s %s --once --json "$(echo %s | base64 -d)"\n' \
                "$task" "$box" "$(qdir "$dir")" "$TIMEOUT" "$LITE" "$b64"
        fi
    done <"$MANIFEST"
    exit 0
fi

# 并发跑：jobs 上限靠 `jobs -rp | wc -l` 自旋，不引入 xargs/parallel。
running=0
while IFS=$'\t' read -r task box dir prompt; do
    run_task "$task" "$box" "$dir" "$prompt" &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then
        wait -n 2>/dev/null || true
        running=$((running - 1))
    fi
done <"$MANIFEST"
wait

# 汇总：JSONL 解析交给 lua（content 里可能带 \" 与 \/ 转义，shell 切不干净）。
LITE_CLUSTER_OUT="$OUT" LITE_CLUSTER_TOTAL="$TOTAL" \
    "$ROOT/tools/lite-lua" -e '
local cjson = require("cjson")
local dir, total = os.getenv("LITE_CLUSTER_OUT"), tonumber(os.getenv("LITE_CLUSTER_TOTAL")) or 0
local function slurp(p)
    local f = io.open(p, "r"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end
-- 按 UTF-8 字符截断到 n 个「显示列」（CJK 记 2），不切断多字节序列。
local function trim(s, cols)
    local out, w, i = {}, 0, 1
    while i <= #s do
        local b = s:byte(i)
        local len = b < 0x80 and 1 or (b >= 0xF0 and 4 or (b >= 0xE0 and 3 or 2))
        local chunk = s:sub(i, i + len - 1)
        local dw = len > 1 and 2 or 1
        if w + dw > cols then return table.concat(out) .. "…" end
        out[#out + 1] = chunk; w = w + dw; i = i + len
    end
    return table.concat(out)
end
local function width(s)
    local w, i = 0, 1
    while i <= #s do
        local b = s:byte(i)
        local len = b < 0x80 and 1 or (b >= 0xF0 and 4 or (b >= 0xE0 and 3 or 2))
        w = w + (len > 1 and 2 or 1); i = i + len
    end
    return w
end

local manifest = assert(slurp(dir .. "/tasks.tsv"), "cluster: tasks.tsv lost")
local rows = {}
for line in manifest:gmatch("[^\n]+") do
    local task, box, wd = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t")
    if task then
        local rc = tonumber(((slurp(dir .. "/" .. task .. ".rc") or "?"):gsub("%s", ""))) or -1
        local sec = tonumber(((slurp(dir .. "/" .. task .. ".sec") or "?"):gsub("%s", ""))) or 0
        local ok, said, why, tools, comp = false, "", nil, 0, 0
        local body = slurp(dir .. "/" .. task .. ".jsonl") or ""
        for l in body:gmatch("[^\n]+") do
            local okj, ev = pcall(cjson.decode, l)
            if okj and type(ev) == "table" then
                if ev.type == "assistant" and type(ev.content) == "string" then
                    said = ev.content                      -- 只留最后一条，避免流式 delta 刷屏
                elseif ev.type == "tool_start" then
                    tools = tools + 1
                elseif ev.type == "usage" then
                    comp = comp + (tonumber(ev.completion) or 0)
                elseif ev.type == "done" then
                    ok = ev.ok == true
                    if ev.error then why = tostring(ev.error) end
                elseif ev.type == "error" then
                    ok = false; why = tostring(ev.message or ev.code or "error")
                end
            end
        end
        if rc ~= 0 and not why then
            local e = slurp(dir .. "/" .. task .. ".err") or ""
            why = e ~= "" and (e:gsub("%s+$", ""):sub(1, 120)) or ("exit " .. rc)
        end
        rows[#rows + 1] = { task = task, box = box, wd = wd, rc = rc, sec = sec,
                            ok = ok, said = said, why = why, tools = tools, comp = comp }
    end
end

local w = { task = 4, box = 3 }
for _, r in ipairs(rows) do
    if width(r.task) > w.task then w.task = width(r.task) end
    if width(r.box) > w.box then w.box = width(r.box) end
end
local function pad(s, n) return s .. string.rep(" ", n - width(s)) end

io.write("\n", pad("TASK", w.task), "  ", pad("BOX", w.box), "  RC  OK  SEC   TOOLS  SAYS\n")
io.write(string.rep("-", w.task + w.box + 26), "\n")
local pass, wall, tok = 0, 0, 0
for _, r in ipairs(rows) do
    if r.ok and r.rc == 0 then pass = pass + 1 end
    if r.sec > wall then wall = r.sec end
    tok = tok + r.comp
    local says = r.ok and trim((r.said:gsub("%s+", " ")), 64) or ("!! " .. trim(r.why or "failed", 60))
    io.write(pad(r.task, w.task), "  ", pad(r.box, w.box), "  ",
        string.format("%-2d  %-2s  %4.1f  %5d  %s\n",
            r.rc, (r.ok and r.rc == 0) and "y" or "n", r.sec, r.tools, says))
end
io.write(string.rep("-", w.task + w.box + 26), "\n")
io.write(string.format("%d/%d ok | wall %.1fs | completion %d tok | logs %s/<task>.jsonl\n",
    pass, total, wall, tok, dir))
os.exit(pass == total and 0 or 1)
'
