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
PROJECT="kubernetes-cache"
IMG_NAME="kube-proxy"
TAG="v1.26.5"
REPO="$PROJECT/$IMG_NAME"
IMAGE_REF="registry.k8s.io/$IMG_NAME:$TAG"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ODIR="$WORK_DIR/oracle"

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

echo "[oracle] check 1: the fixtures are untouched: Harbor (the stand-in) and the egress proxy are the processes of setup, the"
echo "[oracle]          Harbor holds what setup pushed, containerd's start script is unchanged..."
alive_same registry || fail "Harbor is not the process of setup (it was restarted or replaced)"
alive_same hubgate || fail "the egress proxy is not the process of setup (it was restarted or replaced)"
cmp -s "$STATE_DIR/registry.state0" "$REG_DIR/state.json" || fail "the content of Harbor changed"
[ "$(sudo sha256sum "$CTL_DIR/containerdctl" | awk '{print $1}')" = "$(sudo cat "$STATE_DIR/containerdctl.sha")" ] \
    || fail "$CTL_DIR/containerdctl was changed (containerd must keep going through the egress proxy)"
# a restart by the solution returns before the new containerd answers: wait for it
for _ in $(seq 1 60); do
    $CTR version >/dev/null 2>&1 && "${CRI[@]}" version >/dev/null 2>&1 && break
    sleep 1
done
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK (it must be running, on its own socket)"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[oracle] resetting what a solution may have pulled or started, so the pull below really goes through the"
echo "[oracle] registry configuration: pods, containers, the image in every name, and its blobs in the content store..."
for c in $("${CRI[@]}" ps -a -q 2>/dev/null); do
    "${CRI[@]}" stop -t 1 "$c" >/dev/null 2>&1 || true
    "${CRI[@]}" rm -f "$c" >/dev/null 2>&1 || true
done
for p in $("${CRI[@]}" pods -q 2>/dev/null); do
    "${CRI[@]}" stopp "$p" >/dev/null 2>&1 || true
    "${CRI[@]}" rmp -f "$p" >/dev/null 2>&1 || true
