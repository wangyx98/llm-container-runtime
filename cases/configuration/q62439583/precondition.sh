#!/bin/bash
set -e

CASE_ID="bench62439583"
LIB="/var/lib/$CASE_ID"
ETC="$LIB/etc"
COMMON="$LIB/common"
SOCK="$COMMON/run/containerd.sock"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CTL="$STATE_DIR/ctl"
ADDR_DOCKER="127.62.43.95"
ADDR_QUAY="127.62.43.96"
PORT=8082
WEB_REPO="benchlab62439/web"
FLANNEL_REPO="benchlab62439/flannel"
FLANNEL_TAG="v0.11.0-amd64"
WEB_REF="docker.io/$WEB_REPO:v1"
K8S_REF="k8s.gcr.io/$WEB_REPO:v1"
FLANNEL_REF="quay.io/$FLANNEL_REPO:$FLANNEL_TAG"
TYPO_REF="quai.io/$FLANNEL_REPO:$FLANNEL_TAG"

fail() { echo "  -> FAIL: $*"; exit 1; }
node_crictl() { sudo crictl -r "unix://$SOCK" -i "unix://$SOCK" --timeout 60s "$@"; }
ctl_crictl() { sudo crictl -r "unix://$CTL/common/run/containerd.sock" -i "unix://$CTL/common/run/containerd.sock" --timeout 60s "$@"; }
log_lines() { sudo wc -l < "$RUN/jcr.log"; }
# what the JFrog stand-in logged since line $1, one line per request: repo user status method kind(manifests|blobs|ping)
jcr_since() { sudo tail -n +"$(($1 + 1))" "$RUN/jcr.log" | python3 -c '
import json
import sys

for ln in sys.stdin:
    r = json.loads(ln)
    kind = "manifests" if "/manifests/" in r["path"] else ("blobs" if "/blobs/" in r["path"] else "ping")
    print(r["repo"], r["who"], r["status"], r["method"], kind)'; }
code() {   # code USER:PASSWORD|- ADDR PATH : the HTTP status of a GET
    if [ "$1" = "-" ]; then curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' "http://$2:$PORT$3"
    else curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' -u "$1" "http://$2:$PORT$3"; fi
}

echo "[precondition] the lab is as its record says: programs and accounts unchanged, the JFrog stand-in the process setup started, the node running with the sandbox image..."
sudo sh -c 'cd / && sha256sum -c --quiet "$1/lab.sha"' _ "$STATE_DIR" >/dev/null 2>&1 || fail "a program of the lab or the accounts file was changed"
JCR_PID=$(sudo cat "$STATE_DIR/jcr.pid")
[ "$(sudo awk '{print $22}' "/proc/$JCR_PID/stat" 2>/dev/null)" = "$(sudo cat "$STATE_DIR/jcr.start")" ] || fail "the JFrog stand-in is not the process setup started"
sudo "$LIB/bin/nodectl" status >/dev/null || fail "the node is not running"
node_crictl inspecti -o json "$CASE_ID.local/pause:1" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["id"])' | cmp -s - <(sudo cat "$STATE_DIR/pause.id") || fail "the sandbox image of the node is not the imported one"
echo "  -> OK"

echo "[precondition] the engineer's registry settings: a wildcard mirror and the three named registries, one endpoint (the repository docker) for all of them, the account ci for both repositories, the name quai.io..."
CONF="$ETC/containerd.toml"
for k in "'\\*'" "'docker\\.io'" "'k8s\\.gcr\\.io'" "'quai\\.io'"; do
    sudo grep -qE "registry\.mirrors\.$k\]" "$CONF" || fail "containerd.toml has no mirror entry $k"
done
[ "$(sudo grep -cF "endpoint = ['http://$ADDR_DOCKER:$PORT']" "$CONF")" = 4 ] || fail "the four mirror entries do not all point at http://$ADDR_DOCKER:$PORT"
! sudo grep -qE "registry\.mirrors\.'quay\.io'" "$CONF" || fail "containerd.toml already has a quay.io entry"
for a in "$ADDR_DOCKER:$PORT" "$ADDR_QUAY:$PORT"; do
    sudo grep -qF "registry.configs.'$a'.auth]" "$CONF" || fail "containerd.toml has no authentication block for $a"
done
[ "$(sudo grep -c "^  username = 'ci'" "$CONF")" = 2 ] || fail "the two authentication blocks are not those of ci"
! sudo grep -qE "^[[:space:]]*config_path[[:space:]]*=[[:space:]]*'[^']" "$CONF" || fail "containerd.toml has a config_path already"
echo "  -> OK"

