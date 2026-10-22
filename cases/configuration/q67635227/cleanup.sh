#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned) and every command may fail without aborting the cleanup.

CASE_ID="bench67635227"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# Kill the processes called $1 (exact process name) whose command line mentions the case id ('pkill -f' would also kill the shell that runs this script).
kill_ours() {   # $1 = comm, $2 = signal
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}

echo "[cleanup] stopping the node, the hub and the containers..."
if [ -x "$LIB/bin/mk8sctl" ]; then
    sudo timeout 60 "$LIB/bin/mk8sctl" stop >/dev/null 2>&1 || true
fi
# the containers of this node: runc keeps their state below $LIB/common/run/containerd/runc/<namespace> (a container outlives its shim and containerd), they are killed through runc, then the shims
for root in $(sudo find "$LIB/common/run/containerd/runc" -mindepth 1 -maxdepth 1 -type d 2>/dev/null); do
    for id in $(sudo runc --root "$root" list -q 2>/dev/null); do
        sudo runc --root "$root" kill "$id" KILL >/dev/null 2>&1
        sleep 0.2
        sudo runc --root "$root" delete -f "$id" >/dev/null 2>&1
    done
done
for pid in $(sudo pgrep -f -- "containerd-shim-runc-v[2] .*$LIB/common/run/containerd.sock" 2>/dev/null); do
    sudo kill -KILL "$pid" 2>/dev/null
done
for sig in TERM KILL; do
    kill_ours containerd "$sig"
    kill_ours python3 "$sig"
    kill_ours crictl "$sig"
    kill_ours timeout "$sig"
    sleep 1
done

echo "[cleanup] unmounting what the pods left below the node's directories (deepest first), removing their cgroup directories..."
for _ in 1 2 3; do
    awk '{print $2}' /proc/mounts | grep -e "$CASE_ID" | sort -r | while read -r m; do sudo umount "$m" >/dev/null 2>&1 || sudo umount -l "$m" >/dev/null 2>&1; done
    awk '{print $2}' /proc/mounts | grep -q -e "$CASE_ID" || break
    sleep 1
done
for _ in 1 2 3; do
    sudo find /sys/fs/cgroup -maxdepth 9 -depth -type d -path "*$CASE_ID*" -exec rmdir {} \; 2>/dev/null
    sudo find /sys/fs/cgroup -maxdepth 9 -type d -path "*$CASE_ID*" 2>/dev/null | grep -q . || break
    sleep 1
done

echo "[cleanup] removing the node's directories, the hub's files and the work dir..."
sudo rm -rf "$LIB" "$RUN" "$WORK_DIR" "$WORK_DIR"-* /tmp/"$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
