#!/bin/bash
set -e

CASE_ID="bench78132064"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/nexus"
HUB_DIR="$RUN_BASE/hubgate"
REPO="library/benchapp"
IMAGE_REF="docker.io/library/benchapp:1.0"
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

echo "[oracle] NOTE: the 'Nexus proxy' of this case is a FIXTURE (a registry API server holding the cached image);"
echo "[oracle] this is not an acceptance test of the Sonatype Nexus product."

echo "[oracle] check 1: the fixtures are untouched: the proxy and the egress gateway are the processes of setup, the"
echo "[oracle]          proxy holds what setup pushed, containerd's start script is unchanged..."
alive_same registry || fail "the proxy fixture is not the process of setup (it was restarted or replaced)"
alive_same hubgate || fail "the egress gateway is not the process of setup (it was restarted or replaced)"
cmp -s "$STATE_DIR/registry.state0" "$REG_DIR/state.json" || fail "the content of the proxy fixture changed"
[ "$(sudo sha256sum "$CTL_DIR/containerdctl" | awk '{print $1}')" = "$(sudo cat "$STATE_DIR/containerdctl.sha")" ] \
    || fail "$CTL_DIR/containerdctl was changed (containerd must keep going through the egress gateway)"
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
    for r in $($CTR -n "$ns" images ls -q 2>/dev/null | grep benchapp || true); do
        $CTR -n "$ns" images rm "$r" >/dev/null 2>&1 || true
    done
done
for k in manifest config layer; do
    $CTR -n k8s.io content rm "$(jget $k)" >/dev/null 2>&1 || true
done
# the unpacked snapshots too: with a snapshot of the layer left over from an earlier pull (a solution that pulled
# the image or started a pod to look at the result), containerd needs no blob and downloads nothing
for _ in 1 2 3 4 5; do
    KEYS=$($CTR -n k8s.io snapshots ls 2>/dev/null | awk 'NR>1 {print $1}')
    [ -n "$KEYS" ] || break
    for k in $KEYS; do $CTR -n k8s.io snapshots rm "$k" >/dev/null 2>&1 || true; done
done
if [ -n "$($CTR -n k8s.io snapshots ls 2>/dev/null | awk 'NR>1 {print $1}')" ]; then fail "could not remove the snapshots of containerd before the pull"; fi
if $CTR -n k8s.io images ls -q | grep -q benchapp; then fail "could not remove the image from containerd before the pull"; fi
if $CTR -n k8s.io content ls -q | grep -qF "$(jget layer)"; then fail "could not remove the layer blob from containerd before the pull"; fi

mkdir -p "$ODIR/logs"
H0=$(sudo wc -l < "$HUB_DIR/requests.log")
P0=$(sudo wc -l < "$REG_DIR/requests.log")

echo "[oracle] check 2: 'crictl pull $IMAGE_REF' (the name the cluster uses, unchanged) must now succeed..."
if ! "${CRI[@]}" pull "$IMAGE_REF" > "$ODIR/pull_out.txt" 2> "$ODIR/pull_err.txt"; then
    tail -2 "$ODIR/pull_err.txt" | cut -c1-300
    fail "the pull through the CRI failed"
fi
echo "  -> OK"

echo "[oracle] check 3: the image that arrived is the one the proxy caches (same manifest digest)..."
D=$(sudo cat "$STATE_DIR/manifest.digest")
"${CRI[@]}" inspecti -o json "$IMAGE_REF" > "$ODIR/image.json" 2>/dev/null || fail "crictl inspecti failed"
python3 - "$ODIR/image.json" "$D" <<'PY' || fail "the pulled image has not the digest of the image cached in the proxy"
import json, sys
st = json.load(open(sys.argv[1])).get("status", {})
digests = st.get("repoDigests", [])
sys.exit(0 if any(d.endswith("@" + sys.argv[2]) for d in digests) else 1)
PY
echo "  -> OK ($D)"