echo "[precondition] the rules of the JFrog stand-in: no credentials 401, ci reads docker and not quay-remote (403), quay-reader reads quay-remote and not docker (403), the repository docker does not hold the Quay image (404)..."
CI="ci:$(sudo python3 -c 'import json; print(json.load(open("'"$LIB"'/accounts.json"))["ci"])')"
QR="quay-reader:$(sudo python3 -c 'import json; print(json.load(open("'"$LIB"'/accounts.json"))["quay-reader"])')"
WEB_PATH="/v2/$WEB_REPO/manifests/v1"
FLANNEL_PATH="/v2/$FLANNEL_REPO/manifests/$FLANNEL_TAG"
[ "$(code - "$ADDR_DOCKER" "$WEB_PATH")" = 401 ] || fail "docker answers an anonymous request with something else than 401"
[ "$(code - "$ADDR_QUAY" "$FLANNEL_PATH")" = 401 ] || fail "quay-remote answers an anonymous request with something else than 401"
[ "$(code "$CI" "$ADDR_DOCKER" "$WEB_PATH")" = 200 ] || fail "ci cannot read the web image from docker"
[ "$(code "$CI" "$ADDR_QUAY" "$FLANNEL_PATH")" = 403 ] || fail "ci is not refused (403) by quay-remote"
[ "$(code "$QR" "$ADDR_QUAY" "$FLANNEL_PATH")" = 200 ] || fail "quay-reader cannot read the Quay image from quay-remote"
[ "$(code "$QR" "$ADDR_DOCKER" "$WEB_PATH")" = 403 ] || fail "quay-reader is not refused (403) by docker"
[ "$(code "$CI" "$ADDR_DOCKER" "$FLANNEL_PATH")" = 404 ] || fail "the repository docker does not answer 404 for the Quay image"
echo "  -> OK"

echo "[precondition] the problem: the node pulls the Docker Hub image under two names, and the Quay image fails: its pull goes to the repository docker (404) and never reaches quay-remote..."
N0=$(log_lines)
OUT=$(node_crictl pull "$WEB_REF" 2>&1) || fail "the node cannot pull $WEB_REF: $(echo "$OUT" | tail -1 | cut -c1-200)"
OUT=$(node_crictl pull "$K8S_REF" 2>&1) || fail "the node cannot pull $K8S_REF: $(echo "$OUT" | tail -1 | cut -c1-200)"
jcr_since "$N0" | grep -q "^docker ci 200 GET blobs" || fail "the images were not pulled from docker as ci"
! jcr_since "$N0" | grep -q "^quay-remote" || fail "a request reached quay-remote while only the Docker Hub image was pulled"
N0=$(log_lines)
OUT=$(node_crictl pull "$FLANNEL_REF" 2>&1) && fail "the pull of $FLANNEL_REF worked: $OUT"
jcr_since "$N0" | grep -q "^docker ci 404 " || fail "the stand-in did not answer 404 to ci for the Quay image in the repository docker"
! jcr_since "$N0" | grep -q "^quay-remote" || fail "a request reached quay-remote"
OUT=$(node_crictl pull "$TYPO_REF" 2>&1) && fail "the pull of $TYPO_REF worked"
node_crictl rmi "$WEB_REF" "$K8S_REF" >/dev/null 2>&1 || true
echo "  -> OK"

