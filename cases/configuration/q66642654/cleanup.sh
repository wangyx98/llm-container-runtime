#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned) and every command may fail without aborting the cleanup.

CASE_ID="bench66642654"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
ADDR="10.66.64.45"
ALIAS="lo:b66642"

# Kill the processes called $1 (exact process name) whose command line mentions the case id ('pkill -f' would also kill the shell that runs this script).
kill_ours() {   # $1 = comm, $2 = signal
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}

echo "[cleanup] stopping the node, the registry and the containers (the runc state below $LIB/common/run names every container)..."
if [ -x "$LIB/bin/mk8sctl" ]; then
    sudo timeout 60 "$LIB/bin/mk8sctl" stop >/dev/null 2>&1 || true
fi
for root in "$LIB"/common/run/runc "$LIB"/common/run/runc/* "$LIB"/ctl-common/run/runc; do
    [ -d "$root" ] || continue
    for id in $(sudo runc --root "$root" list -q 2>/dev/null); do
        sudo runc --root "$root" kill "$id" KILL >/dev/null 2>&1
        sleep 0.2
        sudo runc --root "$root" delete -f "$id" >/dev/null 2>&1
    done
done
for sig in TERM KILL; do
    kill_ours containerd "$sig"
    kill_ours containerd-shim-runc-v2 "$sig"
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

echo "[cleanup] removing the registry address, the node's directories and the work dir..."
if [ -f "$CASE_DIR/helpers/alias.py" ] && sudo python3 "$CASE_DIR/helpers/alias.py" has "$ALIAS" "$ADDR" 2>/dev/null; then
    sudo python3 "$CASE_DIR/helpers/alias.py" del "$ALIAS" "$ADDR" 2>/dev/null
fi
sudo rm -rf "$LIB" "$RUN" "$WORK_DIR" "$WORK_DIR"-* /tmp/"$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
