#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, daemons not running), and every command here may fail without
# aborting the cleanup.

CASE_ID="bench66762671"
RUN_DIR="/run/$CASE_ID"
LIB_DIR="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# Kill the processes called $1 (exact process name) whose command line mentions
# this case's run dir. Matching by name first and by command line second is
# deliberate: 'pkill -f <path>' would also kill any shell whose own command
# line merely contains the path, including the one running this script. A
# system Docker/containerd on the host does not mention the run dir and is
# left alone.
kill_ours() {   # $1 = comm, $2 = signal
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$RUN_DIR"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}
any_ours() {    # $1 = comm
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$RUN_DIR" && return 0
    done
    return 1
}

echo "[cleanup] stopping this case's dockerd, containerd and container processes..."
# the container's program is PID 1 of its container and ignores SIGTERM, so
# dockerd would wait its 10 s stop timeout for it: kill it first
sudo pkill -9 -x b66762671-app 2>/dev/null || true
kill_ours dockerd TERM
for _ in $(seq 1 30); do any_ours dockerd || break; sleep 0.5; done
kill_ours dockerd KILL
kill_ours containerd TERM
for _ in $(seq 1 30); do any_ours containerd || break; sleep 0.5; done
kill_ours containerd KILL
# the shims and the container's program may outlive their daemons
kill_ours containerd-shim KILL
sudo pkill -9 -x b66762671-app 2>/dev/null || true
sleep 1

echo "[cleanup] unmounting what Docker and containerd mounted under this case's dirs..."
for _ in 1 2 3; do
    awk '{print $2}' /proc/mounts | grep -E "^($RUN_DIR|$LIB_DIR)(/|$)" | sort -r | while read -r m; do
        sudo umount -l "$m" 2>/dev/null || true
    done
done

echo "[cleanup] removing the run dir, the state dir and the work dir..."
sudo rm -rf "$RUN_DIR" "$LIB_DIR" "$WORK_DIR"

echo "[cleanup] done. Environment reset to clean state."
