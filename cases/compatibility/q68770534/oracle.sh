#!/bin/bash
set -e

SOCK="/run/bench68770534/containerd.sock"
# explicit endpoints: whatever the solution did to /etc/crictl.yaml, grade against the node itself
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK --timeout 30s"
POD_NAME="bench68770534-pod"
CONTAINER_NAME="bench68770534"
WORK_DIR="/tmp/bench68770534"
STATE_DIR="$WORK_DIR/.bench"
FULL_REF="docker.io/nvidia/cuda:11.0-base"

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

echo "[oracle] check 0: the node's containerd must still be the process setup started (not stopped,"
echo "[oracle]          not restarted) and answer on its CRI socket..."
$CRICTL info >/dev/null 2>&1 || { echo "  -> FAIL: the node's containerd is not answering"; exit 1; }
NPID=$(cat "$STATE_DIR/containerd_pid" 2>/dev/null || true)
NSTART=$(cat "$STATE_DIR/containerd_start" 2>/dev/null || true)
if [ -z "$NPID" ] || [ -z "$NSTART" ] || [ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$NPID/stat" 2>/dev/null)" != "$NSTART" ]; then
    echo "  -> FAIL: the node's containerd is not the recorded process any more (it was restarted)"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 1: setup's recorded state must be present..."
EXPECTED_ID=$(cat "$STATE_DIR/expected_image_id" 2>/dev/null || true)
EXPECTED_DIGEST=$(cat "$STATE_DIR/expected_digest" 2>/dev/null || true)
TOKEN=$(cat "$STATE_DIR/token" 2>/dev/null || true)
POD_ID_AT_SETUP=$(cat "$STATE_DIR/pod_id" 2>/dev/null || true)
if [ -z "$EXPECTED_ID" ] || [ -z "$EXPECTED_DIGEST" ] || [ -z "$TOKEN" ] || [ -z "$POD_ID_AT_SETUP" ]; then
    echo "  -> FAIL: setup's recorded image id / digest / token / pod id are missing"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: the image of the node must be untouched: the node's CRI lists it (id = sha256 of"
echo "[oracle]          its config blob, recorded at setup) under its full name, ctr still has the full"
echo "[oracle]          name at the recorded digest, and the store holds no image but this one and the"
echo "[oracle]          pause image (nothing was pulled, rebuilt or swapped in)..."
IMAGES_JSON=$($CRICTL images -o json 2>/dev/null || true)
FOUND_ID=$(echo "$IMAGES_JSON" | jget "next((i['id'] for i in d['images'] if '$FULL_REF' in (i.get('repoTags') or [])), '')")
if [ -z "$FOUND_ID" ]; then
    echo "  -> FAIL: the node's 'crictl images' does not list $FULL_REF"
    exit 1
fi
if [ "${FOUND_ID#sha256:}" != "$EXPECTED_ID" ]; then
    echo "  -> FAIL: $FULL_REF has id ${FOUND_ID#sha256:}, expected $EXPECTED_ID (another image under the name)"
    exit 1
fi
CTR_DIGEST=$(sudo ctr -a "$SOCK" -n k8s.io images ls 2>/dev/null | awk -v r="$FULL_REF" '$1 == r {print $3}')
if [ "$CTR_DIGEST" != "$EXPECTED_DIGEST" ]; then
    echo "  -> FAIL: ctr shows $FULL_REF with digest '${CTR_DIGEST:-nothing}', expected $EXPECTED_DIGEST"
    exit 1
fi
STRANGE=$(echo "$IMAGES_JSON" | jget "' '.join(i['id'] for i in d['images'] if i['id'].replace('sha256:', '') != '$EXPECTED_ID' and not any('bench68770534-pause' in t for t in (i.get('repoTags') or [])))")
if [ -n "$STRANGE" ]; then
    echo "  -> FAIL: the node's store holds an image that setup did not put there: $STRANGE"
    exit 1
fi
ACCEPTED_REFS=$(echo "$IMAGES_JSON" | jget "' '.join([i['id'] for i in d['images'] if i['id'] == '$FOUND_ID'] + [r for i in d['images'] if i['id'] == '$FOUND_ID' for r in (i.get('repoDigests') or [])])")
echo "  -> OK ($FOUND_ID)"

echo "[oracle] check 3: the pod sandbox must be the ORIGINAL one (not deleted and recreated), exactly one,"
echo "[oracle]          SANDBOX_READY..."
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

echo "[oracle] check 4: exactly one container named '$CONTAINER_NAME', in that pod, CONTAINER_RUNNING..."
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
    echo "  -> FAIL: container image reference '${CTR_IMAGE_REF:-?}' is not the image of the node"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 6: it must run the image's own entrypoint (no overridden command), and that"
echo "[oracle]          OS-level process must really be alive..."
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

echo "[oracle] check 7: the container's log must contain the per-run token that exists only inside the"
echo "[oracle]          application image (waits up to 10s)..."
SEEN=0
for _ in $(seq 1 20); do
    if $CRICTL logs "$CTR_ID" 2>/dev/null | grep -qF "bench68770534-image-ok token=$TOKEN"; then
        SEEN=1
        break
    fi
    sleep 0.5
done
if [ "$SEEN" != "1" ]; then
    echo "  -> FAIL: the container's log never showed the token of the application image"
    exit 1
fi
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