done
for ns in k8s.io default; do
    for t in $($CTR -n "$ns" tasks ls -q 2>/dev/null); do $CTR -n "$ns" tasks kill -s SIGKILL "$t" >/dev/null 2>&1 || true; done
    sleep 1
    for t in $($CTR -n "$ns" tasks ls -q 2>/dev/null); do $CTR -n "$ns" tasks delete -f "$t" >/dev/null 2>&1 || true; done
    for c in $($CTR -n "$ns" containers ls -q 2>/dev/null); do $CTR -n "$ns" containers delete "$c" >/dev/null 2>&1 || true; done
    for r in $($CTR -n "$ns" images ls -q 2>/dev/null | grep "$IMG_NAME" || true); do
        $CTR -n "$ns" images rm "$r" >/dev/null 2>&1 || true
    done
    for k in manifest config layer; do
        $CTR -n "$ns" content rm "$(jget $k)" >/dev/null 2>&1 || true
    done
    # content that no image refers to any more is removed by containerd's garbage collector, not at once: force a run
    $CTR -n "$ns" leases create bench-gc >/dev/null 2>&1 || true
    $CTR -n "$ns" leases delete --sync bench-gc >/dev/null 2>&1 || true
    # the unpacked snapshots too: with a snapshot of the layer left over from an earlier pull (a solution that pulled
    # the image or started a pod to look at the result), containerd needs no blob and downloads nothing
    for _ in 1 2 3 4 5; do
        KEYS=$($CTR -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1 {print $1}')
        [ -n "$KEYS" ] || break
        for k in $KEYS; do $CTR -n "$ns" snapshots rm "$k" >/dev/null 2>&1 || true; done
    done
    if [ -n "$($CTR -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1 {print $1}')" ]; then fail "could not remove the snapshots of namespace $ns before the pull"; fi
    if $CTR -n "$ns" images ls -q 2>/dev/null | grep -q "$IMG_NAME"; then fail "could not remove the image from namespace $ns before the pull"; fi
done
BLOBS="$LIB_BASE/containerd/io.containerd.content.v1.content/blobs/sha256"
for k in manifest config layer; do
    H=$(jget $k); H=${H#sha256:}
    for _ in $(seq 1 30); do sudo test -e "$BLOBS/$H" || break; sleep 1; done
    if sudo test -e "$BLOBS/$H"; then fail "the $k blob is still on the disk of containerd: a pull would reuse it"; fi
done

mkdir -p "$ODIR/logs"
H0=$(sudo wc -l < "$HUB_DIR/requests.log")
P0=$(sudo wc -l < "$REG_DIR/requests.log")

echo "[oracle] check 2: 'crictl pull $IMAGE_REF' (no flag, the name the cluster uses) must now succeed..."
if ! "${CRI[@]}" pull "$IMAGE_REF" > "$ODIR/pull_out.txt" 2> "$ODIR/pull_err.txt"; then
    tail -2 "$ODIR/pull_err.txt" | cut -c1-300
    fail "the pull through the CRI failed"
fi
echo "  -> OK"

echo "[oracle] check 3: the image that arrived is the one Harbor holds (same manifest digest)..."
D=$(sudo cat "$STATE_DIR/manifest.digest")
"${CRI[@]}" inspecti -o json "$IMAGE_REF" > "$ODIR/image.json" 2>/dev/null || fail "crictl inspecti failed"
python3 - "$ODIR/image.json" "$D" <<'PY' || fail "the pulled image has not the digest of the image Harbor holds"
import json, sys
st = json.load(open(sys.argv[1])).get("status", {})
digests = st.get("repoDigests", [])
sys.exit(0 if any(d.endswith("@" + sys.argv[2]) for d in digests) else 1)
PY
echo "  -> OK ($D)"

echo "[oracle] check 4: Harbor's request log: containerd got the manifest and the blobs below /v2/$REPO/ with the token of"
echo "[oracle]          /service/token, and no request of containerd was answered with an error or missed the project..."
sudo tail -n +"$((P0 + 1))" "$REG_DIR/requests.log" > "$ODIR/harbor_new.log"
grep 'ua=containerd/' "$ODIR/harbor_new.log" > "$ODIR/harbor_containerd.log" || true
sed 's/^/     /' "$ODIR/harbor_containerd.log" | cut -c1-200
python3 - "$ODIR/harbor_containerd.log" "$REPO" "$(jget manifest)" "$(jget layer)" "$(jget config)" <<'PY' || fail "Harbor's log lacks the manifest, token or blob requests of containerd at /v2/<project>/<repository>/..."
import re, sys
log, repo, manifest, layer, config = sys.argv[1:6]
lines = [l.rstrip("\n") for l in open(log)]
def seen(method_re, path, status="200", auth=r"auth=bearer:\S*"):
    return any(re.match(r"^(%s) %s(\?\S*)? %s ua=containerd/.*%s" % (method_re, re.escape(path), status, auth), l) for l in lines)
ok = seen("GET|HEAD", "/v2/%s/manifests/v1.26.5" % repo)
ok = ok and seen("GET", "/v2/%s/manifests/%s" % (repo, manifest))
ok = ok and seen("GET", "/v2/%s/blobs/%s" % (repo, layer))
ok = ok and seen("GET", "/v2/%s/blobs/%s" % (repo, config))
ok = ok and any(re.match(r"^GET /service/token\?\S* 200 ua=containerd/.* scope=\S*%s" % re.escape(repo), l) for l in lines)
sys.exit(0 if ok else 1)
PY
if grep -E '^[A-Z]+ \S+ (400|404|5[0-9][0-9]) ' "$ODIR/harbor_containerd.log" | sed 's/^/     /' | head -3 | grep .; then
    fail "Harbor answered a containerd request with an error: the path or the repository name was wrong"
fi
if grep -E '^[A-Z]+ /v2/' "$ODIR/harbor_containerd.log" | grep -v -E "^[A-Z]+ /v2/($REPO/|\?|$)" | grep -v -E '^[A-Z]+ /v2/ ' | grep .; then
    fail "containerd asked Harbor for a path outside /v2/$REPO/"
fi
if grep -E '^[A-Z]+ /' "$ODIR/harbor_containerd.log" | grep -v -E '^[A-Z]+ (/v2/|/service/token)' | grep .; then
    fail "containerd asked Harbor for a path that is not /v2/... (the project replaced /v2 in the path)"
fi
echo "  -> OK"

echo "[oracle] check 5: nothing went to the original registry: the egress proxy log shows no request to registry.k8s.io and"
echo "[oracle]          no refused request, the pull went to Harbor over plain HTTP (absolute http:// URLs)..."
sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" > "$ODIR/proxy_new.log"
sed 's/^/     /' "$ODIR/proxy_new.log" | head -5 | cut -c1-150
grep -q "^\(HEAD\|GET\) http://$REG_HOST:8083/v2/$REPO/manifests/" "$ODIR/proxy_new.log" \
    || fail "the egress proxy did not forward a plain-HTTP request for the manifest in Harbor"
if grep -qE "(CONNECT |://)registry\.k8s\.io" "$ODIR/proxy_new.log"; then grep -E "(CONNECT |://)registry\.k8s\.io" "$ODIR/proxy_new.log" | head -2 | sed 's/^/     /'; fail "containerd tried to reach registry.k8s.io"; fi
if grep -q DENY "$ODIR/proxy_new.log"; then grep DENY "$ODIR/proxy_new.log" | head -2 | sed 's/^/     /'; fail "containerd made a request that the egress proxy refused"; fi
echo "  -> OK"

echo "[oracle] check 6: a pod runs that image (by its name registry.k8s.io/...) through the CRI and prints the per-run token baked into it..."
TOKEN=$(sudo cat "$STATE_DIR/token")
cat > "$ODIR/pod.json" <<CONF
{
  "metadata": {"name": "bench77342162-pod", "namespace": "default", "attempt": 1, "uid": "bench77342162-uid"},
  "log_directory": "$ODIR/logs",
  "linux": {"security_context": {"namespace_options": {"network": 2}}}
}
CONF
cat > "$ODIR/container.json" <<CONF
{
  "metadata": {"name": "bench77342162-ctr"},
  "image": {"image": "$IMAGE_REF"},
  "log_path": "ctr.log"
}
CONF
POD_ID=$("${CRI[@]}" runp "$ODIR/pod.json" 2> "$ODIR/runp_err.txt") || { tail -2 "$ODIR/runp_err.txt" | cut -c1-300; fail "crictl runp failed"; }
CTR_ID=$("${CRI[@]}" create "$POD_ID" "$ODIR/container.json" "$ODIR/pod.json" 2> "$ODIR/create_err.txt") || { tail -2 "$ODIR/create_err.txt" | cut -c1-300; fail "crictl create failed"; }
"${CRI[@]}" start "$CTR_ID" >/dev/null 2> "$ODIR/start_err.txt" || { tail -2 "$ODIR/start_err.txt" | cut -c1-300; fail "crictl start failed"; }
GOT=""
for _ in $(seq 1 30); do
    GOT=$("${CRI[@]}" logs "$CTR_ID" 2>/dev/null | grep -F "bench77342162-kube-proxy-ok token=$TOKEN" | head -1 || true)
    [ -n "$GOT" ] && break
    sleep 1
done
[ -n "$GOT" ] || fail "the container did not print the token of the image (state: $("${CRI[@]}" inspect -o json "$CTR_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])' 2>/dev/null))"
CSTATE=$("${CRI[@]}" inspect -o json "$CTR_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])')
[ "$CSTATE" = "CONTAINER_RUNNING" ] || fail "container state is $CSTATE"
echo "  -> OK ($GOT)"

echo "[oracle] check 7: nothing was refused by the egress proxy, and nothing went to registry.k8s.io, while the pod started either..."
sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" > "$ODIR/proxy_all.log"
if grep -q DENY "$ODIR/proxy_all.log"; then fail "the egress proxy refused a request while the pod started"; fi
if grep -qE "(CONNECT |://)registry\.k8s\.io" "$ODIR/proxy_all.log"; then fail "a request to registry.k8s.io appeared while the pod started"; fi
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
