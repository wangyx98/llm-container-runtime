#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not
# running), and every command here may fail without aborting the cleanup.

CASE_ID="bench64460740"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

# Kill the processes called $1 (exact process name) whose command line mentions the run dir. Matching by
# name first and by command line second is deliberate: 'pkill -f <path>' would also kill any shell whose
# own command line merely contains the path, including the one running this script.
kill_ours() {   # $1 = comm, $2 = signal
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE "$RUN_BASE|$LIB_BASE"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}
any_ours() {    # $1 = comm
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE "$RUN_BASE|$LIB_BASE" && return 0
    done
    return 1
}

# the pods and containers of the private containerd first: a workload that runs forever keeps a shim and
# mounts alive
for SOCK in "$T_SOCK"; do
    if [ -S "$SOCK" ] && command -v ctr >/dev/null 2>&1; then
        echo "[cleanup] removing every container and task of the containerd at $SOCK (all namespaces)..."
        for ns in $(sudo timeout -k 3 20 ctr -a "$SOCK" namespaces ls -q 2>/dev/null); do
            for t in $(sudo timeout -k 3 20 ctr -a "$SOCK" -n "$ns" tasks ls -q 2>/dev/null); do
                sudo timeout -k 3 20 ctr -a "$SOCK" -n "$ns" tasks kill -s SIGKILL "$t" >/dev/null 2>&1 || true
                sudo timeout -k 3 20 ctr -a "$SOCK" -n "$ns" tasks delete --force "$t" >/dev/null 2>&1 || true
            done
            for c in $(sudo timeout -k 3 20 ctr -a "$SOCK" -n "$ns" containers ls -q 2>/dev/null); do
                sudo timeout -k 3 20 ctr -a "$SOCK" -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
            done
        done
    fi
done

# the ids of the node's pod and containers, as setup recorded them (read BEFORE the work dir goes): runc keeps a state directory per
# container in the runc root that all containerds of the machine share; when the daemon's data was deleted behind its back (or the
# daemon killed), nobody removes them
RECORDED_IDS=$(for f in container_app container_old container_job pod_id; do sudo cat "$WORK_DIR/.bench/$f" 2>/dev/null; done)

echo "[cleanup] stopping this case's containerd daemons, fixtures and what they left behind..."
# a client of this case that was left running (or stopped by the terminal: SIGTTIN) keeps its
# `timeout` and `sudo` parents alive; SIGKILL works on a stopped process
kill_ours ctr KILL
kill_ours crictl KILL
kill_ours timeout KILL
kill_ours sudo KILL
kill_ours containerd TERM
for _ in $(seq 1 30); do any_ours containerd || break; sleep 0.5; done
kill_ours containerd KILL
for comm in containerd-shim containerd-shim-runc-v2; do
    kill_ours "$comm" KILL
done
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything:
# rm -rf must never walk into a live mount (overlay mounts of a container, shm).
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

for id in $RECORDED_IDS; do
    sudo rm -rf --one-file-system /run/containerd/runc/*/"$id" 2>/dev/null || true
done

echo "[cleanup] removing the containerd state..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"

echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
