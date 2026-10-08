#!/bin/bash
set -e

CASE_ID="bench72419513"
RUN_BASE="/run/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/registry"
HUB_DIR="$RUN_BASE/proxy"
REG_HOST="registry.bench72419513.test"
REG_PORT=5000
REPO="team/imagename"
IMAGE_REF="$REG_HOST:$REG_PORT/$REPO:v1"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

CTR="sudo ctr -a $CTD_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" --timeout 60s)
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])' "$STATE_DIR/image.truth" "$1"; }

echo "[precondition] checking the state setup recorded and the three daemons (containerd, registry, egress proxy)..."
for f in containerd.id registry.id hubgate.id token manifest.digest image.truth registry.state0 containerdctl.sha; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
for d in containerd registry hubgate; do alive_same "$d" || fail "the recorded $d is not running"; done
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[precondition] checking the registry speaks plain HTTP only (127.0.0.1:$REG_PORT) and serves $REPO:v1 with the recorded digest..."
D=$(sudo cat "$STATE_DIR/manifest.digest")
HDR=$(curl -sI --max-time 5 -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "http://127.0.0.1:$REG_PORT/v2/$REPO/manifests/v1" | tr -d '\r')
echo "$HDR" | head -1 | grep -q ' 200' || fail "the registry does not serve $REPO:v1 over HTTP"
[ "$(echo "$HDR" | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')" = "$D" ] || fail "the digest of $REPO:v1 is not the recorded one"
if curl -skf --max-time 5 "https://127.0.0.1:$REG_PORT/v2/" >/dev/null 2>&1; then fail "the registry answers over TLS"; fi
echo "  -> OK ($D)"

echo "[precondition] checking containerd has NO registry configuration for the CRI (config_path empty, no hosts directory for the registry)..."
CP=$(sudo awk '/^[[:space:]]*\[.*registry\][[:space:]]*$/ {s=1; next} /^[[:space:]]*\[/ {s=0} s && /config_path/ {print}' "$RUN_BASE/config.toml")
echo "$CP" | grep -Eq "config_path *= *(''|\"\")" || fail "the CRI registry section of the config has a config_path: $CP"
sudo grep -q "mirrors" "$RUN_BASE/config.toml" && fail "the config has a mirrors table"
[ ! -e "/etc/containerd/certs.d/$REG_HOST:$REG_PORT" ] || fail "/etc/containerd/certs.d/$REG_HOST:$REG_PORT exists"
echo "  -> OK"

echo "[precondition] checking the image is not in containerd, and pulling it through the CRI must FAIL by trying HTTPS on a plain-HTTP registry..."
H0=$(sudo wc -l < "$HUB_DIR/requests.log")
P0=$(sudo wc -l < "$REG_DIR/requests.log")
if $CTR -n k8s.io images ls -q | grep -q imagename; then fail "the image is already in containerd"; fi
if "${CRI[@]}" pull "$IMAGE_REF" > "$WORK_DIR/pre_out.txt" 2> "$WORK_DIR/pre_err.txt"; then
    fail "the pull of $IMAGE_REF succeeded before any fix was applied"
fi
grep -Eq "server gave HTTP response to HTTPS client|first record does not look like a TLS handshake" "$WORK_DIR/pre_err.txt" \
    || fail "the pull failed, but not because of HTTP vs HTTPS: $(tail -1 "$WORK_DIR/pre_err.txt" | cut -c1-240)"
sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" | grep -q "^CONNECT $REG_HOST:$REG_PORT ALLOW" || fail "the egress proxy log has no HTTPS (CONNECT) attempt to $REG_HOST:$REG_PORT"
if sudo tail -n +"$((P0 + 1))" "$REG_DIR/requests.log" | grep -q "ua=containerd"; then fail "the registry served a request of containerd during the failing pull"; fi
echo "  -> OK (containerd tried HTTPS: $(grep -o 'Head [^:]*:[^:]*' "$WORK_DIR/pre_err.txt" | head -1 | cut -c1-120))"

echo "[precondition] PASS - containerd's CRI insists on HTTPS for $REG_HOST:$REG_PORT, which speaks plain HTTP only."
