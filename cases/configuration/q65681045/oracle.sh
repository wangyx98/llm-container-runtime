#!/bin/bash
set -e

CASE_ID="bench65681045"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/registry"
HUB_DIR="$RUN_BASE/proxy"
REG_HOST="v048011.dom600.test"
REG_PORT=5000
REPO="myjenkins"
TAG="latest"
IMAGE_REF="$REG_HOST:$REG_PORT/$REPO:$TAG"
HOSTS_DIR="/etc/containerd/certs.d"
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

echo "[oracle] check 1: the fixtures are untouched: the registry and the egress proxy are the processes of setup, the"
echo "[oracle]          registry holds what setup pushed, containerd's start script is unchanged..."
alive_same registry || fail "the registry is not the process of setup (it was restarted or replaced)"
alive_same hubgate || fail "the egress proxy is not the process of setup (it was restarted or replaced)"
cmp -s "$STATE_DIR/registry.state0" "$REG_DIR/state.json" || fail "the content of the registry changed"
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
echo "[oracle] hosts directory: containers and tasks, the image in every name and namespace, and its blobs in the content store..."
for ns in default k8s.io; do
    for t in $($CTR -n "$ns" tasks ls -q 2>/dev/null); do $CTR -n "$ns" tasks kill -s SIGKILL "$t" >/dev/null 2>&1 || true; done
    sleep 1
    for t in $($CTR -n "$ns" tasks ls -q 2>/dev/null); do $CTR -n "$ns" tasks delete -f "$t" >/dev/null 2>&1 || true; done
    for c in $($CTR -n "$ns" containers ls -q 2>/dev/null); do $CTR -n "$ns" containers delete "$c" >/dev/null 2>&1 || true; done
    for r in $($CTR -n "$ns" images ls -q 2>/dev/null | grep "/myjenkins" || true); do
        $CTR -n "$ns" images rm "$r" >/dev/null 2>&1 || true
    done
    for k in manifest config layer; do
        $CTR -n "$ns" content rm "$(jget $k)" >/dev/null 2>&1 || true
    done
    # content that no image refers to any more is removed by containerd's garbage collector, not at once: force a run
    $CTR -n "$ns" leases create bench-gc >/dev/null 2>&1 || true
    $CTR -n "$ns" leases delete --sync bench-gc >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        KEYS=$($CTR -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1 {print $1}')
        [ -n "$KEYS" ] || break
        for k in $KEYS; do $CTR -n "$ns" snapshots rm "$k" >/dev/null 2>&1 || true; done
    done
    if [ -n "$($CTR -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1 {print $1}')" ]; then fail "could not remove the snapshots of namespace $ns before the pull"; fi
    if $CTR -n "$ns" images ls -q 2>/dev/null | grep -q "/myjenkins"; then fail "could not remove the image from namespace $ns before the pull"; fi
done
BLOBS="$LIB_BASE/containerd/io.containerd.content.v1.content/blobs/sha256"
for k in manifest config layer; do
    H=$(jget $k); H=${H#sha256:}
    for _ in $(seq 1 30); do sudo test -e "$BLOBS/$H" || break; sleep 1; done
    if sudo test -e "$BLOBS/$H"; then fail "the $k blob is still on the disk of containerd: a pull would reuse it"; fi
done

mkdir -p "$ODIR"
H0=$(sudo wc -l < "$HUB_DIR/requests.log")
P0=$(sudo wc -l < "$REG_DIR/requests.log")

echo "[oracle] check 2: 'ctr images pull --hosts-dir $HOSTS_DIR $IMAGE_REF' must now succeed..."
if ! $CTR images pull --hosts-dir "$HOSTS_DIR" "$IMAGE_REF" > "$ODIR/pull_out.txt" 2> "$ODIR/pull_err.txt" </dev/null; then
    grep -v DEPRECATION "$ODIR/pull_err.txt" | tail -2 | cut -c1-300
    fail "the ctr pull failed"
fi
echo "  -> OK"

echo "[oracle] check 3: the image is in the default namespace under that name, with the manifest digest the registry holds..."
D=$(sudo cat "$STATE_DIR/manifest.digest")
GOT=$($CTR images ls 2>/dev/null | awk -v r="$IMAGE_REF" '$1 == r {print $3}')
[ -n "$GOT" ] || fail "ctr images ls (default namespace) does not list $IMAGE_REF"
[ "$GOT" = "$D" ] || fail "the digest of $IMAGE_REF is $GOT, the registry holds $D"
echo "  -> OK ($D)"

echo "[oracle] check 4: the registry's request log shows containerd fetching the manifest and the blobs..."
sudo tail -n +"$((P0 + 1))" "$REG_DIR/requests.log" > "$ODIR/registry_new.log"
sed 's/^/     /' "$ODIR/registry_new.log" | cut -c1-200
python3 - "$ODIR/registry_new.log" "$REPO" "$TAG" "$(jget layer)" "$(jget config)" <<'PY' || fail "the registry log lacks the manifest or blob requests of containerd"
import re, sys
log, repo, tag, layer, config = sys.argv[1:6]
lines = [l.rstrip("\n") for l in open(log)]
def seen(method_re, path):
    return any(re.match(r"^(%s) %s(\?\S*)? 200 ua=containerd/" % (method_re, re.escape(path)), l) for l in lines)
ok = seen("GET|HEAD", "/v2/%s/manifests/%s" % (repo, tag))
ok = ok and seen("GET", "/v2/%s/blobs/%s" % (repo, layer))
ok = ok and seen("GET", "/v2/%s/blobs/%s" % (repo, config))
sys.exit(0 if ok else 1)
PY
echo "  -> OK"

echo "[oracle] check 5: the pull went over plain HTTP: the egress proxy forwarded containerd's requests in clear (absolute URLs with"
echo "[oracle]          http://) and refused nothing..."
sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" > "$ODIR/proxy_new.log"
sed 's/^/     /' "$ODIR/proxy_new.log" | head -5 | cut -c1-150
grep -q "^HEAD http://$REG_HOST:$REG_PORT/v2/$REPO/manifests/$TAG ALLOW" "$ODIR/proxy_new.log" || grep -q "^GET http://$REG_HOST:$REG_PORT/v2/$REPO/manifests/" "$ODIR/proxy_new.log" \
    || fail "the egress proxy did not forward a plain-HTTP request for the manifest"
if grep -q DENY "$ODIR/proxy_new.log"; then grep DENY "$ODIR/proxy_new.log" | head -2 | sed 's/^/     /'; fail "containerd made a request that the egress proxy refused"; fi
echo "  -> OK"

echo "[oracle] check 6: ctr runs the image and prints its marker, with an argument only this check knows..."
TOKEN=$(sudo cat "$STATE_DIR/token")
ARG="m-$(date +%s%N)-$RANDOM"
if ! OUT=$(timeout 90 $CTR run --rm "$IMAGE_REF" bench65681045-oracle /app "$ARG" </dev/null 2> "$ODIR/run_err.txt"); then
    grep -v DEPRECATION "$ODIR/run_err.txt" | tail -2 | cut -c1-300
    fail "ctr run failed"
fi
echo "     output: $OUT"
[ "$OUT" = "bench65681045-ok token=$TOKEN args=$ARG" ] || fail "the output is not the marker of the image with the argument given"
sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" | grep -q DENY && fail "the egress proxy refused a request while the container started"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
