#!/bin/bash
set -e

CASE_ID="bench62675268"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CRIO_SOCK="$RUN_BASE/crio.sock"
REG_DIR="$RUN_BASE/registry"
HUB_DIR="$RUN_BASE/proxy"
REG_HOST="registry.bench62675268.test"
REG_PORT=5000
REPO="kubernetes/pause"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ODIR="$WORK_DIR/oracle"

CRI=(sudo crictl --runtime-endpoint "unix://$CRIO_SOCK" --image-endpoint "unix://$CRIO_SOCK" --timeout 60s)
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])' "$STATE_DIR/image.truth" "$1"; }

echo "[oracle] check 1: the fixtures are untouched: the registry and the egress proxy are the processes of setup, the"
echo "[oracle]          registry holds what setup pushed, CRI-O's start script is unchanged..."
alive_same registry || fail "the registry is not the process of setup (it was restarted or replaced)"
alive_same hubgate || fail "the egress proxy is not the process of setup (it was restarted or replaced)"
sudo cmp -s "$STATE_DIR/registry.state0" "$REG_DIR/state.json" || fail "the content of the registry changed"
[ "$(sudo sha256sum "$CTL_DIR/crioctl" | awk '{print $1}')" = "$(sudo cat "$STATE_DIR/crioctl.sha")" ] \
    || fail "$CTL_DIR/crioctl was changed (CRI-O must keep going through the egress proxy)"
# a restart by the solution returns before the new CRI-O answers: wait for it
for _ in $(seq 1 60); do
    "${CRI[@]}" version >/dev/null 2>&1 && break
    sleep 1
done
"${CRI[@]}" version >/dev/null 2>&1 || fail "CRI-O does not answer on $CRIO_SOCK (it must be running, on its own socket)"
echo "  -> OK"

echo "[oracle] resetting what a solution may have started or pulled, so the sandbox below really pulls its image:"
echo "[oracle] pods, containers and every image of CRI-O..."
for _ in 1 2 3; do
    "${CRI[@]}" rmp -a -f >/dev/null 2>&1 || true
    for p in $("${CRI[@]}" pods -q 2>/dev/null); do "${CRI[@]}" rmp -f "$p" >/dev/null 2>&1 || true; done
    "${CRI[@]}" rmi -a >/dev/null 2>&1 || true
    [ -z "$("${CRI[@]}" pods -q 2>/dev/null)$("${CRI[@]}" images -q 2>/dev/null)" ] && break
    sleep 1
done
[ -z "$("${CRI[@]}" pods -q 2>/dev/null)" ] || fail "could not remove the pods before the check"
[ -z "$("${CRI[@]}" images -q 2>/dev/null)" ] || fail "could not remove the images before the check"

mkdir -p "$ODIR/logs"
H0=$(sudo wc -l < "$HUB_DIR/requests.log")
P0=$(sudo wc -l < "$REG_DIR/requests.log")

echo "[oracle] check 2: a new pod sandbox (host network, own PID namespace) must now start and be Ready..."
cat > "$ODIR/pod.json" <<CONF
{
  "metadata": {"name": "bench62675268-pod", "namespace": "default", "attempt": 1, "uid": "bench62675268-uid"},
  "log_directory": "$ODIR/logs",
  "linux": {"security_context": {"namespace_options": {"network": 2, "pid": 0}}}
}
CONF
POD_ID=$("${CRI[@]}" runp "$ODIR/pod.json" 2> "$ODIR/runp_err.txt") || { tail -2 "$ODIR/runp_err.txt" | cut -c1-300; fail "crictl runp failed"; }
"${CRI[@]}" inspectp -o json "$POD_ID" > "$ODIR/pod_inspect.json" 2>/dev/null || fail "crictl inspectp failed"
STATE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"]["state"])' "$ODIR/pod_inspect.json")
[ "$STATE" = "SANDBOX_READY" ] || fail "the sandbox is $STATE"
echo "  -> OK ($STATE)"

