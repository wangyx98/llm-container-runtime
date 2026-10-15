#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned) and every command may fail without aborting the cleanup.

CASE_ID="bench60208766"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
LIB="/var/lib/$CASE_ID"
UNIT="$CASE_ID-containerd.service"
BASE="$LIB/baseline"                    # what setup.sh saved of the places where a solution may have put a proxy variable and of the kernel's forwarding switch

echo "[cleanup] stopping the service, its sandboxes and containers (the shims, the processes of the sandboxes), the lab's API, registry and proxy..."
[ -e /etc/systemd/system/$UNIT ] && { sudo timeout 60 systemctl stop "$UNIT" >/dev/null 2>&1; sudo systemctl reset-failed "$UNIT" >/dev/null 2>&1; }
for sig in TERM KILL; do
    ps -eo pid=,comm=,args= | awk -v re="$CASE_ID" '($2=="containerd" || $2=="containerd-shim-r" || $2=="python3" || $2=="pause" || $2=="app" || $2=="calico" || $2=="calico-ipam") && $0 ~ re {print $1}' | xargs -r sudo kill -$sig >/dev/null 2>&1
    sleep 1
done
# the processes of the sandboxes (pause, the workload) have no case name in their command line, their cgroup (cgroup_parent /bench60208766-pods) has
for p in $(sudo grep -l -e "$CASE_ID" /proc/[0-9]*/cgroup 2>/dev/null | sed 's#/proc/\([0-9]*\)/cgroup#\1#'); do
    [ "$p" = "$$" ] || sudo kill -KILL "$p" >/dev/null 2>&1
done
for _ in 1 2 3; do ps -eo args= | grep -e "-address $LIB\|-address /run/$CASE_ID" | grep -v grep | grep -q . || break; sleep 1; done

echo "[cleanup] unmounting what the sandboxes left below the lab's directories (the network namespaces are there too), removing their cgroup directories..."
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

echo "[cleanup] removing the address 10.96.0.1 of the API Service (the loopback alias)..."
sudo python3 "$CASE_DIR/helpers/alias.py" del "lo:b60208766" 10.96.0.1 >/dev/null 2>&1

echo "[cleanup] removing the unit and its drop-ins, the name in /etc/hosts, and what a solution may have put elsewhere (profile.d, /etc/environment, the manager's environment); restoring the forwarding switch; removing the Calico lock file..."
sudo rm -rf /etc/systemd/system/*"$CASE_ID"* /etc/default/"$CASE_ID"-containerd /etc/sysconfig/"$CASE_ID"-containerd
sudo systemctl daemon-reload >/dev/null 2>&1
sudo sed -i "/# $CASE_ID\$/d" /etc/hosts
if [ -d "$BASE" ]; then
    if [ -e "$BASE/environment" ]; then sudo cp -p "$BASE/environment" /etc/environment; else sudo rm -f /etc/environment; fi
    for f in /etc/profile.d/*; do [ -e "$f" ] && ! grep -qxF "$(basename "$f")" "$BASE/profile.d.list" && sudo rm -rf "$f"; done
    if [ -d /etc/systemd/system.conf.d ]; then
        for f in /etc/systemd/system.conf.d/*; do [ -e "$f" ] && ! grep -qxF "$(basename "$f")" "$BASE/system.conf.d.list" && sudo rm -rf "$f"; done
        [ -e "$BASE/system.conf.d.absent" ] && sudo rmdir /etc/systemd/system.conf.d 2>/dev/null
    fi
    [ -e "$BASE/system.conf" ] && sudo cp -p "$BASE/system.conf" /etc/systemd/system.conf
    sudo systemctl daemon-reload >/dev/null 2>&1
    [ -s "$BASE/ip_forward" ] && sudo sh -c 'cat "$1" > /proc/sys/net/ipv4/ip_forward' _ "$BASE/ip_forward"
    if [ ! -e "$BASE/run-calico.existed" ]; then sudo rm -f /run/calico/ipam.lock; sudo rmdir /run/calico >/dev/null 2>&1; fi
fi

echo "[cleanup] removing the lab's directories and the work dir (the downloaded releases in /var/cache/$CASE_ID stay: they are checked against their checksums at every setup)..."
sudo rm -rf "/etc/$CASE_ID" "$LIB" /run/"$CASE_ID" "$WORK_DIR" "$WORK_DIR"-* /tmp/"$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
