#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not running), and every command here may fail without aborting the cleanup.

CASE_ID="bench65981878"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# Kill the processes called $1 (exact process name) whose command line mentions $3 (default: this case's run dir). Matching by name first and by command line second is
# deliberate: 'pkill -f <path>' would also kill any shell whose own command line merely contains the path, including the one running this script.
kill_ours() {   # $1 = comm, $2 = signal, $3 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "${3:-$RUN}"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}

kill_ours ctr KILL "$CASE_ID"
kill_ours strace KILL "$CASE_ID"
kill_ours crictl.real KILL "$CASE_ID"
kill_ours timeout KILL "$CASE_ID"
echo "[cleanup] stopping the node's containerd, the shims it left and the workload..."
sleep 0.5
if [ -x "$LIB/bin/nodectl" ]; then sudo timeout -k 3 60 "$LIB/bin/nodectl" stop >/dev/null 2>&1 || true; fi
for sig in TERM KILL; do
    kill_ours containerd "$sig" "$CASE_ID"
    kill_ours containerd-shim "$sig" "$CASE_ID"
    for _ in $(seq 1 20); do
        left=0
        for pid in $(pgrep -x containerd 2>/dev/null) $(pgrep -x containerd-shim 2>/dev/null); do
            sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID" && left=1
        done
        [ "$left" = 0 ] && break
        sleep 0.5
    done
done
# the workload itself: a process in the case's cgroup (the shim is gone, the program is not)
for f in $(sudo find /sys/fs/cgroup -path "*/$CASE_ID/*" -name cgroup.procs 2>/dev/null); do
    for pid in $(sudo cat "$f" 2>/dev/null); do sudo kill -KILL "$pid" 2>/dev/null || true; done
done
# whatever else still runs from the case's directories (a program of a solution started on the host)
for pid in $(sudo find /proc -maxdepth 1 -regex '/proc/[0-9]+' 2>/dev/null | sed 's|/proc/||'); do
    [ "$pid" = "$$" ] && continue
    if sudo readlink "/proc/$pid/exe" 2>/dev/null | grep -qF "$CASE_ID"; then sudo kill -KILL "$pid" 2>/dev/null || true; fi
done
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything: rm -rf must never walk into a live mount (the container's rootfs).
for _ in 1 2 3; do
    for base in "$RUN" "$LIB" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# the cgroups of the workload (/bench65981878 in every hierarchy): empty ones only, deepest first
for d in $(sudo find /sys/fs/cgroup -depth -type d -path "*/$CASE_ID" -o -depth -type d -path "*/$CASE_ID/*" 2>/dev/null); do
    sudo rmdir "$d" 2>/dev/null || true
done

echo "[cleanup] removing the node, its databases and the work dir (the downloaded files stay in /var/cache/$CASE_ID)..."
sudo rm -rf --one-file-system "$RUN" "$LIB"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