echo "[oracle] check 3: the image the sandbox runs is the one of the private registry (same manifest digest), and the process"
echo "[oracle]          of the sandbox is the program inside that image..."
IMG=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["info"]["image"])' "$ODIR/pod_inspect.json")
PID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["info"]["pid"])' "$ODIR/pod_inspect.json")
D=$(sudo cat "$STATE_DIR/manifest.digest")
"${CRI[@]}" inspecti -o json "$IMG" > "$ODIR/image.json" 2>/dev/null || fail "crictl inspecti $IMG failed"
python3 - "$ODIR/image.json" "$D" <<'PY' || fail "the sandbox image $IMG has not the digest of the pause image the registry holds"
import json, sys
st = json.load(open(sys.argv[1])).get("status", {})
sys.exit(0 if any(d.endswith("@" + sys.argv[2]) for d in st.get("repoDigests", [])) else 1)
PY
[ "$PID" -gt 1 ] 2>/dev/null || fail "the sandbox has no process (pid $PID)"
[ "$(sudo sha256sum "/proc/$PID/exe" | awk '{print $1}')" = "$(sudo cat "$STATE_DIR/pause.sha256")" ] \
    || fail "the process of the sandbox (pid $PID) is not the program of the pause image of the registry"
echo "  -> OK ($IMG, $D)"

echo "[oracle] check 4: the registry's request log shows CRI-O fetching the manifest and the blobs..."
sudo tail -n +"$((P0 + 1))" "$REG_DIR/requests.log" > "$ODIR/registry_new.log"
sed 's/^/     /' "$ODIR/registry_new.log" | cut -c1-170
python3 - "$ODIR/registry_new.log" "$REPO" "$(jget layer)" "$(jget config)" "$D" <<'PY' || fail "the registry log lacks the manifest or blob requests of CRI-O"
import re, sys
log, repo, layer, config, digest = sys.argv[1:6]
lines = [l.rstrip("\n") for l in open(log)]
def seen(method_re, path_re):
    return any(re.match(r"^(%s) %s(\?\S*)? 200 ua=cri-o/" % (method_re, path_re), l) for l in lines)
ok = seen("GET|HEAD", "/v2/%s/manifests/(%s|%s)" % (re.escape(repo), "3.2", re.escape(digest)))
ok = ok and seen("GET", "/v2/%s/blobs/%s" % (re.escape(repo), re.escape(layer)))
ok = ok and seen("GET", "/v2/%s/blobs/%s" % (re.escape(repo), re.escape(config)))
sys.exit(0 if ok else 1)
PY
echo "  -> OK"

echo "[oracle] check 5: the egress proxy refused nothing: CRI-O did not try to reach k8s.gcr.io (or anything else)..."
sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" > "$ODIR/proxy_new.log"
sed 's/^/     /' "$ODIR/proxy_new.log" | head -5 | cut -c1-150
if grep -q DENY "$ODIR/proxy_new.log"; then grep DENY "$ODIR/proxy_new.log" | head -2 | sed 's/^/     /'; fail "CRI-O made a request that the egress proxy refused"; fi
grep -q "^GET http://$REG_HOST:$REG_PORT/v2/$REPO/manifests/.* ALLOW" "$ODIR/proxy_new.log" \
    || fail "the egress proxy did not forward the request for the manifest to the private registry"
echo "  -> OK"

echo "[oracle] check 6: a second sandbox starts as well (the image is now in CRI-O's store, the setting holds)..."
sed -i 's/bench62675268-pod/bench62675268-pod2/; s/bench62675268-uid/bench62675268-uid2/' "$ODIR/pod.json"
POD2=$("${CRI[@]}" runp "$ODIR/pod.json" 2> "$ODIR/runp2_err.txt") || { tail -2 "$ODIR/runp2_err.txt" | cut -c1-300; fail "the second crictl runp failed"; }
[ "$("${CRI[@]}" pods --id "$POD2" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["state"])')" = "SANDBOX_READY" ] \
    || fail "the second sandbox is not Ready"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
