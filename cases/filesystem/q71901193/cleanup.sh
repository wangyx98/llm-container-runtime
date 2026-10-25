#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not running), and every command here may fail without aborting the cleanup.

CASE_ID="bench71901193"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# The programs of the containers (their cgroup is /$CASE_ID/...), then the node's own programs (containerd, its shims, runc), found by the file they run from or by their cgroup. No
# 'pkill -f <text>': it would also kill the shell that runs this script, whose command line contains the text.
node_pids() { for d in /proc/[0-9]*; do case "$(sudo readlink "$d/exe" 2>/dev/null)" in "$LIB/node/bin/"*) echo "${d#/proc/}" ;; esac; done; }
echo "[cleanup] stopping the node (containerd, its shims, the containers' processes)..."
if [ -x "$LIB/bin/nodectl" ]; then sudo timeout -k 3 90 "$LIB/bin/nodectl" stop >/dev/null 2>&1 || true; fi
for p in $(pgrep -x python3 2>/dev/null); do
    sudo tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF "$CASE_ID" || continue
    sudo tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qE "cleanup.sh|setup.sh|oracle.sh|precondition.sh" && continue
    sudo kill -KILL "$p" 2>/dev/null
done
for sig in TERM KILL; do
    for pid in $(node_pids); do
        for child in $(pgrep -P "$pid" 2>/dev/null); do sudo kill -KILL "$child" 2>/dev/null; done   # a shim's children are the containers' programs, whatever cgroup nerdctl put them in
        sudo kill "-$sig" "$pid" 2>/dev/null
    done
    for d in /proc/[0-9]*; do
        if sudo grep -qE "(^|/)$CASE_ID(/|$)" "$d/cgroup" 2>/dev/null; then sudo kill "-$sig" "${d#/proc/}" 2>/dev/null; fi
    done
    for _ in $(seq 1 20); do [ -z "$(node_pids)" ] && break; sleep 0.5; done
done

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything: rm -rf must never walk into a live mount (the rootfs of a container is an overlay).
for _ in 1 2 3; do
    for base in "$RUN" "$LIB" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# the cgroups of the containers (v2: /sys/fs/cgroup/$CASE_ID; v1: one per controller)
for cg in /sys/fs/cgroup/$CASE_ID /sys/fs/cgroup/*/$CASE_ID; do
    [ -d "$cg" ] || continue
    sudo find "$cg" -depth -type d -exec rmdir {} \; 2>/dev/null
done

echo "[cleanup] removing the node, its state and the work dir (the downloaded releases stay in /var/cache/$CASE_ID)..."
sudo rm -rf --one-file-system "$RUN" "$LIB"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
