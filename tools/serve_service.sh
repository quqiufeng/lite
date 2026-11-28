#!/usr/bin/env bash
# serve_service.sh — 把常驻 serve（默认 0.0.0.0:8765）装成**开机自启**的 systemd 服务。
#
#   ./tools/serve_service.sh install [--user N] [--host H] [--port P] [--dir D]   写 unit + enable --now
#   ./tools/serve_service.sh uninstall                                           停 + disable + 删 unit
#   ./tools/serve_service.sh start|stop|restart|status|logs [N]                   转给 systemctl
#   ./tools/serve_service.sh dry-run                                             只打印 unit 文本
#
# 环境变量（与 serve_up.sh 同名同义）：
#   LITE_SERVE_HOST  默认 0.0.0.0（**不做鉴权**，暴露面全靠 host 控；只想本机就 127.0.0.1）
#   LITE_SERVE_PORT  默认 8765
#   LITE_SERVE_DIR   workdir + 日志 + pid + mem.lock，默认 $HOME/.local/share/lite-serve
#   LITE_SERVE_USER  unit 以谁的身份跑，默认 $SUDO_USER 再退当前用户
#   LITE_UNIT_DIR    unit 落盘目录，默认 /etc/systemd/system（测试用临时目录覆盖）
#
# 为什么要有这个文件：serve_up.sh 的 setsid 自监督**没有开机钩子**，盒子断电/重启后
# 8765 空着，只能等人 ssh 进去手动 start——而盒子恰恰常常没人守着。
#
# 为什么 unit 里跑的是 serve_up.sh --loop 而不是直接 `lite serve`：
#   /reboot 的 exit 75 要「立刻换进程」（0.3s），崩了要 5s 退避——这套语义在内层循环里，
#   交给 systemd 的 RestartSec 只能取一个值，还要把 75 和真崩溃混为一谈。外层 systemd 只
#   兜内层循环自己死掉（OOM、脚本 bug），两层职责不重叠：内层活着的期间 serve 崩/reboot
#   都不会让 systemd 看见。
#
# 反着改会踩的坑：
# 1) 别去掉 ExecStartPre 里删 pidfile 的那行。进程被 kill -9 后 serve.pid 是陈的，
#    开机后 pid 可能被别的进程复用，alive() 的 kill -0 就会假 true → 服务起不来还报「已在跑」。
# 2) systemd 接管后别用 `serve_up.sh stop`：它写 .stop 标记并按进程组 kill，systemd 的
#    Restart=always 立刻又拉起来，看着像「停不掉」。要停用 systemctl stop。
# 3) LITE_SERVE_DIR 每台机器只能有一个 serve 持有（mem.lock）；别和 TUI 实例共用目录。
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

UNIT_NAME="lite-serve.service"
UNIT_DIR="${LITE_UNIT_DIR:-/etc/systemd/system}"
HOST="${LITE_SERVE_HOST:-0.0.0.0}"
PORT="${LITE_SERVE_PORT:-8765}"
TARGET_USER="${LITE_SERVE_USER:-}"
SERVE_DIR="${LITE_SERVE_DIR:-}"
LITE_BIN="$ROOT/tools/lite"
LOOP="$ROOT/tools/serve_up.sh"

usage() { sed -n '2,31p' "$(readlink -f "$0")" | sed 's/^# \{0,1\}//'; }
die() { echo "lite-serve: $*" >&2; exit 1; }

pick_user() {
    [ -n "$TARGET_USER" ] && { echo "$TARGET_USER"; return; }
    if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then echo "$SUDO_USER"; return; fi
    id -un
}

user_home() {
    local h
    h="$(getent passwd "$1" 2>/dev/null | cut -d: -f6)"
    [ -n "$h" ] || h="/root"
    echo "$h"
}

unit_text() {
    local u="$1" home="$2" dir="$3"
    cat <<EOF
[Unit]
Description=lite serve (常驻 agent，0.0.0.0:$PORT)
Documentation=file://$ROOT/README.md
# 等网卡真有地址再绑 0.0.0.0，否则开机那一刻绑上去局域网连不上，要等下次重连。
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$u
Environment=HOME=$home
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LITE_SERVE_HOST=$HOST
Environment=LITE_SERVE_PORT=$PORT
Environment=LITE_SERVE_DIR=$dir
WorkingDirectory=$dir
# 陈 pidfile 会让 alive() 假 true（见头注释坑 1）；mkdir 给 --loop 的 cd 兜底。
ExecStartPre=-/bin/rm -f $dir/serve.pid $dir/.stop
ExecStartPre=-/bin/mkdir -p $dir
ExecStart=$LOOP --loop
StandardInput=null
# 内层循环自己不会因 serve 崩溃而退出（它自己重起），这里只兜循环本身死掉。
Restart=always
RestartSec=3
# serve 关停时要刷 mem.bin，给够时间再动刀（默认 90s 太久，20s 足够且重启快）。
TimeoutStopSec=20
# control-group：连同内层 lite serve 一起收，否则留下孤儿占着 :$PORT。
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
}

