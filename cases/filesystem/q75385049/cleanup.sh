#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, containerd not running), and every command here may fail without
# aborting the cleanup.

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench75385049"
NS="$CASE_ID"               # the containerd namespace this case works in
WORK_DIR="/tmp/$CASE_ID"
NAME_PREFIX="$CASE_ID"      # every image name this case can create has this in it
CTR="sudo ctr"

if command -v ctr >/dev/null 2>&1 && [ -S "$SOCK" ] && $CTR version >/dev/null 2>&1; then
    echo "[cleanup] emptying the case's containerd namespace '$NS' (containers, images,"
    echo "[cleanup] content blobs, snapshots) and deleting it..."
    for c in $($CTR -n "$NS" containers ls -q 2>/dev/null); do
        $CTR -n "$NS" tasks kill -s SIGKILL "$c" >/dev/null 2>&1 || true
        $CTR -n "$NS" tasks rm -f "$c" >/dev/null 2>&1 || true
        $CTR -n "$NS" containers rm "$c" >/dev/null 2>&1 || true
    done
    for ref in $($CTR -n "$NS" images ls -q 2>/dev/null); do
        $CTR -n "$NS" images rm --sync "$ref" >/dev/null 2>&1 || true
    done
    # an import that creates no image (the symptom of this case) still leaves
    # blobs and unpacked snapshots in the namespace; a namespace can only be
    # deleted once those are gone too
    for d in $($CTR -n "$NS" content ls -q 2>/dev/null); do
        $CTR -n "$NS" content rm "$d" >/dev/null 2>&1 || true
    done
    # snapshots depend on their parents: remove what can be removed, repeat
    for _ in 1 2 3 4 5 6; do
        keys=$($CTR -n "$NS" snapshots ls 2>/dev/null | awk 'NR > 1 {print $1}')
        [ -n "$keys" ] || break
        for k in $keys; do
            $CTR -n "$NS" snapshots rm "$k" >/dev/null 2>&1 || true
        done
    done
    $CTR namespaces rm "$NS" >/dev/null 2>&1 || true

    echo "[cleanup] removing images a solution may have imported into another namespace"
    echo "[cleanup] (for instance by forgetting -n)..."
    for ns in $($CTR namespaces ls -q 2>/dev/null); do
        for ref in $($CTR -n "$ns" images ls -q 2>/dev/null | grep -F "$NAME_PREFIX"); do
            $CTR -n "$ns" images rm --sync "$ref" >/dev/null 2>&1 || true
        done
    done
fi

echo "[cleanup] removing the work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done."
