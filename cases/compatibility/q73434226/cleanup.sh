#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned), and every command may fail without aborting the cleanup.

CASE_ID="bench73434226"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
RUNC_ROOT="$RUN_BASE/runc"

echo "[cleanup] deleting the containers in runc's root of the case (every id, whichever runc made them)..."
for r in "$LIB_BASE/bin/runc" "$(command -v runc)"; do
    [ -x "$r" ] || continue
    for id in $(sudo timeout -k 3 20 "$r" --root "$RUNC_ROOT" list -q 2>/dev/null); do
        sudo timeout -k 3 20 "$r" --root "$RUNC_ROOT" delete -f "$id" >/dev/null 2>&1 || true
    done
done

# what is left of them: every process in a cgroup of the case (a container the solution made with another root, or whose state is gone)
for d in /proc/[0-9]*; do
    if sudo grep -q "$CASE_ID" "$d/cgroup" 2>/dev/null; then sudo kill -KILL "${d#/proc/}" 2>/dev/null || true; fi
done
sleep 0.5

echo "[cleanup] stopping the systemd scopes of the case and removing the cgroups made without systemd..."
for u in $(systemctl list-units --all --plain --no-legend "$CASE_ID-*" 2>/dev/null | awk '{print $1}'); do
    sudo systemctl stop "$u" >/dev/null 2>&1 || true
    sudo systemctl reset-failed "$u" >/dev/null 2>&1 || true
done
removed=0
for f in /run/systemd/transient/"$CASE_ID"-*; do
    [ -e "$f" ] || continue
    sudo rm -rf "$f"; removed=1
done
[ "$removed" = 1 ] && sudo systemctl daemon-reload >/dev/null 2>&1
# a container made with the cgroupfs driver lives in a directory of its own (runc delete removes it, a killed process leaves it)
for _ in 1 2 3; do
    sudo find /sys/fs/cgroup -depth -type d -name "$CASE_ID*" -exec rmdir {} \; 2>/dev/null
    sleep 0.3
done

echo "[cleanup] unmounting what is still mounted below the case directories..."
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

echo "[cleanup] removing the state, the bundle, the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state (the download in /var/cache/$CASE_ID is kept)."