echo "[oracle] check 4: the proxy's request log shows containerd fetching the manifest and the blobs..."
sudo tail -n +"$((P0 + 1))" "$REG_DIR/requests.log" > "$ODIR/proxy_new.log"
sed 's/^/     /' "$ODIR/proxy_new.log" | cut -c1-200
python3 - "$ODIR/proxy_new.log" "$REPO" "$(jget layer)" "$(jget config)" <<'PY' || fail "the proxy log lacks the manifest or blob requests of containerd"
import re, sys
log, repo, layer, config = sys.argv[1:5]
lines = [l.rstrip("\n") for l in open(log)]
def seen(method_re, path):
    return any(re.match(r"^(%s) %s(\?\S*)? 200 ua=containerd/" % (method_re, re.escape(path)), l) for l in lines)
ok = seen("GET|HEAD", "/v2/%s/manifests/1.0" % repo)
ok = ok and seen("GET", "/v2/%s/blobs/%s" % (repo, layer))
ok = ok and seen("GET", "/v2/%s/blobs/%s" % (repo, config))
sys.exit(0 if ok else 1)
PY
echo "  -> OK"

echo "[oracle] check 5: Docker Hub saw NOTHING during the pull (the egress gateway log did not grow)..."
H1=$(sudo wc -l < "$HUB_DIR/requests.log")
if [ "$H1" != "$H0" ]; then
    sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" | head -3 | sed 's/^/     /'
    fail "containerd contacted Docker Hub $((H1 - H0)) time(s) during the pull"
fi
echo "  -> OK (0 requests to Docker Hub)"

echo "[oracle] check 6: a pod runs that image through the CRI and prints the per-run token baked into it..."
TOKEN=$(sudo cat "$STATE_DIR/token")
cat > "$ODIR/pod.json" <<CONF
{
  "metadata": {"name": "bench78132064-pod", "namespace": "default", "attempt": 1, "uid": "bench78132064-uid"},
  "log_directory": "$ODIR/logs",
  "linux": {"security_context": {"namespace_options": {"network": 2}}}
}
CONF
cat > "$ODIR/container.json" <<CONF
{
  "metadata": {"name": "bench78132064-ctr"},
  "image": {"image": "$IMAGE_REF"},
  "log_path": "ctr.log"
}
CONF
POD_ID=$("${CRI[@]}" runp "$ODIR/pod.json" 2> "$ODIR/runp_err.txt") || { tail -2 "$ODIR/runp_err.txt" | cut -c1-300; fail "crictl runp failed"; }
CTR_ID=$("${CRI[@]}" create "$POD_ID" "$ODIR/container.json" "$ODIR/pod.json" 2> "$ODIR/create_err.txt") || { tail -2 "$ODIR/create_err.txt" | cut -c1-300; fail "crictl create failed"; }
"${CRI[@]}" start "$CTR_ID" >/dev/null 2> "$ODIR/start_err.txt" || { tail -2 "$ODIR/start_err.txt" | cut -c1-300; fail "crictl start failed"; }
GOT=""
for _ in $(seq 1 30); do
    GOT=$("${CRI[@]}" logs "$CTR_ID" 2>/dev/null | grep -F "bench78132064-benchapp-ok token=$TOKEN" | head -1 || true)
    [ -n "$GOT" ] && break
    sleep 1
done
[ -n "$GOT" ] || fail "the container did not print the token of the image (state: $("${CRI[@]}" inspect -o json "$CTR_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])' 2>/dev/null))"
CSTATE=$("${CRI[@]}" inspect -o json "$CTR_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])')
[ "$CSTATE" = "CONTAINER_RUNNING" ] || fail "container state is $CSTATE"
echo "  -> OK ($GOT)"

echo "[oracle] check 7: still no request to Docker Hub after the pod started..."
[ "$(sudo wc -l < "$HUB_DIR/requests.log")" = "$H0" ] || fail "Docker Hub was contacted while the pod started"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED (fixture proxy, not a Nexus product test)"
