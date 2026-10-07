#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, nothing running), and
# every command here may fail without aborting the cleanup.

CASE_ID="bench55103653"
CID="bench55103653-sub"
WORK_DIR="/tmp/$CASE_ID"

# Kill the processes called $1 (exact process name) whose command line mentions $2. Matching by name first
# and by command line second is deliberate: 'pkill -f <text>' would also kill any shell whose own command
# line merely contains the text, including the one running this script.
kill_ours() {   # $1 = comm, $2 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$2"; then
            sudo kill -KILL "$pid" 2>/dev/null || true
        fi
    done
}

echo "[cleanup] stopping the script of the case and what it started..."
kill_ours python3 "$WORK_DIR/capture_output.py"
kill_ours timeout "$CID"
kill_ours runc "$CID"
kill_ours sudo "$WORK_DIR"
kill_ours setsid "$WORK_DIR"

echo "[cleanup] deleting the container $CID (a container that is still running is killed)..."
if command -v runc >/dev/null 2>&1; then
    sudo timeout -k 3 20 runc delete -f "$CID" >/dev/null 2>&1 || true
fi
# a process of the container that outlived runc (its root dir is the rootfs below the work dir)
for p in $(sudo ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    r=$(sudo readlink "/proc/$p/root" 2>/dev/null) || continue
    case "$r" in "$WORK_DIR"/*) sudo kill -KILL "$p" 2>/dev/null || true;; esac
done
sleep 0.3
sudo timeout -k 3 20 runc delete -f "$CID" >/dev/null 2>&1 || true
# state directories and cgroups that runc left (it removes them itself on a normal delete)
sudo rm -rf --one-file-system "/run/runc/$CID" 2>/dev/null || true
for d in $(sudo find /sys/fs/cgroup -type d -name "$CID" 2>/dev/null | sort -r); do
    sudo rmdir "$d" 2>/dev/null || true
done

echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$WORK_DIR(/|\$)" | sort -r); do
    sudo umount -l "$m" 2>/dev/null || true
done
sudo rm -rf --one-file-system "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
