#!/bin/bash
set -e

CASE_ID="bench72298729"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/registry"
DOCKER_DIR="$LIB_BASE/docker"
HOSTS_DIR="$LIB_BASE/certs.d"
REG_HOST="127.0.0.1"
REG_PORT=5000
REG_USER="ci-puller"
REPO="qtech/graphql"
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

echo "[precondition] checking the state setup recorded and the two daemons (containerd, registry)..."
for f in containerd.id registry.id regpass token manifest.digest image.truth registry.state0 containerdctl.sha secrets.sha; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
for d in containerd registry; do alive_same "$d" || fail "the recorded $d is not running"; done
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[precondition] checking the registry is private: no credentials -> 401 (Basic challenge), a wrong password -> 401..."
URL="http://127.0.0.1:$REG_PORT/v2/$REPO/manifests/$TAG"
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$REG_PORT/v2/")" = "401" ] || fail "the registry answers without credentials"
curl -sI --max-time 5 "http://127.0.0.1:$REG_PORT/v2/" | tr -d '\r' | grep -qi '^www-authenticate: *basic' || fail "the registry sends no Basic challenge"
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -u "$REG_USER:wrong" "$URL")" = "401" ] || fail "the registry accepts a wrong password"
echo "  -> OK"

echo "[precondition] checking what 'docker login' left (docker's config.json) works against the registry, as in the question..."
CREDS=$(sudo python3 - "$DOCKER_DIR/config.json" "$REG_HOST:$REG_PORT" <<'PY'
import base64, json, sys
d = json.load(open(sys.argv[1]))
print(base64.b64decode(d["auths"][sys.argv[2]]["auth"]).decode())
PY
) || fail "docker's config.json has no entry for $REG_HOST:$REG_PORT"
D=$(sudo cat "$STATE_DIR/manifest.digest")
HDR=$(curl -sI --max-time 5 -u "$CREDS" -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "$URL" | tr -d '\r')
echo "$HDR" | head -1 | grep -q ' 200' || fail "the credentials of docker's config.json are not accepted by the registry"
[ "$(echo "$HDR" | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')" = "$D" ] || fail "the digest of $REPO:$TAG is not the recorded one"
echo "  -> OK (the account is $REG_USER, $REPO:$TAG = $D)"

echo "[precondition] checking containerd has no credentials: no auth in its config, no header in the hosts directory..."
sudo grep -qE "^\s*\[.*(\.auth|\.configs)" "$RUN_BASE/config.toml" && fail "the config of containerd already holds registry credentials"
sudo grep -qE "^\s*(username|password|auth|identitytoken)\s*=" "$RUN_BASE/config.toml" && fail "the config of containerd already holds registry credentials"
sudo grep -rqiE "authorization|header" "$HOSTS_DIR" && fail "the hosts directory already carries a header"
sudo grep -q "http://$REG_HOST:$REG_PORT" "$HOSTS_DIR/$REG_HOST:$REG_PORT/hosts.toml" || fail "the hosts directory does not set the registry as plain HTTP"
echo "  -> OK"

echo "[precondition] checking the image is not in containerd, and pulling it through the CRI must FAIL with an authorization error..."
P0=$(sudo wc -l < "$REG_DIR/requests.log")
if $CTR -n k8s.io images ls -q | grep -q graphql; then fail "the image is already in containerd"; fi
if "${CRI[@]}" pull "$IMAGE_REF" > "$WORK_DIR/pre_out.txt" 2> "$WORK_DIR/pre_err.txt"; then
    fail "the pull of $IMAGE_REF succeeded before any fix was applied"
fi
grep -Eq "no basic auth credentials|authorization failed|pull access denied|401" "$WORK_DIR/pre_err.txt" \
    || fail "the pull failed, but not on authorization: $(tail -1 "$WORK_DIR/pre_err.txt" | cut -c1-240)"
sudo tail -n +"$((P0 + 1))" "$REG_DIR/requests.log" > "$WORK_DIR/pre_registry.log"
grep -q "401 ua=containerd/.* auth=none" "$WORK_DIR/pre_registry.log" || fail "the registry log has no 401 for a request of containerd without credentials"
if grep -q "ua=containerd/.* 200 \|200 ua=containerd/" "$WORK_DIR/pre_registry.log"; then fail "the registry served containerd during the failing pull"; fi
echo "  -> OK (containerd reached the registry over HTTP and was refused: $(grep -o 'authorization failed[^"]*' "$WORK_DIR/pre_err.txt" | head -1))"

echo "[precondition] PASS - the registry wants Basic credentials, docker's config.json holds them, and containerd's CRI pulls without any."
