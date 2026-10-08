#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not
# running), and every command here may fail without aborting the cleanup.

CASE_ID="bench62675268"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
CRIO_SOCK="$RUN_BASE/crio.sock"

# Kill the processes called $1 (exact process name) whose command line mentions the run dir. Matching by
# name first and by command line second is deliberate: 'pkill -f <path>' would also kill any shell whose
# own command line merely contains the path, including the one running this script.
kill_ours() {   # $1 = comm, $2 = signal
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$RUN_BASE"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}
any_ours() {    # $1 = comm
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$RUN_BASE" && return 0
    done
    return 1
}

IDS=""
# the pods and containers of the private CRI-O first: a sandbox keeps a conmon, a pause process and mounts alive
if [ -S "$CRIO_SOCK" ] && command -v crictl >/dev/null 2>&1; then
    echo "[cleanup] removing every pod and container of this case's CRI-O..."
    CRI=(sudo timeout -k 3 30 crictl --runtime-endpoint "unix://$CRIO_SOCK" --image-endpoint "unix://$CRIO_SOCK" --timeout 20s)
    IDS="$("${CRI[@]}" pods -q --no-trunc 2>/dev/null) $("${CRI[@]}" ps -a -q --no-trunc 2>/dev/null)"
    "${CRI[@]}" rmp -a -f >/dev/null 2>&1 || true
fi

echo "[cleanup] stopping this case's CRI-O, fixtures and what they left behind..."
# a client of this case that was left running (or stopped by the terminal: SIGTTIN) keeps its
# `timeout` and `sudo` parents alive; SIGKILL works on a stopped process
kill_ours crictl KILL
kill_ours timeout KILL
kill_ours sudo KILL
kill_ours python3 KILL          # the registry fixture and the egress proxy (their command lines name the run dir)
kill_ours crio TERM
for _ in $(seq 1 30); do any_ours crio || break; sleep 0.5; done
kill_ours crio KILL
# what a sandbox left: the runtime's own state names every container (runc --root), and conmon names the run dir
if command -v runc >/dev/null 2>&1 && [ -d "$RUN_BASE/runc" ]; then
    for c in $(sudo runc --root "$RUN_BASE/runc" list -q 2>/dev/null); do
        IDS="$IDS $c"
        sudo runc --root "$RUN_BASE/runc" delete -f "$c" >/dev/null 2>&1 || true
    done
fi
kill_ours conmon KILL
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything:
# rm -rf must never walk into a live mount (overlay mounts of a container, shm, namespace pins).
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# cgroups of the sandboxes (cgroupfs driver, /crio-<id>): CRI-O removes them when it removes a pod, but a pod that
# was killed with its CRI-O leaves them; the ids are the ones collected above
for id in $IDS; do
    [ "${#id}" -ge 32 ] || continue
    sudo find /sys/fs/cgroup -depth -type d -name "*$id*" -exec rmdir {} + 2>/dev/null || true
done

echo "[cleanup] removing the CRI-O state..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"

echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
