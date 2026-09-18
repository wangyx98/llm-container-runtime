#!/bin/bash
set -e

POD_NAME="bench65650082-pod"
CONTAINER_NAME="bench65650082"

echo "[oracle] check 0: crictl must be talking to a genuine, running CRI-O backend..."
RUNTIME_ENDPOINT=$(grep -E '^runtime-endpoint' /etc/crictl.yaml 2>/dev/null | awk '{print $2}')
case "$RUNTIME_ENDPOINT" in
    *crio*)
        echo "  -> OK (runtime-endpoint=$RUNTIME_ENDPOINT)"
        ;;
    *)
        echo "  -> FAIL: runtime-endpoint is '$RUNTIME_ENDPOINT', expected the CRI-O socket"
        exit 1
        ;;
esac
if ! sudo systemctl is-active --quiet crio.service; then
    echo "  -> FAIL: crio.service is not active"
    exit 1
fi
sudo crictl info >/dev/null || { echo "  -> FAIL: crictl cannot reach the runtime"; exit 1; }
echo "  -> OK (crio.service active, crictl info succeeded)"

echo "[oracle] check 1: pod sandbox '$POD_NAME' must exist and be READY..."
POD_ID=$(sudo crictl pods --name "$POD_NAME" -q 2>/dev/null | head -1)
if [ -z "$POD_ID" ]; then
    echo "  -> FAIL: no pod sandbox named '$POD_NAME' found"
    exit 1
fi
POD_STATE=$(sudo crictl inspectp "$POD_ID" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('status', {}).get('state', ''))
except Exception:
    print('')
")
if [ "$POD_STATE" != "SANDBOX_READY" ]; then
    echo "  -> FAIL: pod sandbox state is '${POD_STATE:-<unknown>}', expected 'SANDBOX_READY'"
    exit 1
fi
echo "  -> OK (pod $POD_ID is SANDBOX_READY)"

echo "[oracle] check 2: container '$CONTAINER_NAME' must exist, be RUNNING,"
echo "[oracle]          belong to that exact pod, and use the busybox image..."
CTR_ID=$(sudo crictl ps --name "$CONTAINER_NAME" -q 2>/dev/null | head -1)
if [ -z "$CTR_ID" ]; then
    echo "  -> FAIL: no running container named '$CONTAINER_NAME' found"
    exit 1
fi
CTR_JSON=$(sudo crictl inspect "$CTR_ID" 2>/dev/null)

CTR_STATE=$(echo "$CTR_JSON" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('status', {}).get('state', ''))
except Exception:
    print('')
")
if [ "$CTR_STATE" != "CONTAINER_RUNNING" ]; then
    echo "  -> FAIL: container state is '${CTR_STATE:-<unknown>}', expected 'CONTAINER_RUNNING'"
    exit 1
fi
echo "  -> OK (container $CTR_ID is CONTAINER_RUNNING)"

CTR_IMAGE=$(echo "$CTR_JSON" | python3 -c "
import json, sys
try:
    img = json.load(sys.stdin)['status']['image']
    print(img.get('image') or img.get('userSpecifiedImage') or '')
except Exception:
    print('')
")
case "$CTR_IMAGE" in
    *busybox*)
        echo "  -> OK (image matches: $CTR_IMAGE)"
        ;;
    *)
        echo "  -> FAIL: container image is '${CTR_IMAGE:-<unknown>}', expected the busybox image"
        exit 1
        ;;
esac

CTR_SANDBOX=$(echo "$CTR_JSON" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('info', {}).get('sandboxID', ''))
except Exception:
    print('')
")
if [ -n "$CTR_SANDBOX" ] && [ "$CTR_SANDBOX" != "$POD_ID" ]; then
    echo "  -> FAIL: container's sandboxID ($CTR_SANDBOX) does not match pod ($POD_ID)"
    exit 1
fi
echo "  -> OK (container is linked to pod $POD_ID)"

echo "[oracle] check 3: a real OS process must be alive and be the expected 'sleep' command..."
PID=$(echo "$CTR_JSON" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('info', {}).get('pid', ''))
except Exception:
    print('')
")
if [ -z "$PID" ] || [ "$PID" = "0" ] || ! sudo test -d "/proc/$PID"; then
    echo "  -> FAIL: no live process for PID '${PID:-<none>}'"
    exit 1
fi
CMDLINE=$(sudo tr '\0' ' ' < "/proc/$PID/cmdline")
echo "  -> process cmdline: $CMDLINE"
case "$CMDLINE" in
    *sleep*100000*)
        echo "  -> OK (matches expected sleep process)"
        ;;
    *)
        echo "  -> FAIL: process does not look like the expected sleep command"
        exit 1
        ;;
esac

echo "[oracle] ALL CHECKS PASSED"
