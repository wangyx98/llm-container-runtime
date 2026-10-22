#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not running), and every command here may fail without aborting the cleanup.

CASE_ID="bench73341204"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
CSOCK="$RUN/containerd.sock"

# Kill the processes called $1 (exact process name) whose command line mentions $3 (default: this case's run dir).
kill_ours() {   # $1 = comm, $2 = signal, $3 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "${3:-$RUN}"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}
any_ours() {    # $1 = comm, $2 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "${2:-$RUN}" && return 0
    done
    return 1
}

echo "[cleanup] removing the tasks and containers of the lab's containerd (all namespaces)..."
if [ -S "$CSOCK" ] && command -v ctr >/dev/null 2>&1; then
    for ns in $(sudo timeout -k 3 20 ctr -a "$CSOCK" namespaces ls -q 2>/dev/null); do
        for t in $(sudo timeout -k 3 20 ctr -a "$CSOCK" -n "$ns" tasks ls -q 2>/dev/null); do
            sudo timeout -k 3 20 ctr -a "$CSOCK" -n "$ns" tasks kill -s SIGKILL "$t" >/dev/null 2>&1 || true
            sudo timeout -k 3 20 ctr -a "$CSOCK" -n "$ns" tasks delete --force "$t" >/dev/null 2>&1 || true
        done
        for c in $(sudo timeout -k 3 20 ctr -a "$CSOCK" -n "$ns" containers ls -q 2>/dev/null); do
            sudo timeout -k 3 20 ctr -a "$CSOCK" -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
        done
    done
fi
# the containers through runc (a container outlives its shim and containerd): the node's default root and the roots below the run dir
if command -v runc >/dev/null 2>&1; then
    for root in "$RUN/runc" $(sudo find "$RUN/containerd-runc" -mindepth 1 -maxdepth 1 -type d 2>/dev/null); do
        for id in $(sudo timeout -k 3 20 runc --root "$root" list -q 2>/dev/null); do
            sudo timeout -k 3 20 runc --root "$root" kill "$id" KILL >/dev/null 2>&1
        done
        sleep 0.5
        for id in $(sudo timeout -k 3 20 runc --root "$root" list -q 2>/dev/null); do
            sudo timeout -k 3 20 runc --root "$root" delete -f "$id" >/dev/null 2>&1
        done
    done
fi
# a shim's process name is cut to 15 characters: found by its command line; the lab's programs by their paths
for pid in $(sudo pgrep -f -- "containerd-shim-runc-v[2] .*$CSOCK" 2>/dev/null); do
    sudo kill -KILL "$pid" 2>/dev/null || true
done
# the lab's processes that outlived their containers (or that a solution started from the root file systems): found by the file they run
for pid in $(pgrep -x redis-server 2>/dev/null; pgrep -x idle 2>/dev/null); do
    if sudo readlink "/proc/$pid/exe" 2>/dev/null | grep -qF "$LIB/"; then sudo kill -KILL "$pid" 2>/dev/null || true; fi
done

echo "[cleanup] stopping this case's containerd..."
# containerd's command line names the configuration file in the lib dir (not the run dir)
kill_ours containerd TERM "$LIB"
for _ in $(seq 1 30); do any_ours containerd "$LIB" || break; sleep 0.5; done
kill_ours containerd KILL "$LIB"
kill_ours ctr KILL
kill_ours runc KILL
kill_ours timeout KILL
kill_ours sudo KILL
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything: rm -rf must never walk into a live mount.
for _ in 1 2 3; do
    for base in "$RUN" "$LIB" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done
# the cgroup directories of the lab's containers (the paths contain the case id)
for _ in 1 2 3; do
    sudo find /sys/fs/cgroup -maxdepth 9 -depth -type d -path "*$CASE_ID*" -exec rmdir {} \; 2>/dev/null
    sudo find /sys/fs/cgroup -maxdepth 9 -type d -path "*$CASE_ID*" 2>/dev/null | grep -q . || break
    sleep 1
done

echo "[cleanup] removing the state of the lab, the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf --one-file-system "$RUN" "$LIB"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
