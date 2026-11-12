#!/usr/bin/env bash
# serve/attach 冒烟：TCP 协议探针 + tmux attach 显示 + diff 转发。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
S="lite_serve_$$"
ART=""
SRV_PID=""

cleanup() {
    tmux kill-session -t "$S" >/dev/null 2>&1 || true
    if [ -n "$SRV_PID" ]; then
        kill "$SRV_PID" >/dev/null 2>&1 || true
        wait "$SRV_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
    ART="$ROOT/artifacts/$(date +%Y%m%d-%H%M%S)/serve.smoke"
    mkdir -p "$ART"
    tmux capture-pane -p -t "$S" > "$ART/screen.txt" 2>/dev/null || true
    cp "$TMP/serve.out" "$ART/serve.out" 2>/dev/null || true
    cp "$TMP/serve.err" "$ART/serve.err" 2>/dev/null || true
    echo "FAIL serve.smoke: $1" >&2
    echo "artifacts: $ART" >&2
    exit 1
}

wait_for() {
    local pat="$1" timeout="${2:-8}" i=0
    while [ "$i" -lt "$((timeout * 10))" ]; do
        if tmux capture-pane -p -t "$S" 2>/dev/null | grep -qF -- "$pat"; then
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

# 临时 git 仓库（server cwd）
git -C "$TMP" init -q
git -C "$TMP" config user.email lite@test
git -C "$TMP" config user.name lite
printf 'old line\nsecond\n' > "$TMP/a.txt"
git -C "$TMP" add a.txt
git -C "$TMP" commit -qm init
printf 'new line\nsecond\n' > "$TMP/a.txt"

LITE_CWD="$TMP" "$ROOT/tools/lite-lua" "$ROOT/tools/seed_todos.lua" "$TMP" >/dev/null

# headless serve，端口 0 由内核分配
env DEEPSEEK_API_KEY=dummy LITE_CWD="$TMP" LITE_MEMORY_DIR="$TMP" \
    XDG_DATA_HOME="$TMP/data" \
    "$ROOT/tools/run.sh" serve --port 0 >"$TMP/serve.out" 2>"$TMP/serve.err" &
SRV_PID=$!

PORT=""
for _ in $(seq 1 60); do
    PORT="$(sed -n 's/^PORT=//p' "$TMP/serve.out" 2>/dev/null | head -1)"
    [ -n "$PORT" ] && break
    sleep 0.1
done
[ -n "$PORT" ] || fail "serve did not start"

"$ROOT/tools/lite-lua" "$ROOT/tools/serve_probe.lua" 127.0.0.1 "$PORT" \
    || fail "protocol probe"

# HTTP 前端：探活 + 未知端点 404（/prompt 要真模型，冒烟里不跑）
if command -v curl >/dev/null 2>&1; then
    HEALTH="$(curl -s -m 5 "http://127.0.0.1:$PORT/health" || true)"
    case "$HEALTH" in
        *'"live":true'*) ;;
        *) fail "GET /health: $HEALTH" ;;
    esac
    CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
        -d '{"prompt":"hi"}' "http://127.0.0.1:$PORT/v1/chat/completions" || true)"
    [ "$CODE" = "404" ] || fail "old /v1 endpoint should be 404, got $CODE"
else
    echo "SKIP serve.http (curl missing)"
fi

# 探活去抖（master 侧那份规则）：活着的 serve 连续 3 次空闲 → 退出码 0；
# 没人听的端口 → 4（连一次都没答上来）。--probe 不启服务端、不要 API key，
# 走 lite 自己的 libcurl，所以不受上面 curl 分支影响。
"$ROOT/tools/run.sh" serve --probe "127.0.0.1:$PORT" --samples 3 --interval 0.1 \
    --probe-timeout 5 >/dev/null || fail "serve --probe on live server should be 0"
set +e
"$ROOT/tools/run.sh" serve --probe 127.0.0.1:1 --samples 2 --interval 0 \
    --probe-timeout 1 >/dev/null 2>&1
DEAD_RC=$?
set -e
[ "$DEAD_RC" = "4" ] || fail "serve --probe on dead port should exit 4, got $DEAD_RC"

if command -v tmux >/dev/null 2>&1; then
    tmux new-session -d -s "$S" -x 120 -y 30 -c "$TMP" \
        "env LITE_CWD=$TMP $ROOT/tools/run.sh attach --port $PORT"

    wait_for "connected to" 8 || fail "attach initial screen"
    wait_for "mem:" 4 || fail "attach status bar"
    wait_for "todo:1/2" 4 || fail "attach todo status"
    tmux capture-pane -p -t "$S" > "$TMP/attach.txt"
    grep -qF "connected to 127.0.0.1:$PORT" "$TMP/attach.txt" || fail "attach connect text"

    tmux send-keys -t "$S" C-t
    wait_for "TODOS" 4 || fail "attach todo view"
    tmux capture-pane -p -t "$S" > "$TMP/todo.txt"
    grep -qF "[x] write code" "$TMP/todo.txt" || fail "attach todo completed"
    grep -qF "[ ] run tests" "$TMP/todo.txt" || fail "attach todo pending"
    tmux send-keys -t "$S" -l "q"
    sleep 0.2

    tmux send-keys -t "$S" C-g
    wait_for "DIFF" 8 || fail "attach diff"
    tmux capture-pane -p -t "$S" > "$TMP/diff.txt"
    grep -qF "a.txt" "$TMP/diff.txt" || fail "attach diff file"
    grep -qF "old line" "$TMP/diff.txt" || fail "attach diff old"
    grep -qF "new line" "$TMP/diff.txt" || fail "attach diff new"

    tmux send-keys -t "$S" -l "q"
    sleep 0.2
    tmux send-keys -t "$S" C-d
    sleep 0.3
else
    echo "SKIP serve.attach (tmux missing)"
fi

if [ -n "$SRV_PID" ]; then
    kill -TERM "$SRV_PID" 2>/dev/null || true
    for _ in $(seq 1 50); do
        if ! kill -0 "$SRV_PID" 2>/dev/null; then break; fi
        sleep 0.1
    done
    if kill -0 "$SRV_PID" 2>/dev/null; then
        fail "serve did not exit on SIGTERM"
    fi
    wait "$SRV_PID" 2>/dev/null || true
    SRV_PID=""
fi

echo "OK serve.smoke"
