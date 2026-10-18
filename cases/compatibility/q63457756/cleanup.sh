#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned), and every command here may fail without aborting the cleanup.

CASE_ID="bench63457756"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# the engineer's stack first (dockerd, then containerd)
if [ -x "$LIB_BASE/bin/stack" ]; then
    echo "[cleanup] stopping the engineer's stack..."
    sudo timeout -k 3 90 "$LIB_BASE/bin/stack" stop >/dev/null 2>&1 || true
fi

# whatever of the case still runs: the daemons, shims, containers, a loop a solution started. Matched by the executable (a file below the case's
# directories) or by the case's paths on the command line; this script and its parents are never touched
protect=" $$ "
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    protect="$protect$p "
done
for _ in 1 2 3; do
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        case "$protect" in *" $pid "*) continue ;; esac
        exe="$(readlink "$d/exe" 2>/dev/null)"
        cmd="$(sudo tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
        case "$exe" in "$LIB_BASE"/*|"$RUN_BASE"/*) sudo kill -KILL "$pid" 2>/dev/null; continue ;; esac
        case "$cmd" in *"$LIB_BASE/"*|*"$RUN_BASE/"*|*"-namespace $CASE_ID "*) sudo kill -KILL "$pid" 2>/dev/null ;; esac
    done
    sleep 0.3
done

# runc's state of the containers of the case's containerd namespace (the shims keep it below /run/containerd/runc/<namespace>)
sudo rm -rf --one-file-system "/run/containerd/runc/$CASE_ID" "/run/containerd/runc/$CASE_ID-plugins"

# unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

echo "[cleanup] removing the state of the case..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"
echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state (Go and the two compiled packages in /var/cache/$CASE_ID are kept)."
