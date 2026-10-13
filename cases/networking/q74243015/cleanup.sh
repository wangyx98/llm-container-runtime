#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned) and every command may fail without aborting the cleanup.

CASE_ID="bench74243015"
UNIT="$CASE_ID-crio.service"
HOST="registry.$CASE_ID.test"
WORK_DIR="/tmp/$CASE_ID"
BASE="/var/lib/$CASE_ID/baseline"       # what setup.sh saved of the places where a solution may have put a proxy variable (outside the lab's own files)

echo "[cleanup] stopping the service and the Pods of the lab (runc roots below /run/$CASE_ID*, the conmon of each Pod, the throw-away CRI-O of the precondition)..."
if [ -e "/etc/systemd/system/$UNIT" ] || systemctl is-active "$UNIT" >/dev/null 2>&1; then
    sudo timeout 60 systemctl stop "$UNIT" >/dev/null 2>&1 || true
    sudo systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
fi
for root in /run/$CASE_ID*/runc; do
    [ -d "$root" ] || continue
    for id in $(sudo runc --root "$root" list -q 2>/dev/null); do
        sudo runc --root "$root" kill "$id" KILL >/dev/null 2>&1
        sleep 0.2
        sudo runc --root "$root" delete -f "$id" >/dev/null 2>&1
    done
done
for sig in TERM KILL; do
    ps -eo pid=,comm=,args= | awk -v re="$CASE_ID" '($2=="crio" || $2=="python3" || $2=="conmon" || $2=="pause") && $0 ~ re {print $1}' | xargs -r sudo kill -$sig >/dev/null 2>&1
    sleep 1
done

echo "[cleanup] unmounting what the Pods left below the lab's directories (deepest first), removing their cgroup directories..."
for _ in 1 2 3; do
    awk '{print $2}' /proc/mounts | grep -e "$CASE_ID" | sort -r | while read -r m; do sudo umount "$m" >/dev/null 2>&1 || sudo umount -l "$m" >/dev/null 2>&1; done
    awk '{print $2}' /proc/mounts | grep -q -e "$CASE_ID" || break
    sleep 1
done
for _ in 1 2 3; do
    sudo find /sys/fs/cgroup -maxdepth 9 -depth -type d \( -path "*$CASE_ID*" \) -exec rmdir {} \; 2>/dev/null
    sudo find /sys/fs/cgroup -maxdepth 9 -type d -path "*$CASE_ID*" 2>/dev/null | grep -q . || break
    sleep 1
done

echo "[cleanup] removing the unit, its drop-ins and environment file, the name in /etc/hosts, the CA of the registry, and what a solution may have put elsewhere (profile.d, /etc/environment, the manager's environment)..."
sudo rm -rf "/etc/systemd/system/$UNIT" "/etc/systemd/system/$UNIT.d" /etc/systemd/system/*"$CASE_ID"* /etc/default/"$CASE_ID"-crio /etc/sysconfig/"$CASE_ID"-crio
sudo systemctl daemon-reload >/dev/null 2>&1
sudo sed -i "/# $CASE_ID\$/d" /etc/hosts
sudo rm -rf "/etc/containers/certs.d/$HOST:35743"
if [ -d "$BASE" ]; then
    if [ -e "$BASE/environment" ]; then sudo cp -p "$BASE/environment" /etc/environment; else sudo rm -f /etc/environment; fi
    for f in /etc/profile.d/*; do [ -e "$f" ] && ! grep -qxF "$(basename "$f")" "$BASE/profile.d.list" && sudo rm -rf "$f"; done
    if [ -d /etc/systemd/system.conf.d ]; then
        for f in /etc/systemd/system.conf.d/*; do [ -e "$f" ] && ! grep -qxF "$(basename "$f")" "$BASE/system.conf.d.list" && sudo rm -rf "$f"; done
        [ -e "$BASE/system.conf.d.absent" ] && sudo rmdir /etc/systemd/system.conf.d 2>/dev/null
    fi
    [ -e "$BASE/system.conf" ] && sudo cp -p "$BASE/system.conf" /etc/systemd/system.conf
    sudo systemctl daemon-reload >/dev/null 2>&1
fi

echo "[cleanup] removing the lab's directories and the work dir..."
sudo rm -rf "/etc/$CASE_ID" /var/lib/"$CASE_ID" /var/lib/"$CASE_ID"-* /run/"$CASE_ID" /run/"$CASE_ID"-* "$WORK_DIR" "$WORK_DIR"-* /tmp/"$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
