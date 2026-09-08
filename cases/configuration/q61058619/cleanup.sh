#!/bin/bash
# 不加 set -e：teardown阶段允许部分命令因"本来就不存在"而失败

CRIO_DROPIN_DIR="/etc/crio/crio.conf.d"

echo "[cleanup] removing any leftover containers for this pod..."
for cid in $(sudo crictl ps -a -o json 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for c in data.get('containers', []):
    if c.get('metadata', {}).get('name') == 'bench61058619-ctr':
        print(c['id'])
" 2>/dev/null); do
    sudo crictl stop "$cid" 2>/dev/null || true
    sudo crictl rm "$cid" 2>/dev/null || true
done

echo "[cleanup] removing any leftover pod sandboxes for this case..."
for pid in $(sudo crictl pods -o json 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for p in data.get('items', []):
    if p.get('metadata', {}).get('name') == 'bench61058619':
        print(p['id'])
" 2>/dev/null); do
    sudo crictl stopp "$pid" 2>/dev/null || true
    sudo crictl rmp "$pid" 2>/dev/null || true
done

echo "[cleanup] removing the broken/fixed seccomp drop-in (leftover from earlier iterations, if any)..."
sudo rm -f "$CRIO_DROPIN_DIR/99-broken-seccomp.conf"
sudo rm -f /etc/crio/valid-seccomp.json
sudo rm -f /etc/crio/broken-seccomp.json

echo "[cleanup] restarting crio to a clean baseline..."
sudo systemctl restart crio 2>/dev/null || true
sleep 1

echo "[cleanup] removing test artifacts..."
sudo rm -f /tmp/bench61058619_pod.json /tmp/bench61058619_container.json /tmp/bench61058619_podid.txt
sudo rm -rf /tmp/bench61058619-logs
sudo rm -f /tmp/precheck_ctrid.txt /tmp/precheck_err.txt
sudo rm -f /tmp/oracle_create_err.txt /tmp/oracle_start_err.txt

echo "[cleanup] done. Environment reset to clean state."
