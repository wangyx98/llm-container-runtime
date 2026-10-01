#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: whatever the solution did to /etc/crictl.yaml, grade
# against containerd itself
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
POD_NAME="bench73420677-pod"
CONTAINER_NAME="bench73420677"
WORK_DIR="/tmp/bench73420677"
STATE_DIR="$WORK_DIR/.bench"
TARBALL="$WORK_DIR/app.tar"

# $1 = python expression over `d` (the parsed JSON on stdin); prints its value
jget() {
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = eval(sys.argv[1])
except Exception:
    sys.exit(0)
if v is not None:
    print(v)
' "$1"
}

echo "[oracle] check 0: containerd must be up and answering on the CRI..."
sudo systemctl is-active --quiet containerd || { echo "  -> FAIL: containerd is not active"; exit 1; }
$CRICTL info >/dev/null 2>&1 || { echo "  -> FAIL: crictl cannot talk to containerd"; exit 1; }
echo "  -> OK"

echo "[oracle] check 1: the tarball must be untouched (the image has to come"
echo "[oracle]          from it, not from something regenerated)..."
EXPECTED_SHA=$(cat "$STATE_DIR/tarball.sha256" 2>/dev/null || true)
ACTUAL_SHA=$(sha256sum "$TARBALL" 2>/dev/null | awk '{print $1}')
if [ -z "$EXPECTED_SHA" ] || [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    echo "  -> FAIL: $TARBALL changed or is missing"
    exit 1
fi
EXPECTED_ID=$(cat "$STATE_DIR/expected_image_id" 2>/dev/null || true)
TOKEN=$(cat "$STATE_DIR/token" 2>/dev/null || true)
POD_ID_AT_SETUP=$(cat "$STATE_DIR/pod_id" 2>/dev/null || true)
if [ -z "$EXPECTED_ID" ] || [ -z "$TOKEN" ] || [ -z "$POD_ID_AT_SETUP" ]; then
    echo "  -> FAIL: setup's recorded image id / token / pod id are missing"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: the CRI's own image view (what a kubelet with"
echo "[oracle]          imagePullPolicy: Never consults) must list the image,"
echo "[oracle]          and it must be THE image from the tarball (id = sha256 of"
echo "[oracle]          its config blob, recorded at setup)..."
IMAGES_JSON=$($CRICTL images -o json 2>/dev/null || true)
FOUND_ID=$(echo "$IMAGES_JSON" | jget "next((i['id'] for i in d['images'] if any('bench73420677-app:latest' in t for t in (i.get('repoTags') or []))), '')")
if [ -z "$FOUND_ID" ]; then
    echo "  -> FAIL: 'crictl images' does not list bench73420677-app:latest"
    exit 1
fi
if [ "${FOUND_ID#sha256:}" != "$EXPECTED_ID" ]; then
    echo "  -> FAIL: the listed image has id ${FOUND_ID#sha256:}, expected $EXPECTED_ID"
    exit 1
fi
ACCEPTED_REFS=$(echo "$IMAGES_JSON" | jget "' '.join([i['id'] for i in d['images'] if i['id'] == '$FOUND_ID'] + [r for i in d['images'] if i['id'] == '$FOUND_ID' for r in (i.get('repoDigests') or [])])")
echo "  -> OK ($FOUND_ID)"

echo "[oracle] check 3: the pod sandbox must be the ORIGINAL one (not deleted and"
echo "[oracle]          recreated), exactly one, SANDBOX_READY..."
PODS_JSON=$($CRICTL pods -o json 2>/dev/null || true)
POD_COUNT=$(echo "$PODS_JSON" | jget "sum(1 for p in d['items'] if p['metadata']['name'] == '$POD_NAME')")
if [ "${POD_COUNT:-0}" != "1" ]; then
    echo "  -> FAIL: expected exactly 1 pod sandbox named '$POD_NAME', found ${POD_COUNT:-0}"
    exit 1
fi
POD_ID=$(echo "$PODS_JSON" | jget "next(p['id'] for p in d['items'] if p['metadata']['name'] == '$POD_NAME')")
POD_STATE=$(echo "$PODS_JSON" | jget "next(p['state'] for p in d['items'] if p['metadata']['name'] == '$POD_NAME')")
if [ "$POD_ID" != "$POD_ID_AT_SETUP" ]; then
    echo "  -> FAIL: the pod sandbox was recreated (id $POD_ID, was $POD_ID_AT_SETUP)"
    exit 1
fi
if [ "$POD_STATE" != "SANDBOX_READY" ]; then
    echo "  -> FAIL: pod sandbox is $POD_STATE, expected SANDBOX_READY"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 4: exactly one container named '$CONTAINER_NAME', in that pod,"
echo "[oracle]          CONTAINER_RUNNING..."
CTRS_JSON=$($CRICTL ps -a -o json 2>/dev/null || true)
CTR_COUNT=$(echo "$CTRS_JSON" | jget "sum(1 for c in d['containers'] if c['metadata']['name'] == '$CONTAINER_NAME')")
if [ "${CTR_COUNT:-0}" != "1" ]; then
    echo "  -> FAIL: expected exactly 1 container named '$CONTAINER_NAME', found ${CTR_COUNT:-0}"
    exit 1
fi
CTR_ID=$(echo "$CTRS_JSON" | jget "next(c['id'] for c in d['containers'] if c['metadata']['name'] == '$CONTAINER_NAME')")
CTR_STATE=$(echo "$CTRS_JSON" | jget "next(c['state'] for c in d['containers'] if c['metadata']['name'] == '$CONTAINER_NAME')")
CTR_POD=$(echo "$CTRS_JSON" | jget "next(c['podSandboxId'] for c in d['containers'] if c['metadata']['name'] == '$CONTAINER_NAME')")
if [ "$CTR_POD" != "$POD_ID" ]; then
    echo "  -> FAIL: the container belongs to pod $CTR_POD, not to '$POD_NAME' ($POD_ID)"
    exit 1
fi
if [ "$CTR_STATE" != "CONTAINER_RUNNING" ]; then
    echo "  -> FAIL: container is $CTR_STATE, expected CONTAINER_RUNNING"
    exit 1
fi
echo "  -> OK ($CTR_ID)"

echo "[oracle] check 5: the container must have been created from that very image..."
INSPECT_JSON=$($CRICTL inspect -o json "$CTR_ID" 2>/dev/null || true)
CTR_IMAGE_REF=$(echo "$INSPECT_JSON" | jget "d['status'].get('imageRef', '')")
CTR_IMAGE_ID=$(echo "$INSPECT_JSON" | jget "d['status'].get('imageId', '')")
MATCH=0
for ref in $CTR_IMAGE_REF $CTR_IMAGE_ID; do
    for ok in $ACCEPTED_REFS; do
        [ "$ref" = "$ok" ] && MATCH=1
    done
done
if [ "$MATCH" != "1" ]; then
    echo "  -> FAIL: container image reference '${CTR_IMAGE_REF:-?}' is not the image from the tarball"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 6: it must run the image's own entrypoint (no overridden"
echo "[oracle]          command), and that OS-level process must really be alive..."
CTR_ARGS=$(echo "$INSPECT_JSON" | jget "' '.join(d['info']['runtimeSpec']['process']['args'])")
if [ "$CTR_ARGS" != "/bench-app" ]; then
    echo "  -> FAIL: the container's process args are '$CTR_ARGS', expected '/bench-app'"
    exit 1
fi
CTR_PID=$(echo "$INSPECT_JSON" | jget "d['info'].get('pid')")
if [ -z "$CTR_PID" ] || [ "$CTR_PID" = "0" ] || ! sudo kill -0 "$CTR_PID" 2>/dev/null; then
    echo "  -> FAIL: the container's process (pid '${CTR_PID:-none}') is not alive"
    exit 1
fi
PROC_CMD=$(sudo cat "/proc/$CTR_PID/cmdline" 2>/dev/null | tr '\0' ' ')
case "$PROC_CMD" in
    "/bench-app"*) ;;
    *) echo "  -> FAIL: pid $CTR_PID is '$PROC_CMD', not /bench-app"; exit 1 ;;
esac
echo "  -> OK (pid $CTR_PID)"

echo "[oracle] check 7: the container's log must contain the per-run token that"
echo "[oracle]          exists only inside the imported image (waits up to 10s)..."
SEEN=0
for _ in $(seq 1 20); do
    if $CRICTL logs "$CTR_ID" 2>/dev/null | grep -qF "bench73420677-image-ok token=$TOKEN"; then
        SEEN=1
        break
    fi
    sleep 0.5
done
if [ "$SEEN" != "1" ]; then
    echo "  -> FAIL: the container's log never showed the token of the imported image"
    exit 1
fi
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
