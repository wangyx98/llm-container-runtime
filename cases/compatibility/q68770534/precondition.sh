#!/bin/bash
set -e

CASE_ID="bench68770534"
SOCK="/run/$CASE_ID/containerd.sock"
# explicit endpoints: do not depend on what /etc/crictl.yaml currently says
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK --timeout 30s"
CTR="sudo ctr -a $SOCK -n k8s.io"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
FULL_REF="docker.io/nvidia/cuda:11.0-base"
BARE_REF="cuda"

echo "[precondition] checking the node (its containerd) is the recorded process and answers on the CRI..."
$CRICTL info >/dev/null
NPID=$(cat "$STATE_DIR/containerd_pid" 2>/dev/null || true)
NSTART=$(cat "$STATE_DIR/containerd_start" 2>/dev/null || true)
[ -n "$NPID" ] && [ -n "$NSTART" ] || { echo "  -> FAIL: setup's record of the node's containerd is missing"; exit 1; }
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$NPID/stat" 2>/dev/null)" = "$NSTART" ] || { echo "  -> FAIL: pid $NPID is not the recorded containerd"; exit 1; }
echo "  -> OK"

echo "[precondition] checking setup's recorded state and the workload configs..."
EXPECTED_ID=$(cat "$STATE_DIR/expected_image_id" 2>/dev/null || true)
EXPECTED_DIGEST=$(cat "$STATE_DIR/expected_digest" 2>/dev/null || true)
echo "$EXPECTED_ID" | grep -qE '^[0-9a-f]{64}$' || { echo "  -> FAIL: setup did not record a valid expected image id"; exit 1; }
echo "$EXPECTED_DIGEST" | grep -qE '^sha256:[0-9a-f]{64}$' || { echo "  -> FAIL: setup did not record the image digest"; exit 1; }
for f in pod-config.json container-config.json; do
    [ -s "$WORK_DIR/$f" ] || { echo "  -> FAIL: $WORK_DIR/$f is missing"; exit 1; }
done
grep -q "\"image\": \"$BARE_REF\"" "$WORK_DIR/container-config.json" || { echo "  -> FAIL: the container config does not name the image '$BARE_REF'"; exit 1; }
echo "  -> OK (image id sha256:$EXPECTED_ID)"

echo "[precondition] ctr shows the image under BOTH names in the k8s.io namespace, with one digest (the"
echo "[precondition] 'but the image is there!' half of the symptom)..."
for ref in "$BARE_REF" "$FULL_REF"; do
    D=$($CTR images ls 2>/dev/null | awk -v r="$ref" '$1 == r {print $3}')
    [ "$D" = "$EXPECTED_DIGEST" ] || { echo "  -> FAIL: 'ctr -n k8s.io images ls' shows '$ref' with digest '${D:-nothing}', expected $EXPECTED_DIGEST"; exit 1; }
done
echo "  -> OK"

echo "[precondition] the node's CRI knows the image by its full name only: the short name '$BARE_REF' is not there..."
IMAGES_JSON=$($CRICTL images -o json 2>/dev/null)
R=$(echo "$IMAGES_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
exp = "'"$EXPECTED_ID"'"
tags = [t for i in d.get("images", []) if i["id"].replace("sha256:", "") == exp for t in (i.get("repoTags") or [])]
print("FULL=%d BARE=%d" % (any(t == "'"$FULL_REF"'" for t in tags), any(t in ("cuda", "cuda:latest", "docker.io/library/cuda:latest") for t in tags)))
')
[ "$R" = "FULL=1 BARE=0" ] || { echo "  -> FAIL: the CRI view of the image is '$R', expected FULL=1 BARE=0"; exit 1; }
if $CRICTL inspecti "$BARE_REF" >/dev/null 2>&1; then
    echo "  -> FAIL: 'crictl inspecti $BARE_REF' succeeds; the short name is visible to the CRI"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the pod sandbox is up (the 'scheduled' pod) and no container exists in it yet..."
POD_ID=$(cat "$STATE_DIR/pod_id" 2>/dev/null || true)
LISTED=$($CRICTL pods -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(" ".join(p["id"] + ":" + p["state"] for p in d.get("items", [])))
')
[ "$LISTED" = "$POD_ID:SANDBOX_READY" ] || { echo "  -> FAIL: expected exactly the recorded pod sandbox READY, got '$LISTED'"; exit 1; }
[ -z "$($CRICTL ps -a -q 2>/dev/null)" ] || { echo "  -> FAIL: the node already has a container"; exit 1; }
echo "  -> OK (pod sandbox $POD_ID)"

echo "[precondition] reproducing the symptom: creating the container from the short name must fail with 'not found'..."
if OUT=$($CRICTL create "$POD_ID" "$WORK_DIR/container-config.json" "$WORK_DIR/pod-config.json" 2>&1); then
    echo "  -> FAIL: container creation succeeded; the environment is not broken"
    exit 1
fi
echo "$OUT" | grep -qiE "not found|no such image" || { echo "  -> FAIL: creation failed, but not with 'not found': $(echo "$OUT" | tail -1 | cut -c1-200)"; exit 1; }
echo "  -> OK (creation fails as in the bug report)"

echo "[precondition] PASS - ctr lists '$BARE_REF' and '$FULL_REF', the CRI knows only the full name, the pod"
echo "[precondition]        sandbox is Ready and the container cannot be created from '$BARE_REF'."