# 手动 setsid 起的那份会占着端口，systemd 起来只会报 address already in use。
free_port() {
    local pid
    pid="$(ss -lptnH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"
    [ -n "$pid" ] || return 0
    if systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then return 0; fi
    echo "lite-serve: 停掉占着 :$PORT 的手动进程 pid=$pid" >&2
    # 手动那份是 setsid 起的独立进程组：只 kill 单个 pid 会留下 lite serve 子进程。
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    sleep 1
}

need_root() {
    [ "$(id -u)" = 0 ] || die "要 root（写 $UNIT_DIR 并 systemctl enable）：sudo $0 ${1:-install}"
}

cmd="${1:-install}"; shift 2>/dev/null || true
while [ $# -gt 0 ]; do
    case "$1" in
        --user) TARGET_USER="${2:-}"; shift 2 ;;
        --host) HOST="${2:-}"; shift 2 ;;
        --port) PORT="${2:-}"; shift 2 ;;
        --dir)  SERVE_DIR="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数：$1（--user/--host/--port/--dir）" ;;
    esac
done
[ -n "$PORT" ] && [ -n "$HOST" ] || die "host/port 不能为空"

U="$(pick_user)"
HOME_DIR="$(user_home "$U")"
[ -n "$SERVE_DIR" ] || SERVE_DIR="$HOME_DIR/.local/share/lite-serve"

case "$cmd" in
dry-run)
    unit_text "$U" "$HOME_DIR" "$SERVE_DIR"
    ;;

install)
    [ -x "$LITE_BIN" ] || die "找不到可执行文件：$LITE_BIN（先 ./tools/build.sh 或装包）"
    [ -x "$LOOP" ] || die "找不到 $LOOP（serve 常驻靠它，包漏了 tools/serve_up.sh？）"
    id "$U" >/dev/null 2>&1 || die "用户不存在：$U"
    need_root install
    free_port
    # serve 持这里的 mem.lock，目录属主必须是跑它的那个用户。
    mkdir -p "$SERVE_DIR"
    chown "$U":"$(id -gn "$U")" "$SERVE_DIR" 2>/dev/null || true
    mkdir -p "$UNIT_DIR"
    unit_text "$U" "$HOME_DIR" "$SERVE_DIR" > "$UNIT_DIR/$UNIT_NAME"
    chmod 644 "$UNIT_DIR/$UNIT_NAME"
    systemctl daemon-reload
    systemctl enable --now "$UNIT_NAME" || die "enable --now 失败（journalctl -u $UNIT_NAME -n 40）"
    echo "已装 $UNIT_DIR/$UNIT_NAME → $U@$HOME_DIR，监听 $HOST:$PORT，dir $SERVE_DIR"

    # 起来不等于能用：等端口，再探一次活才算数（probe 3 次采样，单次不算判决）。
    for _ in $(seq 1 30); do
        if curl -fsS -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
            rc=0
            LITE_SERVE_PORT="$PORT" "$LITE_BIN" serve --probe "127.0.0.1:$PORT" >/dev/null 2>&1 || rc=$?
            case "$rc" in
                0) echo "自检 OK: :$PORT 在应答，probe=wake（idle）"; exit 0 ;;
                3) echo "自检 OK: :$PORT 在应答，probe=busy（正忙，也算活着）"; exit 0 ;;
                *) echo "自检警告: /health 通了但 probe exit=$rc"; exit 0 ;;
            esac
        fi
        sleep 0.5
    done
    die "服务起了但 :$PORT 没应答（journalctl -u $UNIT_NAME -n 40）"
    ;;

uninstall)
    need_root uninstall
    systemctl disable --now "$UNIT_NAME" 2>/dev/null || true
    rm -f "$UNIT_DIR/$UNIT_NAME"
    systemctl daemon-reload
    echo "已卸载 $UNIT_NAME（$SERVE_DIR 里的会话/记忆保留）"
    ;;

start|stop|restart|status)
    need_root "$cmd"
    systemctl "$cmd" "$UNIT_NAME"
    [ "$cmd" = status ] || { systemctl --no-pager -l status "$UNIT_NAME" | head -10; exit 0; }
    systemctl --no-pager -l status "$UNIT_NAME" | head -12
    ;;

logs)
    need_root logs
    journalctl -u "$UNIT_NAME" -n "${1:-40}" --no-pager
    ;;

*)
    usage; exit 2 ;;
esac
