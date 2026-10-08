#!/bin/bash
set -e

CASE_ID="bench72298729"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/registry"
REG_HOST="127.0.0.1"
REG_PORT=5000
REG_USER="ci-puller"
DOCKER_DIR="$LIB_BASE/docker"
REPO="qtech/graphql"
TAG="latest"
IMAGE_REF="$REG_HOST:$REG_PORT/$REPO:$TAG"
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

echo "[oracle] check 1: the fixtures are untouched: the registry is the process of setup, it holds what setup pushed, its"
echo "[oracle]          accounts and docker's config.json are unchanged, containerd's start script is unchanged..."
alive_same registry || fail "the registry is not the process of setup (it was restarted or replaced)"
cmp -s "$STATE_DIR/registry.state0" "$REG_DIR/state.json" || fail "the content of the registry changed"
[ "$(sudo sha256sum "$REG_DIR/users.json" "$DOCKER_DIR/config.json" | awk '{print $1}')" = "$(sudo cat "$STATE_DIR/secrets.sha")" ] \
    || fail "the accounts of the registry or docker's config.json were changed"
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

REGPASS=$(sudo cat "$STATE_DIR/regpass")
registry_still_private() {   # direct requests to the registry: it must still ask for credentials, and check them
    local url="http://127.0.0.1:$REG_PORT/v2/$REPO/manifests/$TAG" code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$REG_PORT/v2/")
    [ "$code" = "401" ] || { echo "     no credentials: HTTP $code (401 expected)"; return 1; }
    curl -sI --max-time 5 "http://127.0.0.1:$REG_PORT/v2/" | tr -d '\r' | grep -qi '^www-authenticate: *basic' \
        || { echo "     no WWW-Authenticate: Basic challenge"; return 1; }
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -u "$REG_USER:wrong-$REGPASS" "$url")
    [ "$code" = "401" ] || { echo "     wrong password: HTTP $code (401 expected)"; return 1; }
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -u "$REG_USER:$REGPASS" -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "$url")
    [ "$code" = "200" ] || { echo "     right password: HTTP $code (200 expected)"; return 1; }
}
echo "[oracle] check 2: the registry still requires authentication: no credentials -> 401 with a Basic challenge, a wrong"
echo "[oracle]          password -> 401, the right account -> 200 (the fix may not make the registry anonymous)..."
registry_still_private || fail "the registry does not behave as a private registry any more"
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
    for r in $($CTR -n "$ns" images ls -q 2>/dev/null | grep graphql || true); do
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
    if $CTR -n "$ns" images ls -q 2>/dev/null | grep -q graphql; then fail "could not remove the image from namespace $ns before the pull"; fi
