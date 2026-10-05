#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, containerd not running), and every command here may fail without
# aborting the cleanup.

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench75533491"
WORK_DIR="/tmp/$CASE_ID"

if command -v ctr >/dev/null 2>&1 && [ -S "$SOCK" ] && sudo ctr version >/dev/null 2>&1; then
    echo "[cleanup] removing the containers carrying this case's label, in every namespace. Nothing else"
    echo "[cleanup] is touched..."
    for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
        for c in $(sudo ctr -n "$ns" containers ls -q "labels.$CASE_ID==1" 2>/dev/null); do
            timeout -k 5 20 sudo ctr -n "$ns" tasks kill -s SIGKILL "$c" >/dev/null 2>&1 || true
            timeout -k 5 20 sudo ctr -n "$ns" tasks delete --force "$c" >/dev/null 2>&1 || true
            timeout -k 5 20 sudo ctr -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
        done
    done
fi

# runc removes a container's own cgroup directory, not the parent directories the case's cgroup paths
# put it under: remove those (empty, so rmdir works, deepest first)
echo "[cleanup] removing the cgroup directories made for the case..."
for _ in 1 2 3 4 5; do
    LEFT=0
    for d in $(sudo find /sys/fs/cgroup -mindepth 1 -maxdepth 2 -type d -name "$CASE_ID*" 2>/dev/null); do
        sudo find "$d" -depth -type d -exec rmdir {} \; >/dev/null 2>&1
        [ -d "$d" ] && LEFT=1
    done
    [ "$LEFT" = 0 ] && break
    sleep 1
done

echo "[cleanup] removing the work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done."
