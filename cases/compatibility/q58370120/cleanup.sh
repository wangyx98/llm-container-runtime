#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned). The pinned runsc download in /var/cache/bench58370120 stays.
CASE_ID="bench58370120"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

protect=" $$ "
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    protect="$protect$p "
done

echo "[cleanup] deleting the runsc sandboxes of the case..."
if [ -x "$LIB_BASE/bin/runsc" ]; then
    for root in "$RUN_BASE"/*/; do
        [ -d "$root" ] || continue
        for id in $(sudo "$LIB_BASE/bin/runsc" --root "${root%/}" list -quiet 2>/dev/null); do
            sudo "$LIB_BASE/bin/runsc" --root "${root%/}" delete -force "$id" >/dev/null 2>&1
        done
    done
fi

echo "[cleanup] killing the processes that belong to the case (their command line names $CASE_ID)..."
for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    case "$protect" in *" $pid "*) continue ;; esac
    if sudo cat "$d/cmdline" 2>/dev/null | tr '\0' ' ' | grep -qF "$CASE_ID"; then
        sudo kill -KILL "$pid" 2>/dev/null
    fi
done
sleep 0.3

for m in $(awk -v b="$CASE_ID" 'index($2, b) {print $2}' /proc/mounts | sort -r); do sudo umount -l "$m" 2>/dev/null; done
sudo rm -rf --one-file-system "$WORK_DIR" "$RUN_BASE" "$LIB_BASE"
echo "[cleanup] done"