done
BLOBS="$LIB_BASE/containerd/io.containerd.content.v1.content/blobs/sha256"
for k in manifest config layer; do
    H=$(jget $k); H=${H#sha256:}
    for _ in $(seq 1 30); do sudo test -e "$BLOBS/$H" || break; sleep 1; done
    if sudo test -e "$BLOBS/$H"; then fail "the $k blob is still on the disk of containerd: a pull would reuse it"; fi
done

mkdir -p "$ODIR/logs"
P0=$(sudo wc -l < "$REG_DIR/requests.log")

echo "[oracle] check 3: 'crictl pull $IMAGE_REF' (no flag, the name the cluster uses) must now succeed..."
if ! "${CRI[@]}" pull "$IMAGE_REF" > "$ODIR/pull_out.txt" 2> "$ODIR/pull_err.txt"; then
    tail -2 "$ODIR/pull_err.txt" | cut -c1-300
    fail "the pull through the CRI failed"
fi
echo "  -> OK"

echo "[oracle] check 4: the image that arrived is the one the registry holds (same manifest digest)..."
D=$(sudo cat "$STATE_DIR/manifest.digest")
"${CRI[@]}" inspecti -o json "$IMAGE_REF" > "$ODIR/image.json" 2>/dev/null || fail "crictl inspecti failed"
python3 - "$ODIR/image.json" "$D" <<'PY' || fail "the pulled image has not the digest of the image the registry holds"
import json, sys
st = json.load(open(sys.argv[1])).get("status", {})
digests = st.get("repoDigests", [])
sys.exit(0 if any(d.endswith("@" + sys.argv[2]) for d in digests) else 1)
PY
echo "  -> OK ($D)"

echo "[oracle] check 5: the registry's request log shows containerd fetching the manifest and the blobs..."
sudo tail -n +"$((P0 + 1))" "$REG_DIR/requests.log" > "$ODIR/registry_new.log"
sed 's/^/     /' "$ODIR/registry_new.log" | cut -c1-200
python3 - "$ODIR/registry_new.log" "$REPO" "$TAG" "$REG_USER" "$(jget layer)" "$(jget config)" <<'PY' || fail "the registry log lacks the authenticated manifest or blob requests of containerd"
import re, sys
log, repo, tag, user, layer, config = sys.argv[1:7]
lines = [l.rstrip("\n") for l in open(log)]
def seen(method_re, path):
    return any(re.match(r"^(%s) %s(\?\S*)? 200 ua=containerd/.* auth=ok:%s$" % (method_re, re.escape(path), re.escape(user)), l) for l in lines)
ok = seen("GET|HEAD", "/v2/%s/manifests/%s" % (repo, tag))
ok = ok and seen("GET", "/v2/%s/blobs/%s" % (repo, layer))
ok = ok and seen("GET", "/v2/%s/blobs/%s" % (repo, config))
sys.exit(0 if ok else 1)
PY
echo "  -> OK"

echo "[oracle] check 6: a pod runs that image through the CRI and prints the per-run token baked into it..."
TOKEN=$(sudo cat "$STATE_DIR/token")
cat > "$ODIR/pod.json" <<CONF
{
  "metadata": {"name": "bench72298729-pod", "namespace": "default", "attempt": 1, "uid": "bench72298729-uid"},
  "log_directory": "$ODIR/logs",
  "linux": {"security_context": {"namespace_options": {"network": 2}}}
}
CONF
cat > "$ODIR/container.json" <<CONF
{
  "metadata": {"name": "bench72298729-ctr"},
  "image": {"image": "$IMAGE_REF"},
  "log_path": "ctr.log"
}
CONF
POD_ID=$("${CRI[@]}" runp "$ODIR/pod.json" 2> "$ODIR/runp_err.txt") || { tail -2 "$ODIR/runp_err.txt" | cut -c1-300; fail "crictl runp failed"; }
CTR_ID=$("${CRI[@]}" create "$POD_ID" "$ODIR/container.json" "$ODIR/pod.json" 2> "$ODIR/create_err.txt") || { tail -2 "$ODIR/create_err.txt" | cut -c1-300; fail "crictl create failed"; }
"${CRI[@]}" start "$CTR_ID" >/dev/null 2> "$ODIR/start_err.txt" || { tail -2 "$ODIR/start_err.txt" | cut -c1-300; fail "crictl start failed"; }
GOT=""
for _ in $(seq 1 30); do
    GOT=$("${CRI[@]}" logs "$CTR_ID" 2>/dev/null | grep -F "bench72298729-graphql-ok token=$TOKEN" | head -1 || true)
    [ -n "$GOT" ] && break
    sleep 1
done
[ -n "$GOT" ] || fail "the container did not print the token of the image (state: $("${CRI[@]}" inspect -o json "$CTR_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])' 2>/dev/null))"
CSTATE=$("${CRI[@]}" inspect -o json "$CTR_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])')
[ "$CSTATE" = "CONTAINER_RUNNING" ] || fail "container state is $CSTATE"
echo "  -> OK ($GOT)"

echo "[oracle] check 7: and the registry still requires authentication after all this (same controls as check 2)..."
registry_still_private || fail "the registry does not behave as a private registry any more"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
