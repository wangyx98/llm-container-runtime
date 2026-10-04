#!/bin/bash
set -e

CASE_ID="bench69672550"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
PORT=5000

echo "[precondition] checking containerd answers and the image $IMAGE_REF is imported..."
sudo ctr version >/dev/null 2>&1 || { echo "  -> FAIL: containerd does not answer"; exit 1; }
if ! sudo ctr images ls -q 2>/dev/null | grep -qFx "$IMAGE_REF"; then
    echo "  -> FAIL: containerd does not list the image $IMAGE_REF"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking no container of this case exists yet (none named after it, none"
echo "[precondition] made from the image) and no task runs..."
for c in $(sudo ctr containers ls -q 2>/dev/null); do
    IMAGE_OF=$(sudo ctr containers info "$c" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Image",""))' 2>/dev/null || true)
    if [ "$IMAGE_OF" = "$IMAGE_REF" ] || [ "${c#*$CASE_ID}" != "$c" ]; then
        echo "  -> FAIL: container '$c' of this case already exists"
        exit 1
    fi
done
echo "  -> OK"

echo "[precondition] checking the symptom: from the host, port $PORT is not reachable..."
if OUT=$(curl -sS --noproxy '*' --max-time 3 "http://127.0.0.1:$PORT/" 2>&1); then
    echo "  -> FAIL: the host already gets an answer on 127.0.0.1:$PORT: $OUT"
    exit 1
fi
echo "  -> OK ($OUT)"

echo "[precondition] checking what the task names is there: CNI plugins in /opt/cni/bin and a CNI"
echo "[precondition] network configuration in /etc/cni/net.d..."
[ -x /opt/cni/bin/bridge ] && [ -x /opt/cni/bin/portmap ] || { echo "  -> FAIL: CNI plugins missing in /opt/cni/bin"; exit 1; }
sudo sh -c 'for f in /etc/cni/net.d/*.conf /etc/cni/net.d/*.conflist /etc/cni/net.d/*.json; do [ -f "$f" ] && exit 0; done; exit 1' >/dev/null 2>&1 \
    || { echo "  -> FAIL: no CNI network configuration in /etc/cni/net.d"; exit 1; }
echo "  -> OK"

echo "[precondition] PASS - the image is imported, no container exists, and nothing on the host answers"
echo "[precondition]        port $PORT."
