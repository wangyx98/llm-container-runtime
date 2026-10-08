#!/bin/bash
set -e

CASE_ID="bench78018481"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
OLD_DIR="$RUN_BASE/registry-old"
NEW_DIR="$RUN_BASE/registry-new"
REPO="google_containers/pause"
OLD_REF="127.0.0.1:18081/$REPO:3.6"
NEW_REF="127.0.0.1:18082/$REPO:3.6"
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
jget() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATE_DIR/$1.truth" "$2"; }
sandbox_image() {   # $1 = pod sandbox id -> the image the sandbox runs, as containerd reports it for that sandbox
    "${CRI[@]}" inspectp -o json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["image"])'
}
image_digests() {   # $1 = image ref -> its repo digests, one per line (nothing when the image is not in containerd)
    local out
    out=$("${CRI[@]}" inspecti -o json "$1" 2>/dev/null) || return 0
    printf '%s' "$out" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["status"].get("repoDigests", [])))'
}

echo "[oracle] check 1: the fixtures are untouched: the two registries are the processes of setup and hold what setup"
echo "[oracle]          pushed, containerd's start script is unchanged, containerd runs on its own socket..."
alive_same registry-old || fail "the OLD registry is not the process of setup (it was restarted or replaced)"
alive_same registry-new || fail "the NEW registry is not the process of setup (it was restarted or replaced)"
cmp -s "$STATE_DIR/registry-old.state0" "$OLD_DIR/state.json" || fail "the content of the OLD registry changed"
cmp -s "$STATE_DIR/registry-new.state0" "$NEW_DIR/state.json" || fail "the content of the NEW registry changed"
[ "$(sudo sha256sum "$CTL_DIR/containerdctl" | awk '{print $1}')" = "$(sudo cat "$STATE_DIR/containerdctl.sha")" ] \
    || fail "$CTL_DIR/containerdctl was changed"
# a restart by the solution returns before the new containerd answers: wait for it
for _ in $(seq 1 60); do
    $CTR version >/dev/null 2>&1 && "${CRI[@]}" version >/dev/null 2>&1 && break
    sleep 1
done
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK (it must be running, on its own socket)"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[oracle] resetting what the solution may have started or pulled, so that the NEW sandbox below is judged on its"
echo "[oracle] own: every pod and container is removed (the existing sandbox, which keeps its OLD pause, proves nothing),"
echo "[oracle] and the NEW pause image is removed from containerd with its blobs, so it has to be downloaded..."
for c in $("${CRI[@]}" ps -a -q 2>/dev/null); do
    "${CRI[@]}" stop -t 1 "$c" >/dev/null 2>&1 || true
    "${CRI[@]}" rm -f "$c" >/dev/null 2>&1 || true
done
for p in $("${CRI[@]}" pods -q 2>/dev/null); do
    "${CRI[@]}" stopp "$p" >/dev/null 2>&1 || true
    "${CRI[@]}" rmp -f "$p" >/dev/null 2>&1 || true
done
for ns in k8s.io default; do
    for r in $($CTR -n "$ns" images ls -q 2>/dev/null | grep -F "127.0.0.1:18082/" || true); do
        $CTR -n "$ns" images rm "$r" >/dev/null 2>&1 || true
    done
done
for k in manifest config layer; do
    $CTR -n k8s.io content rm "$(jget new $k)" >/dev/null 2>&1 || true
done
# the unpacked snapshots too: with a snapshot of the layer left over from an earlier pull (the solution may have
# started a pod to look at the result), containerd needs no blob and downloads nothing
for _ in 1 2 3 4 5; do
    KEYS=$($CTR -n k8s.io snapshots ls 2>/dev/null | awk 'NR>1 {print $1}')
    [ -n "$KEYS" ] || break
    for k in $KEYS; do $CTR -n k8s.io snapshots rm "$k" >/dev/null 2>&1 || true; done
done
if [ -n "$($CTR -n k8s.io snapshots ls 2>/dev/null | awk 'NR>1 {print $1}')" ]; then fail "could not remove the snapshots of containerd before the check"; fi
if image_digests "$NEW_REF" | grep -q .; then fail "could not remove the NEW pause image from containerd before the check"; fi
if $CTR -n k8s.io content ls -q | grep -qF "$(jget new layer)"; then fail "could not remove the NEW pause layer from containerd before the check"; fi

