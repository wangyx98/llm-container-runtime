#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned)
CASE_ID="bench62874903"
WORK_DIR="/tmp/$CASE_ID"
LIB="/var/lib/$CASE_ID"
DROPIN="/etc/crio/crio.conf.d/62-$CASE_ID.conf"

if command -v crictl >/dev/null 2>&1 && sudo crictl info >/dev/null 2>&1; then
    echo "[cleanup] removing the pods and containers of the case (their names start with $CASE_ID)..."
    for p in $(sudo crictl pods -q --name "$CASE_ID" 2>/dev/null); do
        sudo crictl stopp "$p" >/dev/null 2>&1
        sudo crictl rmp -f "$p" >/dev/null 2>&1
    done
    for c in $(sudo crictl ps -a -q --name "$CASE_ID" 2>/dev/null); do
        sudo crictl rm -f "$c" >/dev/null 2>&1
    done
    sudo crictl rmi "localhost/$CASE_ID/app:local" >/dev/null 2>&1
fi

if [ -f "$DROPIN" ]; then
    echo "[cleanup] removing the runtime handlers and restarting crio.service..."
    sudo rm -f "$DROPIN"
    sudo systemctl restart crio.service >/dev/null 2>&1
    for _ in $(seq 1 20); do sudo crictl info >/dev/null 2>&1 && break; sleep 1; done
fi
sudo rm -rf --one-file-system "$WORK_DIR" "$LIB" /run/benchrt-62874903 /run/benchrt-verify-62874903
echo "[cleanup] done"
