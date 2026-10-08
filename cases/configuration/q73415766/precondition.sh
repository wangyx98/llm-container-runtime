#!/bin/bash
set -e

CASE_ID="bench73415766"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_A_DIR="$RUN_BASE/regA"
REG_B_DIR="$RUN_BASE/regB"
HUB_DIR="$RUN_BASE/proxy"
HOST_A="pvt-a.registry.test:5028"
HOST_B="pvt-b.registry.test:5038"
REPO="team/app"
TAG="1.0"
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
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])' "$STATE_DIR/$1.truth" "$2"; }

echo "[precondition] checking the state setup recorded and the four daemons (containerd, two registries, egress proxy)..."
for f in containerd.id registry-a.id registry-b.id hubgate.id token.a token.b a.truth b.truth registry-a.state0 registry-b.state0 containerdctl.sha; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
for d in containerd registry-a registry-b hubgate; do alive_same "$d" || fail "the recorded $d is not running"; done
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[precondition] checking both registries answer over HTTPS, with a certificate that a normal client rejects..."
for p in "a:5028" "b:5038"; do
    port=${p#*:}
    curl -sfk --max-time 5 "https://127.0.0.1:$port/v2/" >/dev/null || fail "the registry on port $port does not answer over HTTPS"
    if curl -sf --max-time 5 "https://127.0.0.1:$port/v2/" >/dev/null 2>&1; then fail "the certificate of the registry on port $port is trusted by this machine"; fi
done
echo "  -> OK"

echo "[precondition] checking containerd's config: the TLS block of the question is there, in a table that is not a plugin's,"
echo "[precondition] and the CRI has no registry hosts directory..."
sudo grep -q "^\[plugin\.\"io.containerd.grpc.v1.cri\"\.registry\.configs\.\"$HOST_A\"\.tls\]" "$RUN_BASE/config.toml" || fail "the misspelt TLS block is not in the config"
sudo grep -q "insecure_skip_verify = true" "$RUN_BASE/config.toml" || fail "insecure_skip_verify is not in the config"
CP=$(sudo awk '/^[[:space:]]*\[.*registry\][[:space:]]*$/ {s=1; next} /^[[:space:]]*\[/ {s=0} s && /config_path/ {print}' "$RUN_BASE/config.toml")
echo "$CP" | grep -Eq "config_path *= *(''|\"\")" || fail "the CRI registry section has a config_path: $CP"
echo "  -> OK"

echo "[precondition] pulling the image of each registry through the CRI must FAIL on the certificate (x509), not on the network..."
for w in a b; do
    if [ "$w" = a ]; then host=$HOST_A; dir=$REG_A_DIR; else host=$HOST_B; dir=$REG_B_DIR; fi
    L0=$(sudo wc -l < "$dir/requests.log")
    if $CTR -n k8s.io images ls -q 2>/dev/null | grep -q "/$REPO:"; then fail "an image of $REPO is already in containerd"; fi
    if "${CRI[@]}" pull "$host/$REPO:$TAG" > "$WORK_DIR/pre_$w.out" 2> "$WORK_DIR/pre_$w.err"; then
        fail "the pull of $host/$REPO:$TAG succeeded before any fix was applied"
    fi
    grep -q "x509: certificate signed by unknown authority" "$WORK_DIR/pre_$w.err" || fail "the pull of $host failed, but not on the certificate: $(tail -1 "$WORK_DIR/pre_$w.err" | cut -c1-240)"
    [ "$(sudo wc -l < "$dir/requests.log")" = "$L0" ] || fail "the registry of $host saw requests during the failing pull"
    echo "     $host: $(grep -o 'x509: [a-z ]*' "$WORK_DIR/pre_$w.err" | head -1)"
done
sudo grep -q "^CONNECT $HOST_A ALLOW" "$HUB_DIR/requests.log" || fail "the egress proxy did not see the connection to $HOST_A"
echo "  -> OK"

echo "[precondition] PASS - both private registries are reached over HTTPS and rejected on their certificate."
