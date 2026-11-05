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

echo "OK serve.smoke"
