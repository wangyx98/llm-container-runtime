#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, no unit, no daemon),
# and every command here may fail without aborting the cleanup.

CASE_ID="bench71584810"
UNITS=("$CASE_ID-app.service" "$CASE_ID-registry.service" "$CASE_ID-containerd.service")
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# Kill the processes called $1 (exact process name) whose command line mentions the case dirs. Matching by
# name first and by command line second is deliberate: 'pkill -f <path>' would also kill any shell whose own
# command line merely contains the path, including the one running this script.
ours_re="$RUN_BASE|$LIB_BASE|$WORK_DIR|$CASE_ID"
kill_ours() {   # $1 = comm, $2 = signal
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE "$ours_re"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}
any_ours() {    # $1 = comm
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE "$ours_re" && return 0
    done
    return 1
}

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    echo "[cleanup] stopping and removing the systemd units of the case (every place a unit can live)..."
    for u in "${UNITS[@]}"; do
        sudo timeout 60 systemctl disable --now "$u" >/dev/null 2>&1 || true
        sudo timeout 60 systemctl stop "$u" >/dev/null 2>&1 || true
        sudo timeout 20 systemctl kill --signal=SIGKILL "$u" >/dev/null 2>&1 || true
    done
    for d in /etc/systemd/system /etc/systemd/system.control /usr/local/lib/systemd/system \
             /usr/lib/systemd/system /lib/systemd/system /run/systemd/system /run/systemd/system.control \
             /run/systemd/transient; do
        [ -d "$d" ] && sudo find "$d" -maxdepth 3 -name "$CASE_ID-*" -exec rm -rf {} + 2>/dev/null
    done
    sudo timeout 60 systemctl daemon-reload >/dev/null 2>&1 || true
    for u in "${UNITS[@]}"; do
        sudo timeout 20 systemctl reset-failed "$u" >/dev/null 2>&1 || true
    done
fi

echo "[cleanup] stopping what is left of the case's processes (also ones a solution started by hand)..."
# a client of this case that was left running (or stopped by the terminal: SIGTTIN) keeps its
# `timeout` and `sudo` parents alive; SIGKILL works on a stopped process
for c in crictl ctr journalctl python3 tail timeout sudo; do
    kill_ours "$c" KILL
done
kill_ours containerd TERM
for _ in $(seq 1 30); do any_ours containerd || break; sleep 0.5; done
kill_ours containerd KILL
for comm in containerd-shim containerd-shim-runc-v2; do
    kill_ours "$comm" KILL
done
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything.
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

echo "[cleanup] removing the containerd state, its root and the work dir (and files a solution left beside it in /tmp)..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*
# the journal keeps the lines the units logged (it is the host's, and is not the case's to rotate or vacuum): they are history, not state

echo "[cleanup] done. Environment reset to clean state."
