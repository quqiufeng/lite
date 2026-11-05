#!/usr/bin/env bash
# TUI 冒烟：真实终端（tmux）渲染 + diff pager；使用假 key，不访问网络。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v tmux >/dev/null 2>&1; then
    echo "SKIP tui.smoke (tmux missing)"
    exit 0
fi

TMP="$(mktemp -d)"
S="lite_smoke_$$"
ART=""

cleanup() {
    tmux kill-session -t "$S" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
    ART="$ROOT/artifacts/$(date +%Y%m%d-%H%M%S)/tui.smoke"
    mkdir -p "$ART"
    tmux capture-pane -p -t "$S" > "$ART/screen.txt" 2>/dev/null || true
    echo "FAIL tui.smoke: $1" >&2
    echo "screen saved: $ART/screen.txt" >&2
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

# 临时 git 仓库：一个有改动的文件，用于 diff pager。
git -C "$TMP" init -q
git -C "$TMP" config user.email lite@test
git -C "$TMP" config user.name lite
printf 'old line\nsecond\n' > "$TMP/a.txt"
git -C "$TMP" add a.txt
git -C "$TMP" commit -qm init
printf 'new line\nsecond\n' > "$TMP/a.txt"

LITE_CWD="$TMP" "$ROOT/tools/lite-lua" "$ROOT/tools/seed_todos.lua" "$TMP" >/dev/null

tmux new-session -d -s "$S" -x 120 -y 30 -c "$TMP" \
    "env DEEPSEEK_API_KEY=dummy LITE_CWD=$TMP LITE_MEMORY_DIR=$TMP $ROOT/tools/run.sh --tui"

wait_for "lite TUI" 8 || fail "initial screen"
wait_for "mem:" 4 || fail "status bar"
wait_for "todo:1/2" 4 || fail "todo status"

tmux send-keys -t "$S" C-t
wait_for "TODOS" 4 || fail "todo view"
tmux capture-pane -p -t "$S" > "$TMP/todo.txt"
grep -qF "[x] write code" "$TMP/todo.txt" || fail "todo completed item"
grep -qF "[ ] run tests" "$TMP/todo.txt" || fail "todo pending item"
tmux send-keys -t "$S" -l "q"
sleep 0.2

tmux send-keys -t "$S" C-g
wait_for "DIFF" 8 || fail "diff pager"

tmux capture-pane -p -t "$S" > "$TMP/split.txt"
grep -qF "a.txt" "$TMP/split.txt" || fail "diff file header"
grep -qF "old line" "$TMP/split.txt" || fail "split old"
grep -qF "new line" "$TMP/split.txt" || fail "split new"
grep -qF "│" "$TMP/split.txt" || fail "split gutter"

tmux send-keys -t "$S" Tab
wait_for "[unified]" 4 || fail "unified toggle"
tmux capture-pane -p -t "$S" > "$TMP/unified.txt"
grep -q -- "-.*old line" "$TMP/unified.txt" || fail "unified old sign"
grep -q -- "+.*new line" "$TMP/unified.txt" || fail "unified new sign"

tmux send-keys -t "$S" -l "q"
sleep 0.2

tmux send-keys -t "$S" -l "/reload"
tmux send-keys -t "$S" Enter
wait_for "reloaded lua" 4 || fail "reload lua"

tmux send-keys -t "$S" -l "quit"
tmux send-keys -t "$S" Enter
sleep 0.5
if tmux has-session -t "$S" 2>/dev/null; then
    fail "quit + Enter did not exit"
fi

echo "OK tui.smoke"
