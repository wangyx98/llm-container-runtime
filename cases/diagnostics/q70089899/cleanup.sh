#!/bin/bash
# no 'set -e': nothing here is guaranteed to exist (first run, already
# cleaned, or the solution already ended the stuck processes).

CONTAINER="bench70089899"
WORK_DIR="/tmp/bench70089899"
BUNDLE_DIR="$WORK_DIR/bundle"
STATE_DIR="$WORK_DIR/.bench"

kill_pidfile() {
    # $1: pidfile, $2: expected cmdline prefix (guards against pid reuse)
    local pidfile="$1" expect="$2" pid cmd
    [ -s "$pidfile" ] || return 0
    pid=$(cat "$pidfile")
    [ -n "$pid" ] || return 0
    cmd=$(sudo cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ')
    case "$cmd" in
        "$expect"*) sudo kill -9 "$pid" 2>/dev/null || true ;;
    esac
}

echo "[cleanup] killing the stuck runc process tree, if still there..."
# Primary method: every process of the container (runc init and the hook's
# child) sits in a cgroup named after the container id, whichever pid it has
# and whoever its parent is. This also catches orphans that were reparented
# to pid 1 (an earlier version that only trusted recorded pids leaked one of
# these, which then kept the cgroup busy and broke every later run).
for cgfile in /proc/[0-9]*/cgroup; do
    pid=${cgfile#/proc/}; pid=${pid%/cgroup}
    [ "$pid" = "$$" ] && continue
    if sudo grep -q "/$CONTAINER\$" "$cgfile" 2>/dev/null; then
        sudo kill -9 "$pid" 2>/dev/null || true
    fi
done

# Then the launcher side, which is not in the container cgroup.
kill_pidfile "$STATE_DIR/runc_create.pid" "runc create --bundle $BUNDLE_DIR"
kill_pidfile "$STATE_DIR/launcher.pid" "sudo runc create --bundle $BUNDLE_DIR"
kill_pidfile "$STATE_DIR/stderr_holder.pid" "sleep infinity"

# Fallback for when the pidfiles are gone (e.g. the work dir was deleted by
# hand). Patterns are anchored on this case's exact bundle path + container
# id, so they can't hit unrelated runc processes. When this file runs as
# `bash cleanup.sh`, its own cmdline is just that, so the patterns can't
# match the cleanup script itself either.
for pid in $(pgrep -f "^runc create --bundle $BUNDLE_DIR $CONTAINER\$" 2>/dev/null); do
    for child in $(pgrep -P "$pid" -f '^runc init' 2>/dev/null); do
        sudo kill -9 "$child" 2>/dev/null || true
    done
    sudo kill -9 "$pid" 2>/dev/null || true
done
for pid in $(pgrep -f "^sudo runc create --bundle $BUNDLE_DIR $CONTAINER\$" 2>/dev/null); do
    sudo kill -9 "$pid" 2>/dev/null || true
done
sleep 1

echo "[cleanup] removing any runc state / cgroup left for '$CONTAINER'..."
sudo runc delete -f "$CONTAINER" >/dev/null 2>&1 || true
sudo rm -rf "/run/runc/$CONTAINER" 2>/dev/null || true
for cg in "/sys/fs/cgroup/$CONTAINER" /sys/fs/cgroup/*/"$CONTAINER"; do
    [ -d "$cg" ] && sudo rmdir "$cg" 2>/dev/null || true
done

echo "[cleanup] removing the work dir (bundle, FIFO, pidfiles, stack trace)..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done. Environment reset to clean state."
