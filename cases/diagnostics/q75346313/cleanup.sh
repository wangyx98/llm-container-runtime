#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not running), and every command here may fail
# without aborting the cleanup. The docker-default profile is not touched: once Docker loads it, it is what any Docker host has.

CASE_ID="bench75346313"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# Kill the processes called $1 (exact process name) whose command line mentions the case dirs (matching the name first and the command line
# second: 'pkill -f <path>' would also kill any shell whose own command line contains the path, including the one running this script).
kill_ours() {   # $1 = comm, $2 = signal
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE "$RUN_BASE|$LIB_BASE|$WORK_DIR"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}
any_ours() {    # $1 = comm
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE "$RUN_BASE|$LIB_BASE|$WORK_DIR" && return 0
    done
    return 1
}

DSOCK="$RUN_BASE/docker.sock"
if [ -S "$DSOCK" ] && command -v docker >/dev/null 2>&1; then
    for c in $(sudo timeout -k 3 20 docker -H "unix://$DSOCK" ps -aq 2>/dev/null); do
        sudo timeout -k 3 20 docker -H "unix://$DSOCK" rm -f "$c" >/dev/null 2>&1 || true
    done
fi

echo "[cleanup] stopping this case's daemons and what they left behind..."
kill_ours docker KILL
kill_ours python3 KILL
kill_ours timeout KILL
kill_ours sudo KILL
kill_ours dockerd TERM
for _ in $(seq 1 30); do any_ours dockerd || break; sleep 0.5; done
kill_ours dockerd KILL
kill_ours containerd TERM
for _ in $(seq 1 30); do any_ours containerd || break; sleep 0.5; done
kill_ours containerd KILL
for comm in containerd-shim containerd-shim-runc-v2; do
    kill_ours "$comm" KILL
done
# a container's own process outlives its shim: it is ours if its mounts are in the data root of this case
for pid in $(pgrep -x app 2>/dev/null); do
    sudo grep -q "$LIB_BASE" "/proc/$pid/mountinfo" 2>/dev/null && sudo kill -9 "$pid" 2>/dev/null || true
done
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything:
# rm -rf must never walk into a live mount (overlay mounts of a container, shm).
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

echo "[cleanup] removing the state, the data and the work dir (and what a solution may have left beside it in /tmp)..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