mkdir -p "$ODIR"
NB=$(sudo wc -l < "$NEW_DIR/requests.log")
NA=$(sudo wc -l < "$OLD_DIR/requests.log")

echo "[oracle] check 2: a NEW sandbox (a new pod, host network) must start..."
cat > "$ODIR/pod.json" <<CONF
{
  "metadata": {"name": "bench78018481-new", "namespace": "default", "attempt": 1, "uid": "bench78018481-new-uid"},
  "log_directory": "$ODIR/logs",
  "linux": {"security_context": {"namespace_options": {"network": 2}}}
}
CONF
POD=$("${CRI[@]}" runp "$ODIR/pod.json" 2> "$ODIR/runp_err.txt") || { tail -2 "$ODIR/runp_err.txt" | cut -c1-300; fail "crictl runp failed"; }
STATE=$("${CRI[@]}" pods --id "$POD" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["state"])')
[ "$STATE" = "SANDBOX_READY" ] || fail "the new sandbox is $STATE"
echo "  -> OK (sandbox $POD is SANDBOX_READY)"

echo "[oracle] check 3: containerd reports that this sandbox runs the NEW pause image (asked of containerd at run time,"
echo "[oracle]          not read from a file)..."
GOT=$(sandbox_image "$POD")
echo "     sandbox image: $GOT"
[ "$GOT" = "$NEW_REF" ] || fail "the new sandbox runs $GOT, not $NEW_REF"
CTRIMG=$($CTR -n k8s.io containers info "$POD" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Image",""))')
[ "$CTRIMG" = "$NEW_REF" ] || fail "the sandbox container of containerd runs '$CTRIMG', not $NEW_REF"
echo "  -> OK"

echo "[oracle] check 4: the sandbox image in containerd is the image of the NEW registry (same manifest digest), and not the old one..."
NEWD=$(jget new manifest); OLDD=$(jget old manifest)
DIG=$(image_digests "$NEW_REF")
echo "$DIG" | sed 's/^/     /'
echo "$DIG" | grep -qF "@$NEWD" || fail "the pause image of the new sandbox has not the digest of the NEW registry ($NEWD)"
if echo "$DIG" | grep -qF "@$OLDD"; then fail "the pause image of the new sandbox is the OLD image"; fi
echo "  -> OK ($NEWD)"

echo "[oracle] check 5: the NEW registry's request log shows containerd fetching that manifest and its blobs, and the OLD"
echo "[oracle]          registry saw no request of containerd for this sandbox..."
sudo tail -n +"$((NB + 1))" "$NEW_DIR/requests.log" > "$ODIR/new_registry.log"
sudo tail -n +"$((NA + 1))" "$OLD_DIR/requests.log" > "$ODIR/old_registry.log"
sed 's/^/     /' "$ODIR/new_registry.log" | cut -c1-200
python3 - "$ODIR/new_registry.log" "$REPO" "$NEWD" "$(jget new layer)" "$(jget new config)" <<'PY' || fail "the NEW registry log lacks the manifest or blob requests of containerd"
import re, sys
log, repo, mdig, layer, config = sys.argv[1:6]
lines = [l.rstrip("\n") for l in open(log)]
def seen(method_re, path):
    return any(re.match(r"^(%s) %s(\?\S*)? 200 ua=containerd/" % (method_re, re.escape(path)), l) for l in lines)
ok = seen("GET|HEAD", "/v2/%s/manifests/3.6" % repo) or seen("GET", "/v2/%s/manifests/%s" % (repo, mdig))
ok = ok and seen("GET", "/v2/%s/blobs/%s" % (repo, layer)) and seen("GET", "/v2/%s/blobs/%s" % (repo, config))
sys.exit(0 if ok else 1)
PY
if grep -q "ua=containerd/" "$ODIR/old_registry.log"; then
    sed 's/^/     /' "$ODIR/old_registry.log" | head -3
    fail "containerd still asked the OLD registry while the new sandbox started"
fi
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
