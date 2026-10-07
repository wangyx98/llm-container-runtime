#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, daemon not
# running), and every command here may fail without aborting the cleanup.

CASE_ID="bench67820679"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"

# Kill the processes called $1 (exact process name) whose command line mentions this case's run dir.
# Matching by name first and by command line second is deliberate: 'pkill -f <path>' would also kill
# any shell whose own command line merely contains the path, including the one running this script.
# A system Docker/containerd on the host does not mention the run dir and is left alone.
kill_ours() {   # $1 = comm, $2 = signal
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$RUN_BASE"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}
any_ours() {    # $1 = comm
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$RUN_BASE" && return 0
    done
    return 1
}

# the tasks of the private containerd first: the container here runs forever, and what runs in a
# namespace is only found through containerd (the namespace of the case, and any other)
if [ -S "$CTD_SOCK" ] && command -v ctr >/dev/null 2>&1; then
    echo "[cleanup] removing every container and task of the private containerd (all namespaces)..."
    for ns in $(sudo timeout -k 3 20 ctr -a "$CTD_SOCK" namespaces ls -q 2>/dev/null); do
        for t in $(sudo timeout -k 3 20 ctr -a "$CTD_SOCK" -n "$ns" tasks ls -q 2>/dev/null); do
            sudo timeout -k 3 20 ctr -a "$CTD_SOCK" -n "$ns" tasks kill -s SIGKILL "$t" >/dev/null 2>&1 || true
            sudo timeout -k 3 20 ctr -a "$CTD_SOCK" -n "$ns" tasks delete --force "$t" >/dev/null 2>&1 || true
        done
        for c in $(sudo timeout -k 3 20 ctr -a "$CTD_SOCK" -n "$ns" containers ls -q 2>/dev/null); do
            sudo timeout -k 3 20 ctr -a "$CTD_SOCK" -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
        done
    done
fi

echo "[cleanup] stopping this case's containerd, its event recorder and what they left behind..."
# a ctr client of this case that was left running (or stopped by the terminal: SIGTTIN) keeps its
# `timeout` and `sudo` parents alive; SIGKILL works on a stopped process
kill_ours ctr KILL
kill_ours timeout KILL
kill_ours sudo KILL
kill_ours containerd TERM
for _ in $(seq 1 30); do any_ours containerd || break; sleep 0.5; done
kill_ours containerd KILL
# a container process that outlived its shim (its root dir is the rootfs below the work dir)
for p in $(sudo ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    r=$(sudo readlink "/proc/$p/root" 2>/dev/null) || continue
    case "$r" in "$WORK_DIR"/*) sudo kill -KILL "$p" 2>/dev/null || true;; esac
done
# the shims may outlive their daemon
for comm in containerd-shim containerd-shim-runc-v2; do
    kill_ours "$comm" KILL
done
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting
# anything: rm -rf must never walk into a live mount (overlay mounts of ctr or Docker, shm, netns).
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# the runc shim keeps its state under /run/containerd/runc/<namespace>, outside of RUN_BASE; the
# namespaces here (default, moby) are shared with other containerds on the host, so nothing is removed
# from there except the entries of this case's own containers (none are named by the case)
echo "[cleanup] removing the containerd state..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"

echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp"
echo "[cleanup] (a file written by a root command is not removable by the plain user: sticky /tmp)..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
