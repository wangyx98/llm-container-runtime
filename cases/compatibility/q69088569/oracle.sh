#!/bin/bash
# Postcondition oracle. Every check is dynamic: the pod that runs, the digest it reports, its log, the requests
# the registry saw, and a pull made through the CRI (what the kubelet calls) are observed on the running
# machine.
set -e

CASE_ID="bench69088569"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/registry"
NODE="bench69088569-node"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

CTR="sudo ctr -a $CTD_SOCK"
MK="sudo $CTL_DIR/mk8s"
K3S_BIN=$(cat "$STATE_DIR/k3s.bin" 2>/dev/null || true)
CRI=(sudo "$K3S_BIN" crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK")
alive_same() {
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])' "$STATE_DIR/image.truth" "$1"; }
# The last 500 characters of this output are all the report keeps: failures are one short line.
fail() { echo "FAIL: $*"; exit 1; }

D=$(sudo cat "$STATE_DIR/manifest.digest")
TOKEN=$(sudo cat "$STATE_DIR/token")
LAYER=$(jget layer)
CONFIG=$(jget config)
L0=$(sudo cat "$STATE_DIR/registry.lines0")
newlog() { sudo tail -n +"$(( ${1:-$L0} + 1 ))" "$REG_DIR/requests.log"; }

echo "[oracle] check 1: the registry is the one of setup, and nothing was pushed to it or deleted from it..."
alive_same registry || fail "the registry is not the process of setup"
sudo cmp -s "$REG_DIR/state.json" "$STATE_DIR/registry.state0" || fail "the content of the registry changed"
if newlog | grep -qE '^(POST|PUT|PATCH|DELETE) '; then fail "something wrote to the registry"; fi
echo "  -> OK"

echo "[oracle] check 2: Kubernetes (k3s) runs on this machine's containerd, which answers..."
[ "$(pgrep -x k3s-server | wc -l)" = "1" ] || fail "there is not exactly one k3s-server process"
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
READY=""; RT=""
for _ in $(seq 1 30); do   # right after a restart of containerd or k3s the status of the node is stale or unknown for a while
    READY=$($MK kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    RT=$($MK kubectl get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' 2>/dev/null || true)
    [ "$READY" = "True" ] && [ "$RT" = "containerd://$(cat "$STATE_DIR/external.version")" ] && break
    sleep 2
done
[ "$READY" = "True" ] || fail "the node $NODE is not Ready"
[ "$RT" = "containerd://$(cat "$STATE_DIR/external.version")" ] || fail "the node does not run on this machine's containerd ($RT)"
echo "  -> OK"

echo "[oracle] check 3: the deployment argus has a pod that RUNS the registry's image: the image id of its container"
echo "[oracle] is the one of argus:registry (its manifest digest, or its config digest), and the pod asks for it by"
echo "[oracle] its registry name..."
POD=""; WHY=""
for _ in $(seq 1 55); do
    ROW=$($MK kubectl get pods -l app=argus -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.deletionTimestamp}{"|"}{.status.phase}{"|"}{.status.containerStatuses[0].ready}{"|"}{.status.containerStatuses[0].restartCount}{"|"}{.status.containerStatuses[0].imageID}{"|"}{.spec.containers[0].image}{"|"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null || true)
    POD=$(echo "$ROW" | awk -F'|' -v d="$D" -v c="$CONFIG" '$2=="" && $3=="Running" && $4=="true" && ($6 == c || $6 ~ ("argus@" d "$")) {print $1; exit}')
    [ -n "$POD" ] && break
    WHY=$(echo "$ROW" | awk -F'|' '$2=="" && $7!="argus" {print $8 " (image " $7 ")"}' | tail -1)
    [ -n "$WHY" ] || WHY=$(echo "$ROW" | awk -F'|' '$2=="" {print $8 " (image " $7 ")"}' | tail -1)
    sleep 2
done
if [ -z "$POD" ]; then
    $MK kubectl get deployment argus >/dev/null 2>&1 || fail "the deployment argus does not exist"
    fail "no pod of argus runs the registry's image after 110s (last: ${WHY:-no pod})"
fi
IMG=$(echo "$ROW" | awk -F'|' -v p="$POD" '$1==p {print $7}')
echo "$IMG" | grep -qE "^(localhost|127\.0\.0\.1):32000/argus(:registry|@$D)\$" \
    || fail "the pod runs it under the name '$IMG', not the name it has in the registry (localhost:32000/argus:registry)"
[ "$(echo "$ROW" | awk -F'|' -v p="$POD" '$1==p {print $5}')" = "0" ] || fail "the container of $POD was restarted"
echo "  -> OK ($POD runs $IMG)"

echo "[oracle] check 4: the pod is the program of the image (its log has the token of the image) and it keeps running..."
$MK kubectl logs "$POD" 2>/dev/null | grep -qF "token=$TOKEN" || fail "the log of $POD does not carry the token of the image"
sleep 6
STATE=$($MK kubectl get pod "$POD" -o jsonpath='{.status.phase}{" "}{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)
[ "$STATE" = "Running 0" ] || fail "the pod $POD does not keep running ($STATE)"
echo "  -> OK"

echo "[oracle] check 5: the registry saw containerd fetch the manifest and both blobs of the image..."
LOG=$(newlog)
echo "$LOG" | grep -E '^(GET|HEAD) /v2/argus/manifests/' | grep -q ' 200 ua=containerd' || fail "containerd never fetched the manifest from the registry"
for b in "$CONFIG" "$LAYER"; do
    echo "$LOG" | grep -qE "^GET /v2/argus/blobs/$b 200 ua=containerd" || fail "containerd never fetched the blob ${b:0:19} from the registry"
done
echo "  -> OK"

echo "[oracle] check 6: Kubernetes can pull the image from the registry BY ITSELF: remove it from the runtime and"
echo "[oracle] pull it again through the CRI (the call of the kubelet)..."
$CTR -n k8s.io images rm "$IMG" >/dev/null 2>&1 || true
L1=$(sudo wc -l < "$REG_DIR/requests.log")
OUT=$(timeout -k 5 60 "${CRI[@]}" pull "$IMG" 2>&1) || fail "the CRI cannot pull $IMG: $(echo "$OUT" | tail -1 | cut -c1-230)"
"${CRI[@]}" inspecti "$IMG" 2>/dev/null | grep -qF "argus@$D" || fail "after the CRI pull the image has not the digest of the registry's image"
newlog "$L1" | grep -E '^(GET|HEAD) /v2/argus/manifests/' | grep -q ' 200 ua=containerd' || fail "the CRI pull did not go to the registry"
STATE=$($MK kubectl get pod "$POD" -o jsonpath='{.status.phase}{" "}{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)
[ "$STATE" = "Running 0" ] || fail "the pod $POD does not keep running ($STATE)"
echo "  -> OK"

echo "[oracle] all checks passed."
