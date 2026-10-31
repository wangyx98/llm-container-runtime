#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a node not running), and every command here may fail without aborting the cleanup.

CASE_ID="bench58642878"
LIB="/var/lib/$CASE_ID"
DISK="/mnt/$CASE_ID-disk"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

echo "[cleanup] stopping the node (k3s, its containerd, the shims, the containers' programs)..."
[ -x "$LIB/bin/k3sctl" ] && sudo timeout -k 3 150 "$LIB/bin/k3sctl" stop >/dev/null 2>&1
for sig in TERM KILL; do    # whatever k3sctl could not find: the lab's k3s program, shims of the node's containerd socket, programs running from the lab
    for p in $(pgrep -f -- "-address /run/k3s/containerd/containerd.sock" 2>/dev/null); do
        for c in $(pgrep -P "$p"); do sudo kill -KILL "$c" 2>/dev/null; done
        sudo kill "-$sig" "$p" 2>/dev/null
    done
    for d in /proc/[0-9]*; do
        e=$(sudo readlink "$d/exe" 2>/dev/null)
        case "$e" in "$LIB"/*|"$DISK"/*|"$WORK_DIR"/*) sudo kill "-$sig" "${d#/proc/}" 2>/dev/null ;; esac
    done
    sleep 1
done

# Unmount whatever is still mounted below the case's directories (deepest first) BEFORE deleting anything: rm -rf must never walk into a live mount.
for _ in 1 2 3; do
    for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^($LIB|/run/k3s|$DISK|$WORK_DIR)(/|$)" | sort -r); do
        sudo umount -l "$m" 2>/dev/null || true
    done
done
for l in $(sudo losetup -j "$LIB/disk.img" 2>/dev/null | cut -d: -f1); do sudo losetup -d "$l" 2>/dev/null; done

echo "[cleanup] removing the lab, the disk's directory, the work dir (the k3s release stays in /var/cache/$CASE_ID)..."
sudo test -f "$STATE_DIR/owns-run-k3s" && sudo rm -rf /run/k3s
sudo test -f "$STATE_DIR/owns-etc-rancher" && sudo rm -rf /etc/rancher
sudo test -f "$STATE_DIR/owns-var-lib-rancher" && sudo rm -rf /var/lib/rancher
sudo rm -rf --one-file-system "$LIB"
sudo rmdir "$DISK" 2>/dev/null
sudo sh -c "rm -rf /var/log/pods/*b58642878* /var/log/containers/*b58642878*" 2>/dev/null
sudo rm -rf --one-file-system "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
