#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, containerd not running), and every command here may fail without
# aborting the cleanup.

CTD_SOCK="/run/containerd/containerd.sock"
BK_SOCK="/run/buildkit/buildkitd.sock"
CASE_ID="bench71709053"
RUN_DIR="/run/$CASE_ID"
LIB_DIR="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
NAME_PREFIX="$CASE_ID"     # every image this case can create has this in its name

echo "[cleanup] stopping the BuildKit daemon this case runs..."
# Match by process name (comm) first, NOT with 'pkill -f': a pattern in a
# command line would also match the shell that is running this very script.
# setup.sh takes over BuildKit's default socket, so every buildkitd is ours.
for pid in $(pgrep -x buildkitd 2>/dev/null); do
    sudo kill "$pid" 2>/dev/null || true
done
for _ in $(seq 1 20); do
    pgrep -x buildkitd >/dev/null 2>&1 || break
    sleep 0.5
done
for pid in $(pgrep -x buildkitd 2>/dev/null); do
    sudo kill -9 "$pid" 2>/dev/null || true
done
sudo rm -rf "$(dirname "$BK_SOCK")"   # stale sockets of the killed daemon

if command -v ctr >/dev/null 2>&1 && [ -S "$CTD_SOCK" ]; then
    echo "[cleanup] removing this case's images from every containerd namespace..."
    for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
        for ref in $(sudo ctr -n "$ns" images ls -q 2>/dev/null | grep -F "$NAME_PREFIX"); do
            sudo ctr -n "$ns" images rm "$ref" >/dev/null 2>&1 || true
        done
    done
    # BuildKit's own namespaces ('buildkit' for the worker, 'buildkit_history'
    # for its build records): setup.sh took BuildKit over for this case, so
    # drop their leases and blobs and then the namespaces themselves
    for ns in buildkit buildkit_history default_history; do
        for lease in $(sudo ctr -n "$ns" leases ls -q 2>/dev/null); do
            sudo ctr -n "$ns" leases rm --sync "$lease" >/dev/null 2>&1 || true
        done
        BLOBS=$(sudo ctr -n "$ns" content ls -q 2>/dev/null | tr '\n' ' ')
        [ -n "$BLOBS" ] && sudo ctr -n "$ns" content rm $BLOBS >/dev/null 2>&1
        sudo ctr namespaces rm "$ns" >/dev/null 2>&1 || true
    done
fi

echo "[cleanup] removing the work dir, BuildKit's state and the run dir..."
sudo rm -rf "$WORK_DIR" "$LIB_DIR" "$RUN_DIR"

echo "[cleanup] done. Environment reset to clean state."
