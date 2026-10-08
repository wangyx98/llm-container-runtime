#!/bin/bash
set -e

CASE_ID="bench73415766"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
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
ODIR="$WORK_DIR/oracle"

CTR="sudo ctr -a $CTD_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" --timeout 90s)
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])' "$STATE_DIR/$1.truth" "$2"; }

echo "[oracle] check 1: the fixtures are untouched: the two registries and the egress proxy are the processes of setup, the"
echo "[oracle]          registries hold what setup pushed, containerd's start script is unchanged..."
alive_same registry-a || fail "the registry of $HOST_A is not the process of setup (it was restarted or replaced)"
alive_same registry-b || fail "the registry of $HOST_B is not the process of setup (it was restarted or replaced)"
alive_same hubgate || fail "the egress proxy is not the process of setup (it was restarted or replaced)"
cmp -s "$STATE_DIR/registry-a.state0" "$REG_A_DIR/state.json" || fail "the content of the registry of $HOST_A changed"
cmp -s "$STATE_DIR/registry-b.state0" "$REG_B_DIR/state.json" || fail "the content of the registry of $HOST_B changed"
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

echo "[oracle] resetting what a solution may have pulled or started: containers, the images of $REPO in every name, their blobs"
echo "[oracle] (with a forced garbage collection) and snapshots, so the pulls below really go through the registry configuration..."
for ns in k8s.io default; do
    for t in $($CTR -n "$ns" tasks ls -q 2>/dev/null); do
        $CTR -n "$ns" tasks kill -s SIGKILL "$t" >/dev/null 2>&1 || true
        $CTR -n "$ns" tasks delete --force "$t" >/dev/null 2>&1 || true
    done
    for c in $($CTR -n "$ns" containers ls -q 2>/dev/null); do
        $CTR -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
    done
    for r in $($CTR -n "$ns" images ls -q 2>/dev/null | grep "/$REPO:" || true); do
        $CTR -n "$ns" images rm "$r" >/dev/null 2>&1 || true
    done
    for w in a b; do
        for k in manifest config layer; do
            $CTR -n "$ns" content rm "$(jget $w $k)" >/dev/null 2>&1 || true
        done
    done
    $CTR -n "$ns" leases create bench-gc >/dev/null 2>&1 || true
    $CTR -n "$ns" leases delete --sync bench-gc >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        KEYS=$($CTR -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1 {print $1}')
        [ -n "$KEYS" ] || break
        for k in $KEYS; do $CTR -n "$ns" snapshots rm "$k" >/dev/null 2>&1 || true; done
    done
    if [ -n "$($CTR -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1 {print $1}')" ]; then fail "could not remove the snapshots of namespace $ns before the pulls"; fi
    if $CTR -n "$ns" images ls -q 2>/dev/null | grep -q "/$REPO:"; then fail "could not remove the images from namespace $ns before the pulls"; fi
done
BLOBS="$LIB_BASE/containerd/io.containerd.content.v1.content/blobs/sha256"
for w in a b; do
    for k in manifest config layer; do
        H=$(jget $w $k); H=${H#sha256:}
        for _ in $(seq 1 30); do sudo test -e "$BLOBS/$H" || break; sleep 1; done
        if sudo test -e "$BLOBS/$H"; then fail "the $k blob of the image of registry $w is still on the disk of containerd: a pull would reuse it"; fi
    done
done

mkdir -p "$ODIR"
LA0=$(sudo wc -l < "$REG_A_DIR/requests.log")
LB0=$(sudo wc -l < "$REG_B_DIR/requests.log")
HUB0=$(sudo wc -l < "$HUB_DIR/requests.log")

echo "[oracle] check 2: 'crictl pull $HOST_A/$REPO:$TAG' (the registry named in the question) must succeed..."
if ! "${CRI[@]}" pull "$HOST_A/$REPO:$TAG" > "$ODIR/pull_a.out" 2> "$ODIR/pull_a.err"; then
    tail -2 "$ODIR/pull_a.err" | cut -c1-320
    fail "the pull through the CRI failed"
fi
echo "  -> OK"

echo "[oracle] check 3: the image that arrived is the one the registry of $HOST_A holds (same manifest digest)..."
"${CRI[@]}" inspecti -o json "$HOST_A/$REPO:$TAG" > "$ODIR/image_a.json" 2>/dev/null || fail "crictl inspecti failed"
python3 - "$ODIR/image_a.json" "$(jget a manifest)" <<'PY' || fail "the pulled image has not the digest of the image of the registry of $HOST_A"
import json, sys
st = json.load(open(sys.argv[1])).get("status", {})
sys.exit(0 if any(d.endswith("@" + sys.argv[2]) for d in st.get("repoDigests", [])) else 1)
PY
echo "  -> OK ($(jget a manifest))"

echo "[oracle] check 4: the registry's log shows containerd fetching the manifest and the blobs over TLS, every request, and the"
echo "[oracle]          egress proxy only tunnelled (no plain-HTTP request, nothing refused)..."
sudo tail -n +"$((LA0 + 1))" "$REG_A_DIR/requests.log" > "$ODIR/reg_a_new.log"
sed 's/^/     /' "$ODIR/reg_a_new.log" | cut -c1-150
python3 - "$ODIR/reg_a_new.log" "$REPO" "$TAG" "$(jget a manifest)" "$(jget a layer)" "$(jget a config)" <<'PY' || fail "the registry log lacks containerd's TLS requests for the manifest or the blobs, or has a request that is not TLS"
import re, sys
log, repo, tag, mdig, layer, config = sys.argv[1:7]
lines = [l.rstrip("\n") for l in open(log)]
def seen(method_re, path):
    return any(re.match(r"^(%s) %s 200 ua=containerd/\S* tls=TLSv1\.[23]" % (method_re, re.escape(path)), l) for l in lines)
ok = seen("GET|HEAD", "/v2/%s/manifests/%s" % (repo, tag)) and seen("GET", "/v2/%s/manifests/%s" % (repo, mdig))
ok = ok and seen("GET", "/v2/%s/blobs/%s" % (repo, layer)) and seen("GET", "/v2/%s/blobs/%s" % (repo, config))
ok = ok and all(" tls=TLSv1." in l for l in lines)
sys.exit(0 if ok else 1)
PY
sudo tail -n +"$((HUB0 + 1))" "$HUB_DIR/requests.log" > "$ODIR/proxy_new.log"
grep -q "^CONNECT $HOST_A ALLOW" "$ODIR/proxy_new.log" || fail "the egress proxy did not tunnel the connection to $HOST_A"
if grep -q DENY "$ODIR/proxy_new.log"; then grep DENY "$ODIR/proxy_new.log" | head -2 | sed 's/^/     /'; fail "containerd made a request that the egress proxy refused"; fi
echo "  -> OK"

echo "[oracle] check 5: the other private registry ($HOST_B, a certificate of another unknown CA) must STILL be rejected on its"
echo "[oracle]          certificate: the verification was skipped for $HOST_A only..."
if "${CRI[@]}" pull "$HOST_B/$REPO:$TAG" > "$ODIR/pull_b.out" 2> "$ODIR/pull_b.err"; then
    fail "the pull of $HOST_B/$REPO:$TAG succeeded: the certificate check was skipped for it too"
fi
grep -q "x509" "$ODIR/pull_b.err" || fail "the pull of $HOST_B failed, but not on its certificate: $(tail -1 "$ODIR/pull_b.err" | cut -c1-240)"
[ "$(sudo wc -l < "$REG_B_DIR/requests.log")" = "$LB0" ] || fail "the registry of $HOST_B received requests: it was reached without a verified certificate"
if $CTR -n k8s.io images ls -q 2>/dev/null | grep -q "$HOST_B"; then fail "an image of $HOST_B is in containerd"; fi
echo "  -> OK ($(grep -o 'x509: [a-z ]*' "$ODIR/pull_b.err" | head -1))"

echo "[oracle] check 6: the image of $HOST_A runs (ctr, namespace k8s.io, the one of the CRI) and prints its marker with an argument only"
echo "[oracle]          this check knows..."
TOKEN=$(sudo cat "$STATE_DIR/token.a")
ARG="m-$(date +%s%N)-$RANDOM"
if ! OUT=$(timeout 90 $CTR -n k8s.io run --rm "$HOST_A/$REPO:$TAG" bench73415766-oracle /app "$ARG" </dev/null 2> "$ODIR/run.err"); then
    grep -v DEPRECATION "$ODIR/run.err" | tail -2 | cut -c1-300
    fail "ctr run failed"
fi
echo "     output: $OUT"
[ "$OUT" = "bench73415766-ok token=$TOKEN args=$ARG" ] || fail "the output is not the marker of the image of $HOST_A with the argument given"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
