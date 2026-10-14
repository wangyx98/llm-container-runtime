#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned) and every command may fail without aborting the cleanup.

CASE_ID="bench71671179"
HOST="registry.$CASE_ID.test"
WORK_DIR="/tmp/$CASE_ID"
LIB="/var/lib/$CASE_ID"
BASE="$LIB/baseline"       # what setup.sh saved of the places where a solution may leave something on the machine itself

echo "[cleanup] stopping the three nodes and their Pods (runc roots below /run/$CASE_ID/*, the conmon of each Pod)..."
for u in /etc/systemd/system/$CASE_ID-*-crio.service; do
    [ -e "$u" ] || continue
    sudo timeout 60 systemctl stop "$(basename "$u")" >/dev/null 2>&1
    sudo systemctl reset-failed "$(basename "$u")" >/dev/null 2>&1
done
for root in /run/$CASE_ID/*/runc; do
    [ -d "$root" ] || continue
    for id in $(sudo runc --root "$root" list -q 2>/dev/null); do
        sudo runc --root "$root" kill "$id" KILL >/dev/null 2>&1
        sleep 0.2
        sudo runc --root "$root" delete -f "$id" >/dev/null 2>&1
    done
done
for sig in TERM KILL; do
    ps -eo pid=,comm=,args= | awk -v re="$CASE_ID" '($2=="crio" || $2=="python3" || $2=="conmon" || $2=="pause" || $2=="app") && $0 ~ re {print $1}' | xargs -r sudo kill -$sig >/dev/null 2>&1
    sleep 1
done

echo "[cleanup] unmounting what the Pods left below the lab's directories (deepest first), removing their cgroup directories..."
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

echo "[cleanup] removing the units and their drop-ins, the name in /etc/hosts, and what a solution may have put on the machine itself (certs.d, registries.conf, the OS trust store)..."
sudo rm -rf /etc/systemd/system/*"$CASE_ID"*
sudo systemctl daemon-reload >/dev/null 2>&1
sudo sed -i "/# $CASE_ID\$/d" /etc/hosts
if [ -d "$BASE" ]; then
    REFRESH=0
    for d in /etc/containers/certs.d /etc/docker/certs.d /etc/containers/registries.conf.d /usr/local/share/ca-certificates; do
        k=$(echo "$d" | tr '/' '_')
        if [ -d "$d" ]; then
            for f in "$d"/*; do
                [ -e "$f" ] && ! grep -qxF "$(basename "$f")" "$BASE/$k.list" && { sudo rm -rf "$f"; [ "$d" = /usr/local/share/ca-certificates ] && REFRESH=1; }
            done
            [ -e "$BASE/$k.absent" ] && sudo rmdir "$d" 2>/dev/null
        fi
    done
    [ -e "$BASE/_etc_docker_certs.d.absent" ] && sudo rmdir /etc/docker 2>/dev/null
    if [ -e "$BASE/registries.conf" ]; then sudo cp -p "$BASE/registries.conf" /etc/containers/registries.conf; else sudo rm -f /etc/containers/registries.conf; fi
    [ "$REFRESH" = 1 ] && command -v update-ca-certificates >/dev/null 2>&1 && sudo update-ca-certificates --fresh >/dev/null 2>&1
fi

echo "[cleanup] removing the lab's directories and the work dir..."
sudo rm -rf "/etc/$CASE_ID" "$LIB" /run/"$CASE_ID" "$WORK_DIR" "$WORK_DIR"-* /tmp/"$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
