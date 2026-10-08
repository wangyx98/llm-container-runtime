#!/bin/bash
set -e

CASE_ID="bench62675268"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CRIO_SOCK="$RUN_BASE/crio.sock"
REG_DIR="$RUN_BASE/registry"
HUB_DIR="$RUN_BASE/proxy"
HUB_PORT=18095
REG_HOST="registry.bench62675268.test"
REG_PORT=5000
REPO="kubernetes/pause"
TAG="3.2"
PAUSE_REF="$REG_HOST:$REG_PORT/$REPO:$TAG"
DEFAULT_PAUSE="k8s.gcr.io/pause:3.2"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

CRI=(sudo crictl --runtime-endpoint "unix://$CRIO_SOCK" --image-endpoint "unix://$CRIO_SOCK" --timeout 60s)
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
jget() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATE_DIR/image.truth" "$1"; }

echo "[precondition] checking the state setup recorded and the three daemons (CRI-O, the registry, the egress proxy)..."
for f in crio.id registry.id hubgate.id image.truth manifest.digest pause.sha256 registry.state0 crioctl.sha; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
for d in crio registry hubgate; do alive_same "$d" || fail "the recorded $d is not running"; done
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of CRI-O does not answer"
echo "  -> OK"

echo "[precondition] checking CRI-O is set up with the old default sandbox image, and starts with nothing (no pod, no image)..."
sudo grep -q "^pause_image = \"$DEFAULT_PAUSE\"" "$RUN_BASE/crio.conf" || fail "crio.conf has not pause_image = $DEFAULT_PAUSE"
sudo grep -q "$REG_HOST:$REG_PORT" "$RUN_BASE/registries.conf" || fail "registries.conf does not name the private registry"
[ -z "$("${CRI[@]}" pods -q 2>/dev/null)" ] || fail "there are pods in CRI-O"
[ -z "$("${CRI[@]}" images -q 2>/dev/null)" ] || fail "there are images in CRI-O"
echo "  -> OK"

echo "[precondition] checking the private registry serves the pause image, and the egress proxy refuses k8s.gcr.io..."
HDR=$(curl -sI --max-time 5 -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "http://127.0.0.1:$REG_PORT/v2/$REPO/manifests/$TAG" | tr -d '\r')
echo "$HDR" | head -1 | grep -q ' 200' || fail "the registry does not serve $REPO:$TAG"
[ "$(echo "$HDR" | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')" = "$(sudo cat "$STATE_DIR/manifest.digest")" ] \
    || fail "the digest in the registry is not the recorded one"
if curl -s --max-time 10 -o /dev/null -x "http://127.0.0.1:$HUB_PORT" "https://k8s.gcr.io/v2/" 2>/dev/null; then fail "k8s.gcr.io is reachable through the egress proxy"; fi
sudo grep -q "^CONNECT k8s.gcr.io:443 DENY" "$HUB_DIR/requests.log" || fail "the egress proxy did not log the refusal of k8s.gcr.io"
echo "  -> OK ($(sudo cat "$STATE_DIR/manifest.digest" | cut -c1-19)...)"

echo "[precondition] checking a new pod sandbox fails because CRI-O asks for $DEFAULT_PAUSE (the reported symptom)..."
mkdir -p "$WORK_DIR/logs"
cat > "$WORK_DIR/pre-pod.json" <<CONF
{
  "metadata": {"name": "bench62675268-pre", "namespace": "default", "attempt": 1, "uid": "bench62675268-pre-uid"},
  "log_directory": "$WORK_DIR/logs",
  "linux": {"security_context": {"namespace_options": {"network": 2, "pid": 0}}}
}
CONF
H0=$(sudo wc -l < "$HUB_DIR/requests.log")
P0=$(sudo wc -l < "$REG_DIR/requests.log")
if PRE_POD=$("${CRI[@]}" runp "$WORK_DIR/pre-pod.json" 2> "$WORK_DIR/pre_err.txt"); then
    "${CRI[@]}" rmp -f "$PRE_POD" >/dev/null 2>&1 || true
    fail "the test sandbox started: the problem is not there"
fi
grep -q "$DEFAULT_PAUSE" "$WORK_DIR/pre_err.txt" || { tail -2 "$WORK_DIR/pre_err.txt" | cut -c1-300; fail "the error does not name $DEFAULT_PAUSE"; }
sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" | grep -q "^CONNECT k8s.gcr.io:443 DENY" || fail "the egress proxy log shows no refused request for k8s.gcr.io"
if sudo tail -n +"$((P0 + 1))" "$REG_DIR/requests.log" | grep -q "ua=cri-o/"; then fail "CRI-O talked to the private registry"; fi
[ -z "$("${CRI[@]}" pods -q 2>/dev/null)" ] || fail "a failed sandbox is left in CRI-O"
echo "  -> OK ($(grep -o 'initializing source docker://[^:]*:[^:]*' "$WORK_DIR/pre_err.txt" | head -1))"

echo "[precondition] checking CRI-O itself can pull from the private registry (so the registry configuration is not the problem)..."
"${CRI[@]}" pull "$PAUSE_REF" >/dev/null 2> "$WORK_DIR/pre_pull_err.txt" || { tail -2 "$WORK_DIR/pre_pull_err.txt" | cut -c1-300; fail "crictl pull of $PAUSE_REF failed"; }
"${CRI[@]}" rmi "$PAUSE_REF" >/dev/null 2>&1 || true
[ -z "$("${CRI[@]}" images -q 2>/dev/null)" ] || fail "could not remove the test image again"
echo "  -> OK"

echo "[precondition] PASS - the sandbox image of CRI-O is $DEFAULT_PAUSE, which the node cannot reach; the private registry works."
