#!/usr/bin/env bash
# serve_up.sh — 把 lite 作为常驻 serve 看护起来，默认对外 0.0.0.0:8765（局域网调试用）。
#
#   ./tools/serve_up.sh start     起一个后台 supervise 循环（`/reboot` 与崩溃都能自愈）
#   ./tools/serve_up.sh stop      停（写 .stop 标记再按 pid 收，不碰别的 lite 进程）
#   ./tools/serve_up.sh restart
#   ./tools/serve_up.sh status    pid + 探活结论 + 端口 + 最近日志
#   ./tools/serve_up.sh logs [N]  跟踪日志
#
# 环境变量：
#   LITE_SERVE_HOST  默认 0.0.0.0（**不做鉴权**，暴露面全靠 host 控；只想本机就 127.0.0.1）
#   LITE_SERVE_PORT  默认 8765
#   LITE_SERVE_DIR   workdir + 日志 + pid + .stop，默认 $HOME/.local/share/lite-serve
#                    （serve 持该目录的 mem.lock，所以别跟别的实例共用目录）
#   LITE_BIN         lite 可执行文件，默认 `command -v lite` 再退 $HOME/.local/bin/lite
#   LITE_SERVE_BACKOFF  非 reboot 退出的重起间隔秒，默认 5
#
# 为什么不用 systemd：AGENTS.md 禁 systemd --user；这里用 setsid + 自监督循环，等价效果。
# 为什么不 `pkill -f lite`：会误杀 TUI/别人实例，只按 pidfile 里的进程组收。
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

HOST="${LITE_SERVE_HOST:-0.0.0.0}"
PORT="${LITE_SERVE_PORT:-8765}"
DIR="${LITE_SERVE_DIR:-$HOME/.local/share/lite-serve}"
LOG="$DIR/serve.log"
PIDF="$DIR/serve.pid"
STOPF="$DIR/.stop"
BACKOFF="${LITE_SERVE_BACKOFF:-5}"

lite_bin() {
    if [ -n "${LITE_BIN:-}" ]; then echo "$LITE_BIN"; return; fi
    command -v lite 2>/dev/null && return
    echo "$HOME/.local/bin/lite"
}

usage() { sed -n '2,28p' "$(readlink -f "$0")" | sed 's/^# \{0,1\}//'; }

alive() {
    [ -f "$PIDF" ] || return 1
    local pid; pid="$(cat "$PIDF" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

port_busy() {
    # 只看「有没有人已经在听这个端口」，不判断是谁（免得依赖 ss/netstat 的差异）
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && { exec 3<&- 3>&-; return 0; }
    return 1
}

supervise_loop() {
    cd "$DIR" || exit 1
    export PATH="$HOME/.local/bin:$PATH"
    local bin; bin="$(lite_bin)"
    local pid self=$$
    echo "$self" > "$PIDF"
    # 父进程（setsid 前的 start）退出后这里继续；Ctrl+C 之类不该带走看护循环
    trap '' INT HUP
    while :; do
        [ -f "$STOPF" ] && { echo "[$(date '+%F %T')] stop 标记 → 退出看护"; break; }
        echo "[$(date '+%F %T')] serve 起 host=$HOST port=$PORT bin=$bin"
        LITE_SUPERVISED=1 "$bin" serve --host "$HOST" --port "$PORT" >>"$LOG" 2>&1 &
        pid=$!
        wait "$pid"; local rc=$?
        echo "[$(date '+%F %T')] serve 退 rc=$rc"
        [ -f "$STOPF" ] && break
        # rc=75 是 /reboot（见 lua/main.lua 的 LITE_SUPERVISED 分支）→ 立刻换新进程
        if [ "$rc" -eq 75 ]; then sleep 0.3; else sleep "$BACKOFF"; fi
    done
    rm -f "$PIDF" "$STOPF"
}

cmd_start() {
    mkdir -p "$DIR"
    if alive; then echo "已在跑: pid $(cat "$PIDF")  $HOST:$PORT  (log $LOG)"; return 0; fi
    rm -f "$STOPF"
    if port_busy; then
        echo "端口 $PORT 已被占用，先停掉占用者或换 LITE_SERVE_PORT" >&2
        return 1
    fi
    : > "$LOG"
    setsid nohup "$(readlink -f "$0")" --loop >>"$LOG" 2>&1 &
    local i=0
    while [ "$i" -lt 60 ]; do
        if alive && port_busy; then
            echo "已起: pid $(cat "$PIDF")  http://$HOST:$PORT  (log $LOG)"
            echo "探活: $0 status   停: $0 stop"
            return 0
        fi
        sleep 0.5; i=$((i + 1))
    done
    echo "30s 内没起来，看日志: $LOG" >&2
    tail -20 "$LOG" >&2
    return 1
}

cmd_stop() {
    if ! alive; then
        echo "没在跑（pidfile ${PIDF}）"
        rm -f "$PIDF"
        return 0
    fi
    local pid; pid="$(cat "$PIDF")"
    touch "$STOPF"
    # 看护循环在 wait 里，子进程不会自己退 → 先收整组（setsid 给了独立进程组）
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    local i=0
    while [ "$i" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then
        echo "还在退，补一刀 KILL（pid $pid）"
        kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
        sleep 0.5
    fi
    rm -f "$PIDF" "$STOPF"
    echo "已停"
}

cmd_status() {
    echo "dir   $DIR"
    echo "addr  $HOST:$PORT   log $LOG"
    if alive; then echo "pid   $(cat "$PIDF")  (supervise 循环)"; else echo "pid   —（没在跑）"; fi
    local bin; bin="$(lite_bin)"
    if port_busy; then
        echo "port  在听"
        "$bin" serve --probe "127.0.0.1:$PORT" 2>&1 | sed 's/^/probe /'
        echo "probe exit=$?（0=wake 3=busy 4=unreachable 5=unstable）"
        curl -s --max-time 3 "http://127.0.0.1:$PORT/health" 2>/dev/null | head -c 300 | sed 's/^/health /'; echo
    else
        echo "port  没人听"
    fi
    [ -f "$LOG" ] && { echo "--- log tail ---"; tail -8 "$LOG"; }
}

case "${1:-status}" in
    --loop) supervise_loop ;;
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_stop; sleep 1; cmd_start ;;
    status)  cmd_status ;;
    logs)    tail -n "${2:-40}" -f "$LOG" ;;
    -h|--help|help) usage ;;
    *) echo "未知动作: $1" >&2; usage >&2; exit 2 ;;
esac
