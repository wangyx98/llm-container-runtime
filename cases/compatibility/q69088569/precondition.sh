#!/bin/bash
set -e

CASE_ID="bench69088569"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/registry"
REG="http://127.0.0.1:32000"
REF="localhost:32000/argus:registry"
NODE="bench69088569-node"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

CTR="sudo ctr -a $CTD_SOCK"
MK="sudo $CTL_DIR/mk8s"
K3S_BIN=$(cat "$STATE_DIR/k3s.bin" 2>/dev/null || true)
CRI=(sudo "$K3S_BIN" crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK")
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])' "$STATE_DIR/image.truth" "$1"; }

echo "[precondition] checking the state setup recorded and the three daemons (containerd, registry, k3s)..."
for f in containerd.id registry.id k3s.id k3s.bin token manifest.digest image.truth registry.state0 registry.lines0 external.version; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
for d in containerd registry k3s; do alive_same "$d" || fail "the recorded $d is not running"; done
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
echo "  -> OK"

echo "[precondition] checking the registry (plain HTTP on 127.0.0.1:32000) holds argus:registry with the recorded digest..."
D=$(sudo cat "$STATE_DIR/manifest.digest")
HDR=$(curl -sI --max-time 5 -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "$REG/v2/argus/manifests/registry" | tr -d '\r')
echo "$HDR" | head -1 | grep -q ' 200' || fail "the registry does not serve argus:registry"
[ "$(echo "$HDR" | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')" = "$D" ] || fail "the digest of argus:registry is not the recorded one"
for k in config layer; do
    curl -sfI --max-time 5 "$REG/v2/argus/blobs/$(jget $k)" >/dev/null || fail "the registry lacks the $k blob of the image"
done
[ "$(curl -sf --max-time 5 "$REG/v2/_catalog" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["repositories"]))')" = "argus" ] || fail "the registry holds more or less than the repository argus"
echo "  -> OK ($D)"

echo "[precondition] checking Kubernetes (k3s) runs on this containerd and the node is Ready..."
READY=$($MK kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[ "$READY" = "True" ] || fail "the node $NODE is not Ready"
RT=$($MK kubectl get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')
[ "$RT" = "containerd://$(cat "$STATE_DIR/external.version")" ] || fail "the node does not run on this containerd ($RT)"
echo "  -> OK ($RT)"

echo "[precondition] checking the deployment argus asks for the image 'argus' and its pod cannot start..."
IMG=$($MK kubectl get deployment argus -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
[ "$IMG" = "argus" ] || fail "the deployment argus does not ask for the image 'argus' ('$IMG')"
STATES=$($MK kubectl get pods -l app=argus -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{" "}{.status.containerStatuses[0].state.running.startedAt}{"\n"}{end}')
echo "$STATES" | grep -qE 'ErrImagePull|ImagePullBackOff' || fail "the pod of argus is not waiting on an image pull ('$STATES')"
echo "$STATES" | awk 'NF==2 || ($1!="ErrImagePull" && $1!="ImagePullBackOff" && NF>0) {bad=1} END {exit bad}' || fail "a pod of argus runs ('$STATES')"
echo "  -> OK (pod: $(echo "$STATES" | awk 'NR==1 {print $1}'))"

echo "[precondition] checking nothing configures the registries of containerd's CRI, and no image of argus is in"
echo "[precondition] containerd (namespaces default and k8s.io)..."
sudo awk '/^[[:space:]]*\[plugins\.'"'"'io\.containerd\.cri\.v1\.images'"'"'\.registry\]/ {f=1; next} /^[[:space:]]*\[/ {f=0} f && /config_path/ {print}' "$RUN_BASE/config.toml" | grep -qE "config_path = ''" \
    || fail "the CRI registry config_path of containerd is already set: $(sudo grep -n 'config_path' "$RUN_BASE/config.toml" | tr '\n' ' ' | cut -c1-200)"
[ ! -e "/etc/containerd/certs.d/localhost:32000" ] || fail "a registry configuration for localhost:32000 already exists"
for ns in default k8s.io; do
    ! $CTR -n "$ns" images ls -q 2>/dev/null | grep -q 'argus' || fail "an image of argus is already in the namespace $ns"
done
echo "  -> OK"

echo "[precondition] checking the first commands of the engineer fail and change nothing: ctr (no --plain-http) and"
echo "[precondition] the CRI pull both talk HTTPS to a plain-HTTP registry..."
L0=$(sudo wc -l < "$REG_DIR/requests.log")
OUT=$($CTR -n k8s.io images pull "$REF" 2>&1) && fail "ctr pulled the image without --plain-http: '$OUT'"
echo "$OUT" | grep -qiE 'https|tls|handshake' || fail "ctr failed for another reason: '$(echo "$OUT" | tail -1)'"
OUT=$("${CRI[@]}" pull "$REF" 2>&1) && fail "the CRI pulled the image without any registry configuration"
echo "$OUT" | grep -qiE 'https|tls|handshake' || fail "the CRI pull failed for another reason: '$(echo "$OUT" | tail -1)'"
[ "$(sudo wc -l < "$REG_DIR/requests.log")" = "$L0" ] || fail "the failed pulls reached the registry"
for ns in default k8s.io; do
    ! $CTR -n "$ns" images ls -q 2>/dev/null | grep -q 'argus' || fail "a failed pull left an image in $ns"
done
echo "  -> OK"

echo "[precondition] all conditions met."
