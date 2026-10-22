#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not
# running), and every command here may fail without aborting the cleanup.

CASE_ID="bench54303822"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
CSOCK="$RUN_BASE/containerd.sock"
DSOCK="$RUN_BASE/docker.sock"

# Kill the processes called $1 (exact process name) whose command line mentions $3 (default: this case's run dir).
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

echo "[cleanup] removing the containers of the lab, stopping its dockerd..."
if [ -S "$DSOCK" ] && command -v docker >/dev/null 2>&1; then
    for c in $(sudo timeout -k 3 30 docker -H "unix://$DSOCK" ps -aq 2>/dev/null); do
        sudo timeout -k 3 30 docker -H "unix://$DSOCK" rm -f "$c" >/dev/null 2>&1 || true
    done
fi
kill_ours dockerd TERM
for _ in $(seq 1 40); do any_ours dockerd || break; sleep 0.5; done
kill_ours dockerd KILL

# the tasks of the lab's containerd (all namespaces), then the containers through runc (a container outlives its shim and containerd)
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
if command -v runc >/dev/null 2>&1; then
    for root in $(sudo find "$RUN_BASE/exec/runtime-runc" -mindepth 1 -maxdepth 1 -type d 2>/dev/null); do
        for id in $(sudo timeout -k 3 20 runc --root "$root" list -q 2>/dev/null); do
            sudo timeout -k 3 20 runc --root "$root" kill "$id" KILL >/dev/null 2>&1
        done
        sleep 0.5
        for id in $(sudo timeout -k 3 20 runc --root "$root" list -q 2>/dev/null); do
            sudo timeout -k 3 20 runc --root "$root" delete -f "$id" >/dev/null 2>&1
        done
    done
fi
# a shim's process name is cut to 15 characters: found by its command line
for pid in $(sudo pgrep -f -- "containerd-shim-runc-v[2] .*$RUN_BASE/containerd.sock" 2>/dev/null); do
    sudo kill -KILL "$pid" 2>/dev/null || true
done
echo "[cleanup] stopping this case's containerd..."
# containerd's command line names the configuration file in the lib dir (not the run dir)
kill_ours containerd TERM "$LIB_BASE"
for _ in $(seq 1 30); do any_ours containerd "$LIB_BASE" || break; sleep 0.5; done
kill_ours containerd KILL "$LIB_BASE"
kill_ours docker KILL
kill_ours ctr KILL
kill_ours timeout KILL
kill_ours sudo KILL
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything: rm -rf must never walk into a live mount.
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

echo "[cleanup] removing the state of the lab..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"

echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