start_ctl() {   # a throw-away containerd (own root, state and socket) with the node's configuration up to the registry settings, $1 = the registry settings
    sudo rm -rf "$CTL"
    sudo install -d -m 700 "$CTL" "$CTL/common/run" "$CTL/common/var/lib/containerd"
    { sudo sed -e '/^# registry settings of the node/,$d' -e "s@$COMMON@$CTL/common@g" "$ETC/containerd.toml"; echo "$1"; } | sudo tee "$CTL/containerd.toml" >/dev/null
    sudo sh -c "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin setsid nohup containerd --config '$CTL/containerd.toml' >'$CTL/containerd.log' 2>&1 </dev/null &"
    for _ in $(seq 60); do sudo test -S "$CTL/common/run/containerd.sock" && ctl_crictl version >/dev/null 2>&1 && return 0; sleep 0.5; done
    fail "the control containerd did not start: $(sudo tail -3 "$CTL/containerd.log")"
}
stop_ctl() {
    sudo pkill -TERM -f -- "--config $CTL/[c]ontainerd.toml" 2>/dev/null || true
    for _ in $(seq 20); do sudo pgrep -f -- "--config $CTL/[c]ontainerd.toml" >/dev/null || break; sleep 0.5; done
    sudo pkill -KILL -f -- "--config $CTL/[c]ontainerd.toml" 2>/dev/null || true
    sudo rm -rf "$CTL"
}
R="plugins.'io.containerd.cri.v1.images'.registry"
CI_PW=${CI#ci:}
QR_PW=${QR#quay-reader:}
mirror() { printf "[%s.mirrors.'%s']\n  endpoint = ['%s']\n\n" "$R" "$1" "$2"; }
account() { printf "[%s.configs.'%s'.auth]\n  username = '%s'\n  password = '%s'\n\n" "$R" "$1" "$2" "$3"; }

echo "[precondition] control 1: the wildcard alone is a working default route: with only the mirror '*' all three names (docker.io, k8s.gcr.io, quay.io) go to the repository docker; the Docker Hub image is served, the Quay image is not there (404)..."
start_ctl "$(mirror '*' "http://$ADDR_DOCKER:$PORT"; account "$ADDR_DOCKER:$PORT" ci "$CI_PW")"
N0=$(log_lines)
ctl_crictl pull "$WEB_REF" >/dev/null 2>&1 || { stop_ctl; fail "with the wildcard alone the pull of $WEB_REF failed"; }
ctl_crictl pull "$K8S_REF" >/dev/null 2>&1 || { stop_ctl; fail "with the wildcard alone the pull of $K8S_REF failed"; }
OUT=$(ctl_crictl pull "$FLANNEL_REF" 2>&1) && { stop_ctl; fail "with the wildcard alone the Quay image was pulled"; }
jcr_since "$N0" | grep -q "^docker ci 404 " || { stop_ctl; fail "the Quay image was not looked for in the repository docker"; }
! jcr_since "$N0" | grep -q "^quay-remote" || { stop_ctl; fail "a request reached quay-remote"; }
stop_ctl
echo "  -> OK"

echo "[precondition] control 2: quay.io (spelled right) sent to quay-remote, with ci as in the engineer's file: refused with 403 Forbidden, the answer of the question..."
start_ctl "$(mirror '*' "http://$ADDR_DOCKER:$PORT"; mirror quay.io "http://$ADDR_QUAY:$PORT"; account "$ADDR_DOCKER:$PORT" ci "$CI_PW"; account "$ADDR_QUAY:$PORT" ci "$CI_PW")"
N0=$(log_lines)
OUT=$(ctl_crictl pull "$FLANNEL_REF" 2>&1) && { stop_ctl; fail "the pull with ci worked"; }
jcr_since "$N0" | grep -q "^quay-remote ci 403 " || { stop_ctl; fail "the stand-in did not answer 403 to ci on quay-remote"; }
stop_ctl
echo "  -> OK"

echo "[precondition] control 3: the same with the account quay-reader for the endpoint of quay-remote pulls the Quay image, as that account; the Docker Hub image still comes from docker as ci (the lab can be solved)..."
start_ctl "$(mirror '*' "http://$ADDR_DOCKER:$PORT"; mirror quay.io "http://$ADDR_QUAY:$PORT"; account "$ADDR_DOCKER:$PORT" ci "$CI_PW"; account "$ADDR_QUAY:$PORT" quay-reader "$QR_PW")"
N0=$(log_lines)
OUT=$(ctl_crictl pull "$FLANNEL_REF" 2>&1) || { stop_ctl; fail "the pull with quay-reader failed: $(echo "$OUT" | tail -1 | cut -c1-200)"; }
OUT=$(ctl_crictl pull "$WEB_REF" 2>&1) || { stop_ctl; fail "the pull of the Docker Hub image failed: $(echo "$OUT" | tail -1 | cut -c1-200)"; }
jcr_since "$N0" | grep -q "^quay-remote quay-reader 200 GET blobs" || { stop_ctl; fail "quay-remote did not serve the blobs to quay-reader"; }
jcr_since "$N0" | grep -q "^docker ci 200 GET blobs" || { stop_ctl; fail "docker did not serve the blobs to ci"; }
stop_ctl
echo "  -> OK"

echo "[precondition] PASS - the Quay image is pulled from the wrong repository (404); the right endpoint with the engineer's account is refused (403); with the account of quay-remote it is served."
