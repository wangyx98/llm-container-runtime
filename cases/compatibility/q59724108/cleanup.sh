#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned), and every command here may fail without aborting the cleanup.

CASE_ID="bench59724108"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
PODMAN="$LIB_BASE/bin/podman"

# the containers of the engineer's podman first (the service listens on port 8081 and keeps conmon and runc state)
if [ -x "$PODMAN" ]; then
    echo "[cleanup] removing the containers of the engineer's podman..."
    for id in $(sudo timeout -k 3 60 "$PODMAN" ps -aq --no-trunc 2>/dev/null); do
        sudo timeout -k 3 60 "$PODMAN" rm -f "$id" >/dev/null 2>&1 || true
    done
fi

# whatever of the case still runs: conmon, the service, a cleaner a solution started. Matched by the executable (a file below the case's
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
        case "$cmd" in *"$LIB_BASE/"*|*"$RUN_BASE/"*) sudo kill -KILL "$pid" 2>/dev/null ;; esac
    done
    sleep 0.3
done

# runc's state of the containers (runc's default root /run/runc is shared with the host: only the ids of the case's storage are touched)
if command -v runc >/dev/null 2>&1; then
    for id in $(ls "$RUN_BASE"/storage/*-containers 2>/dev/null); do
        sudo runc delete -f "$id" >/dev/null 2>&1 || true
    done
fi

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

echo "[cleanup] done. Environment reset to clean state (the programs compiled in /var/cache/$CASE_ID are kept)."
