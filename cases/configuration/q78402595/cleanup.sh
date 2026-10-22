#!/bin/bash
# idempotent: safe to run when nothing exists; puts the host sysctls back first, then removes the lab (the cache of the downloaded release is kept)

CASE_ID="bench78402595"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
SOCK="$RUN_BASE/containerd.sock"
NS="bench78402595"
RUNC_ROOT="/run/containerd/runc/$NS"

# 1. the host's JIT settings, as they were before the lab (whatever the solution did to them)
for k in bpf_jit_limit bpf_jit_enable bpf_jit_harden; do
    if sudo test -f "$LIB_BASE/orig.$k"; then
        v=$(sudo cat "$LIB_BASE/orig.$k")
        [ "$(sudo cat /proc/sys/net/core/$k 2>/dev/null)" = "$v" ] || sudo sh -c "echo $v > /proc/sys/net/core/$k" 2>/dev/null
    fi
done

# 2. the container and its processes (through containerd while it answers, through runc in any case)
if [ -S "$SOCK" ] && [ -x "$LIB_BASE/libexec/ctr" ]; then
    CTR="sudo $LIB_BASE/libexec/ctr --address $SOCK --namespace $NS --timeout 20s"
    $CTR tasks kill -s SIGKILL --all tgt >/dev/null 2>&1
    sleep 1
    $CTR tasks delete --force tgt >/dev/null 2>&1
    $CTR containers delete tgt >/dev/null 2>&1
fi
if sudo test -d "$RUNC_ROOT"; then
    for id in $(sudo ls "$RUNC_ROOT" 2>/dev/null); do
        sudo runc --root "$RUNC_ROOT" delete --force "$id" >/dev/null 2>&1
    done
fi

# 3. containerd and the shims that belong to it (matched on the socket of this lab, which only they carry on the command line)
if [ -x "$LIB_BASE/bin/containerdctl" ]; then sudo "$LIB_BASE/bin/containerdctl" stop >/dev/null 2>&1; fi
sudo pkill -KILL -f -- "-address /run/[b]ench78402595/containerd.sock" 2>/dev/null
sudo pkill -KILL -f -- "--address /run/[b]ench78402595/containerd.sock" 2>/dev/null
sleep 1

# 4. mounts (container root filesystems), cgroups, runc state, shim sockets
for base in "$RUN_BASE" "$LIB_BASE"; do
    awk -v b="$base/" 'index($2, b) == 1 {print $2}' /proc/mounts 2>/dev/null | sort -r | while read -r m; do sudo umount -l "$m" 2>/dev/null; done
done
for d in /sys/fs/cgroup/"$NS" /sys/fs/cgroup/*/"$NS"; do
    [ -d "$d" ] && sudo find "$d" -depth -type d -exec rmdir {} \; 2>/dev/null
done
sudo rm -rf "$RUNC_ROOT"
if sudo test -f "$LIB_BASE/shims.before" && [ -d /run/containerd/s ]; then
    sudo find /run/containerd/s -maxdepth 1 -mindepth 1 2>/dev/null | sort | comm -13 "$LIB_BASE/shims.before" - | while read -r s; do sudo rm -f "$s"; done
fi
if sudo test -f "$LIB_BASE/run_containerd_created"; then
    sudo rmdir /run/containerd/s /run/containerd/runc /run/containerd/fifo /run/containerd 2>/dev/null
fi

# 5. the lab's directories (the leftover state of the lab is under /run and /var/lib of its own name)
sudo rm -rf "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"
exit 0
