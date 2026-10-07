#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not
# running), and every command here may fail without aborting the cleanup.

CASE_ID="bench71572715"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
# k3s keeps files in fixed places outside the case's directories. They are removed only when setup.sh
# left this marker, i.e. when they are the case's own (setup.sh refuses to start on a host that has them).
OWNED_MARKER="$LIB_BASE/k3s_host_dirs_owned"
HOST_DIRS="/etc/rancher /var/lib/rancher /var/lib/kubelet /run/k3s"

# Kill the processes called $1 (exact process name) whose command line mentions $3 (default: this case's
# run dir). Matching by name first and by command line second is deliberate: 'pkill -f <path>' would also
# kill any shell whose own command line merely contains the path, including the one running this script.
kill_ours() {   # $1 = comm, $2 = signal, $3 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "${3:-$RUN_BASE}"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}
any_ours() {    # $1 = comm, $2 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "${2:-$RUN_BASE}" && return 0
    done
    return 1
}

if [ -e "$OWNED_MARKER" ]; then
    echo "[cleanup] stopping k3s (the one this case started; its own containerd goes with it)..."
    for p in $(pgrep -x k3s-server 2>/dev/null); do sudo kill -TERM "$p" 2>/dev/null || true; done
    for _ in $(seq 1 40); do pgrep -x k3s-server >/dev/null 2>&1 || break; sleep 1; done
    for p in $(pgrep -x k3s-server 2>/dev/null); do sudo kill -KILL "$p" 2>/dev/null || true; done
    # whatever k3s' own containerd left behind: the daemon and the shims name its socket
    for comm in containerd containerd-shim containerd-shim-runc-v2; do
        kill_ours "$comm" KILL "/run/k3s/"
    done
fi

# the tasks of the private (external) containerd first: the workload runs forever, and a leftover task
# keeps a shim and mounts alive
if [ -S "$CTD_SOCK" ] && command -v ctr >/dev/null 2>&1; then
    echo "[cleanup] removing every container and task of the external containerd (all namespaces)..."
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

echo "[cleanup] stopping this case's external containerd and what it left behind..."
# a ctr client of this case that was left running (or stopped by the terminal: SIGTTIN) keeps its
# `timeout` and `sudo` parents alive; SIGKILL works on a stopped process
kill_ours ctr KILL
kill_ours timeout KILL
kill_ours sudo KILL
kill_ours containerd TERM
for _ in $(seq 1 30); do any_ours containerd || break; sleep 0.5; done
kill_ours containerd KILL
# the shims may outlive their daemon
for comm in containerd-shim containerd-shim-runc-v2; do
    kill_ours "$comm" KILL
done
# a workload process that outlived its shim (its root dir is the rootfs below the work dir)
for p in $(sudo ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    r=$(sudo readlink "/proc/$p/root" 2>/dev/null) || continue
    case "$r" in "$WORK_DIR"/*) sudo kill -KILL "$p" 2>/dev/null || true;; esac
done
sleep 0.5

# Unmount whatever is still mounted below the case directories and below the k3s directories (deepest
# first) BEFORE deleting anything: rm -rf must never walk into a live mount (kubelet's own bind mount,
# overlay mounts of a container, shm).
for _ in 1 2 3; do
    bases="$RUN_BASE $LIB_BASE $WORK_DIR"
    [ -e "$OWNED_MARKER" ] && bases="$bases /var/lib/kubelet /var/lib/rancher /run/k3s"
    for base in $bases; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

if [ -e "$OWNED_MARKER" ]; then
    echo "[cleanup] removing the files k3s keeps outside the case's directories..."
    for d in $HOST_DIRS; do sudo rm -rf --one-file-system "$d"; done
fi

echo "[cleanup] removing the containerd and k3s state..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"

echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
