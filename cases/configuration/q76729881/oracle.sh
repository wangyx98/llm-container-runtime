#!/bin/bash
set -e

CASE_ID="bench76729881"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/nexus"
HUB_DIR="$RUN_BASE/hubgate"
REPO="benchorg/kubevip"
IMAGE_REF="docker.io/benchorg/kubevip:0.6.1"
HOSTS_DIR="/etc/containerd/certs.d"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ODIR="$WORK_DIR/oracle"

CTR="sudo ctr -a $CTD_SOCK"
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
    $CTR version >/dev/null 2>&1 && break
    sleep 1
done
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK (it must be running, on its own socket)"
echo "  -> OK"

echo "[oracle] resetting what a solution may have pulled or started, so the pull below really goes through the hosts"
echo "[oracle] directory: containers, the image in every name and namespace, its blobs in the content store, its snapshots..."
for ns in default k8s.io; do
    for t in $($CTR -n "$ns" tasks ls -q 2>/dev/null); do
        $CTR -n "$ns" tasks kill -s SIGKILL "$t" >/dev/null 2>&1 || true
        $CTR -n "$ns" tasks delete --force "$t" >/dev/null 2>&1 || true
    done
    for c in $($CTR -n "$ns" containers ls -q 2>/dev/null); do
        $CTR -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
    done
    for r in $($CTR -n "$ns" images ls -q 2>/dev/null | grep kubevip || true); do
        $CTR -n "$ns" images rm "$r" >/dev/null 2>&1 || true
    done
    for k in manifest config layer; do
        $CTR -n "$ns" content rm "$(jget $k)" >/dev/null 2>&1 || true
    done
    # garbage collection runs on its own schedule and deletes the unreferenced blobs from the disk; a blob that is
    # still on the disk is reused by the next pull without a download. Force a collection and wait for it.
    $CTR -n "$ns" leases create bench-gc >/dev/null 2>&1 || true
    $CTR -n "$ns" leases delete --sync bench-gc >/dev/null 2>&1 || true
    # with a snapshot of the layer left over from an earlier pull, containerd needs no blob and downloads nothing
    for _ in 1 2 3 4 5; do
        KEYS=$($CTR -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1 {print $1}')
        [ -n "$KEYS" ] || break
        for k in $KEYS; do $CTR -n "$ns" snapshots rm "$k" >/dev/null 2>&1 || true; done
    done
    if [ -n "$($CTR -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1 {print $1}')" ]; then fail "could not remove the snapshots of namespace $ns before the pull"; fi
    if $CTR -n "$ns" images ls -q 2>/dev/null | grep -q kubevip; then fail "could not remove the image from namespace $ns before the pull"; fi
    if $CTR -n "$ns" content ls -q 2>/dev/null | grep -qF "$(jget layer)"; then fail "could not remove the layer blob from namespace $ns before the pull"; fi
done
BLOBS="$LIB_BASE/containerd/io.containerd.content.v1.content/blobs/sha256"
for k in manifest config layer; do
    H=$(jget $k); H=${H#sha256:}
    for _ in $(seq 1 30); do sudo test -e "$BLOBS/$H" || break; sleep 1; done
    if sudo test -e "$BLOBS/$H"; then fail "the $k blob is still on the disk of containerd (not garbage collected): the pull would reuse it"; fi
done

mkdir -p "$ODIR"
H0=$(sudo wc -l < "$HUB_DIR/requests.log")
P0=$(sudo wc -l < "$REG_DIR/requests.log")

echo "[oracle] check 2: 'ctr images pull --hosts-dir $HOSTS_DIR $IMAGE_REF' (namespace default) must succeed..."
if ! timeout 120 $CTR images pull --hosts-dir "$HOSTS_DIR" "$IMAGE_REF" </dev/null > "$ODIR/pull_out.txt" 2> "$ODIR/pull_err.txt"; then
    grep -v DEPRECATION "$ODIR/pull_err.txt" | tail -2 | cut -c1-300
    fail "the pull with ctr and the hosts directory failed"
fi
echo "  -> OK"

echo "[oracle] check 3: the image in namespace default under the name $IMAGE_REF is the one the proxy caches (same manifest digest)..."
D=$(sudo cat "$STATE_DIR/manifest.digest")
$CTR -n default images ls 2>/dev/null | awk 'NR>1 {print $1, $3}' > "$ODIR/images.txt"
GOT=$(awk -v r="$IMAGE_REF" '$1 == r {print $2}' "$ODIR/images.txt")
[ -n "$GOT" ] || fail "no image named $IMAGE_REF in namespace default of containerd"
[ "$GOT" = "$D" ] || fail "$IMAGE_REF points to $GOT, not to the digest of the image cached in the proxy ($D)"
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
ok = seen("GET|HEAD", "/v2/%s/manifests/0.6.1" % repo)
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

echo "[oracle] check 6: ctr runs the image and prints its marker, with an argument only this check knows..."
TOKEN=$(sudo cat "$STATE_DIR/token")
ARG="m-$(date +%s%N)-$RANDOM"
if ! OUT=$(timeout 90 $CTR run --rm "$IMAGE_REF" bench76729881-oracle /app "$ARG" </dev/null 2> "$ODIR/run_err.txt"); then
    grep -v DEPRECATION "$ODIR/run_err.txt" | tail -2 | cut -c1-300
    fail "ctr run failed"
fi
echo "     output: $OUT"
[ "$OUT" = "bench76729881-ok token=$TOKEN args=$ARG" ] || fail "the output is not the marker of the image with the argument given"
[ "$(sudo wc -l < "$HUB_DIR/requests.log")" = "$H0" ] || fail "Docker Hub was contacted while the container started"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED (fixture proxy, not a Nexus product test)"
