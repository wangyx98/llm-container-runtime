#!/bin/bash
set -e

CASE_ID="bench65576292"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/registry"
HUB_DIR="$RUN_BASE/proxy"
PKI_DIR="$LIB_BASE/pki"
REG_HOST="registry.foo.test"
REG_PORT=5443
REG_USER="admin"
REPO="library/myimage"
TAG="latest"
IMAGE_REF="$REG_HOST:$REG_PORT/$REPO:$TAG"
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
# a request straight to the registry, verified against the company CA (the name is resolved to the registry by hand)
direct() { curl -s --noproxy "*" --max-time 5 --cacert "$PKI_DIR/ca.pem" --resolve "$REG_HOST:$REG_PORT:127.0.0.1" "$@"; }

echo "[precondition] checking the state setup recorded and the three daemons (containerd, registry, egress proxy)..."
for f in containerd.id registry.id hubgate.id regpass token manifest.digest image.truth registry.state0 containerdctl.sha secrets.sha; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
for d in containerd registry hubgate; do alive_same "$d" || fail "the recorded $d is not running"; done
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[precondition] checking TLS is fine (the certificate verifies against the company CA) and the registry is private:"
echo "[precondition] no credentials -> 401 (Basic challenge), a wrong password -> 401, the account -> 200..."
REGPASS=$(sudo cat "$STATE_DIR/regpass")
URL="https://$REG_HOST:$REG_PORT/v2/$REPO/manifests/$TAG"
[ "$(direct -o /dev/null -w '%{http_code}' "https://$REG_HOST:$REG_PORT/v2/")" = "401" ] || fail "the registry does not answer 401 without credentials over verified TLS"
direct -I "https://$REG_HOST:$REG_PORT/v2/" | tr -d '\r' | grep -qi '^www-authenticate: *basic' || fail "the registry sends no Basic challenge"
[ "$(direct -o /dev/null -w '%{http_code}' -u "$REG_USER:wrong" "$URL")" = "401" ] || fail "the registry accepts a wrong password"
D=$(sudo cat "$STATE_DIR/manifest.digest")
HDR=$(direct -I -u "$REG_USER:$REGPASS" -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "$URL" | tr -d '\r')
echo "$HDR" | head -1 | grep -q ' 200' || fail "the account $REG_USER is not accepted by the registry"
[ "$(echo "$HDR" | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')" = "$D" ] || fail "the digest of $REPO:$TAG is not the recorded one"
if curl -s --max-time 5 -o /dev/null "http://127.0.0.1:$REG_PORT/v2/" 2>/dev/null; then fail "the registry answers over plain HTTP"; fi
echo "  -> OK ($D)"

echo "[precondition] checking the credentials are in the config of containerd under the host name WITHOUT the port, and that"
echo "[precondition] nothing else configures the registry: no config_path, no key with the port, no hosts directory..."
sudo grep -q "registry.configs.'$REG_HOST'.auth\]" "$RUN_BASE/config.toml" || fail "the registry.configs table of the engineer (key $REG_HOST) is not in the config"
sudo grep -q "$REG_HOST:$REG_PORT" "$RUN_BASE/config.toml" && fail "the config already names $REG_HOST:$REG_PORT"
CP=$(sudo awk '/^[[:space:]]*\[.*registry\][[:space:]]*$/ {s=1; next} /^[[:space:]]*\[/ {s=0} s && /config_path/ {print}' "$RUN_BASE/config.toml")
echo "$CP" | grep -Eq "config_path *= *(''|\"\")" || fail "the CRI registry section of the config has a config_path: $CP"
for h in "$REG_HOST:$REG_PORT" "$REG_HOST" "${REG_HOST}_$REG_PORT"; do
    [ ! -e "/etc/containerd/certs.d/$h" ] || fail "/etc/containerd/certs.d/$h exists"
done
echo "  -> OK"

echo "[precondition] checking the image is not in containerd, and pulling it through the CRI must FAIL with an authorization error..."
H0=$(sudo wc -l < "$HUB_DIR/requests.log")
P0=$(sudo wc -l < "$REG_DIR/requests.log")
if $CTR -n k8s.io images ls -q | grep -q myimage; then fail "the image is already in containerd"; fi
if "${CRI[@]}" pull "$IMAGE_REF" > "$WORK_DIR/pre_out.txt" 2> "$WORK_DIR/pre_err.txt"; then
    fail "the pull of $IMAGE_REF succeeded before any fix was applied"
fi
grep -Eq "no basic auth credentials|authorization failed|pull access denied|401" "$WORK_DIR/pre_err.txt" \
    || fail "the pull failed, but not on authorization: $(tail -1 "$WORK_DIR/pre_err.txt" | cut -c1-240)"
sudo tail -n +"$((P0 + 1))" "$REG_DIR/requests.log" > "$WORK_DIR/pre_registry.log"
grep -Eq "^HEAD .* 401 ua=containerd/.* tls=TLSv[0-9.]+ auth=none" "$WORK_DIR/pre_registry.log" || fail "the registry log has no 401 over TLS for a request of containerd without credentials"
if grep -q " 200 ua=containerd/" "$WORK_DIR/pre_registry.log"; then fail "the registry served containerd during the failing pull"; fi
sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" | grep -q "^CONNECT $REG_HOST:$REG_PORT ALLOW" || fail "the egress proxy log has no tunnel to $REG_HOST:$REG_PORT"
echo "  -> OK (TLS works, containerd reached the registry and was refused: $(grep -o 'authorization failed[^"]*' "$WORK_DIR/pre_err.txt" | head -1))"

echo "[precondition] PASS - the registry (HTTPS, valid certificate) wants Basic credentials and containerd sends none: its credentials are keyed by $REG_HOST, the registry is $REG_HOST:$REG_PORT."
