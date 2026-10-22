#!/bin/bash
# idempotent: safe to run when nothing exists (the cache of the downloaded release is kept)

CASE_ID="bench72879219"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

if [ -x "$LIB/bin/containerdctl" ]; then sudo "$LIB/bin/containerdctl" stop >/dev/null 2>&1; fi
sudo pkill -KILL -f -- "--address /run/[b]ench72879219/containerd.sock" 2>/dev/null
sudo pkill -KILL -f -- "/tmp/[b]ench72879219/.bench/" 2>/dev/null     # the temporary instance of precondition.sh
sleep 1
for base in "$RUN" "$LIB" "$WORK_DIR"; do
    awk -v b="$base/" 'index($2, b) == 1 {print $2}' /proc/mounts 2>/dev/null | sort -r | while read -r m; do sudo umount -l "$m" 2>/dev/null; done
done
sudo rm -rf "$RUN" "$LIB" "$WORK_DIR"
exit 0
