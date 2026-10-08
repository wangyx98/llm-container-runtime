#!/bin/bash
set -e

CASE_ID="bench76729881"
RUN_BASE="/run/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/nexus"
HUB_DIR="$RUN_BASE/hubgate"
REG="http://127.0.0.1:8181"
REPO="benchorg/kubevip"
IMAGE_REF="docker.io/benchorg/kubevip:0.6.1"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

CTR="sudo ctr -a $CTD_SOCK"
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])' "$STATE_DIR/image.truth" "$1"; }

echo "[precondition] checking the state setup recorded and the three daemons (containerd, proxy fixture, egress gateway)..."
for f in containerd.id registry.id hubgate.id token manifest.digest image.truth registry.state0 containerdctl.sha; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
for d in containerd registry hubgate; do alive_same "$d" || fail "the recorded $d is not running"; done
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
echo "  -> OK"

echo "[precondition] checking the proxy fixture (plain HTTP on 127.0.0.1:8181) serves $REPO:0.6.1 with the recorded digest..."
D=$(sudo cat "$STATE_DIR/manifest.digest")
HDR=$(curl -sI --max-time 5 -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "$REG/v2/$REPO/manifests/0.6.1" | tr -d '\r')
echo "$HDR" | head -1 | grep -q ' 200' || fail "the proxy does not serve $REPO:0.6.1"
[ "$(echo "$HDR" | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')" = "$D" ] || fail "the digest of $REPO:0.6.1 is not the recorded one"
for k in config layer; do
    curl -sfI --max-time 5 "$REG/v2/$REPO/blobs/$(jget $k)" >/dev/null || fail "the proxy lacks the $k blob of the image"
done
echo "  -> OK ($D)"

echo "[precondition] checking containerd's config has the CRI mirror docker.io -> the proxy (the state the question starts from),"
echo "[precondition] and that no hosts directory exists for docker.io..."
sudo grep -Eq "mirrors" "$RUN_BASE/config.toml" || fail "the config has no mirrors table for the CRI"
sudo grep -q "endpoint = \['http://127.0.0.1:8181'\]" "$RUN_BASE/config.toml" || fail "the config has no mirror endpoint for the proxy"
[ ! -e /etc/containerd/certs.d/docker.io ] || fail "/etc/containerd/certs.d/docker.io exists"
[ ! -e /etc/containerd/certs.d/_default ] || fail "/etc/containerd/certs.d/_default exists"
echo "  -> OK"

echo "[precondition] checking the image is not in containerd, and 'ctr images pull $IMAGE_REF' must FAIL by trying Docker Hub..."
H0=$(sudo wc -l < "$HUB_DIR/requests.log")
P0=$(sudo wc -l < "$REG_DIR/requests.log")
for ns in default k8s.io; do
    if $CTR -n "$ns" images ls -q 2>/dev/null | grep -q kubevip; then fail "the image is already in containerd (namespace $ns)"; fi
done
if timeout 90 $CTR images pull "$IMAGE_REF" </dev/null > "$WORK_DIR/pre_out.txt" 2> "$WORK_DIR/pre_err.txt"; then
    fail "the pull of $IMAGE_REF with ctr succeeded before any fix was applied"
fi
grep -q "registry-1.docker.io" "$WORK_DIR/pre_err.txt" || fail "the pull failed, but not on Docker Hub: $(grep -v DEPRECATION "$WORK_DIR/pre_err.txt" | tail -1 | cut -c1-200)"
H1=$(sudo wc -l < "$HUB_DIR/requests.log")
[ "$H1" -gt "$H0" ] || fail "containerd did not try to reach Docker Hub (the egress gateway log did not grow)"
sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" | grep -q "^CONNECT registry-1.docker.io:443" || fail "the gateway log has no CONNECT to registry-1.docker.io:443"
P1=$(sudo wc -l < "$REG_DIR/requests.log")
[ "$P1" = "$P0" ] || fail "the proxy fixture saw requests during the failing pull"
echo "  -> OK (ctr went to Docker Hub, not to the CRI mirror's proxy: $(grep -o 'Head [^:]*:[^:]*' "$WORK_DIR/pre_err.txt" | head -1 | cut -c1-120))"

echo "[precondition] PASS - the CRI has a mirror, but ctr pulls docker.io images from Docker Hub only; the proxy is unused by ctr."
