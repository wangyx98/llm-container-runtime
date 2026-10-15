#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a container already gone), and every command here may fail without aborting the cleanup.

CASE_ID="bench78631941"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
SOCK="$RUN_BASE/containerd.sock"
LAN="/run/netns/$CASE_ID-lan"

echo "[cleanup] stopping the containers of the private containerd (every namespace)..."
if [ -S "$SOCK" ]; then
    for ns in $(sudo timeout 10 ctr -a "$SOCK" namespaces ls -q 2>/dev/null); do
        for c in $(sudo timeout 10 ctr -a "$SOCK" -n "$ns" containers ls -q 2>/dev/null); do
            sudo timeout 10 ctr -a "$SOCK" -n "$ns" tasks kill -s KILL "$c" >/dev/null 2>&1 || true
            sudo timeout 20 ctr -a "$SOCK" -n "$ns" tasks delete -f "$c" >/dev/null 2>&1 || true
            sudo timeout 20 ctr -a "$SOCK" -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
        done
    done
fi

echo "[cleanup] removing the veth pair of the registry's network (CNI DEL)..."
if [ -e "$LAN" ] && [ -x "$LIB_BASE/cni/bin/ptp" ]; then
    echo '{"cniVersion":"1.0.0","name":"'"$CASE_ID"'","type":"ptp","ipMasq":false,"ipam":{"type":"host-local","subnet":"10.78.63.0/24","dataDir":"'"$LIB_BASE"'/ipam"}}' \
        | sudo env CNI_COMMAND=DEL CNI_CONTAINERID="$CASE_ID" CNI_NETNS="$LAN" CNI_IFNAME=eth0 CNI_PATH="$LIB_BASE/cni/bin" "$LIB_BASE/cni/bin/ptp" >/dev/null 2>&1 || true
fi

# the [c] keeps the pattern from matching the command line of the sudo that runs pkill: killing that sudo (which has put the terminal in raw mode) leaves the user's terminal without echo and without CR
echo "[cleanup] stopping the SOCI snapshotter (its FUSE mounts are unmounted), the shims, the daemons of the lab (containerd, registry) and every process in a cgroup of the lab..."
[ -x "$LIB_BASE/bin/soci-service" ] && sudo timeout 30 "$LIB_BASE/bin/soci-service" stop >/dev/null 2>&1 </dev/null
sudo pkill -9 -f "[c]ontainerd-shim-runc-v2.*-namespace $CASE_ID" >/dev/null 2>&1 || true
for pid in $(pgrep -x python3 2>/dev/null; pgrep -x containerd 2>/dev/null; pgrep -x nsenter 2>/dev/null; pgrep -x soci-snapshotte 2>/dev/null); do
    sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$CASE_ID" && sudo kill -9 "$pid" 2>/dev/null || true
done
if [ -f "$RUN_BASE/containerd.pid" ]; then sudo kill -9 "$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null)" 2>/dev/null || true; fi
for p in /proc/[0-9]*; do                      # a process whose cgroup path has the case name: the containers' processes
    pid=${p#/proc/}
    sudo grep -q "$CASE_ID" "$p/cgroup" 2>/dev/null && sudo kill -9 "$pid" 2>/dev/null || true
done
sleep 1

echo "[cleanup] unmounting what the containers and the snapshotter left below the lab's directories (deepest first; FUSE mounts and bind mounts of namespace files included), removing the namespace file..."
for _ in 1 2 3 4; do
    awk '{print $2}' /proc/mounts | grep -e "$CASE_ID" | sort -r | while read -r m; do sudo umount "$m" >/dev/null 2>&1 || sudo umount -l "$m" >/dev/null 2>&1; done
    awk '{print $2}' /proc/mounts | grep -q -e "$CASE_ID" || break
    sleep 1
done
sudo rm -rf "$LAN" /run/containerd/runc/"$CASE_ID" /run/containerd/runc/"$CASE_ID"-ctl /run/containerd/io.containerd.runtime.v2.task/"$CASE_ID" /run/containerd/io.containerd.runtime.v2.task/"$CASE_ID"-ctl \
    /run/containerd/io.containerd.sandbox.controller.v1.shim/"$CASE_ID" /run/containerd/io.containerd.sandbox.controller.v1.shim/"$CASE_ID"-ctl

echo "[cleanup] removing the cgroup directories that are left (children first), the lab's directories and the work dir..."
sudo find /sys/fs/cgroup -maxdepth 12 -depth -type d -name "$CASE_ID*" -exec rmdir {} \; 2>/dev/null
sudo rm -rf --one-file-system "$LIB_BASE" "$RUN_BASE"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-* "/tmp/$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
