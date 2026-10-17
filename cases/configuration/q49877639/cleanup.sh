#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned) and every command may fail without aborting the cleanup.

CASE_ID="bench49877639"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
CSOCK="$RUN/containerd.sock"

# Kill the processes called $1 (exact process name) whose command line mentions the case id ('pkill -f' would also kill the shell that runs this script).
kill_ours() {   # $1 = comm, $2 = signal
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}

# the plugins of the lab (every plugin id has a directory below the data root), remembered for the last steps
IDS=$(ls "$LIB/docker/plugins" 2>/dev/null | grep -E '^[0-9a-f]{64}$')

echo "[cleanup] disabling the plugins and stopping the lab's dockerd and containerd..."
if [ -S "$RUN/docker.sock" ]; then
    for p in $(sudo timeout 20 docker -H "unix://$RUN/docker.sock" plugin ls -q 2>/dev/null); do
        sudo timeout 60 docker -H "unix://$RUN/docker.sock" plugin disable -f "$p" >/dev/null 2>&1
    done
fi
for id in $(sudo timeout 20 ctr -a "$CSOCK" -n plugins.moby tasks ls -q 2>/dev/null); do
    sudo timeout 20 ctr -a "$CSOCK" -n plugins.moby tasks kill -s KILL "$id" >/dev/null 2>&1
done
for root in "$RUN"/exec/runtime-runc/* "$RUN"/ctd/runc/*; do
    [ -d "$root" ] || continue
    for id in $(sudo runc --root "$root" list -q 2>/dev/null); do
        sudo runc --root "$root" kill "$id" KILL >/dev/null 2>&1
        sleep 0.2
        sudo runc --root "$root" delete -f "$id" >/dev/null 2>&1
    done
done
for sig in TERM KILL; do
    kill_ours dockerd "$sig"
    sleep 1
    kill_ours containerd "$sig"
    kill_ours containerd-shim-runc-v2 "$sig"
    kill_ours python3 "$sig"
    kill_ours ctr "$sig"
    kill_ours docker "$sig"
    kill_ours timeout "$sig"
    sleep 1
done

echo "[cleanup] unmounting what the plugins left below the lab's directories (deepest first), removing the plugins' cgroup directories..."
for _ in 1 2 3; do
    awk '{print $2}' /proc/mounts | grep -e "$CASE_ID" | sort -r | while read -r m; do sudo umount "$m" >/dev/null 2>&1 || sudo umount -l "$m" >/dev/null 2>&1; done
    awk '{print $2}' /proc/mounts | grep -q -e "$CASE_ID" || break
    sleep 1
done
for id in $IDS; do
    for _ in 1 2 3; do
        sudo find /sys/fs/cgroup -maxdepth 9 -depth -type d -name "$id" -exec rmdir {} \; 2>/dev/null
        sudo find /sys/fs/cgroup -maxdepth 9 -type d -name "$id" 2>/dev/null | grep -q . || break
        sleep 1
    done
    sudo rm -rf "/run/docker/plugins/$id"
done

echo "[cleanup] removing the lab's directories and the work dir..."
sudo rmdir /run/docker/plugins 2>/dev/null     # only when it is empty: another Docker on this machine may use it
sudo rm -rf "$LIB" "$RUN" "$WORK_DIR" "$WORK_DIR"-* /tmp/"$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
