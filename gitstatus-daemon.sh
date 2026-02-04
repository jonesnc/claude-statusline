#!/bin/bash
#~ nj: Gitstatus Daemon for Claude Statusline
#
# Start this daemon before using Claude Code for git status in the statusline.
# It runs in the background and communicates via FIFOs.
#
# Usage: ./gitstatus-daemon.sh start|stop|status

DAEMON_NAME="CLAUDE_STATUSLINE"
FIFO_PREFIX="/tmp/gitstatus.${DAEMON_NAME}.$(id -u)"
REQ_FIFO="${FIFO_PREFIX}.req"
RESP_FIFO="${FIFO_PREFIX}.resp"
PID_FILE="${FIFO_PREFIX}.pid"

# Find gitstatusd binary
find_gitstatusd() {
    local paths=(
        "$HOME/.cache/gitstatus/gitstatusd-linux-x86_64"
        "$HOME/.local/share/gitstatus/gitstatusd-linux-x86_64"
        "/usr/local/bin/gitstatusd"
        "/usr/bin/gitstatusd"
    )
    for p in "${paths[@]}"; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

start_daemon() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Daemon already running (PID $(cat "$PID_FILE"))"
        return 0
    fi

    local gitstatusd
    gitstatusd=$(find_gitstatusd)
    if [[ -z "$gitstatusd" ]]; then
        echo "Error: gitstatusd not found. Install gitstatus first."
        echo "  brew install romkatv/gitstatus/gitstatus"
        echo "  or download from https://github.com/romkatv/gitstatus"
        return 1
    fi

    # Create FIFOs
    rm -f "$REQ_FIFO" "$RESP_FIFO"
    mkfifo "$REQ_FIFO" "$RESP_FIFO"

    # Start daemon with persistent FIFO (sleep keeps write end open to prevent EOF)
    ( sleep infinity > "$REQ_FIFO" ) &
    local keep_open_pid=$!

    "$gitstatusd" \
        --num-threads=8 \
        --max-num-staged=-1 \
        --max-num-unstaged=-1 \
        --max-num-untracked=-1 \
        < "$REQ_FIFO" > "$RESP_FIFO" &
    local pid=$!

    echo "$keep_open_pid" > "${FIFO_PREFIX}.keep"

    echo "$pid" > "$PID_FILE"
    echo "Started gitstatus daemon (PID $pid)"
    echo "FIFOs: $REQ_FIFO, $RESP_FIFO"
}

stop_daemon() {
    if [[ ! -f "$PID_FILE" ]]; then
        echo "No daemon running"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        echo "Stopped daemon (PID $pid)"
    else
        echo "Daemon not running (stale PID file)"
    fi

    # Also kill the keep-alive process
    if [[ -f "${FIFO_PREFIX}.keep" ]]; then
        kill "$(cat "${FIFO_PREFIX}.keep")" 2>/dev/null
        rm -f "${FIFO_PREFIX}.keep"
    fi

    rm -f "$PID_FILE" "$REQ_FIFO" "$RESP_FIFO"
}

status_daemon() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Daemon running (PID $(cat "$PID_FILE"))"
        echo "FIFOs: $REQ_FIFO, $RESP_FIFO"
        return 0
    else
        echo "Daemon not running"
        return 1
    fi
}

case "${1:-status}" in
    start)  start_daemon ;;
    stop)   stop_daemon ;;
    status) status_daemon ;;
    restart) stop_daemon; sleep 0.5; start_daemon ;;
    *)
        echo "Usage: $0 {start|stop|status|restart}"
        exit 1
        ;;
esac
