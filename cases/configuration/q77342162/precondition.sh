#!/bin/bash
set -e

CASE_ID="bench77342162"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/harbor"
HUB_DIR="$RUN_BASE/proxy"
REG_HOST="harbor.bench77342162.test"
REG_PORT=8083
PROJECT="kubernetes-cache"
UPSTREAM="registry.k8s.io"
IMG_NAME="kube-proxy"
TAG="v1.26.5"
HARBOR_REPO="$PROJECT/$IMG_NAME"
EXT_REF="$UPSTREAM/$IMG_NAME:$TAG"
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
hget() {   # $1 = path (below the registry), $2 = token ('' = none), rest = extra curl args -> status code, headers+body in $WORK_DIR/h.out
    local p=$1 t=$2; shift 2
    curl -s --max-time 5 --noproxy '*' -o "$WORK_DIR/h.body" -D "$WORK_DIR/h.hdr" -w '%{http_code}' ${t:+-H "Authorization: Bearer $t"} "$@" "http://127.0.0.1:$REG_PORT$p"
}

echo "[precondition] checking the state setup recorded and the three daemons (containerd, Harbor's stand-in, the egress proxy)..."
for f in containerd.id registry.id hubgate.id image.truth manifest.digest registry.state0 containerdctl.sha; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
for d in containerd registry hubgate; do alive_same "$d" || fail "the recorded $d is not running"; done
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[precondition] checking Harbor's API as the fixture models it: /v2/ asks for a Bearer token, a public project gives anonymous"
echo "[precondition] tokens, the repository is $HARBOR_REPO (<project>/<repository>), and a name without the project is refused..."
[ "$(hget /v2/ '')" = "401" ] || fail "/v2/ does not answer 401"
grep -qi '^www-authenticate: Bearer realm="http://[^"]*/service/token",service="harbor-registry"' "$WORK_DIR/h.hdr" || fail "/v2/ gives no Bearer challenge"
[ "$(hget "/service/token?service=harbor-registry&scope=repository:$HARBOR_REPO:pull" '')" = "200" ] || fail "no anonymous token for the public project"
TOK=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$WORK_DIR/h.body")
[ "$(hget "/v2/$HARBOR_REPO/manifests/$TAG" "$TOK" -I -H 'Accept: application/vnd.docker.distribution.manifest.v2+json')" = "200" ] || fail "the manifest of $HARBOR_REPO:$TAG is not served with a token"
[ "$(tr -d '\r' < "$WORK_DIR/h.hdr" | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')" = "$(sudo cat "$STATE_DIR/manifest.digest")" ] || fail "the digest in Harbor is not the recorded one"
[ "$(hget "/v2/$HARBOR_REPO/manifests/$TAG" '')" = "401" ] || fail "the manifest is served without a token"
[ "$(hget "/v2/$IMG_NAME/manifests/$TAG" "$TOK")" = "400" ] || fail "a repository name without the project is not refused with 400"
echo "  -> OK ($(sudo cat "$STATE_DIR/manifest.digest" | cut -c1-19)...)"

echo "[precondition] checking containerd's registry configuration is the one of the question (a mirror of $UPSTREAM with the"
echo "[precondition] endpoint http://$REG_HOST:$REG_PORT/$PROJECT), without a hosts directory, and that it holds no image..."
sudo grep -q "mirrors.'$UPSTREAM'" "$RUN_BASE/config.toml" || fail "the mirror of $UPSTREAM is not in the config"
sudo grep -q "http://$REG_HOST:$REG_PORT/$PROJECT'" "$RUN_BASE/config.toml" || fail "the endpoint of the question is not in the config"
[ ! -e "/etc/containerd/certs.d/$UPSTREAM" ] || fail "/etc/containerd/certs.d/$UPSTREAM exists"
if "${CRI[@]}" images 2>/dev/null | grep -q "$IMG_NAME"; then fail "containerd already holds the image"; fi
echo "  -> OK"

echo "[precondition] checking the pull of the cluster's reference fails, and recording the request that Harbor got (the actual error path)..."
H0=$(sudo wc -l < "$HUB_DIR/requests.log")
P0=$(sudo wc -l < "$REG_DIR/requests.log")
if "${CRI[@]}" pull "$EXT_REF" > "$WORK_DIR/pre_out.txt" 2> "$WORK_DIR/pre_err.txt"; then fail "the pull worked: the problem is not there"; fi
sudo tail -n +"$((P0 + 1))" "$REG_DIR/requests.log" | grep 'ua=containerd/' > "$WORK_DIR/pre_harbor.log" || fail "Harbor got no request from containerd"
sed 's/^/     /' "$WORK_DIR/pre_harbor.log" | cut -c1-150
grep -q "^\(HEAD\|GET\) /$PROJECT/$IMG_NAME/manifests/$TAG[?[:space:]].* 404 " "$WORK_DIR/pre_harbor.log" \
    || fail "Harbor did not get 'HEAD /$PROJECT/$IMG_NAME/manifests/$TAG' (the project replaces /v2 in the path) answered 404"
if grep -q "^[A-Z]* /v2/$HARBOR_REPO/" "$WORK_DIR/pre_harbor.log"; then fail "containerd already used the right path"; fi
awk '{print $1, $2}' "$WORK_DIR/pre_harbor.log" | head -1 | sudo tee "$STATE_DIR/error_request.txt" >/dev/null
sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" | grep -q "^CONNECT $UPSTREAM:443 DENY" || fail "the egress proxy log shows no refused connection to $UPSTREAM (the fallback to the original registry)"
echo "  -> OK (the wrong request: $(sudo cat "$STATE_DIR/error_request.txt" | cut -c1-120))"

echo "[precondition] PASS - containerd sends Harbor a path without /v2/$PROJECT, gets 404, falls back to $UPSTREAM, which the node cannot reach."
