#!/bin/bash
# idempotent: safe to run when nothing exists (the cache of the downloaded releases is kept)

CASE_ID="bench76136482"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# containerd (and anything it started), the registry and the token service: through their control scripts, then by the command line of this lab
if [ -x "$LIB/bin/containerdctl" ]; then sudo "$LIB/bin/containerdctl" stop >/dev/null 2>&1; fi
if [ -x "$LIB/bin/hubctl" ]; then sudo "$LIB/bin/hubctl" stop >/dev/null 2>&1; fi
sudo pkill -KILL -f -- "--address /run/[b]ench76136482/containerd.sock" 2>/dev/null
sudo pkill -KILL -f -- "/var/lib/[b]ench76136482/libexec/registry" 2>/dev/null
sudo pkill -KILL -f -- "/var/lib/[b]ench76136482/auth/tokensrv.py" 2>/dev/null
sleep 1

# mounts (snapshots of containerd), the lab's lines of /etc/hosts
for base in "$RUN" "$LIB"; do
    awk -v b="$base/" 'index($2, b) == 1 {print $2}' /proc/mounts 2>/dev/null | sort -r | while read -r m; do sudo umount -l "$m" 2>/dev/null; done
done
sudo sed -i "/# $CASE_ID\$/d" /etc/hosts 2>/dev/null

sudo rm -rf "$RUN" "$LIB" "$WORK_DIR"
exit 0
