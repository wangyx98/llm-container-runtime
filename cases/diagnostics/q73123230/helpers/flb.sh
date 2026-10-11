#!/bin/bash
# flb.sh start CONF | stop : run the pinned Fluent Bit (as root, in the background) with the classic configuration file CONF, and stop it.
# Reads the binary's path from $WORK_DIR/.bench/flb.path; its log is $WORK_DIR/.bench/fb.log, its pid $WORK_DIR/.bench/fb.pid.
# `start` fails, with the errors of the log, when Fluent Bit is not running after three seconds (a configuration it does not accept).
WORK_DIR="/tmp/bench73123230"
STATE_DIR="$WORK_DIR/.bench"
BIN=$(cat "$STATE_DIR/flb.path")

stop_flb() {
    local p
    p=$(sudo cat "$STATE_DIR/fb.pid" 2>/dev/null)
    if [ -n "$p" ] && [ "$(cat /proc/$p/comm 2>/dev/null)" = fluent-bit ]; then
        sudo kill "$p" 2>/dev/null
        for _ in $(seq 1 20); do sudo kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
        sudo kill -9 "$p" 2>/dev/null
    fi
    sudo rm -f "$STATE_DIR/fb.pid"
}

case "$1" in
start)
    stop_flb
    sudo rm -f "$STATE_DIR/fb.log"
    sudo setsid -f bash -c 'echo $$ > "$1"; exec "$2" -c "$3" >"$4" 2>&1 </dev/null' _ "$STATE_DIR/fb.pid" "$BIN" "$2" "$STATE_DIR/fb.log" </dev/null >/dev/null 2>&1
    sleep 3
    p=$(sudo cat "$STATE_DIR/fb.pid" 2>/dev/null)
    if [ -z "$p" ] || [ "$(cat /proc/$p/comm 2>/dev/null)" != fluent-bit ]; then
        echo "Fluent Bit did not stay up with $2. The errors in its log:"
        sudo grep -iE 'error|fail|invalid|unknown|cannot|unable' "$STATE_DIR/fb.log" 2>/dev/null | tail -4 | cut -c1-260
        exit 1
    fi
    ;;
stop)
    stop_flb
    ;;
esac
