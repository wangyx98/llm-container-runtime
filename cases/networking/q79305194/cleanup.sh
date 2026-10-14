#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned) and every command may fail without aborting the cleanup.

CASE_ID="bench79305194"
WORK_DIR="/tmp/$CASE_ID"
LIB="/var/lib/$CASE_ID"
UNIT="$CASE_ID-containerd.service"

echo "[cleanup] stopping the service and its sandboxes and containers (the shims, the processes of the sandboxes)..."
[ -e /etc/systemd/system/$UNIT ] && { sudo timeout 60 systemctl stop "$UNIT" >/dev/null 2>&1; sudo systemctl reset-failed "$UNIT" >/dev/null 2>&1; }
for sig in TERM KILL; do
    ps -eo pid=,comm=,args= | awk -v re="$CASE_ID" '($2=="containerd" || $2=="containerd-shim-r" || $2=="python3" || $2=="pause" || $2=="app") && $0 ~ re {print $1}' | xargs -r sudo kill -$sig >/dev/null 2>&1
    sleep 1
done
# the processes of the sandboxes (pause, the workload) have no case name in their command line, their cgroup (cgroup_parent /bench79305194-pods) has
for p in $(sudo grep -l -e "$CASE_ID" /proc/[0-9]*/cgroup 2>/dev/null | sed 's#/proc/\([0-9]*\)/cgroup#\1#'); do
    [ "$p" = "$$" ] || sudo kill -KILL "$p" >/dev/null 2>&1
done
for _ in 1 2 3; do ps -eo args= | grep -e "-address $LIB\|-address /run/$CASE_ID" | grep -v grep | grep -q . || break; sleep 1; done

echo "[cleanup] unmounting what the sandboxes left below the lab's directories (deepest first), removing their cgroup directories..."
for _ in 1 2 3; do
    awk '{print $2}' /proc/mounts | grep -e "$CASE_ID" | sort -r | while read -r m; do sudo umount "$m" >/dev/null 2>&1 || sudo umount -l "$m" >/dev/null 2>&1; done
    awk '{print $2}' /proc/mounts | grep -q -e "$CASE_ID" || break
    sleep 1
done
for _ in 1 2 3; do
    sudo find /sys/fs/cgroup -maxdepth 9 -depth -type d -path "*$CASE_ID*" -exec rmdir {} \; 2>/dev/null
    sudo find /sys/fs/cgroup -maxdepth 9 -type d -path "*$CASE_ID*" 2>/dev/null | grep -q . || break
    sleep 1
done

echo "[cleanup] removing the unit and its drop-ins and the name in /etc/hosts..."
sudo rm -rf /etc/systemd/system/*"$CASE_ID"*
sudo systemctl daemon-reload >/dev/null 2>&1
sudo sed -i "/# $CASE_ID\$/d" /etc/hosts

echo "[cleanup] removing the lab's directories and the work dir (the downloaded release in /var/cache/$CASE_ID stays: it is checked against its published checksum at every setup)..."
sudo rm -rf "/etc/$CASE_ID" "$LIB" /run/"$CASE_ID" "$WORK_DIR" "$WORK_DIR"-* /tmp/"$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
