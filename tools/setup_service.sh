#!/usr/bin/env bash
# setup_service.sh — 把 `lite setup`（API Key 初始化页）装成**开机自启**的常驻服务。
#
#   ./tools/setup_service.sh install [--user N] [--host H] [--port P]   写 unit + enable --now
#   ./tools/setup_service.sh uninstall                                  停 + disable + 删 unit
#   ./tools/setup_service.sh start|stop|restart|status|logs [N]
#   ./tools/setup_service.sh dry-run                                    只打印 unit 文本（不碰系统）
#
# 环境变量：
#   LITE_SETUP_HOST      默认 0.0.0.0（**无鉴权**，谁都能改 key；只想本机就 127.0.0.1）
#   LITE_SETUP_PORT      默认 8080
#   LITE_SETUP_USER      unit 以谁的身份跑 —— 决定读写谁的 ~/.config/lite/.env
#                        默认：有 $SUDO_USER 就用它，否则当前用户（盒子 ssh root 进来 = root）
#   LITE_SETUP_UNIT_DIR  unit 落盘目录，默认 /etc/systemd/system（测试用临时目录覆盖）
#
# 为什么用 systemd **system** 服务：AGENTS.md 禁的是 `systemd --user`（要登录会话才活，
# 盒子重启没人登录就永远不起）。system 级 unit 开机即起、崩溃自动重启，正是「默认自启」。
# serve_up.sh 那套 setsid 自监督没有开机钩子，只适合手动拉起的临时 serve。
#
# 安全提醒：/api/key 不鉴权。绑 0.0.0.0 等于**局域网内谁都能覆盖 API Key**（含花你的钱）。
# 初始化完想收紧：`LITE_SETUP_HOST=127.0.0.1 ./tools/setup_service.sh install` 重装一次。
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

UNIT_NAME="lite-setup.service"
UNIT_DIR="${LITE_SETUP_UNIT_DIR:-/etc/systemd/system}"
PORT="${LITE_SETUP_PORT:-8080}"
HOST="${LITE_SETUP_HOST:-0.0.0.0}"
TARGET_USER="${LITE_SETUP_USER:-}"
LITE_BIN="$ROOT/tools/lite"

usage() { sed -n '2,23p' "$(readlink -f "$0")" | sed 's/^# \{0,1\}//'; }
die() { echo "lite-setup: $*" >&2; exit 1; }

# 默认身份：sudo 来的用原用户（key 要写进他的 home），否则就是当前用户。
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
    local u="$1" home="$2"
    cat <<EOF
[Unit]
Description=lite setup web (DeepSeek API Key 初始化页)
Documentation=file://$ROOT/README.md
# network-online 而不是 network：开机那几秒 8080 抢不到网卡也能起，
# 但要等网卡有地址再绑 0.0.0.0，否则局域网访问会连不上到下次重连。
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$u
Environment=HOME=$home
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=$home
ExecStart=$LITE_BIN setup --host $HOST --port $PORT
# 常驻页不需要 stdin；崩了 3 秒后重起，/reboot 与 kill 都算正常退出也拉回来。
StandardInput=null
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

# 手动 setsid 起的那份会占着端口，systemd 起不来只能是 "address already in use"。
free_port() {
    local pid
    pid="$(ss -lptnH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"
    [ -n "$pid" ] || return 0
    # 已经是自己的 unit 起的就别动（restart 由 systemctl 负责）。
    if systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then return 0; fi
    echo "lite-setup: 停掉占着 :$PORT 的手动进程 pid=$pid" >&2
    kill "$pid" 2>/dev/null || true
    sleep 0.5
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
        -h|--help) usage; exit 0 ;;
        *) die "未知参数：$1（--user/--host/--port）" ;;
    esac
done
[ -n "$PORT" ] && [ -n "$HOST" ] || die "host/port 不能为空"

case "$cmd" in
dry-run)
    unit_text "$(pick_user)" "$(user_home "$(pick_user)")"
    ;;

install)
    [ -x "$LITE_BIN" ] || die "找不到可执行文件：$LITE_BIN（先 ./tools/build.sh 或装包）"
    u="$(pick_user)"
    id "$u" >/dev/null 2>&1 || die "用户不存在：$u"
    need_root install
    free_port
    mkdir -p "$UNIT_DIR"
    unit_text "$u" "$(user_home "$u")" > "$UNIT_DIR/$UNIT_NAME"
    chmod 644 "$UNIT_DIR/$UNIT_NAME"
    systemctl daemon-reload
    systemctl enable --now "$UNIT_NAME" || die "enable --now 失败（journalctl -u $UNIT_NAME -n 40）"
    echo "已装 $UNIT_DIR/$UNIT_NAME → $u@$(user_home "$u")，监听 $HOST:$PORT"

    # 起来不等于能用：等端口，再打一次 /api/state 才算数。
    for _ in $(seq 1 20); do
        if curl -fsS -m 2 "http://127.0.0.1:$PORT/api/state" >/tmp/lite-setup-state.$$ 2>/dev/null; then
            echo "自检 OK: $(cat /tmp/lite-setup-state.$$)"
            rm -f /tmp/lite-setup-state.$$
            exit 0
        fi
        sleep 0.5
    done
    rm -f /tmp/lite-setup-state.$$
    die "服务起了但 :$PORT 没应答（journalctl -u $UNIT_NAME -n 40）"
    ;;

uninstall)
    need_root uninstall
    systemctl disable --now "$UNIT_NAME" 2>/dev/null || true
    rm -f "$UNIT_DIR/$UNIT_NAME"
    systemctl daemon-reload
    echo "已卸载 $UNIT_NAME（.env 里的 key 保留）"
    ;;

start|stop|restart|status)
    need_root "$cmd"
    systemctl "$cmd" "$UNIT_NAME"
    [ "$cmd" = status ] && exit 0
    systemctl --no-pager -l status "$UNIT_NAME" | head -8
    ;;

logs)
    need_root logs
    journalctl -u "$UNIT_NAME" -n "${1:-40}" --no-pager
    ;;

*)
    usage; exit 2 ;;
esac
