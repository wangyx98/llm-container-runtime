#!/bin/bash
# Idempotent; no 'set -e'. The VM is a mount namespace that only this case's processes live in: its containers are removed, then every process of the case is killed
# (the containers' processes first, they are children of the shims), the namespace goes away with its last process, and the directories are removed.
# The pinned containerd and nerdctl in /var/cache/bench73982083 stay (sha256 is checked at every setup).
CASE_ID="bench73982083"
LIB_BASE="/opt/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NC="$WORK_DIR/bin/nerdctl"

VMPID=$(cat "$LIB_BASE/vm.pid" 2>/dev/null)
VMNS=$(cat "$LIB_BASE/vm.ns" 2>/dev/null)
if [ -n "$VMPID" ] && sudo test -d "/proc/$VMPID" && [ -x "$NC" ]; then
    echo "[cleanup] removing every container in the VM's containerd..."
    for ns in default k8s.io; do
        for c in $(timeout -k 3 30 "$NC" --namespace "$ns" ps -a -q 2>/dev/null); do timeout -k 3 30 "$NC" --namespace "$ns" rm -f -v "$c" >/dev/null 2>&1; done
    done
fi

echo "[cleanup] stopping the VM's containerd and every process of the case (children before parents)..."
protect=" $$ "
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    protect="$protect$p "
done
kill_tree() {   # $1 = pid
    local c
    for c in $(ps -o pid= --ppid "$1" 2>/dev/null); do kill_tree "$c"; done
    sudo kill -KILL "$1" 2>/dev/null
}
for _ in 1 2 3; do
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        case "$protect" in *" $pid "*) continue ;; esac
        exe="$(sudo readlink "$d/exe" 2>/dev/null)"
        case "$exe" in "$LIB_BASE"/*) kill_tree "$pid"; continue ;; esac
        if [ -n "$VMNS" ] && [ "$(sudo readlink "$d/ns/mnt" 2>/dev/null)" = "$VMNS" ]; then kill_tree "$pid"; fi
    done
    sleep 0.3
done
for _ in $(seq 1 20); do sudo test -d "/proc/${VMPID:-0}" || break; sleep 0.25; done

echo "[cleanup] the cgroups the containers left (empty ones only), the AppArmor profile nerdctl may have loaded..."
for d in $(sudo find /sys/fs/cgroup -maxdepth 3 -type d -path '*/default/*' 2>/dev/null | sort -r); do sudo rmdir "$d" 2>/dev/null; done
for d in $(sudo find /sys/fs/cgroup -maxdepth 2 -type d -name default 2>/dev/null); do sudo rmdir "$d" 2>/dev/null; done
if [ -r /sys/kernel/security/apparmor/profiles ] && sudo test -f "$STATE_DIR/state.json" \
   && [ "$(sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["aa_had_nerdctl_default"])' "$STATE_DIR/state.json" 2>/dev/null)" = "False" ] \
   && grep -q '^nerdctl-default ' /sys/kernel/security/apparmor/profiles; then
    printf nerdctl-default | sudo tee /sys/kernel/security/apparmor/.remove >/dev/null 2>&1
fi

echo "[cleanup] removing the directories..."
sudo rm -rf --one-file-system "$LIB_BASE" "$WORK_DIR"
echo "[cleanup] done."
exit 0
