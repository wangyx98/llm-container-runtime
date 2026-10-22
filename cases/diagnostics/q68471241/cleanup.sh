#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not running), and every command here may fail without aborting the cleanup.

CASE_ID="bench68471241"
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
any_ours() {    # $1 = comm, $2 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "${2:-$RUN}" && return 0
    done
    return 1
}

# the pods and containers of CRI-O first: they run forever, and a leftover one keeps a conmon and mounts alive
if [ -S "$RUN/crio.sock" ] && [ -x "$LIB/bin/crictl" ]; then
    echo "[cleanup] removing every pod and container of the CRI-O of the case..."
    sudo timeout -k 3 90 "$LIB/bin/crictl" -r "unix://$RUN/crio.sock" -i "unix://$RUN/crio.sock" --timeout 60s rmp -f -a >/dev/null 2>&1 || true
fi

echo "[cleanup] stopping CRI-O (the node's, the probe's and any started by hand), the registry and what they left behind..."
kill_ours crictl KILL
kill_ours timeout KILL
kill_ours sudo KILL
# every crio of the case, whatever it was started with: its command line or its program names the case's directories
for sig in TERM KILL; do
    for pid in $(pgrep -x crio 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID" || sudo readlink "/proc/$pid/exe" 2>/dev/null | grep -qF "$CASE_ID"; then
            sudo kill "-$sig" "$pid" 2>/dev/null || true
        fi
    done
    for _ in $(seq 1 30); do
        left=0
        for pid in $(pgrep -x crio 2>/dev/null); do
            if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID" || sudo readlink "/proc/$pid/exe" 2>/dev/null | grep -qF "$CASE_ID"; then left=1; fi
        done
        [ "$left" = 0 ] && break
        sleep 0.5
    done
done
# the registry of setup, the proxies and the servers that a solution may have started on the metrics port (their command lines name the case's directories)
kill_ours registry TERM "$LIB"
for p in $(pgrep -x python3 2>/dev/null); do
    sudo tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF "$CASE_ID" && ! sudo tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qE "cleanup.sh|setup.sh|oracle.sh|precondition.sh" && sudo kill -KILL "$p" 2>/dev/null
done
for _ in $(seq 1 20); do any_ours registry "$LIB" || break; sleep 0.5; done
kill_ours registry KILL "$LIB"
kill_ours conmon KILL
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything: rm -rf must never walk into a live mount (overlay mounts of a container, shm, namespaces).
for _ in 1 2 3; do
    for base in "$RUN" "$LIB" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# the cgroups of the containers of the case's CRI-O (below "crio"; setup recorded the ones that were there before): empty ones only, deepest first
if [ -e "$LIB/cgroups.before" ]; then
    for d in $(sudo find /sys/fs/cgroup -depth -type d \( -name crio -o -path '*/crio/*' -o -name 'crio-conmon-*' \) 2>/dev/null); do
        grep -qxF "$d" "$LIB/cgroups.before" || sudo rmdir "$d" 2>/dev/null || true
    done
fi

echo "[cleanup] removing the node, its state and the work dir (the downloaded releases stay in /var/cache/$CASE_ID)..."
sudo rm -rf --one-file-system "$RUN" "$LIB"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
