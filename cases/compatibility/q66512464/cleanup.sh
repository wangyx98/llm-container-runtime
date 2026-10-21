#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned) and every command may fail without aborting the cleanup.

CASE_ID="bench66512464"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# Kill the processes called $1 (exact process name) that belong to the case: their command line mentions the case id ('pkill -f' would also kill the shell that runs this script).
kill_ours() {   # $1 = comm, $2 = signal
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}

echo "[cleanup] stopping the kubelet, Docker, containerd and the containers (the runc state below $RUN names every container)..."
if [ -x "$LIB/bin/kubeletctl" ]; then
    sudo timeout 60 "$LIB/bin/kubeletctl" stop >/dev/null 2>&1 || true
fi
kill_ours kubelet TERM
sleep 1
kill_ours kubelet KILL
IDS=""
RUNC="$LIB/opt/docker/runc"
[ -x "$RUNC" ] || RUNC="$(command -v runc)"
if [ -n "$RUNC" ] && [ -d "$RUN" ]; then
    for root in $(sudo find "$RUN/runc" "$RUN/docker-exec/runtime-runc" -mindepth 1 -maxdepth 1 -type d 2>/dev/null); do
        for id in $(sudo "$RUNC" --root "$root" list -q 2>/dev/null); do
            IDS="$IDS $id"
            sudo "$RUNC" --root "$root" kill "$id" KILL >/dev/null 2>&1
            sleep 0.2
            sudo "$RUNC" --root "$root" delete -f "$id" >/dev/null 2>&1
        done
    done
fi
# containers made with ctr (not through the CRI) keep their runc state in the default root of the host, /run/containerd/runc/<namespace>: only the ones whose bundle is below $RUN
if [ -n "$RUNC" ]; then
    for root in $(sudo find /run/containerd/runc -mindepth 1 -maxdepth 1 -type d 2>/dev/null); do
        for id in $(sudo "$RUNC" --root "$root" list 2>/dev/null | awk -v c="$RUN/" 'NR>1 && index($4,c){print $1}'); do
            IDS="$IDS $id"
            sudo "$RUNC" --root "$root" kill "$id" KILL >/dev/null 2>&1
            sleep 0.2
            sudo "$RUNC" --root "$root" delete -f "$id" >/dev/null 2>&1
        done
    done
fi
for sig in TERM KILL; do
    kill_ours dockerd "$sig"
    kill_ours containerd "$sig"
    kill_ours containerd-shim "$sig"
    kill_ours crictl "$sig"
    kill_ours ctr "$sig"
    kill_ours docker "$sig"
    kill_ours timeout "$sig"
    sleep 1
done

echo "[cleanup] unmounting what the containers, the snapshots and the pods left below the node's directories (deepest first), removing their cgroup directories..."
for _ in 1 2 3; do
    awk '{print $2}' /proc/mounts | grep -e "$CASE_ID" | sort -r | while read -r m; do sudo umount "$m" >/dev/null 2>&1 || sudo umount -l "$m" >/dev/null 2>&1; done
    awk '{print $2}' /proc/mounts | grep -q -e "$CASE_ID" || break
    sleep 1
done
for id in $IDS; do
    for _ in 1 2; do sudo find /sys/fs/cgroup -maxdepth 9 -depth -type d -name "$id*" -exec rmdir {} \; 2>/dev/null; done
done
for _ in 1 2 3; do
    sudo find /sys/fs/cgroup -maxdepth 9 -depth -type d -path "*$CASE_ID*" -exec rmdir {} \; 2>/dev/null
    sudo find /sys/fs/cgroup -maxdepth 9 -type d -path "*$CASE_ID*" 2>/dev/null | grep -q . || break
    sleep 1
done

for d in $(sudo find /sys/fs/cgroup -maxdepth 3 -depth -type d \( -name k8s.io -o -name docker \) 2>/dev/null); do sudo rmdir "$d" 2>/dev/null; done   # the parents the runtimes made (rmdir: only while nothing is in them)

echo "[cleanup] removing what the kubelet put on the host outside the node (pod logs, its device-plugin and certificate directories, a dockershim socket)..."
sudo rm -rf /var/log/pods/*"$CASE_ID"* /var/log/containers/*"$CASE_ID"*
sudo rmdir /var/log/pods /var/log/containers 2>/dev/null
sudo rm -f /var/lib/kubelet/device-plugins/kubelet.sock /var/lib/kubelet/device-plugins/DEPRECATION
sudo rmdir /var/lib/kubelet/device-plugins /var/lib/kubelet/pki /var/lib/kubelet 2>/dev/null
sudo rm -f /var/run/dockershim.sock

# ctr (a solution may use it) puts the fifos of the containers it starts in /run/containerd/fifo of the host: the ones made since the end of setup
if [ -f "$WORK_DIR/.bench/truth.json" ] && [ -d /run/containerd/fifo ]; then
    sudo find /run/containerd/fifo -mindepth 1 -maxdepth 1 -newer "$WORK_DIR/.bench/truth.json" -exec rm -rf {} + 2>/dev/null
fi

echo "[cleanup] removing the node's directories and the work dir (the downloaded kubelet and Docker packages stay in /var/cache/$CASE_ID)..."
sudo rm -rf "$LIB" "$RUN" "$WORK_DIR" "$WORK_DIR"-* /tmp/"$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
