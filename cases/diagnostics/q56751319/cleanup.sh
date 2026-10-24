#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned), and every command here may fail without aborting the cleanup.
# The downloaded runc in /var/cache/bench56751319 is kept on purpose (checked against a pinned sha256 by setup.sh); delete that directory by hand to free the space.

CASE_ID="bench56751319"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

echo "[cleanup] stopping the containers of the cell (the runc root of each, then whatever still runs in the case's cgroups or from its directories)..."
for root in "$RUN"/garden/*/; do
    [ -d "$root" ] || continue
    for id in $(sudo ls "$root" 2>/dev/null); do
        [ -f "$root/$id/state.json" ] && sudo timeout -k 3 20 "$LIB/packages/runc/runc.bin" --root "$root" delete -f "$id" >/dev/null 2>&1
    done
done
for _ in 1 2 3; do
    for f in $(sudo find /sys/fs/cgroup -path "*/$CASE_ID/*" -name cgroup.procs 2>/dev/null); do
        for pid in $(sudo cat "$f" 2>/dev/null); do sudo kill -KILL "$pid" 2>/dev/null || true; done
    done
    # a program of a solution started on the host (and a container's init, whose exe is a file of the case)
    for pid in $(sudo find /proc -maxdepth 1 -regex '/proc/[0-9]+' 2>/dev/null | sed 's|/proc/||'); do
        [ "$pid" = "$$" ] && continue
        if sudo readlink "/proc/$pid/exe" 2>/dev/null | grep -qF "$CASE_ID"; then sudo kill -KILL "$pid" 2>/dev/null || true; fi
    done
    sleep 0.3
done

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything: rm -rf must never walk into a live mount (a container's rootfs).
for _ in 1 2 3; do
    for base in "$RUN" "$LIB" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# the cgroups of the containers (/bench56751319/garden/<handle> in every hierarchy): empty ones only, deepest first
for d in $(sudo find /sys/fs/cgroup -depth -type d \( -path "*/$CASE_ID" -o -path "*/$CASE_ID/*" \) 2>/dev/null); do
    sudo rmdir "$d" 2>/dev/null || true
done

echo "[cleanup] removing the cell and the work dir (the downloaded runc stays in /var/cache/$CASE_ID)..."
sudo rm -rf --one-file-system "$RUN" "$LIB"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
